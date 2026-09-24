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
    /// Device Information service, its firmware- and software-revision strings. The Z1F's
    /// `V0.0.6` is the software revision; its firmware reads like `J41_V301.08.14`.
    public static let deviceInformationServiceUUID16: UInt16 = 0x180A
    public static let firmwareRevisionUUID16: UInt16 = 0x2A26
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

    /// The vendor channel beside FTMS on the Z1 generation (KS-HD-* belts), and the gate in front
    /// of it.
    ///
    /// Until this channel is unlocked, the pad acknowledges every write but ignores the FTMS
    /// Control Point and sends no notification on any characteristic. The unlock token comes from
    /// the belt's Bluetooth name; the pad answers `71 80`, and from then on FTMS behaves by the
    /// book. Verified on a `KS-HD-Z1D`, firmware V0.0.6, by slandau3/z1-walkingpad-mcp
    /// (`docs/protocol.md`) and by the duttke.de Web Bluetooth controller.
    ///
    /// Frames in both directions are `[cmd0, cmd1, length, data…, checksum]`, where the checksum
    /// is the low byte of the sum of every byte before it. Writes go to `…0D00` as Write
    /// Commands, at least `minWriteSpacing` apart; replies arrive on `…0B00`.
    public enum Supplement {
        public static let serviceUUID = "24E2521C-F63B-48ED-85BE-C5330A00FDF7"
        public static let notifyUUID = "24E2521C-F63B-48ED-85BE-C5330B00FDF7"
        public static let writeUUID = "24E2521C-F63B-48ED-85BE-C5330D00FDF7"

        /// The pad drops vendor writes that arrive closer together than this.
        public static let minWriteSpacing: TimeInterval = 0.4
        /// A frame starting with this byte puts the pad's chip into firmware-update mode. The app
        /// never builds one; `isSafeToSend` exists so that stays checkable.
        public static let otaCommand: UInt8 = 0xE8

        public static func frame(_ cmd0: UInt8, _ cmd1: UInt8, _ data: [UInt8] = []) -> [UInt8] {
            var bytes: [UInt8] = [cmd0, cmd1, UInt8(data.count)] + data
            bytes.append(UInt8(bytes.reduce(0) { $0 + Int($1) } & 0xFF))
            return bytes
        }

        public static func isSafeToSend(_ bytes: [UInt8]) -> Bool {
            bytes.first != otaCommand
        }

        /// A reply frame, checksum verified.
        public struct Frame: Equatable, Sendable {
            public let cmd0: UInt8
            public let cmd1: UInt8
            public let data: [UInt8]

            public init?(bytes: [UInt8]) {
                guard bytes.count >= 4 else { return nil }
                let length = Int(bytes[2])
                guard bytes.count >= 3 + length + 1 else { return nil }
                let sum = bytes[0..<(3 + length)].reduce(0) { $0 + Int($1) } & 0xFF
                guard sum == Int(bytes[3 + length]) else { return nil }
                cmd0 = bytes[0]
                cmd1 = bytes[1]
                data = Array(bytes[3..<(3 + length)])
            }

            public var isUnlockAccepted: Bool { cmd0 == 0x71 && cmd1 == 0x80 }
        }

        /// The unlock: `71 00 05 01 <T> <checksum>`, where `T` is the last four bytes of the
        /// belt's name read as a little-endian `UInt32`, plus one. `KS-HD-Z1D` gives
        /// `71 00 05 01 2E 5A 31 44 74`. Nil for a name too short to derive a token from.
        ///
        /// The `01` is a nonce the pad adds to the token. An earlier build sent the variant with
        /// nonce `64` that kkz6/WalkingPadSDK hard-codes (`71 00 05 64 91 5A 31 44`) — the same
        /// frame frozen to one name, never confirmed on this firmware.
        public static func unlockBytes(name: String) -> [UInt8]? {
            let tail = Array(name.utf8.suffix(4))
            guard tail.count == 4 else { return nil }
            let name32: UInt32 = tail.reversed().reduce(0) { ($0 << 8) | UInt32($1) }
            let token = name32 &+ 1
            return frame(0x71, 0x00, [0x01] + littleEndian32(token))
        }

        /// Session info, sent once unlocked: `71 01 08 <unix time LE32> <user id LE32 = 0>`.
        /// The pad answers `71 81` with protocol version, model and capability bits.
        public static func sysInfoBytes(now: Date = Date()) -> [UInt8] {
            frame(0x71, 0x01, littleEndian32(UInt32(now.timeIntervalSince1970)) + littleEndian32(0))
        }

        /// Read every property: `72 00 01 00 73`. The pad answers `72 80`.
        public static let readAllPropertiesBytes: [UInt8] = frame(0x72, 0x00, [0x00])

        /// Properties the Z1 reports, by id.
        public static func propertyLabel(_ id: UInt8) -> String {
            switch id {
            case 1: return "units"
            case 2: return "auto-stop"
            case 4: return "motor version"
            case 5: return "last error"
            case 6: return "child lock"
            case 8: return "switches"
            case 10: return "mode"
            default: return "property \(id)"
            }
        }

        /// A `72 80` reply: four-byte records `[id, error, value lo, value hi]`. Records with an
        /// error are left out.
        public static func parseProperties(_ data: [UInt8]) -> [(id: UInt8, value: UInt16)] {
            var records: [(id: UInt8, value: UInt16)] = []
            var i = 0
            while i + 4 <= data.count {
                if data[i + 1] == 0 { records.append((data[i], word(data[i + 2], data[i + 3]))) }
                i += 4
            }
            return records
        }

        /// A one-line reading of a reply frame, for the log.
        public static func describe(_ bytes: [UInt8]) -> String {
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            guard let f = Frame(bytes: bytes) else { return "Vendor reply (unframed): \(hex)" }
            func props(_ records: [(id: UInt8, value: UInt16)]) -> String {
                records.map { "\(propertyLabel($0.id)) 0x\(String(format: "%04x", $0.value))" }.joined(separator: ", ")
            }
            switch (f.cmd0, f.cmd1) {
            case (0x71, 0x80):
                return "Belt unlocked (71 80)"
            case (0x71, 0x81) where f.data.count >= 8:
                let proto = Int(f.data[0]) | Int(f.data[1]) << 8
                let model = Int(f.data[2]) | Int(f.data[3]) << 8
                let caps = f.data[4..<8].reversed().map { String(format: "%02x", $0) }.joined()
                return "Belt session info: protocol \(proto), model \(model), capabilities 0x\(caps)"
            case (0x72, 0x80):
                return "Belt properties: \(props(parseProperties(f.data)))"
            case (0x72, 0x81):
                return "Belt property write answered: \(hex)"
            case (0x72, 0x50):
                var pushed: [(id: UInt8, value: UInt16)] = []
                var i = 0
                while i + 3 <= f.data.count {
                    pushed.append((f.data[i], word(f.data[i + 1], f.data[i + 2])))
                    i += 3
                }
                return "Belt property changed: \(props(pushed))"
            case (0x73, 0x50):
                return "Belt exercise record: \(hex)"
            case (0x73, 0x51):
                return "Belt fault record: \(hex)"
            default:
                return "Vendor reply: \(hex)"
            }
        }

        private static func word(_ lo: UInt8, _ hi: UInt8) -> UInt16 {
            UInt16(lo) | (UInt16(hi) << 8)
        }

        private static func littleEndian32(_ value: UInt32) -> [UInt8] {
            [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
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
