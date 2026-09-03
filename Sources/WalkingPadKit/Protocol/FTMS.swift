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
    /// Read: feature bit masks (two uint32).
    public static let featureUUID16: UInt16 = 0x2ACC
    /// Notify: training status (flags byte, status byte).
    public static let trainingStatusUUID16: UInt16 = 0x2AD3
    /// Device Information service and its software-revision string.
    public static let deviceInformationServiceUUID16: UInt16 = 0x180A
    public static let softwareRevisionUUID16: UInt16 = 0x2A28

    /// Standard FTMS training-status codes, for the log.
    public static func trainingStatusLabel(_ code: UInt8) -> String {
        switch code {
        case 0x00: return "other"
        case 0x01: return "idle"
        case 0x02: return "warming up"
        case 0x0C: return "manual mode"
        case 0x0D: return "pre-workout"
        case 0x0E: return "post-workout"
        default: return String(format: "code 0x%02x", code)
        }
    }

    // MARK: KingSmith supplement service (KS-HD-* belts)

    /// The vendor channel beside FTMS on the Z1 generation (KS-HD-* belts).
    ///
    /// Frames to the belt are `[type, sub-command, payload length, payload…, checksum]` with the
    /// checksum the low byte of the sum of everything before it. The belt answers on the notify
    /// characteristic with ASCII-tagged frames: `WLR` (status report, 26 bytes), `WLV` (ack),
    /// `WLU` (init / version), `WLQ` (query). Layout from kkz6/WalkingPadSDK, tested on a KS-HD-Z1D.
    ///
    /// Wake alone was not enough on firmware V0.0.6. The Swift SDK that drives a `KS-HD-Z1D`
    /// first identifies the model (`71 00 …Z1D`) and syncs a timestamp (`71 01 …`) before it
    /// queries, and it writes this channel without a GATT response. We do the same, then wake.
    public enum Supplement {
        public static let serviceUUID = "24E2521C-F63B-48ED-85BE-C5330A00FDF7"
        public static let notifyUUID = "24E2521C-F63B-48ED-85BE-C5330B00FDF7"
        public static let writeUUID = "24E2521C-F63B-48ED-85BE-C5330D00FDF7"

        public static func frame(_ type: UInt8, _ sub: UInt8, _ payload: [UInt8] = []) -> [UInt8] {
            var bytes: [UInt8] = [type, sub, UInt8(payload.count)] + payload
            bytes.append(UInt8(bytes.reduce(0) { $0 + Int($1) } & 0xFF))
            return bytes
        }

        /// Model identifier: `71 00 05 64 91 5A 31 44 …`. Payload is two opaque bytes plus ASCII
        /// `Z1D` — the BLE name of the belt under test.
        public static let initDeviceBytes: [UInt8] = frame(0x71, 0x00, [0x64, 0x91, 0x5A, 0x31, 0x44])
        /// Trailing four bytes of the timestamp frame, as the Swift SDK sends them.
        public static let initTimestampTrailer: [UInt8] = [0x32, 0xF6, 0x59, 0x00]
        /// Timestamp sync: `71 01 08` + little-endian unix time + trailer + checksum.
        public static func initTimestampBytes(now: Date = Date()) -> [UInt8] {
            let ts = UInt32(now.timeIntervalSince1970)
            let tsBytes: [UInt8] = [
                UInt8(ts & 0xFF),
                UInt8((ts >> 8) & 0xFF),
                UInt8((ts >> 16) & 0xFF),
                UInt8((ts >> 24) & 0xFF),
            ]
            return frame(0x71, 0x01, tsBytes + initTimestampTrailer)
        }
        /// Wake the belt from standby: `72 01 03 0A 00 00 80`.
        public static let wakeBytes: [UInt8] = frame(0x72, 0x01, [0x0A, 0x00, 0x00])
        /// Put the belt into standby: `72 01 03 0A 40 00 C0`. Not sent by this app; documented so
        /// nobody mistakes it for the wake frame — one byte apart.
        public static let sleepBytes: [UInt8] = frame(0x72, 0x01, [0x0A, 0x40, 0x00])
        /// Ask for a status report (`WLR` reply): `72 00 00 72`.
        public static let queryStatusBytes: [UInt8] = frame(0x72, 0x00)
        /// Ask for the configuration: `75 00 00 75`.
        public static let queryConfigBytes: [UInt8] = frame(0x75, 0x00)

        /// A `WLR` status report as the rest of the app understands it. Distance on the wire is
        /// metres; `PadStatus` stores 10 m units.
        public static func parseStatus(_ bytes: [UInt8], now: Date) -> PadStatus? {
            guard bytes.count >= 12, bytes[0] == 0x57, bytes[1] == 0x4C, bytes[2] == 0x52 else { return nil }
            let speedRaw = bytes[5]
            let metres = Int(bytes[9]) | (Int(bytes[10]) << 8) | (Int(bytes[11]) << 16)
            return PadStatus(
                beltState: bytes[3] == 0 ? .stopped : .running,
                speedRaw: speedRaw,
                modeRaw: PadMode.manual.rawValue,
                elapsed: Int(bytes[7]) | (Int(bytes[8]) << 8),
                distanceRaw: metres / 10,
                steps: 0,
                appSpeedRaw: UInt8(min(255, Int(speedRaw) * 3)),
                controllerButton: 0,
                raw: bytes,
                receivedAt: now
            )
        }

        /// A one-line reading of a reply frame, for the log.
        public static func describe(_ bytes: [UInt8]) -> String {
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            guard bytes.count >= 3, bytes[0] == 0x57, bytes[1] == 0x4C else { return "Supplement reply: \(hex)" }
            switch bytes[2] {
            case 0x52 where bytes.count >= 12:
                let belt = bytes[3]
                let speed = bytes[5]
                let time = Int(bytes[7]) | (Int(bytes[8]) << 8)
                let distance = Int(bytes[9]) | (Int(bytes[10]) << 8) | (Int(bytes[11]) << 16)
                return String(format: "Belt status (WLR): belt byte %d (%@), speed %.1f km/h, %ds, %dm — %@",
                              belt, belt == 0 ? "idle" : "running", Double(speed) / 10, time, distance, hex)
            case 0x52: return "Belt status (WLR, short): \(hex)"
            case 0x56: return "Belt ack (WLV): \(hex)"
            case 0x55: return "Belt init/version (WLU): \(hex)"
            case 0x51: return "Belt query (WLQ): \(hex)"
            default: return "Belt frame WL\(String(UnicodeScalar(bytes[2]))): \(hex)"
            }
        }
    }

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

        /// Bytes the optional fields announced by `flags` occupy, in spec order.
        static func optionalFieldsSize(_ flags: Flags) -> Int {
            var size = 0
            if flags.contains(.averageSpeed) { size += 2 }
            if flags.contains(.totalDistance) { size += 3 }
            if flags.contains(.inclination) { size += 4 }
            if flags.contains(.elevationGain) { size += 4 }
            if flags.contains(.instantaneousPace) { size += 1 }
            if flags.contains(.averagePace) { size += 1 }
            if flags.contains(.expendedEnergy) { size += 5 }
            if flags.contains(.heartRate) { size += 1 }
            if flags.contains(.metabolicEquivalent) { size += 1 }
            if flags.contains(.elapsedTime) { size += 2 }
            if flags.contains(.remainingTime) { size += 2 }
            if flags.contains(.forceOnBelt) { size += 4 }
            if flags.contains(.kingSmithSteps) { size += 3 }
            return size
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

            // The spec says the speed field is absent when "More Data" is set. Firmware does not
            // always agree — KS Fit's own parser reads the speed regardless — so trust the packet
            // length: if there is room for a speed field in front of the announced fields, it is one.
            let roomForSpeed = bytes.count >= 4 + TreadmillData.optionalFieldsSize(flags)
            if !moreData || roomForSpeed {
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
        /// Last instantaneous speed seen, for packets that carry none.
        private var speedHundredths: UInt16 = 0

        public init() {}

        /// Note a target-speed acknowledgement so the status can report it as the "app speed".
        public mutating func noteTargetSpeed(hundredths: UInt16) {
            targetHundredths = hundredths
        }

        /// Feed one notification. Every parseable packet yields a status: fields it omits keep
        /// their last value, so a continuation packet refreshes the counters it does carry rather
        /// than being held back for a final packet the firmware may never send.
        public mutating func ingest(_ bytes: [UInt8], now: Date = Date()) -> PadStatus? {
            guard let part = TreadmillData(bytes: bytes) else { return nil }
            merge(part)
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
            if let v = part.speedHundredths { speedHundredths = v }
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
