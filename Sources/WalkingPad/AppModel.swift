import Combine
import Foundation
import SwiftUI
import WalkingPadKit

/// User-facing settings, persisted in UserDefaults.
struct AppSettings: Equatable {
    var unit: DistanceUnit = .kilometers
    /// App-side speed ceiling for the slider. Independent of the belt's own max-speed setting.
    var speedCeilingKph: Double = 6.0
    /// Speed the Start button uses.
    var startSpeedKph: Double = 2.5
    var weightKg: Double = 75
    var heightCm: Double = 175
    var autoConnectOnLaunch: Bool = true
    var showMenuBarExtra: Bool = true

    /// The R1 Pro tops out at 10 km/h; never let the UI ask for more than the hardware allows.
    static let hardMaxSpeedKph: Double = 10.0
    static let minRunningSpeedKph: Double = 0.5

    var profile: UserProfile { UserProfile(weightKg: weightKg, heightCm: heightCm) }
}

/// Owns the BLE controller, the derived-metrics tracker, and user intent.
@MainActor
final class AppModel: ObservableObject {
    let controller = PadController()
    let tracker = SessionTracker()
    let runner = ProgramRunner()
    let recorder = SessionRecorder()
    let store = SessionStore()

    /// The program currently being edited in the UI. Persisted so it survives a relaunch.
    ///
    /// Published by hand, for the same reason as `settings`: the editor drives this through custom
    /// `Binding(get:set:)` closures, and `@Published` publishes even when the value did not change,
    /// which turns a write-back during body evaluation into an endless invalidation loop.
    var program: SpeedProgram {
        get { storedProgram }
        set {
            guard newValue != storedProgram else { return }
            objectWillChange.send()
            storedProgram = newValue
            persistPrograms()
        }
    }

    /// Named programs the user has saved.
    var savedPrograms: [SpeedProgram] {
        get { storedSavedPrograms }
        set {
            guard newValue != storedSavedPrograms else { return }
            objectWillChange.send()
            storedSavedPrograms = newValue
            persistPrograms()
        }
    }

    private var storedProgram: SpeedProgram
    private var storedSavedPrograms: [SpeedProgram] = []

    /// Settings are published by hand rather than with `@Published`.
    ///
    /// SwiftUI writes bindings back *during* body evaluation (`MenuBarExtra(isInserted:)` does
    /// this on every pass). `@Published` publishes on every assignment whether or not the value
    /// changed, so a no-op write from inside body invalidated the view that had just written it,
    /// and the App body re-evaluated forever at 100% CPU. Dropping no-op writes breaks the cycle.
    var settings: AppSettings {
        get { storedSettings }
        set {
            guard newValue != storedSettings else { return }
            objectWillChange.send()
            storedSettings = newValue
            persist()
            tracker.profile = newValue.profile
            recorder.profile = newValue.profile
            // A Slider whose value sits outside its own range misbehaves, so follow the ceiling down.
            let ceiling = min(newValue.speedCeilingKph, AppSettings.hardMaxSpeedKph)
            if desiredSpeedKph > ceiling {
                desiredSpeedKph = ceiling
                // The ceiling is a safety limit, so it has to reach a belt that is already moving —
                // not just the on-screen number. Sent through the controller directly so that
                // lowering the ceiling is not mistaken for the manual override that ends a program.
                if !runner.isRunning { sendSpeedToBelt(ceiling, mayStartBelt: false) }
            }
            // A running program must respect a ceiling the user lowers underneath it.
            runner.applyCeiling(SpeedProgram.raw(ceiling))
        }
    }

    private var storedSettings: AppSettings

    /// Slider position. Kept separate from the belt's reported speed so dragging feels immediate.
    @Published var desiredSpeedKph: Double

    private var cancellables = Set<AnyCancellable>()
    /// Whether the on-screen target has been synced to the belt for the current connection.
    private var hasAlignedTargetWithBelt = false
    private let defaults = UserDefaults.standard

