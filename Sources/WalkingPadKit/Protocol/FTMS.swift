import Foundation

/// Bluetooth SIG Fitness Machine Service (FTMS), as spoken by the KingSmith Z1 generation.
///
/// Everything here is pure encode/decode with no CoreBluetooth, so it runs under
/// `padctl selftest`. Byte layouts follow the FTMS specification; the KingSmith specifics
/// (step-count extension, which events the firmware actually emits) come from
/// mcdax/walkingpad-controller's reverse engineering of the KS Fit app.
public enum FTMS {
    // MARK: Service and characteristics (16-bit SIG UUIDs)

    public static let serviceUUID16: UInt16 = 0x1826
    /// Notify: live speed / distance / time / steps.
    public static let treadmillDataUUID16: UInt16 = 0x2ACD
    /// Read: min / max / increment, each uint16 in 0.01 km/h.
    public static let supportedSpeedRangeUUID16: UInt16 = 0x2AD4
    /// Write + indicate: commands and their result codes.
    public static let controlPointUUID16: UInt16 = 0x2AD9
    /// Notify: started / stopped / target changed events.
    public static let machineStatusUUID16: UInt16 = 0x2ADA

    // MARK: Control Point opcodes

    public enum Opcode: UInt8, Sendable {
        case requestControl = 0x00
        case reset = 0x01
        case setTargetSpeed = 0x02
        case startOrResume = 0x07
        case stopOrPause = 0x08
        case response = 0x80

        public var label: String {
            switch self {
            case .requestControl: return "request control"
            case .reset: return "reset"
            case .setTargetSpeed: return "set speed"
            case .startOrResume: return "start"
            case .stopOrPause: return "stop"
            case .response: return "response"
            }
        }
    }

    public enum ResultCode: UInt8, Sendable {
        case success = 0x01
        case opcodeNotSupported = 0x02
        case invalidParameter = 0x03
        case operationFailed = 0x04
        case controlNotPermitted = 0x05

        public var label: String {
            switch self {
            case .success: return "ok"
            case .opcodeNotSupported: return "not supported"
            case .invalidParameter: return "invalid parameter (outside the belt's speed range?)"
            case .operationFailed: return "failed"
            case .controlNotPermitted: return "control not permitted"
            }
        }
    }

    // MARK: Command encoding

    public static let requestControlBytes: [UInt8] = [Opcode.requestControl.rawValue]
    public static let startBytes: [UInt8] = [Opcode.startOrResume.rawValue]
    /// Stop (parameter 1). Pause (2) keeps the session counters, but "Stop" in this app means stop.
    public static let stopBytes: [UInt8] = [Opcode.stopOrPause.rawValue, 0x01]

    /// `SET_TARGET_SPEED` with the speed in 0.01 km/h, little-endian.
    ///
    /// Takes the app's 0.1 km/h integer so the conversion is exact: ×10, never through a Double.
    public static func setSpeedBytes(raw tenths: UInt8) -> [UInt8] {
        let hundredths = UInt16(tenths) * 10
        return [Opcode.setTargetSpeed.rawValue, UInt8(hundredths & 0xFF), UInt8(hundredths >> 8)]
    }

    // MARK: Unit conversion

    /// 0.01 km/h → the app's 0.1 km/h grid, rounding half up, clamped to a byte.
    public static func tenths(fromHundredths value: UInt16) -> UInt8 {
        UInt8(min(255, (Int(value) + 5) / 10))
    }

    /// 0.01 km/h → the classic protocol's "app speed" unit of 1/30 km/h.
    public static func thirtieths(fromHundredths value: UInt16) -> UInt8 {
        UInt8(min(255, (Int(value) * 3 + 5) / 10))
    }

    static func uint16LE(_ bytes: ArraySlice<UInt8>) -> UInt16? {
        guard bytes.count >= 2 else { return nil }
        let b = Array(bytes.prefix(2))
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }

    static func uint24LE(_ bytes: ArraySlice<UInt8>) -> Int? {
        guard bytes.count >= 3 else { return nil }
        let b = Array(bytes.prefix(3))
        return Int(b[0]) | (Int(b[1]) << 8) | (Int(b[2]) << 16)
    }

    // MARK: Treadmill Data (0x2ACD)

    /// One Treadmill Data notification, decoded field by field.
    ///
    /// The flags word says which optional fields follow; the order is fixed by the spec. When the
    /// "More Data" bit is set the packet is one part of a multi-packet update and carries no
    /// instantaneous speed — `StatusAssembler` stitches the parts together.
    public struct TreadmillData: Equatable, Sendable {
        public var moreData: Bool
        /// 0.01 km/h. Absent on a "more data" continuation packet.
        public var speedHundredths: UInt16?
        public var totalDistanceMetres: Int?
        public var elapsedSeconds: Int?
        public var totalKcal: Int?
        public var heartRate: Int?
        /// KingSmith extension (flag bit 13): pressure-sensor step count.
        public var steps: Int?

