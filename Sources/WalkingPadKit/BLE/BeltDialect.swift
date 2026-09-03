import CoreBluetooth
import Foundation

/// One GATT write the controller should perform.
public struct BeltWrite: Equatable {
    public let characteristic: CBUUID
    public let bytes: [UInt8]
    /// Largest write the firmware accepts at once; longer payloads go out in pieces, in order.
    public let chunkSize: Int?
    /// Prefer a GATT Write Command. The Swift SDK writes the KingSmith vendor channel this way;
    /// some firmware accepts the write at ATT level but only acts on commands, not requests.
    public let withoutResponse: Bool
    public init(characteristic: CBUUID, bytes: [UInt8], chunkSize: Int? = nil, withoutResponse: Bool = false) {
        self.characteristic = characteristic
        self.bytes = bytes
        self.chunkSize = chunkSize
        self.withoutResponse = withoutResponse
    }

    /// The pieces to write, honouring `chunkSize`.
    public var pieces: [[UInt8]] {
        guard let chunkSize, chunkSize > 0, bytes.count > chunkSize else { return [bytes] }
        return stride(from: 0, to: bytes.count, by: chunkSize).map { Array(bytes[$0..<min($0 + chunkSize, bytes.count)]) }
    }
}

/// Something the belt told us, translated out of its own wire format.
public enum BeltEvent: Equatable {
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
    /// The dialect wants these written now, in order, this far apart — a handshake reply that
    /// calls for the next step, for instance. Not a user command, so it bypasses the command queue.
    case send([BeltWrite], spacing: TimeInterval)
    /// The dialect's reply-driven bring-up is finished (or there was none to do).
    case handshakeComplete
}

/// A step of the link bring-up, run in order once every characteristic has been discovered.
public enum BeltSetupStep: Equatable {
    /// Turn notifications on, then wait `pauseAfter` seconds before the next step.
    case subscribe(CBUUID, pauseAfter: TimeInterval)
    case read(CBUUID)
    case write(BeltWrite)
    /// Hand over to the dialect's reply-driven bring-up (`beginHandshake`), for at most `budget`.
    case handshake(budget: TimeInterval)
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
    /// Characteristics to discover on one service; nil means all of them.
    func characteristicUUIDs(for service: CBUUID) -> [CBUUID]?
    /// Told what the belt actually exposes, before bring-up starts.
    func didDiscover(characteristics: Set<CBUUID>)
    /// Start the reply-driven part of bring-up. Returns what to do first — writes to make, or
    /// `.handshakeComplete` straight away when this belt needs none.
    func beginHandshake(now: Date) -> [BeltEvent]
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
    func characteristicUUIDs(for service: CBUUID) -> [CBUUID]? { characteristicUUIDs }
    func didDiscover(characteristics: Set<CBUUID>) {}
    func beginHandshake(now: Date) -> [BeltEvent] { [.handshakeComplete] }

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
    /// The second pair on the same service: KingSmith's obfuscated text protocol (see `KSText`).
    public static let textNotifyUUID = CBUUID(string: KSText.notifyUUID)
    public static let textWriteUUID = CBUUID(string: KSText.writeUUID)

    private var assembler = FTMS.StatusAssembler()
    /// The firmware replays its last event the moment notifications are enabled — usually a
    /// stale "stopped" from before we connected. Not news, so it is not logged.
    private var sawFirstMachineEvent = false
    /// Treadmill Data frames the parser could not read are logged, a few per connection, so a
    /// belt speaking an unexpected layout shows up in the log instead of as silence.
    private var unparsedFramesLogged = 0

    /// The text protocol, when the belt has a notify/write pair for it. Dedicated `…0E00`/`…0F00`
    /// is preferred; firmware that never grew that pair is driven on the supplement `…0B00`/`…0D00`.
    private var hasTextChannel = false
    private var hasDedicatedTextPair = false
    private var textNotify = FTMSDialect.textNotifyUUID
    private var textWrite = FTMSDialect.textWriteUUID
    private var handshake = KSText.Handshake()
    /// Whether commands and status go over the text channel. Set once the handshake completes.
    public private(set) var usesTextProtocol = false
    /// A `WLR` report arrived on the vendor notify characteristic. Status is then polled there.
    public private(set) var usesVendorStatus = false
    private var textBuffer: [UInt8] = []
    private var textAssembler = KSText.StatusAssembler()

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
    /// FTMS pushes status; the text protocol and the vendor `WLR` report have to be asked.
    public var pollsForStatus: Bool { usesTextProtocol || usesVendorStatus }
    public var holdsSpeedUntilBeltMoves: Bool { true }

