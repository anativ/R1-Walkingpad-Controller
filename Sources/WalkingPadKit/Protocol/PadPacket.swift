import Foundation

/// Wire format for the KingSmith WalkingPad BLE protocol.
///
/// Every frame is `F7 <cmd> <payload...> <crc> FD`, where `crc` is the low byte of
/// the sum of everything between the header and the crc itself.
///
/// Verified against the ph4-walkingpad reverse engineering notes
/// (https://github.com/ph4r05/ph4-walkingpad); the R1 Pro speaks the same dialect
/// as the A1/C1 family.
public enum PadPacket {
    public static let header: UInt8 = 0xF7
    public static let footer: UInt8 = 0xFD

    /// Fills in the CRC byte (second from the end) in place.
    public static func sealed(_ bytes: [UInt8]) -> [UInt8] {
        var out = bytes
        guard out.count >= 4 else { return out }
        // Sum of payload bytes: everything after the header, up to (not incl.) the crc.
        let sum = out[1..<(out.count - 2)].reduce(UInt32(0)) { $0 + UInt32($1) }
        out[out.count - 2] = UInt8(sum % 256)
        return out
    }

    /// Big-endian 3-byte integer, as used for time / distance / steps.
    public static func int24(_ bytes: ArraySlice<UInt8>) -> Int {
        let b = Array(bytes.prefix(3))
        guard b.count == 3 else { return 0 }
        return (Int(b[0]) << 16) | (Int(b[1]) << 8) | Int(b[2])
    }

    public static func bytes24(_ value: Int) -> [UInt8] {
        let v = max(0, value)
        return [UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
}

/// The belt's operating mode.
public enum PadMode: UInt8, CaseIterable, Sendable {
    case automatic = 0
    case manual = 1
    case standby = 2

    public var label: String {
        switch self {
        case .automatic: return "Auto"
        case .manual: return "Manual"
        case .standby: return "Standby"
        }
    }

    public var help: String {
        switch self {
        case .automatic: return "Belt adjusts speed from where you stand on the deck"
        case .manual: return "You set the speed — required for app speed control"
        case .standby: return "Belt idle, motor off"
        }
    }
}

/// Belt run state as reported in the status frame's byte 2.
///
/// `running` and `standby` are confirmed from captured sessions upstream; the rest are
/// transitional values the belt passes through, so they are reported but not over-labelled.
public enum PadBeltState: Equatable, Sendable {
    case stopped
    case running
    case standby
    case starting
    case other(UInt8)

    public init(raw: UInt8) {
        switch raw {
        case 0: self = .stopped
        case 1: self = .running
        case 5: self = .standby
        case 9: self = .starting
        default: self = .other(raw)
        }
    }

    public var raw: UInt8 {
        switch self {
        case .stopped: return 0
        case .running: return 1
        case .standby: return 5
        case .starting: return 9
        case .other(let v): return v
        }
    }

    public var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .running: return "Running"
        case .standby: return "Standby"
        case .starting: return "Starting"
        case .other(let v): return "State \(v)"
        }
    }
}

/// Target types the belt can count down against.
public enum PadTarget: UInt8, CaseIterable, Sendable {
    case none = 0
    case distance = 1
    case calories = 2
    case time = 3

    public var label: String {
        switch self {
        case .none: return "None"
        case .distance: return "Distance"
        case .calories: return "Calories"
        case .time: return "Time"
        }
    }
}

/// Preference keys for the `A6` command family.
public enum PadPreference: UInt8, Sendable {
    case target = 1
    case maxSpeed = 3
    case startSpeed = 4
    case intelligentStart = 5
    case sensitivity = 6
    case display = 7
    case units = 8
    case childLock = 9
}

public enum PadSensitivity: UInt8, CaseIterable, Sendable {
    case high = 1
    case medium = 2
    case low = 3

    public var label: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}

/// The commands this app sends to the belt.
public enum PadCommand: Equatable, Sendable {
    /// Ask for a status frame. The belt replies with an `F8 A2` notification.
    case askStats
    /// Speed in 0.1 km/h units (e.g. 30 == 3.0 km/h). 0 stops the belt.
    case setSpeed(UInt8)
    case setMode(PadMode)
    case start
    /// Ask for the last stored session. Replies with `F8 A7`.
    case askHistory
    case setPreference(PadPreference, type: UInt8, value: Int)

    public var bytes: [UInt8] {
        switch self {
        case .askStats:
            return PadPacket.sealed([0xF7, 0xA2, 0x00, 0x00, 0x00, 0xFD])
        case .setSpeed(let raw):
            return PadPacket.sealed([0xF7, 0xA2, 0x01, raw, 0x00, 0xFD])
        case .setMode(let mode):
            return PadPacket.sealed([0xF7, 0xA2, 0x02, mode.rawValue, 0x00, 0xFD])
        case .start:
            return PadPacket.sealed([0xF7, 0xA2, 0x04, 0x01, 0x00, 0xFD])
        case .askHistory:
            return PadPacket.sealed([0xF7, 0xA7, 0xAA, 0xFF, 0x00, 0xFD])
        case .setPreference(let key, let type, let value):
            let v = PadPacket.bytes24(value)
            return PadPacket.sealed([0xF7, 0xA6, key.rawValue, type, v[0], v[1], v[2], 0x00, 0xFD])
        }
    }

    /// Commands that supersede an earlier queued command of the same kind.
    ///
    /// Dragging the speed slider must not queue up 40 speed changes, and re-tapping Start or a
    /// preset must not queue another mode/start pair — at one frame per 0.7 s that pushes the
    /// speed change seconds into the future and starves the status poll behind it.
    /// Distinct preferences keep distinct keys so they never collapse into each other.
    public var coalesceKey: String? {
        switch self {
        case .setSpeed: return "speed"
        case .askStats: return "stats"
        case .askHistory: return "history"
        case .setMode: return "mode"
        case .start: return "start"
        case .setPreference(let key, _, _): return "pref-\(key.rawValue)"
        }
    }

    public var isStatusPoll: Bool {
        if case .askStats = self { return true }
        return false
    }
}
