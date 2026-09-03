import CoreBluetooth
import Foundation

/// One GATT write the controller should perform.
public struct BeltWrite: Equatable {
    public let characteristic: CBUUID
    public let bytes: [UInt8]
    public init(characteristic: CBUUID, bytes: [UInt8]) {
        self.characteristic = characteristic
        self.bytes = bytes
    }
}

/// Something the belt told us, translated out of its own wire format.
public enum BeltEvent: Equatable, Sendable {
    case status(PadStatus)
    case record(PadRecord)
    /// The belt acknowledged a target speed, in the app's 0.1 km/h units.
    case speedAccepted(UInt8)
    /// The belt accepted a speed command without saying which speed (an FTMS result code).
    case speedCommandAccepted
    /// The belt reported its speed limits.
    case speedRange(FTMS.SpeedRange)
    /// Worth a line in the event log, nothing more.
    case note(String, isWarning: Bool)
    case unknown([UInt8])
}

/// A step of the link bring-up, run in order once every characteristic has been discovered.
public enum BeltSetupStep: Equatable {
    /// Turn notifications on, then wait `pauseAfter` seconds before the next step.
    case subscribe(CBUUID, pauseAfter: TimeInterval)
    case read(CBUUID)
    case write(BeltWrite)
}

/// Everything protocol-specific the controller needs, so `PadController` itself only knows about
/// scanning, connecting, deadlines and the command queue.
///
/// Dialects are classes because a decoder may need to keep state between notifications.
public protocol BeltDialect: AnyObject {
    var family: PadFamily { get }
    /// Service UUIDs to filter the scan on.
    var scanServiceUUIDs: [CBUUID] { get }
    /// Services to discover after connecting, and the characteristics wanted from each.
    var serviceUUIDs: [CBUUID] { get }
    var characteristicUUIDs: [CBUUID] { get }
    /// Characteristics without which the belt cannot be driven.
    var requiredCharacteristicUUIDs: [CBUUID] { get }
    /// Lower-cased fragments a belt's advertised name may contain (the name-matching fallback scan).
    var nameFragments: [String] { get }
    /// Whether status has to be asked for; FTMS belts push it unprompted.
    var pollsForStatus: Bool { get }
    /// FTMS firmware crashes the link if a speed target arrives while the motor is spinning up,
    /// so a speed is held back until the belt reports movement.
    var holdsSpeedUntilBeltMoves: Bool { get }
    var setupSteps: [BeltSetupStep] { get }

    /// The write that realises a command, or nil when this belt has no such command.
    func encode(_ command: PadCommand) -> BeltWrite?
    /// A vendor frame to write immediately before a command, where the firmware wants one.
    func preamble(for command: PadCommand) -> BeltWrite?
    /// Translate a notification or read result.
    func decode(characteristic: CBUUID, bytes: [UInt8], now: Date) -> [BeltEvent]
    /// Forget per-connection decoder state.
    func resetConnectionState()
}

public extension BeltDialect {
    func preamble(for command: PadCommand) -> BeltWrite? { nil }

    /// Whether a name seen during a broad scan is plausibly this family of belt.
    func looksLikeBelt(name: String?) -> Bool {
        guard let name = name?.lowercased() else { return false }
        return nameFragments.contains { name.contains($0) }
    }

    /// Drops the members of a command sequence this belt cannot act on, keeping the rest in order.
    func supported(_ commands: [PadCommand]) -> [PadCommand] {
        commands.filter { encode($0) != nil }
    }
}

/// Whether a dequeued command must wait for the belt to be moving before it is written.
public enum SpeedGate {
    public static func shouldHold(_ command: PadCommand, beltIsMoving: Bool, dialectHolds: Bool) -> Bool {
        guard dialectHolds, case .setSpeed(let raw) = command, raw > 0 else { return false }
        return !beltIsMoving
    }
}

public func makeDialect(for family: PadFamily) -> BeltDialect {
    switch family {
    case .classic: return ClassicDialect()
    case .ftms: return FTMSDialect()
    }
}

