import Foundation

/// Which generation of WalkingPad the app should look for.
///
/// KingSmith changed the Bluetooth protocol wholesale with the Z1 generation, and a belt of one
/// family is invisible to a scan for the other. The user picks the family once (it is remembered)
/// and everything below the controller — scan filter, GATT layout, frame codec — follows.
public enum PadFamily: String, CaseIterable, Codable, Sendable, Identifiable {
    /// R1 Pro, A1, C1, C2, P1, X21: KingSmith's original "WiLink" protocol on service `FE00`,
    /// framed `F7 … FD`. Reverse engineered by ph4-walkingpad.
    case classic
    /// Z1, Z1F and other 2025+ belts advertising as `KS-HD-…`: the Bluetooth SIG Fitness Machine
    /// Service (`1826`), with a KingSmith step-count extension.
    case ftms

    public var id: String { rawValue }

    /// The default for a fresh install — the belt this app was written against.
    public static let `default`: PadFamily = .classic

    public var label: String {
        switch self {
        case .classic: return "R1 Pro · A1 · C1 · P1"
        case .ftms: return "Z1 · Z1F"
        }
    }

    /// One line for the settings pane.
    public var detail: String {
        switch self {
        case .classic:
            return "R1 Pro, A1, C1, C2, P1 and X21 (Bluetooth name “WalkingPad” or “KS-R1…”). "
                + "KingSmith’s original protocol, with belt-side settings and mode control."
        case .ftms:
            return "Z1 and Z1F (2025 models, Bluetooth name “KS-HD-…”). The standard Fitness "
                + "Machine protocol: speed, start and stop, live metrics. Belt-side settings and "
                + "mode switching are not available over Bluetooth on these models."
        }
    }

    /// The classic belt exposes its stored preferences (max speed, child lock…) over the wire.
    public var supportsBeltPreferences: Bool { self == .classic }
    /// Auto / manual / standby switching is a classic-protocol command.
    public var supportsModes: Bool { self == .classic }
    /// Only the classic belt answers a "last stored session" query.
    public var supportsStoredSession: Bool { self == .classic }

    /// Whether the Bluetooth log should be verbose unless the user says otherwise. The Z1 path is
    /// still being understood against real belts, so every byte it exchanges should be easy to
    /// collect; the classic protocol is settled and its poll chatter is noise.
    public var defaultsToVerboseLog: Bool { self == .ftms }

    /// The log mode this family starts in.
    public var defaultLogMode: BeltLogMode { defaultsToVerboseLog ? .verbose : .normal }

    /// The verbosity in force: the user's remembered choice if they made one, else the family default.
    public static func verboseLog(override: Bool?, family: PadFamily) -> Bool {
        override ?? family.defaultsToVerboseLog
    }

    /// The log mode in force: the user's remembered choice if they made one, else the family default.
    public static func logMode(override: Bool?, family: PadFamily) -> BeltLogMode {
        verboseLog(override: override, family: family) ? .verbose : .normal
    }
}

/// How much of the Bluetooth exchange is recorded.
///
/// Verbose is the Z1 default because that belt is not working yet: every command and frame has
/// to be in the diagnostics report. Normal is quieter, for a belt whose protocol is settled.
public enum BeltLogMode: String, CaseIterable, Sendable, Identifiable {
    case normal
    case verbose

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .normal: return "Normal"
        case .verbose: return "Verbose"
        }
    }

    public var isVerbose: Bool { self == .verbose }
}