        public struct Flags: OptionSet, Sendable {
            public let rawValue: UInt16
            public init(rawValue: UInt16) { self.rawValue = rawValue }
            public static let moreData = Flags(rawValue: 1 << 0)
            public static let averageSpeed = Flags(rawValue: 1 << 1)
            public static let totalDistance = Flags(rawValue: 1 << 2)
            public static let inclination = Flags(rawValue: 1 << 3)
            public static let elevationGain = Flags(rawValue: 1 << 4)
            public static let instantaneousPace = Flags(rawValue: 1 << 5)
            public static let averagePace = Flags(rawValue: 1 << 6)
            public static let expendedEnergy = Flags(rawValue: 1 << 7)
            public static let heartRate = Flags(rawValue: 1 << 8)
            public static let metabolicEquivalent = Flags(rawValue: 1 << 9)
            public static let elapsedTime = Flags(rawValue: 1 << 10)
            public static let remainingTime = Flags(rawValue: 1 << 11)
            public static let forceOnBelt = Flags(rawValue: 1 << 12)
            public static let kingSmithSteps = Flags(rawValue: 1 << 13)
        }

        public init?(bytes: [UInt8]) {
            guard let flagsRaw = FTMS.uint16LE(bytes[0...]) else { return nil }
            let flags = Flags(rawValue: flagsRaw)
            var offset = 2
            moreData = flags.contains(.moreData)

            /// Reads `count` bytes if they are all present; a truncated tail ends parsing quietly
            /// rather than tripping over the end of the packet.
            func take(_ count: Int) -> ArraySlice<UInt8>? {
                guard offset + count <= bytes.count else { return nil }
                defer { offset += count }
                return bytes[offset..<(offset + count)]
            }

            if !moreData {
                guard let speed = take(2) else { return nil }
                speedHundredths = FTMS.uint16LE(speed)
            }
            if flags.contains(.averageSpeed) { _ = take(2) }
            if flags.contains(.totalDistance), let d = take(3) { totalDistanceMetres = FTMS.uint24LE(d) }
            if flags.contains(.inclination) { _ = take(4) }
            if flags.contains(.elevationGain) { _ = take(4) }
            if flags.contains(.instantaneousPace) { _ = take(1) }
            if flags.contains(.averagePace) { _ = take(1) }
            if flags.contains(.expendedEnergy), let e = take(5) {
                totalKcal = FTMS.uint16LE(e).map(Int.init)
            }
            if flags.contains(.heartRate), let h = take(1) { heartRate = Int(h.first ?? 0) }
            if flags.contains(.metabolicEquivalent) { _ = take(1) }
            if flags.contains(.elapsedTime), let t = take(2) { elapsedSeconds = FTMS.uint16LE(t).map(Int.init) }
            if flags.contains(.remainingTime) { _ = take(2) }
            if flags.contains(.forceOnBelt) { _ = take(4) }
            if flags.contains(.kingSmithSteps), let s = take(3) { steps = FTMS.uint16LE(s).map(Int.init) }
        }

        /// Builds a notification's bytes — for the check suite, and as executable documentation of
        /// the layout. Fields set to nil are omitted and their flag left clear.
        public static func encode(
            moreData: Bool = false,
            speedHundredths: UInt16? = nil,
            totalDistanceMetres: Int? = nil,
            elapsedSeconds: Int? = nil,
            steps: Int? = nil
        ) -> [UInt8] {
            var flags: Flags = []
            var body: [UInt8] = []
            if moreData { flags.insert(.moreData) } else {
                let s = speedHundredths ?? 0
                body += [UInt8(s & 0xFF), UInt8(s >> 8)]
            }
            if let d = totalDistanceMetres {
                flags.insert(.totalDistance)
                body += [UInt8(d & 0xFF), UInt8((d >> 8) & 0xFF), UInt8((d >> 16) & 0xFF)]
            }
            if let t = elapsedSeconds {
                flags.insert(.elapsedTime)
                body += [UInt8(t & 0xFF), UInt8((t >> 8) & 0xFF)]
            }
            if let steps {
                flags.insert(.kingSmithSteps)
                body += [UInt8(steps & 0xFF), UInt8((steps >> 8) & 0xFF), 0x00]
            }
            return [UInt8(flags.rawValue & 0xFF), UInt8(flags.rawValue >> 8)] + body
        }
    }

