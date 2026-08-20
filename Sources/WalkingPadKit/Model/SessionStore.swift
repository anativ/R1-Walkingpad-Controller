import Combine
import Foundation

/// Stores completed walks as JSON on disk.
///
/// Sessions live in Application Support rather than UserDefaults: the list grows without bound and
/// UserDefaults is the wrong home for a dataset. Writes are atomic, so a crash mid-save cannot
/// truncate the history.
public final class SessionStore: ObservableObject {
    /// Newest first. Kept sorted on write so reading it is free, even on a long history.
    @Published public private(set) var sessions: [WalkSession] = []
    /// Set when the store could not read or write, for surfacing in the UI.
    @Published public private(set) var lastError: String?
    /// Bumped on every change, so views can cache derived statistics against it.
    @Published public private(set) var revision: Int = 0
    /// Sticky notice about a history file that had to be set aside. Deliberately NOT cleared by a
    /// later successful save: otherwise the first walk after a quarantine would erase the only
    /// notification that the old history was archived, and the user would just see "no history".
    @Published public private(set) var quarantineNotice: String?

    /// Set when the history file could not be read AND could not be moved aside. While this is
    /// true the store refuses to write, because overwriting would destroy data we cannot read.
    public private(set) var isReadOnly = false

    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? SessionStore.defaultFileURL()
        load()
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("WalkingPad", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    public var storageLocation: URL { fileURL }

    /// Newest first. Already sorted, so this is O(1).
    public var sessionsNewestFirst: [WalkSession] { sessions }

    public func append(_ session: WalkSession) {
        // Insert in place rather than appending and re-sorting on every read.
        let index = sessions.firstIndex { $0.startedAt <= session.startedAt } ?? sessions.count
        sessions.insert(session, at: index)
        didMutate()
    }

    public func delete(_ session: WalkSession) {
        sessions.removeAll { $0.id == session.id }
        didMutate()
    }

    public func delete(ids: Set<UUID>) {
        sessions.removeAll { ids.contains($0.id) }
        didMutate()
    }

    public func deleteAll() {
        sessions.removeAll()
        didMutate()
    }

    /// Recompute stored (gross) calories for every walk from its duration and average speed,
    /// using the given body data. Returns how many walks changed.
    ///
    /// A stored figure was integrated live against whatever body data was configured at the time,
    /// so this is how a corrected weight reaches walks that are already recorded.
    @discardableResult
    public func recalculateCalories(profile: UserProfile) -> Int {
        var changed = 0
        for index in sessions.indices {
            let session = sessions[index]
            guard session.durationSeconds > 0 else { continue }
            let minutes = Double(session.durationSeconds) / 60
            let recomputed = Metrics.kcalPerMinute(
                speedKph: session.averageSpeedKph, profile: profile
            ) * minutes
            if abs(recomputed - session.kcal) > 0.5 {
                sessions[index].kcal = recomputed
                changed += 1
            }
        }
        if changed > 0 { didMutate() }
        return changed
    }

    /// Bump the revision first, so views recompute even if the write is refused or fails.
    private func didMutate() {
        revision += 1
        save()
    }

    // MARK: Disk

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            sessions = try decoder.decode([WalkSession].self, from: data)
                .sorted { $0.startedAt > $1.startedAt }
        } catch {
            quarantineUnreadableFile(reason: error.localizedDescription)
        }
    }

    /// An unreadable history file must survive.
    ///
    /// Starting empty and carrying on is not enough: the next completed walk would call `save()`
    /// and atomically replace the file with a single entry, destroying everything it could not
    /// parse. So the file is moved aside first, and if even that fails the store goes read-only
    /// rather than overwrite data it cannot read.
    private func quarantineUnreadableFile(reason: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("sessions-unreadable-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: fileURL, to: backup)
            sessions = []
            quarantineNotice = "The previous walk history could not be read (\(reason)). "
                + "It was kept as \(backup.lastPathComponent) in the same folder, "
                + "and a new history was started."
        } catch {
            isReadOnly = true
            sessions = []
            lastError = "Could not read walk history (\(reason)), and it could not be moved aside "
                + "(\(error.localizedDescription)). No walks will be saved until "
                + "\(fileURL.lastPathComponent) is repaired or removed, so the existing file stays intact."
        }
    }

    private func save() {
        // Refuse to write over a history we failed to read and failed to preserve.
        guard !isReadOnly else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try encoder.encode(sessions)
            try data.write(to: fileURL, options: .atomic)
            if lastError != nil { lastError = nil }
        } catch {
            lastError = "Could not save walk history: \(error.localizedDescription)"
        }
    }
}