// MARK: - Classic (WiLink, service FE00)

/// KingSmith's original protocol: `F7 … FD` frames on FE02, `F8 …` notifications on FE01.
public final class ClassicDialect: BeltDialect {
    public static let serviceUUID = CBUUID(string: "0000FE00-0000-1000-8000-00805F9B34FB")
    public static let notifyUUID = CBUUID(string: "0000FE01-0000-1000-8000-00805F9B34FB")
    public static let writeUUID = CBUUID(string: "0000FE02-0000-1000-8000-00805F9B34FB")

    public init() {}

    public var family: PadFamily { .classic }
    public var scanServiceUUIDs: [CBUUID] { [ClassicDialect.serviceUUID] }
    public var serviceUUIDs: [CBUUID] { [ClassicDialect.serviceUUID] }
    public var characteristicUUIDs: [CBUUID] { [ClassicDialect.notifyUUID, ClassicDialect.writeUUID] }
    public var requiredCharacteristicUUIDs: [CBUUID] { [ClassicDialect.writeUUID] }
    public var nameFragments: [String] { ["walkingpad", "kingsmith", "ksmith", "ks-r1", "ks-x21", "r1 pro", "r1pro"] }
    public var pollsForStatus: Bool { true }
    public var holdsSpeedUntilBeltMoves: Bool { false }
    public var setupSteps: [BeltSetupStep] { [.subscribe(ClassicDialect.notifyUUID, pauseAfter: 0)] }

    public func encode(_ command: PadCommand) -> BeltWrite? {
        BeltWrite(characteristic: ClassicDialect.writeUUID, bytes: command.bytes)
    }

    public func decode(characteristic: CBUUID, bytes: [UInt8], now: Date) -> [BeltEvent] {
        switch PadFrame(data: bytes, now: now) {
        case .status(let s): return [.status(s)]
        case .record(let r): return [.record(r)]
        case .unknown(let b): return [.unknown(b)]
        }
    }

    public func resetConnectionState() {}
}

// MARK: - FTMS (Z1 generation, service 1826)

/// The Bluetooth SIG Fitness Machine Service, as the KingSmith Z1 / Z1F implement it.
public final class FTMSDialect: BeltDialect {
    public static let serviceUUID = CBUUID(string: String(format: "%04X", FTMS.serviceUUID16))
    public static let treadmillDataUUID = CBUUID(string: String(format: "%04X", FTMS.treadmillDataUUID16))
    public static let speedRangeUUID = CBUUID(string: String(format: "%04X", FTMS.supportedSpeedRangeUUID16))
    public static let controlPointUUID = CBUUID(string: String(format: "%04X", FTMS.controlPointUUID16))
    public static let machineStatusUUID = CBUUID(string: String(format: "%04X", FTMS.machineStatusUUID16))
    public static let featureUUID = CBUUID(string: String(format: "%04X", FTMS.featureUUID16))
    public static let trainingStatusUUID = CBUUID(string: String(format: "%04X", FTMS.trainingStatusUUID16))
    public static let deviceInformationServiceUUID = CBUUID(string: String(format: "%04X", FTMS.deviceInformationServiceUUID16))
    public static let softwareRevisionUUID = CBUUID(string: String(format: "%04X", FTMS.softwareRevisionUUID16))
    /// KingSmith's vendor "supplement" service on `KS-HD-*` belts (Z1, Z1F).
    public static let supplementServiceUUID = CBUUID(string: FTMS.Supplement.serviceUUID)
    public static let supplementNotifyUUID = CBUUID(string: FTMS.Supplement.notifyUUID)
    public static let supplementWriteUUID = CBUUID(string: FTMS.Supplement.writeUUID)

    private var assembler = FTMS.StatusAssembler()
    /// The firmware replays its last event the moment notifications are enabled — usually a
    /// stale "stopped" from before we connected. Not news, so it is not logged.
    private var sawFirstMachineEvent = false
    /// Treadmill Data frames the parser could not read are logged, a few per connection, so a
    /// belt speaking an unexpected layout shows up in the log instead of as silence.
    private var unparsedFramesLogged = 0