    /// Turns the FTMS notification stream into the `PadStatus` the rest of the app already
    /// understands, so metrics, programs, recording and the UI need no second code path.
    ///
    /// Carries the last known value of every counter forward: a packet that omits distance does
    /// not mean the distance became zero.
    public struct StatusAssembler: Equatable, Sendable {
        private var distanceMetres = 0
        private var elapsed = 0
        private var steps = 0
        /// Last target speed the belt acknowledged, in 0.01 km/h.
        private var targetHundredths: UInt16 = 0
        private var pendingParts: [TreadmillData] = []

        public init() {}

        /// Note a target-speed acknowledgement so the status can report it as the "app speed".
        public mutating func noteTargetSpeed(hundredths: UInt16) {
            targetHundredths = hundredths
        }

        /// Feed one notification. Returns a status once a complete update has arrived.
        public mutating func ingest(_ bytes: [UInt8], now: Date = Date()) -> PadStatus? {
            guard let part = TreadmillData(bytes: bytes) else { return nil }
            merge(part)
            if part.moreData {
                pendingParts.append(part)
                return nil
            }
            pendingParts.removeAll()
            let speedHundredths = part.speedHundredths ?? 0
            let speedRaw = FTMS.tenths(fromHundredths: speedHundredths)
            return PadStatus(
                beltState: speedRaw > 0 ? .running : .stopped,
                speedRaw: speedRaw,
                // FTMS belts are always under app (manual) control; there is no mode byte.
                modeRaw: PadMode.manual.rawValue,
                elapsed: elapsed,
                distanceRaw: distanceMetres / 10,
                steps: steps,
                appSpeedRaw: FTMS.thirtieths(fromHundredths: targetHundredths),
                controllerButton: 0,
                raw: bytes,
                receivedAt: now
            )
        }

        private mutating func merge(_ part: TreadmillData) {
            if let d = part.totalDistanceMetres { distanceMetres = d }
            if let t = part.elapsedSeconds { elapsed = t }
            if let s = part.steps { steps = s }
        }
    }

    // MARK: Control Point indications (0x2AD9)

    /// `[0x80, request opcode, result]`.
    public struct Response: Equatable, Sendable {
        public let opcode: Opcode?
        public let opcodeRaw: UInt8
        public let result: ResultCode?
        public let resultRaw: UInt8

        public init?(bytes: [UInt8]) {
            guard bytes.count >= 3, bytes[0] == Opcode.response.rawValue else { return nil }
            opcodeRaw = bytes[1]
            opcode = Opcode(rawValue: bytes[1])
            resultRaw = bytes[2]
            result = ResultCode(rawValue: bytes[2])
        }

        public var isSuccess: Bool { result == .success }

        public var description: String {
            let what = opcode?.label ?? String(format: "opcode 0x%02x", opcodeRaw)
            let how = result?.label ?? String(format: "result 0x%02x", resultRaw)
            return "Belt \(isSuccess ? "accepted" : "rejected") \(what): \(how)"
        }
    }

    // MARK: Fitness Machine Status events (0x2ADA)

    public enum MachineEvent: Equatable, Sendable {
        case stopped
        case paused
        case stoppedBySafetyKey
        case started
        /// New target speed in 0.01 km/h.
        case targetSpeedChanged(UInt16)
        case other(UInt8)

        public init?(bytes: [UInt8]) {
            guard let opcode = bytes.first else { return nil }
            switch opcode {
            case 0x02:
                self = bytes.count >= 2 && bytes[1] == 0x02 ? .paused : .stopped
            case 0x03: self = .stoppedBySafetyKey
            case 0x04: self = .started
            case 0x05:
                guard let speed = FTMS.uint16LE(bytes[1...]) else { return nil }
                self = .targetSpeedChanged(speed)
            default: self = .other(opcode)
            }
        }

        public var description: String {
            switch self {
            case .stopped: return "Belt reports: stopped"
            case .paused: return "Belt reports: paused"
            case .stoppedBySafetyKey: return "Belt reports: stopped by safety key"
            case .started: return "Belt reports: started"
            case .targetSpeedChanged(let h):
                return String(format: "Belt reports: target speed %.2f km/h", Double(h) / 100)
            case .other(let op): return String(format: "Belt event 0x%02x", op)
            }
        }
    }

    // MARK: Supported Speed Range (0x2AD4)

    public struct SpeedRange: Equatable, Sendable {
        public let minKph: Double
        public let maxKph: Double
        public let incrementKph: Double

        public init?(bytes: [UInt8]) {
            guard let lo = FTMS.uint16LE(bytes[0...]),
                  let hi = FTMS.uint16LE(bytes[2...]),
                  let inc = FTMS.uint16LE(bytes[4...]) else { return nil }
            minKph = Double(lo) / 100
            maxKph = Double(hi) / 100
            incrementKph = Double(inc) / 100
        }

        public var description: String {
            String(format: "Belt speed range %.1f–%.1f km/h in %.2f km/h steps", minKph, maxKph, incrementKph)
        }
    }
}