    init() {
        let loaded = AppModel.load(from: defaults)
        storedSettings = loaded
        desiredSpeedKph = loaded.startSpeedKph
        tracker.profile = loaded.profile
        storedProgram = AppModel.loadDraftProgram(from: defaults)
        storedSavedPrograms = AppModel.loadSavedPrograms(from: defaults)

        // Feed every status frame into the metrics tracker.
        controller.onStatus = { [weak self] status in
            guard let self else { return }
            self.tracker.ingest(status)
            // The belt's 1 Hz status stream is the program's clock: it can only advance while the
            // belt is actually connected and reporting.
            self.runner.tick(beltIsMoving: status.isMoving)
            // Record the walk. The recorder returns a session when one has just finished.
            self.recorder.programName = self.runner.activeProgram?.name
            if let finished = self.recorder.ingest(status) {
                self.store.append(finished)
                self.controller.appendLog(
                    String(format: "Saved walk: %@ · %.2f km · %d steps",
                           Metrics.formatDuration(finished.durationSeconds),
                           finished.distanceKm, finished.steps),
                    .info
                )
            }
            if !self.hasAlignedTargetWithBelt {
                self.hasAlignedTargetWithBelt = true
                self.desiredSpeedKph = status.isMoving
                    ? status.speedKph
                    : min(self.settings.startSpeedKph, self.effectiveMaxSpeed)
            }
        }

        // Re-align on the next connection rather than carrying a stale target across sessions,
        // and never leave a program "running" against a belt that is no longer there.
        controller.$state
            .map(\.isConnected)
            .removeDuplicates()
            .sink { [weak self] connected in
                guard let self else { return }
                if !connected {
                    self.hasAlignedTargetWithBelt = false
                    self.runner.stop(reason: "belt disconnected")
                    // Bank the walk in progress rather than losing it to the dropout.
                    self.finishOpenWalk()
                    self.recorder.clear()
                }
            }
            .store(in: &cancellables)

        // The program speaks to the belt through the controller directly, so that its own writes
        // are not mistaken for the manual override that cancels a program.
        runner.onSpeed = { [weak self] kph in self?.applyProgramSpeed(kph) }
        runner.onNote = { [weak self] note in self?.controller.appendLog(note, .info) }

        runner.objectWillChange
            .merge(with: store.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        recorder.profile = loaded.profile

        // Quitting mid-walk should still save it.
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.finishOpenWalk() }
            .store(in: &cancellables)

        // Re-render on belt updates and on tracker changes.
        controller.objectWillChange
            .merge(with: tracker.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        if settings.autoConnectOnLaunch { controller.connect() }
    }

    // MARK: - Derived view state

    var status: PadStatus? { controller.status }
    var isConnected: Bool { controller.state.isConnected }
    var isMoving: Bool { status?.isMoving ?? false }

    var beltSpeedKph: Double { status?.speedKph ?? 0 }

    var averageSpeedKph: Double { tracker.averageSpeedKph(status: status) }

    var paceMinPerUnit: Double? {
        settings.unit.pace(fromMinPerKm: Metrics.pace(speedKph: beltSpeedKph))
    }

    var effectiveMaxSpeed: Double {
        min(settings.speedCeilingKph, AppSettings.hardMaxSpeedKph)
    }

    /// True while we've asked for a speed the belt hasn't confirmed yet.
    var isSpeedPending: Bool { controller.inFlightSpeedRaw != nil }

    // MARK: - Intents

    func toggleConnection() {
        isConnected || controller.state.isBusy ? controller.disconnect() : controller.connect()
    }

    /// Wakes the belt into manual mode and starts it at the configured start speed.
    func start() {
        guard isConnected else { return }
        // If a program is running (paused because the belt was idle), pick its speed back up
        // rather than dropping to the manual start speed and fighting it on the next step.
        let speed = clamp(runner.isRunning ? runner.currentKph : settings.startSpeedKph)
        desiredSpeedKph = speed
        controller.startWalking(at: speed)
    }

    func stop() {
        // Stopping the belt ends the program too; otherwise it would restart the belt on its next
        // step and a Stop press would look like it had been ignored.
        if runner.isRunning { runner.stop(reason: "belt stopped") }
        controller.stop()
    }

    func toggleStartStop() {
        isMoving ? stop() : start()
    }

    /// Commits the slider/stepper value to the belt.
    func commitSpeed(_ kph: Double) {
        // Bail before touching the displayed target. Otherwise the menu's ⌘↑/⌘↓ would drift the
        // target while disconnected, and the next committed change would start the belt at a
        // speed the user never actually chose.
        guard isConnected else { return }
        // Taking the speed by hand means you have taken over from the program.
        if runner.isRunning { runner.stop(reason: "manual speed change") }
        let speed = clamp(kph)
        if speed < AppSettings.minRunningSpeedKph {
            // The belt cannot run this slowly and ignores such a request outright, which would
            // leave the UI waiting for a confirmation that never comes. Treat it as a stop.
            desiredSpeedKph = 0
            controller.stop()
            return
        }
        desiredSpeedKph = speed
        sendSpeedToBelt(speed, mayStartBelt: true)
    }

    /// The single place that decides how a speed reaches the belt.
    ///
    /// - Parameter mayStartBelt: whether a stopped belt should be started to honour this speed.
    ///   Only ever true for an explicit user action or a program that is genuinely beginning —
    ///   never for a background correction, which must not start a treadmill nobody expects to move.
    private func sendSpeedToBelt(_ kph: Double, mayStartBelt: Bool) {
        guard isConnected else { return }
        if !isMoving {
            guard mayStartBelt else { return }
            // A speed change on a stopped belt needs the belt started first.
            controller.startWalking(at: kph)
        } else {
            controller.setSpeed(kph: kph)
        }
    }

    func nudgeSpeed(by delta: Double) {
        commitSpeed(desiredSpeedKph + delta)
    }

    func setMode(_ mode: PadMode) { controller.setMode(mode) }

    func refreshStoredSession() { controller.requestHistory() }

    func resetSessionMetrics() { tracker.reset() }

    private func clamp(_ kph: Double) -> Double {
        let rounded = (kph * 10).rounded() / 10
        return min(max(0, rounded), effectiveMaxSpeed)
    }

    // MARK: - Walk history

    /// Close and save the walk in progress, if there is one worth keeping.
    func finishOpenWalk() {
        if let finished = recorder.finish() {
            store.append(finished)
        }
    }

    /// Every recorded walk, newest first.
    var sessions: [WalkSession] { store.sessionsNewestFirst }

    /// Lifetime totals across everything recorded.
    var lifetimeTotals: WalkTotals { WalkStats.totals(store.sessions) }

    /// Totals including the walk currently in progress, so the dashboard adds up live.
    var lifetimeTotalsIncludingCurrent: WalkTotals {
        var totals = lifetimeTotals
        if let open = recorder.openSession {
            totals.distanceKm += open.distanceKm
            totals.durationSeconds += open.duration
            totals.steps += open.steps
            totals.kcal += open.kcal
        }
        return totals
    }

    var isRecordingWalk: Bool { recorder.isRecording }

    func deleteSession(_ session: WalkSession) { store.delete(session) }
    func deleteSessions(ids: Set<UUID>) { store.delete(ids: ids) }

    /// CSV of the whole history, for export.
    func historyCSV() -> String { WalkStats.csv(store.sessions) }

    // MARK: - Programs ("algorithms")

    var isProgramRunning: Bool { runner.isRunning }

    /// Start the edited program. Clamped to the app's speed ceiling by the runner.
    func startProgram() {
        guard isConnected else { return }
        runner.start(program, ceilingRaw: SpeedProgram.raw(effectiveMaxSpeed))
    }

    func stopProgram() {
        runner.stop(reason: "stopped by you")
    }

    func toggleProgram() {
        isProgramRunning ? stopProgram() : startProgram()
    }

    /// A speed the program asked for. Goes straight to the controller so it is not treated as a
    /// manual override, and starts the belt if the program is beginning from a standstill.
    private func applyProgramSpeed(_ kph: Double) {
        let speed = clamp(kph)
        desiredSpeedKph = speed
        // A paused program must never start the belt: it is paused precisely because the belt is
        // idle, and the user did not ask for it to move.
        sendSpeedToBelt(speed, mayStartBelt: !runner.isPaused)
    }

    /// Save the edited program over the stored copy with the same id, or add it if new.
    func saveProgram() {
        if let index = savedPrograms.firstIndex(where: { $0.id == program.id }) {
            savedPrograms[index] = program
        } else {
            savedPrograms.append(program)
        }
    }

    /// Save the edited program as a new, separately named entry.
    func saveProgramAsNew(named name: String) {
        var copy = program
        copy.id = UUID()
        copy.name = name.isEmpty ? "Program \(savedPrograms.count + 1)" : name
        savedPrograms.append(copy)
        program = copy
    }

    func loadProgram(_ saved: SpeedProgram) {
        program = saved
    }

    func deleteProgram(_ saved: SpeedProgram) {
        savedPrograms.removeAll { $0.id == saved.id }
    }

    /// True when the program can actually be started right now.
    var canStartProgram: Bool {
        program.isValid && program.clamped(toCeilingRaw: SpeedProgram.raw(effectiveMaxSpeed)) != nil
    }

    /// A note when the app's speed ceiling gets in the program's way. The program is left exactly
    /// as the user wrote it — silently rewriting their numbers would lose their intent — but the
    /// consequence is spelled out rather than discovered when Start does nothing.
    var programCeilingNote: String? {
        guard program.isValid else { return nil }
        let ceilingRaw = SpeedProgram.raw(effectiveMaxSpeed)
        guard program.maxRaw > ceilingRaw else { return nil }
        guard let fitted = program.clamped(toCeilingRaw: ceilingRaw) else {
            return String(
                format: "The app's speed ceiling (%.1f km/h) is below this program's range. "
                    + "Raise it in Settings to run this program.",
                effectiveMaxSpeed
            )
        }
        return String(
            format: "The app's speed ceiling (%.1f km/h) will limit this program to %.1f–%.1f km/h.",
            effectiveMaxSpeed, fitted.minKph, fitted.maxKph
        )
    }

    /// Whether the edited program differs from its saved counterpart.
    var programHasUnsavedChanges: Bool {
        guard let stored = savedPrograms.first(where: { $0.id == program.id }) else { return true }
        return stored != program
    }

    /// Restore the defaults from the original request: 4.0–5.5 km/h, 0.1 steps, every 2 minutes.
    func resetProgramToDefaults() {
        var fresh = SpeedProgram.standard
        fresh.id = program.id
        fresh.name = program.name
        program = fresh
    }

    // MARK: - Belt-side preferences

    func applyBeltMaxSpeed(_ kph: Double) {
        controller.setPreference(.maxSpeed, value: Int((kph * 10).rounded()))
    }

    func applyBeltStartSpeed(_ kph: Double) {
        controller.setPreference(.startSpeed, value: Int((kph * 10).rounded()))
    }

    func applySensitivity(_ sensitivity: PadSensitivity) {
        controller.setPreference(.sensitivity, value: Int(sensitivity.rawValue))
    }

    func applyChildLock(_ enabled: Bool) {
        controller.setPreference(.childLock, value: enabled ? 1 : 0)
    }

    func applyBeltUnits(miles: Bool) {
        controller.setPreference(.units, value: miles ? 1 : 0)
    }

    func applyIntelligentStart(_ enabled: Bool) {
        controller.setPreference(.intelligentStart, value: enabled ? 1 : 0)
    }

    func applyTarget(_ target: PadTarget, value: Int) {
        controller.setTarget(target, value: value)
    }

    // MARK: - Persistence

    private func persist() {
        defaults.set(settings.unit.rawValue, forKey: Keys.unit)
        defaults.set(settings.speedCeilingKph, forKey: Keys.ceiling)
        defaults.set(settings.startSpeedKph, forKey: Keys.startSpeed)
        defaults.set(settings.weightKg, forKey: Keys.weight)
        defaults.set(settings.heightCm, forKey: Keys.height)
        defaults.set(settings.autoConnectOnLaunch, forKey: Keys.autoConnect)
        defaults.set(settings.showMenuBarExtra, forKey: Keys.menuBar)
    }

    private func persistPrograms() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(program) {
            defaults.set(data, forKey: Keys.draftProgram)
        }
        if let data = try? encoder.encode(savedPrograms) {
            defaults.set(data, forKey: Keys.savedPrograms)
        }
    }

