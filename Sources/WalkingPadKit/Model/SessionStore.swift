import Combine
import Foundation

/// Stores completed walks as JSON on disk.
///
/// Sessions live in Application Support rather than UserDefaults: the list grows without bound and
/// UserDefaults is the wrong home for a dataset. Writes are atomic, so a crash mid-save cannot
/// truncate the history.
public final class SessionStore: ObservableObject {
    @Published public private(set) var sessions: [WalkSession] = []
    /// Set when the store could not read or write, for surfacing in the UI.
    @Published public private(set) var lastError: String?

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

    /// Newest first.
    public var sessionsNewestFirst: [WalkSession] {
        sessions.sorted { $0.startedAt > $1.startedAt }
    }

    public func append(_ session: WalkSession) {
        sessions.append(session)
        save()
    }

    public func delete(_ session: WalkSession) {
        sessions.removeAll { $0.id == session.id }
        save()
    }

    public func delete(ids: Set<UUID>) {
        sessions.removeAll { ids.contains($0.id) }
        save()
    }

    public func deleteAll() {
        sessions.removeAll()
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
        } catch {
            // Never silently drop the user's history: keep the file, report the problem.
            lastError = "Could not read walk history: \(error.localizedDescription)"
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try encoder.encode(sessions)
            try data.write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Could not save walk history: \(error.localizedDescription)"
        }
    }
}