    public init() {}

    public var family: PadFamily { .ftms }
    public var scanServiceUUIDs: [CBUUID] { [FTMSDialect.serviceUUID] }
    public var serviceUUIDs: [CBUUID] {
        [FTMSDialect.serviceUUID, FTMSDialect.supplementServiceUUID, FTMSDialect.deviceInformationServiceUUID]
    }
    public var characteristicUUIDs: [CBUUID] {
        [FTMSDialect.treadmillDataUUID, FTMSDialect.speedRangeUUID, FTMSDialect.featureUUID,
         FTMSDialect.controlPointUUID, FTMSDialect.machineStatusUUID, FTMSDialect.trainingStatusUUID,
         FTMSDialect.supplementNotifyUUID, FTMSDialect.supplementWriteUUID,
         FTMSDialect.softwareRevisionUUID]
    }
    public var requiredCharacteristicUUIDs: [CBUUID] {
        [FTMSDialect.controlPointUUID, FTMSDialect.treadmillDataUUID]
    }
    public var nameFragments: [String] {
        ["ks-hd", "ks-mc21", "ks-smc21c", "zp-zealr1", "walkingpad", "kingsmith", "z1"]
    }
    public var pollsForStatus: Bool { false }
    public var holdsSpeedUntilBeltMoves: Bool { true }

    /// The firmware silently drops notification enables that land within ~30 ms of each other,
    /// so the subscriptions are staggered the way the vendor app does it (100 / 200 / 300 ms).
    /// Control is then requested once; some firmware rejects the request yet honours the
    /// commands that follow, so the reply is logged but not acted on.
    ///
    /// On `KS-HD-*` belts the vendor app also asks the supplement service for the belt's property
    /// list before it touches the Control Point, and the firmware treats that as the handshake
    /// that unlocks control: a Z1F never answers a Control Point command without it. Steps whose
    /// characteristic the belt lacks are skipped by the controller, so this is harmless elsewhere.
    ///
    /// The order follows the vendor app's connection sequence as decompiled: capability reads,
    /// then the FTMS subscriptions, then the supplement channel, then device info, then the
    /// handshake, then request control.
    public var setupSteps: [BeltSetupStep] {
        [
            .read(FTMSDialect.featureUUID),
            .read(FTMSDialect.speedRangeUUID),
            .subscribe(FTMSDialect.machineStatusUUID, pauseAfter: 0.1),
            .subscribe(FTMSDialect.trainingStatusUUID, pauseAfter: 0.2),
            .subscribe(FTMSDialect.controlPointUUID, pauseAfter: 0.3),
            .subscribe(FTMSDialect.treadmillDataUUID, pauseAfter: 0.3),
            .subscribe(FTMSDialect.supplementNotifyUUID, pauseAfter: 0.3),
            .read(FTMSDialect.softwareRevisionUUID),
            .write(FTMSDialect.handshake),
            .write(BeltWrite(characteristic: FTMSDialect.supplementWriteUUID, bytes: FTMS.Supplement.propertyListBareBytes)),
            .write(BeltWrite(characteristic: FTMSDialect.controlPointUUID, bytes: FTMS.requestControlBytes)),
        ]
    }

    /// The property-list request the vendor app sends before every Control Point command.
    public static let handshake = BeltWrite(
        characteristic: FTMSDialect.supplementWriteUUID, bytes: FTMS.Supplement.propertyListBytes
    )

    /// Re-sent before each command, exactly as the vendor app does. Whether once at connect
    /// would suffice is unknown; matching the app is the conservative choice.
    public func preamble(for command: PadCommand) -> BeltWrite? {
        switch command {
        case .start, .setSpeed: return FTMSDialect.handshake
        default: return nil
        }
    }

