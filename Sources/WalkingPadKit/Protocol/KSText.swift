import Foundation

/// KingSmith's obfuscated text protocol, spoken by newer belts (the Z1F on firmware V0.0.6 among
/// them) over the second characteristic pair of the vendor service — `…c5330e00fdf7` (notify) and
/// `…c5330f00fdf7` (write).
///
/// Commands are plain ASCII (`props runState 1`), base64-encoded, then each base64 character is
/// swapped for the one at the same index in a 65-character substitution table, and a carriage
/// return is appended. The belt picks one of seven known tables; which one is learned from its
/// first replies. Writes go out in 16-byte chunks. Everything here is pure and runs under
/// `padctl selftest`. Layout from while-loop/c3p0, which took it from the KS Fit APK.
public enum KSText {
    public static let terminator: UInt8 = 0x0D
    /// Longest write the firmware accepts at once.
    public static let chunkSize = 16
    /// Pause between chunks of one command.
    public static let chunkSpacing: TimeInterval = 0.12
    /// Pause between handshake steps.
    public static let handshakeSpacing: TimeInterval = 0.15

    public static let notifyUUID = "24E2521C-F63B-48ED-85BE-C5330E00FDF7"
    public static let writeUUID = "24E2521C-F63B-48ED-85BE-C5330F00FDF7"

    private static let base64Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".utf8)

    /// The substitution tables the firmware is known to use. Each is the base64 alphabet, permuted.
    public static let tables: [String] = [
        "SaCw4FGHIJqLhN+P9RVTU/WcY6ObDdefgEijklmnopQrsBuvMxXz1yA2t5078KZ3=",
        "ZaCw4FGHIJqLhN+P9RMTU/WcY6ObDdefgEijklmnopQrsBuvVxXz1yA2t5078KS3=",
        "0aCw4FGHIJqLhN+P9RVTU/WcY6ObDdefgEijklmnopQrsBuvMxXz1yA2t5Z78KS3=",
        "ZaCw4FGHIJqLhN9P+RVTU/WcY6ObDdefgEijklmnopQrsBuvMxXz1yA2t5078KS3=",
        "iaCw4FGHIJqLhN+P9RVTU/WcY6ObDdefgEZjklmnopQrsBuvMxXz1yA2t5078KS3=",
        "ZaCw4FGHIJqLhN+P8RVTU/WcY6ObDdefgEijklmnopQrsBuvMxXz1yA2t5079KS3=",
        "baCw4FGHIJqLhN+P9RVTU/WcY6OZDdefgEijklmnopQrsBuvMxXz1yA2t5078KS3=",
    ]

    // MARK: Commands

    public static let start = "props runState 1"
    public static let stop = "props runState 0"
    public static func setMode(_ mode: PadMode) -> String { "props ControlMode \(mode.rawValue)" }
    /// Speed in the app's 0.1 km/h units, written as one decimal.
    public static func setSpeed(raw tenths: UInt8) -> String {
        "props CurrentSpeed \(tenths / 10).\(tenths % 10)"
    }
    /// The status poll: every property the app reads.
    public static let pollStatus = "servers getProp 1 2 3 4 5 7 9 12 13 16 17 23 24 31"

    // MARK: Encoding

    /// A command as the belt wants it: substituted base64 plus the terminator.
    public static func encode(_ command: String, table: String) -> [UInt8] {
        let tableChars = Array(table.utf8)
        let base64 = Array(Data(command.utf8).base64EncodedString().utf8)
        var out = base64.map { char -> UInt8 in
            guard let index = base64Alphabet.firstIndex(of: char), index < tableChars.count else { return UInt8(ascii: "_") }
            return tableChars[index]
        }
        out.append(terminator)
        return out
    }

    /// The command encoded once per table, duplicates removed — for when the belt's table is not
    /// yet known and the same command is offered in every spelling.
    public static func encodeForAllTables(_ command: String, tables: [String] = KSText.tables) -> [[UInt8]] {
        var seen: [[UInt8]] = []
        for table in tables {
            let bytes = encode(command, table: table)
            if !seen.contains(bytes) { seen.append(bytes) }
        }
        return seen
    }