    /// Every characteristic of the vendor service is discovered, because which pairs it carries
    /// is exactly what decides how this belt can be driven.
    public func characteristicUUIDs(for service: CBUUID) -> [CBUUID]? {
        service == FTMSDialect.supplementServiceUUID ? nil : characteristicUUIDs
    }

    public func didDiscover(characteristics: Set<CBUUID>) {
        hasDedicatedTextPair = characteristics.contains(FTMSDialect.textNotifyUUID)
            && characteristics.contains(FTMSDialect.textWriteUUID)
        if hasDedicatedTextPair {
            hasTextChannel = true
            textNotify = FTMSDialect.textNotifyUUID
            textWrite = FTMSDialect.textWriteUUID
        } else if characteristics.contains(FTMSDialect.supplementNotifyUUID)
                    && characteristics.contains(FTMSDialect.supplementWriteUUID) {
            // V0.0.6 confirmed `…0B00`/`…0D00` and never listed the v6 pair. The text protocol
            // may live on this pair; binary wake/query on it drew no reply.
            hasTextChannel = true
            textNotify = FTMSDialect.supplementNotifyUUID
            textWrite = FTMSDialect.supplementWriteUUID
        }
    }

    public func beginHandshake(now: Date) -> [BeltEvent] {
        guard hasTextChannel else { return [.handshakeComplete] }
        handshake = KSText.Handshake()
        let note = hasDedicatedTextPair
            ? "KingSmith text channel present — starting its handshake"
            : "No v6 text pair — trying the handshake on the supplement channel"
        return [.note(note, isWarning: false)] + handshakeWrites(now: now)
    }

    /// The current handshake step, in every spelling still possible, as chunked writes.
    private func handshakeWrites(now: Date) -> [BeltEvent] {
        let writes = handshake.payloads(now: now).map {
            BeltWrite(characteristic: textWrite, bytes: $0, chunkSize: KSText.chunkSize, withoutResponse: true)
        }
        guard !writes.isEmpty else { return [] }
        return [.send(writes, spacing: KSText.handshakeSpacing)]
    }

    /// A text command, encoded with the belt's table (or the likeliest one), chunked.
    private func textCommand(_ command: String) -> BeltWrite {
        let table = handshake.table ?? handshake.candidates.first ?? KSText.tables[0]
        return BeltWrite(characteristic: textWrite, bytes: KSText.encode(command, table: table),
                         chunkSize: KSText.chunkSize, withoutResponse: true)
    }

    /// A vendor-channel write. The Swift SDK uses Write Command on this characteristic.
    private static func supplementWrite(_ bytes: [UInt8]) -> BeltWrite {
        BeltWrite(characteristic: FTMSDialect.supplementWriteUUID, bytes: bytes, withoutResponse: true)
    }