    public func encode(_ command: PadCommand) -> BeltWrite? {
        let cp = FTMSDialect.controlPointUUID
        switch command {
        case .start:
            return BeltWrite(characteristic: cp, bytes: FTMS.startBytes)
        case .setSpeed(0):
            return BeltWrite(characteristic: cp, bytes: FTMS.stopBytes)
        case .setSpeed(let raw):
            return BeltWrite(characteristic: cp, bytes: FTMS.setSpeedBytes(raw: raw))
        case .askStats, .askHistory, .setMode, .setPreference:
            // Status is pushed; there is no mode byte, no stored-session query and no
            // preference channel in the standard service.
            return nil
        }
    }

    public func decode(characteristic: CBUUID, bytes: [UInt8], now: Date) -> [BeltEvent] {
        switch characteristic {
        case FTMSDialect.treadmillDataUUID:
            if let status = assembler.ingest(bytes, now: now) { return [.status(status)] }
            guard unparsedFramesLogged < 3 else { return [] }
            unparsedFramesLogged += 1
            return [.note("Unreadable treadmill data frame: " + bytes.map { String(format: "%02x", $0) }.joined(separator: " "),
                          isWarning: true)]

        case FTMSDialect.trainingStatusUUID:
            guard bytes.count >= 2 else { return [.unknown(bytes)] }
            return [.note("Training status: \(FTMS.trainingStatusLabel(bytes[1]))", isWarning: false)]

        case FTMSDialect.featureUUID:
            guard bytes.count >= 8 else { return [.unknown(bytes)] }
            let machine = bytes[0..<4].reversed().map { String(format: "%02x", $0) }.joined()
            let target = bytes[4..<8].reversed().map { String(format: "%02x", $0) }.joined()
            return [.note("Machine features 0x\(machine), target features 0x\(target)", isWarning: false)]

        case FTMSDialect.softwareRevisionUUID:
            let text = String(decoding: bytes.filter { $0 != 0 }, as: UTF8.self)
            return [.note("Belt firmware: \(text.isEmpty ? "unknown" : text)", isWarning: false)]

        case FTMSDialect.machineStatusUUID:
            guard let event = FTMS.MachineEvent(bytes: bytes) else { return [.unknown(bytes)] }
            let isReplay = !sawFirstMachineEvent
            sawFirstMachineEvent = true
            switch event {
            case .targetSpeedChanged(let hundredths):
                assembler.noteTargetSpeed(hundredths: hundredths)
                return [.speedAccepted(FTMS.tenths(fromHundredths: hundredths)),
                        .note(event.description, isWarning: false)]
            case .stoppedBySafetyKey:
                return [.note(event.description, isWarning: true)]
            default:
                return isReplay ? [] : [.note(event.description, isWarning: false)]
            }

        case FTMSDialect.controlPointUUID:
            guard let response = FTMS.Response(bytes: bytes) else { return [.unknown(bytes)] }
            var events: [BeltEvent] = []
            if response.isSuccess, response.opcode == .setTargetSpeed {
                events.append(.speedCommandAccepted)
            }
            // A refused "request control" is routine on this firmware and the belt still obeys.
            let routine = response.opcode == .requestControl
            events.append(.note(response.description, isWarning: !response.isSuccess && !routine))
            return events

        case FTMSDialect.speedRangeUUID:
            guard let range = FTMS.SpeedRange(bytes: bytes) else { return [.unknown(bytes)] }
            return [.speedRange(range), .note(range.description, isWarning: false)]

        case FTMSDialect.supplementNotifyUUID:
            // Not decoded yet — but every reply lands in the log, which is how the handshake
            // gets understood once a real belt has answered it.
            return [.note("Supplement reply: " + bytes.map { String(format: "%02x", $0) }.joined(separator: " "),
                          isWarning: false)]

        default:
            return [.unknown(bytes)]
        }
    }

    public func resetConnectionState() {
        assembler = FTMS.StatusAssembler()
        sawFirstMachineEvent = false
        unparsedFramesLogged = 0
    }
}