    /// The text behind a reply, if `table` is the belt's. Nil when a byte is not in the table or
    /// the result is not base64.
    public static func decode(_ packet: [UInt8], table: String) -> String? {
        let tableChars = Array(table.utf8)
        var body = packet
        if body.last == terminator { body.removeLast() }
        var base64 = [UInt8]()
        base64.reserveCapacity(body.count)
        for byte in body {
            guard let index = tableChars.firstIndex(of: byte), index < base64Alphabet.count else { return nil }
            base64.append(base64Alphabet[index])
        }
        guard let data = Data(base64Encoded: Data(base64)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Words a genuine reply contains; anything else is a wrong-table decode that happened to be text.
    static let knownTokens = ["format error", "shake", "net", "get_dn", "get_pk", "time_posix", "version", "servers", "props"]

    public static func isPlausible(_ text: String) -> Bool {
        if text.isEmpty { return true }
        guard text.utf8.allSatisfy({ $0 >= 9 && $0 <= 126 }) else { return false }
        let lower = text.lowercased()
        return knownTokens.contains { lower.contains($0) }
    }

    /// Every table that turns the packet into plausible text, with that text.
    public static func decodeCandidates(_ packet: [UInt8], tables: [String] = KSText.tables) -> [(table: String, text: String)] {
        tables.compactMap { table in
            guard let text = decode(packet, table: table), isPlausible(text) else { return nil }
            return (table, text)
        }
    }

    /// Split a command's bytes into the chunks the firmware accepts.
    public static func chunks(_ bytes: [UInt8]) -> [[UInt8]] {
        stride(from: 0, to: bytes.count, by: chunkSize).map { Array(bytes[$0..<min($0 + chunkSize, bytes.count)]) }
    }

    // MARK: Properties

    /// `props k v k v …` as a dictionary; nil for anything that is not a props line.
    public static func parseProps(_ text: String) -> [String: String]? {
        guard text.lowercased().hasPrefix("props") else { return nil }
        let parts = text.dropFirst("props".count).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var props: [String: String] = [:]
        var index = 0
        while index + 1 < parts.count {
            props[parts[index]] = parts[index + 1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            index += 2
        }
        return props
    }

    /// Folds `props` replies into the `PadStatus` the rest of the app runs on. The belt reports
    /// the same things the classic protocol does — run state, mode, speed, time, distance, steps —
    /// under text names, and only the ones asked for, so values carry forward between replies.
    public struct StatusAssembler: Equatable, Sendable {
        private var beltStateRaw: UInt8 = 0
        private var speedRaw: UInt8 = 0
        private var modeRaw: UInt8 = PadMode.manual.rawValue
        private var elapsed = 0
        private var distanceRaw = 0
        private var steps = 0

        public init() {}

        /// Apply one props reply. Returns a status if it carried anything the app shows.
        public mutating func apply(_ props: [String: String], raw: [UInt8], now: Date) -> PadStatus? {
            var touched = false
            if let v = props["runState"].flatMap({ UInt8($0) }) { beltStateRaw = v; touched = true }
            if let v = props["CurrentSpeed"].flatMap(Double.init) { speedRaw = UInt8(max(0, min(255, (v * 10).rounded()))); touched = true }
            if let v = props["ControlMode"].flatMap({ UInt8($0) }) { modeRaw = v; touched = true }
            if let v = props["RunningTotalTime"].flatMap({ Int($0) }) { elapsed = v; touched = true }
            if let v = props["RunningDistance"].flatMap({ Int($0) }) { distanceRaw = v / 10; touched = true }
            if let v = props["RunningSteps"].flatMap({ Int($0) }) { steps = v; touched = true }
            guard touched else { return nil }
            return PadStatus(
                beltState: PadBeltState(raw: beltStateRaw),
                speedRaw: speedRaw,
                modeRaw: modeRaw,
                elapsed: elapsed,
                distanceRaw: distanceRaw,
                steps: steps,
                appSpeedRaw: UInt8(min(255, Int(speedRaw) * 3)),
                controllerButton: 0,
                raw: raw,
                receivedAt: now
            )
        }
    }

    // MARK: Handshake

    /// The eight-step greeting the vendor app performs before anything else, and the table
    /// learning that rides on it. Each step sends one command and expects a reply containing a
    /// known word; the reply's table narrows the candidates until one is left.
    public struct Handshake: Equatable, Sendable {
        public private(set) var step = 0
        public private(set) var candidates: [String] = KSText.tables
        /// The belt's table, once known.
        public var table: String? { candidates.count == 1 ? candidates[0] : nil }
        public var isComplete: Bool { step > Handshake.lastStep }
        public static let lastStep = 7

        public init() {}

        public func command(now: Date = Date()) -> String? {
            switch step {
            case 0: return ""
            case 1: return "shake"
            case 2: return "net"
            case 3: return "get_dn"
            case 4: return "get_pk"
            case 5: return "time_posix \(Int(now.timeIntervalSince1970))"
            case 6: return "version"
            case 7: return "servers getProp 1 2 7 12 23 24 31"
            default: return nil
            }
        }

        public static func expectedToken(step: Int) -> String? {
            switch step {
            case 0: return "format error"
            case 1: return "shake"
            case 2: return "net"
            case 3: return "get_dn"
            case 4: return "get_pk"
            case 5: return "time_posix"
            case 6: return "version"
            case 7: return "servers"
            default: return nil
            }
        }

        /// The current step's command, in every spelling still possible.
        public func payloads(now: Date = Date()) -> [[UInt8]] {
            guard let command = command(now: now) else { return [] }
            return KSText.encodeForAllTables(command, tables: candidates)
        }

        /// Feed a complete reply packet. Returns the decoded text when it was understood, and
        /// advances the step when it answers the current one. A `props` reply at any point is
        /// accepted as proof the belt is talking to us.
        public mutating func receive(_ packet: [UInt8]) -> String? {
            let decoded = KSText.decodeCandidates(packet, tables: candidates)
                .ifEmpty { KSText.decodeCandidates(packet) }
            guard !decoded.isEmpty else { return nil }
            let expected = Handshake.expectedToken(step: step)
            let matching = decoded.filter { candidate in
                KSText.parseProps(candidate.text) != nil
                    || expected.map { candidate.text.lowercased().contains($0) } == true
            }
            let chosen = matching.first ?? decoded[0]
            if !matching.isEmpty {
                candidates = matching.map(\.table)
                if !isComplete {
                    if KSText.parseProps(chosen.text) != nil && step == Handshake.lastStep {
                        step = Handshake.lastStep + 1
                    } else if let expected, chosen.text.lowercased().contains(expected) {
                        step += 1
                    }
                }
            }
            return chosen.text
        }
    }
}

private extension Array {
    func ifEmpty(_ fallback: () -> [Element]) -> [Element] { isEmpty ? fallback() : self }
}