    /// The firmware silently drops notification enables that land within ~30 ms of each other,
    /// so the subscriptions are staggered the way the vendor app does it (100 / 200 / 300 ms).
    /// Control is then requested once; some firmware rejects the request yet honours the
    /// commands that follow, so the reply is logged but not acted on.
    ///
    /// On `KS-HD-*` belts the Swift SDK identifies the model and syncs a timestamp on the
    /// vendor channel before it queries, and writes that channel without a GATT response.
    /// Wake-only was accepted by a V0.0.6 Z1F and changed nothing; the init frames are what
    /// it never saw. Steps whose characteristic the belt lacks are skipped by the controller.
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
            .write(FTMSDialect.supplementWrite(FTMS.Supplement.initDeviceBytes)),
            .write(FTMSDialect.supplementWrite(FTMS.Supplement.initTimestampBytes())),
            .write(FTMSDialect.wake),
            .write(FTMSDialect.supplementWrite(FTMS.Supplement.queryStatusBytes)),
            .subscribe(FTMSDialect.textNotifyUUID, pauseAfter: 0.3),
            .handshake(budget: hasDedicatedTextPair ? 10 : 4),
            .write(BeltWrite(characteristic: FTMSDialect.controlPointUUID, bytes: FTMS.requestControlBytes)),
        ]
    }

    /// The vendor wake frame. Harmless on a belt that is already awake.
    public static let wake = BeltWrite(
        characteristic: FTMSDialect.supplementWriteUUID, bytes: FTMS.Supplement.wakeBytes, withoutResponse: true
    )

    /// A start may come long after connecting, and the belt may have dozed off again in between,
    /// so it is woken once more right before. Speed and stop are left alone: a belt that is
    /// moving is awake by definition, and a stop must not be delayed by anything.
    public func preamble(for command: PadCommand) -> BeltWrite? {
        guard !usesTextProtocol else { return nil }
        switch command {
        case .start: return FTMSDialect.wake
        default: return nil
        }
    }

    public func encode(_ command: PadCommand) -> BeltWrite? {
        if usesTextProtocol {
            switch command {
            case .askStats: return textCommand(KSText.pollStatus)
            case .start: return textCommand(KSText.start)
            case .setSpeed(0): return textCommand(KSText.stop)
            case .setSpeed(let raw): return textCommand(KSText.setSpeed(raw: raw))
            case .setMode(let mode): return textCommand(KSText.setMode(mode))
            case .askHistory, .setPreference: return nil
            }
        }
        if usesVendorStatus, case .askStats = command {
            return FTMSDialect.supplementWrite(FTMS.Supplement.queryStatusBytes)
        }
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
            if let status = FTMS.Supplement.parseStatus(bytes, now: now) {
                usesVendorStatus = true
                return [.status(status), .note(FTMS.Supplement.describe(bytes), isWarning: false)]
            }
            if textNotify == FTMSDialect.supplementNotifyUUID {
                return decodeText(bytes, now: now)
            }
            return [.note(FTMS.Supplement.describe(bytes), isWarning: false)]

        case FTMSDialect.textNotifyUUID:
            return decodeText(bytes, now: now)

        default:
            return [.unknown(bytes)]
        }
    }

    /// Replies arrive in pieces and end with a carriage return.
    private func decodeText(_ bytes: [UInt8], now: Date) -> [BeltEvent] {
        textBuffer += bytes
        guard textBuffer.last == KSText.terminator else { return [] }
        let packet = textBuffer
        textBuffer.removeAll()
        let wasComplete = handshake.isComplete
        guard let text = handshake.receive(packet) else {
            return [.note("KS text reply not decodable: " + packet.map { String(format: "%02x", $0) }.joined(separator: " "),
                          isWarning: true)]
        }
        var events: [BeltEvent] = [.note("KS: \(text.isEmpty ? "(empty)" : text)", isWarning: false)]
        if let props = KSText.parseProps(text), let status = textAssembler.apply(props, raw: packet, now: now) {
            events.append(.status(status))
        }
        if handshake.isComplete, !wasComplete {
            usesTextProtocol = true
            let table = handshake.table.map { "table \(KSText.tables.firstIndex(of: $0).map { $0 + 1 } ?? 0)" } ?? "table undecided"
            events.append(.note("KingSmith text handshake complete (\(table)) — driving the belt over it", isWarning: false))
            events.append(.handshakeComplete)
        } else if !handshake.isComplete {
            events += handshakeWrites(now: now)
        }
        return events
    }

    public func resetConnectionState() {
        assembler = FTMS.StatusAssembler()
        sawFirstMachineEvent = false
        unparsedFramesLogged = 0
        hasTextChannel = false
        hasDedicatedTextPair = false
        textNotify = FTMSDialect.textNotifyUUID
        textWrite = FTMSDialect.textWriteUUID
        handshake = KSText.Handshake()
        usesTextProtocol = false
        usesVendorStatus = false
        textBuffer.removeAll()
        textAssembler = KSText.StatusAssembler()
    }
}