    private static func loadDraftProgram(from defaults: UserDefaults) -> SpeedProgram {
        guard let data = defaults.data(forKey: Keys.draftProgram),
              let decoded = try? JSONDecoder().decode(SpeedProgram.self, from: data)
        else { return .standard }
        // Never load a program that cannot run; fall back to the known-good defaults.
        return decoded.isValid ? decoded : .standard
    }

    private static func loadSavedPrograms(from defaults: UserDefaults) -> [SpeedProgram] {
        guard let data = defaults.data(forKey: Keys.savedPrograms),
              let decoded = try? JSONDecoder().decode([SpeedProgram].self, from: data)
        else { return [] }
        return decoded.filter(\.isValid)
    }

    private static func load(from defaults: UserDefaults) -> AppSettings {
        var settings = AppSettings()
        if let raw = defaults.string(forKey: Keys.unit), let unit = DistanceUnit(rawValue: raw) {
            settings.unit = unit
        }
        if defaults.object(forKey: Keys.ceiling) != nil {
            settings.speedCeilingKph = defaults.double(forKey: Keys.ceiling)
        }
        if defaults.object(forKey: Keys.startSpeed) != nil {
            settings.startSpeedKph = defaults.double(forKey: Keys.startSpeed)
        }
        if defaults.object(forKey: Keys.weight) != nil {
            settings.weightKg = defaults.double(forKey: Keys.weight)
        }
        if defaults.object(forKey: Keys.height) != nil {
            settings.heightCm = defaults.double(forKey: Keys.height)
        }
        if defaults.object(forKey: Keys.autoConnect) != nil {
            settings.autoConnectOnLaunch = defaults.bool(forKey: Keys.autoConnect)
        }
        if defaults.object(forKey: Keys.menuBar) != nil {
            settings.showMenuBarExtra = defaults.bool(forKey: Keys.menuBar)
        }
        // Guard against nonsense persisted values.
        settings.speedCeilingKph = min(max(1, settings.speedCeilingKph), AppSettings.hardMaxSpeedKph)
        settings.startSpeedKph = min(max(0.5, settings.startSpeedKph), settings.speedCeilingKph)
        settings.weightKg = min(max(25, settings.weightKg), 250)
        settings.heightCm = min(max(100, settings.heightCm), 230)
        return settings
    }

    private enum Keys {
        static let unit = "unit"
        static let ceiling = "speedCeilingKph"
        static let startSpeed = "startSpeedKph"
        static let weight = "weightKg"
        static let height = "heightCm"
        static let autoConnect = "autoConnectOnLaunch"
        static let menuBar = "showMenuBarExtra"
        static let draftProgram = "draftProgram"
        static let savedPrograms = "savedPrograms"
    }
}
