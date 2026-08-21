import AppKit
import Combine
import Foundation
import SwiftUI
import WalkingPadKit

/// User-facing settings, persisted in UserDefaults.
/// What the menu-bar item shows next to its icon.
enum MenuBarReadout: String, CaseIterable, Identifiable {
    case iconOnly, speed, speedAndDistance, speedAndTime, speedAndSteps

    var id: String { rawValue }

    var label: String {
        switch self {
        case .iconOnly: return "Icon only"
        case .speed: return "Speed"
        case .speedAndDistance: return "Speed and distance"
        case .speedAndTime: return "Speed and time"
        case .speedAndSteps: return "Speed and steps"
        }
    }
}

struct AppSettings: Equatable {
    var unit: DistanceUnit = .kilometers
    /// Everyday walking ceiling for the slider, presets and programs. Independent of the belt's
    /// own max-speed setting.
    var speedCeilingKph: Double = SpeedLimits.defaultWalkingCeilingKph
    /// Running mode lifts the ceiling to the belt's hardware maximum.
    var isRunningMode: Bool = false
    /// What you are doing at the desk, which decides the band the pace algorithms walk in.
    var paceMode: PaceMode = .work
    /// The anchor pace each mode is built around, in raw 0.1 km/h units. Every algorithm places
    /// its own band around the anchor, so one number per mode tunes all of them together.
    var workAnchorRaw: Int = PaceMode.work.defaultAnchorRaw
    var meetingAnchorRaw: Int = PaceMode.meeting.defaultAnchorRaw
    /// Speed the Start button uses.
    var startSpeedKph: Double = 2.5
    var weightKg: Double = 75
    var heightCm: Double = 175
    var ageYears: Double = 35
    var sex: BiologicalSex = .male
    /// How weight is entered and shown. Stored value is always kilograms.
    var weightUnit: WeightUnit = .kilograms
    /// Show calories net of resting metabolism — the extra the walk actually cost.
    var showNetCalories: Bool = false
    var autoConnectOnLaunch: Bool = true
    var showMenuBarExtra: Bool = true
    /// What the menu-bar item displays. Visible whether or not any window is open.
    var menuBarContent: MenuBarReadout = .speed
    /// Run as a menu-bar-only app: no Dock icon, no app switcher entry.
    var hideDockIcon: Bool = false
    /// What to do about a moving belt when the app quits.
    var quitBehavior: QuitBehavior = .ask

    /// The R1 Pro tops out at 10 km/h; never let the UI ask for more than the hardware allows.
    static let hardMaxSpeedKph: Double = SpeedLimits.hardMaxKph
    static let minRunningSpeedKph: Double = SpeedLimits.minRunningKph

    var profile: UserProfile {
        UserProfile(weightKg: weightKg, heightCm: heightCm, ageYears: ageYears, sex: sex)
    }

    /// The anchor pace for a mode, kept inside that mode's sane range.
    func anchorRaw(for mode: PaceMode) -> Int {
        let stored = mode == .work ? workAnchorRaw : meetingAnchorRaw
        return min(max(mode.anchorRange.lowerBound, stored), mode.anchorRange.upperBound)
    }

    mutating func setAnchorRaw(_ raw: Int, for mode: PaceMode) {
        let clamped = min(max(mode.anchorRange.lowerBound, raw), mode.anchorRange.upperBound)
        switch mode {
        case .work: workAnchorRaw = clamped
        case .meeting: meetingAnchorRaw = clamped
        }
    }
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
            var newValue = newValue
            // Hiding the Dock icon without a menu-bar item would leave a running app with no icon,
            // no window and no menu to quit from — recoverable only via Force Quit.
            if newValue.hideDockIcon { newValue.showMenuBarExtra = true }
            guard newValue != storedSettings else { return }
            let oldValue = storedSettings
            objectWillChange.send()
            storedSettings = newValue
            persist()
            tracker.profile = newValue.profile
            recorder.profile = newValue.profile
            if newValue.hideDockIcon != oldValue.hideDockIcon {
                applyDockIconPolicy(hidden: newValue.hideDockIcon)
            }
            // A Slider whose value sits outside its own range misbehaves, so follow the ceiling down.
            let ceiling = SpeedLimits.effectiveCeiling(
                walkingCeilingKph: newValue.speedCeilingKph, isRunningMode: newValue.isRunningMode
            )
            if desiredSpeedKph > ceiling { desiredSpeedKph = ceiling }

            // A running program adopts the new band first, and reports whether it is still driving.
            let programStillDriving = runner.applyCeiling(SpeedProgram.raw(ceiling))

            // Then the ceiling is enforced against the belt itself. This must NOT be skipped just
            // because a program was running: `applyCeiling` stops a program whose band no longer
            // fits, and stopping commands no speed, so the belt would have kept its old pace while
            // the UI showed the new limit. Sent through the controller directly, so that lowering
            // the ceiling is not mistaken for the manual override that ends a program.
            if SpeedLimits.needsCorrectiveWrite(
                programStillDriving: programStillDriving,
                isConnected: isConnected,
                beltIsMovingOrAboutTo: beltIsMovingOrAboutTo,
                commandedSpeedKph: commandedSpeedKph,
                ceilingKph: ceiling
            ) {
                controller.appendLog(
                    String(format: "Ceiling lowered to %.1f km/h — slowing the belt", ceiling), .warning
                )
                sendSpeedToBelt(ceiling, mayStartBelt: false)
            }
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
                let ceiling = self.effectiveMaxSpeed
                self.desiredSpeedKph = status.isMoving
                    ? min(status.speedKph, ceiling)
                    : min(self.settings.startSpeedKph, ceiling)
                // The belt can be found already running faster than the ceiling now in force —
                // reconnecting after a dropout, or after leaving Run mode while disconnected.
                // The ceiling has to reach the hardware, not just the on-screen number.
                if status.isMoving, status.speedKph > ceiling {
                    self.controller.appendLog(
                        String(format: "Belt was above the %.1f km/h ceiling on connect — slowing it",
                               ceiling), .warning
                    )
                    self.sendSpeedToBelt(ceiling, mayStartBelt: false)
                }
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

        applyDockIconPolicy(hidden: loaded.hideDockIcon)

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
        SpeedLimits.effectiveCeiling(
            walkingCeilingKph: settings.speedCeilingKph, isRunningMode: settings.isRunningMode
        )
    }

    /// Speed buttons appropriate to the ceiling in force.
    var speedPresets: [Double] { SpeedLimits.presets(forCeiling: effectiveMaxSpeed) }

    /// Turn running mode on or off. Unlocking the higher range never changes the belt's speed by
    /// itself; turning it off pulls anything above the walking ceiling back down.
    func setRunningMode(_ enabled: Bool) {
        guard settings.isRunningMode != enabled else { return }
        var updated = settings
        updated.isRunningMode = enabled
        settings = updated
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

    /// Switching to `.accessory` drops the Dock icon so the app lives only in the menu bar.
    /// The menu-bar readout keeps updating either way — it does not depend on a window.
    private func applyDockIconPolicy(hidden: Bool) {
        NSApp?.setActivationPolicy(hidden ? .accessory : .regular)
    }

    /// Re-apply the saved Dock-icon preference. `AppModel` is built during scene setup, where
    /// `NSApp` can still be nil, so the preference is applied again once a view is on screen.
    func reapplyDockIconPolicy() {
        applyDockIconPolicy(hidden: settings.hideDockIcon)
    }

    /// The one-line summary shown in the menu bar.
    var menuBarSummary: String? {
        guard settings.menuBarContent != .iconOnly else { return nil }
        guard isConnected, let status = controller.status else { return nil }
        let unit = settings.unit
        let speed = String(format: "%.1f", unit.speed(fromKph: status.speedKph))
        switch settings.menuBarContent {
        case .iconOnly:
            return nil
        case .speed:
            // Just the number: it replaces the icon. The menu states the unit explicitly.
            return speed
        case .speedAndDistance:
            return String(format: "%@ · %.2f %@", speed,
                          unit.distance(fromKm: status.distanceKm), unit.distanceSuffix)
        case .speedAndTime:
            return "\(speed) · \(Metrics.formatDuration(status.elapsed))"
        case .speedAndSteps:
            return "\(speed) · \(status.steps) steps"
        }
    }

    // MARK: - Quitting

    private var quitStopTimer: Timer?
    private var quitBackstop: DispatchWorkItem?
    private var hasRepliedToQuit = false

    /// Decide what to do about a quit request. Called from the app delegate.
    ///
    /// Returning `.terminateLater` means we owe AppKit a `reply(toApplicationShouldTerminate:)`,
    /// which every branch below guarantees — a quit must never hang waiting on hardware.
    func handleQuitRequest() -> NSApplication.TerminateReply {
        switch QuitPolicy.action(
            behavior: settings.quitBehavior,
            isConnected: isConnected,
            beltIsMoving: beltIsMovingOrAboutTo
        ) {
        case .quitNow:
            return .terminateNow
        case .stopThenQuit:
            beginStopThenQuit()
            return .terminateLater
        case .askUser:
            switch presentQuitAlert() {
            case .stopAndQuit:
                beginStopThenQuit()
                return .terminateLater
            case .quitAnyway:
                return .terminateNow
            case .cancel:
                return .terminateCancel
            }
        }
    }

    /// Whether the belt is moving, or has been told to and simply has not reported it yet.
    ///
    /// Status frames arrive about once a second and a start sequence takes ~1.4 s to clear the
    /// command queue, so `isMoving` alone says "stopped" for a moment after you press Start. Quitting
    /// in that window would skip the prompt entirely and walk away from a belt about to move.
    var beltIsMovingOrAboutTo: Bool {
        if isMoving { return true }
        if let pending = controller.inFlightSpeedRaw, pending > 0 { return true }
        return false
    }

    /// The highest speed the belt is running at or has already been told to run at.
    ///
    /// A speed committed a moment ago is not in a status frame yet, so the belt's reported speed
    /// alone would let a faster in-flight command slip under a ceiling change.
    var commandedSpeedKph: Double {
        let inFlight = controller.inFlightSpeedRaw.map { Double($0) / 10 } ?? 0
        return max(beltSpeedKph, inFlight)
    }

    /// Speed to quote in the prompt: the belt's own, or the one it is still being told to run at.
    private var quotedSpeedKph: Double {
        if beltSpeedKph > 0 { return beltSpeedKph }
        if let pending = controller.inFlightSpeedRaw { return Double(pending) / 10 }
        return 0
    }

    private enum QuitChoice { case stopAndQuit, quitAnyway, cancel }

    private func presentQuitAlert() -> QuitChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = isMoving
            ? String(format: "The belt is still running at %.1f %@.",
                     settings.unit.speed(fromKph: quotedSpeedKph), settings.unit.speedSuffix)
            : String(format: "The belt is starting up at %.1f %@.",
                     settings.unit.speed(fromKph: quotedSpeedKph), settings.unit.speedSuffix)
        alert.informativeText = isProgramRunning
            ? "Quitting also ends the running program, so the belt will hold this speed instead of "
                + "continuing to change."
            : "Quitting does not stop the belt by itself."
        alert.addButton(withTitle: "Stop Belt and Quit")
        alert.addButton(withTitle: "Leave Running")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .stopAndQuit
        case .alertSecondButtonReturn: return .quitAnyway
        default: return .cancel
        }
    }

    /// Send a stop and hold the quit until the belt confirms it, or the timeout expires.
    private func beginStopThenQuit() {
        runner.stop(reason: "quitting")
        controller.stop()
        controller.appendLog("Quitting — waiting for the belt to stop", .info)
        hasRepliedToQuit = false

        let deadline = Date().addingTimeInterval(QuitPolicy.stopConfirmationTimeout)

        // The timer MUST be registered in `.common`. While AppKit waits for the terminate reply it
        // runs the run loop in NSModalPanelRunLoopMode, and a timer created by
        // `Timer.scheduledTimer` is registered only in the default mode — it would never fire, the
        // reply would never come, and the app would be unquittable.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    NSApp.reply(toApplicationShouldTerminate: true)
                    return
                }
                // A confirmed stop means the belt SAID it stopped. Losing the connection ends the
                // wait — we can no longer influence the belt — but it is not confirmation, and
                // treating it as such would quit silently on a belt that may still be running.
                let confirmed = !self.isMoving
                guard confirmed || !self.isConnected || Date() >= deadline else { return }
                timer.invalidate()
                if !confirmed, !self.isConnected {
                    self.controller.appendLog(
                        "Lost the connection while waiting for the stop to confirm", .warning
                    )
                }
                self.finishQuit(confirmedStopped: confirmed)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        quitStopTimer?.invalidate()
        quitStopTimer = timer

        // An independent backstop on the main queue, which is serviced in every run loop mode.
        // Two unrelated mechanisms means a hung quit needs both to fail.
        quitBackstop?.cancel()
        let backstop = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.hasRepliedToQuit else { return }
                self.controller.appendLog("Quit backstop fired", .warning)
                self.finishQuit(confirmedStopped: !self.isMoving)
            }
        }
        quitBackstop = backstop
        DispatchQueue.main.asyncAfter(
            deadline: .now() + QuitPolicy.stopConfirmationTimeout + 1, execute: backstop
        )
    }

    /// Reply to AppKit exactly once. Idempotent, because the timer and the backstop race.
    private func finishQuit(confirmedStopped: Bool) {
        guard !hasRepliedToQuit else { return }
        hasRepliedToQuit = true
        quitStopTimer?.invalidate()
        quitStopTimer = nil
        quitBackstop?.cancel()
        quitBackstop = nil

        var proceed = true
        if !confirmedStopped {
            // Quitting silently here would leave the user believing a treadmill is stopped when it
            // may not be. Put that decision to them rather than assuming.
            controller.appendLog(
                "Belt did not confirm the stop within "
                + "\(Int(QuitPolicy.stopConfirmationTimeout))s", .warning
            )
            proceed = confirmUnconfirmedStop()
        }
        if proceed { finishOpenWalk() }
        NSApp.reply(toApplicationShouldTerminate: proceed)
        // Cancelling leaves the app running, so allow a later quit to start this over.
        if !proceed { hasRepliedToQuit = false }
    }

    private func confirmUnconfirmedStop() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "The belt did not confirm that it stopped."
        alert.informativeText = "It may still be running. Check the belt, or quit anyway."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
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

    /// The calorie figure to display for a stored walk, honouring the net/gross preference.
    func displayKcal(gross: Double, durationSeconds: Int) -> Double {
        guard settings.showNetCalories else { return gross }
        return Metrics.netKcal(
            gross: gross, durationSeconds: durationSeconds, profile: settings.profile
        )
    }

    func displayKcal(for session: WalkSession) -> Double {
        displayKcal(gross: session.kcal, durationSeconds: session.durationSeconds)
    }

    func displayKcal(for totals: WalkTotals) -> Double {
        displayKcal(gross: totals.kcal, durationSeconds: totals.durationSeconds)
    }

    /// Live session calories, net or gross.
    var sessionKcal: Double {
        displayKcal(gross: tracker.kcal, durationSeconds: status?.elapsed ?? 0)
    }

    /// Whether the user has actually entered their own weight, or is still on the default.
    ///
    /// Worth surfacing: the estimate is mostly a function of weight, so a default one is a number
    /// nobody should trust, and silently showing it looks the same as a real one.
    var isBodyDataConfigured: Bool {
        UserDefaults.standard.object(forKey: Keys.weight) != nil
    }

    /// Label clarifying which figure is on screen.
    var kcalFootnote: String { settings.showNetCalories ? "net, estimated" : "estimated" }

    /// Recompute every stored walk's calories using the current body data.
    ///
    /// Stored calories are integrated live against the body data of the day, so correcting your
    /// weight later would otherwise only affect future walks and leave the history inconsistent.
    @discardableResult
    func recalculateHistoryCalories() -> Int {
        store.recalculateCalories(profile: settings.profile)
    }

    func deleteSession(_ session: WalkSession) { store.delete(session) }
    func deleteSessions(ids: Set<UUID>) { store.delete(ids: ids) }

    /// CSV of the whole history, for export.
    func historyCSV() -> String { WalkStats.csv(store.sessions) }

    // MARK: - Programs ("algorithms")

    var isProgramRunning: Bool { runner.isRunning }

    /// True only when the freehand editor is the thing driving the belt. The algorithm boxes use
    /// the same runner, so without this the editor would show a Stop button for someone else's run.
    var isFreehandProgramRunning: Bool { runner.isRunning && !startedFromAlgorithmBox }

    /// Start the edited program. Clamped to the app's speed ceiling by the runner.
    func startProgram() {
        guard isConnected else { return }
        startedFromAlgorithmBox = false
        runner.start(program, ceilingRaw: SpeedProgram.raw(effectiveMaxSpeed))
    }

    func stopProgram() {
        startedFromAlgorithmBox = false
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

    /// A note when the app's speed ceiling gets in a program's way. The program is left exactly
    /// as the user wrote it — silently rewriting their numbers would lose their intent — but the
    /// consequence is spelled out rather than discovered when Start does nothing.
    func ceilingNote(for program: SpeedProgram) -> String? {
        guard program.isValid else { return nil }
        let ceilingRaw = SpeedProgram.raw(effectiveMaxSpeed)
        guard program.maxRaw > ceilingRaw else { return nil }
        guard let fitted = program.clamped(toCeilingRaw: ceilingRaw) else {
            return String(
                format: "The speed ceiling (%.1f km/h) is below this program's range. "
                    + "Switch to Run, or raise the limit in Settings, to run this program.",
                effectiveMaxSpeed
            )
        }
        return String(
            format: "The app's speed ceiling (%.1f km/h) will limit this program to %.1f–%.1f km/h.",
            effectiveMaxSpeed, fitted.minKph, fitted.maxKph
        )
    }

    var programCeilingNote: String? { ceilingNote(for: program) }

    // MARK: - Research-backed pace algorithms

    /// The anchor pace of the mode in force, in raw 0.1 km/h units.
    var currentAnchorRaw: Int { settings.anchorRaw(for: settings.paceMode) }

    /// The program an algorithm becomes right now: its own band, placed around the current mode's
    /// anchor pace. Not yet clamped — the runner applies the ceiling, and `ceilingNote(for:)`
    /// explains it.
    func bandedProgram(for algorithm: PaceAlgorithm) -> SpeedProgram {
        algorithm.program(anchorRaw: currentAnchorRaw)
    }

    /// Which algorithm is driving the belt, if one is.
    var runningAlgorithm: PaceAlgorithm? {
        guard let kind = runner.activeProgram?.kind, runner.isRunning else { return nil }
        // The freehand editor uses the same kinds, so only a run started from a box counts.
        guard startedFromAlgorithmBox else { return nil }
        return PaceAlgorithm.named(kind)
    }

    /// Set when a run was started from an algorithm box rather than the freehand editor, so the
    /// two places that can drive the belt do not each claim the other's running state.
    private var startedFromAlgorithmBox = false

    func isRunning(_ algorithm: PaceAlgorithm) -> Bool {
        runningAlgorithm?.kind == algorithm.kind
    }

    /// Whether this algorithm could start right now, ceiling included.
    func canStart(_ algorithm: PaceAlgorithm) -> Bool {
        let candidate = bandedProgram(for: algorithm)
        return candidate.isValid
            && candidate.clamped(toCeilingRaw: SpeedProgram.raw(effectiveMaxSpeed)) != nil
    }

    /// Start an algorithm from its box. Starting one while another runs swaps to it, which is what
    /// tapping a different box plainly means.
    func startAlgorithm(_ algorithm: PaceAlgorithm) {
        guard isConnected else { return }
        if runner.isRunning { runner.stop(reason: "switching program") }
        startedFromAlgorithmBox = runner.start(
            bandedProgram(for: algorithm), ceilingRaw: SpeedProgram.raw(effectiveMaxSpeed)
        )
    }

    func toggleAlgorithm(_ algorithm: PaceAlgorithm) {
        if isRunning(algorithm) {
            stopProgram()
        } else {
            startAlgorithm(algorithm)
        }
    }

    /// Switch what you are doing at the desk. A running algorithm follows the new band immediately
    /// — the whole point of the switch is that a meeting just started, or just ended.
    func setPaceMode(_ mode: PaceMode) {
        guard settings.paceMode != mode else { return }
        var updated = settings
        updated.paceMode = mode
        settings = updated
        guard let algorithm = runningAlgorithm else { return }
        let band = bandedProgram(for: algorithm)
        controller.appendLog(String(format: "%@ mode — %@ now %.1f–%.1f km/h",
                                    mode.label, algorithm.name, band.minKph, band.maxKph), .info)
        // Reband rather than restart: the brisk minutes already walked stay on the clock.
        runner.reband(to: band, ceilingRaw: SpeedProgram.raw(effectiveMaxSpeed))
    }

    /// Tune a mode's anchor pace. A running algorithm follows it live, so the band can be found by
    /// feel while walking instead of guessed at from a standstill.
    func setAnchorRaw(_ raw: Int, for mode: PaceMode) {
        var updated = settings
        updated.setAnchorRaw(raw, for: mode)
        settings = updated
        guard mode == settings.paceMode, let algorithm = runningAlgorithm else { return }
        runner.reband(to: bandedProgram(for: algorithm),
                      ceilingRaw: SpeedProgram.raw(effectiveMaxSpeed))
    }

    /// Whether the edited program differs from its saved counterpart.
    var programHasUnsavedChanges: Bool {
        guard let stored = savedPrograms.first(where: { $0.id == program.id }) else { return true }
        return stored != program
    }

    /// Restore the freehand defaults: a 4.0–5.5 km/h drift in 0.1 steps, every 2 minutes.
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
        defaults.set(settings.isRunningMode, forKey: Keys.runningMode)
        defaults.set(settings.paceMode.rawValue, forKey: Keys.paceMode)
        defaults.set(settings.workAnchorRaw, forKey: Keys.workAnchorRaw)
        defaults.set(settings.meetingAnchorRaw, forKey: Keys.meetingAnchorRaw)
        defaults.set(settings.startSpeedKph, forKey: Keys.startSpeed)
        defaults.set(settings.weightKg, forKey: Keys.weight)
        defaults.set(settings.heightCm, forKey: Keys.height)
        defaults.set(settings.ageYears, forKey: Keys.age)
        defaults.set(settings.sex.rawValue, forKey: Keys.sex)
        defaults.set(settings.weightUnit.rawValue, forKey: Keys.weightUnit)
        defaults.set(settings.showNetCalories, forKey: Keys.netCalories)
        defaults.set(settings.autoConnectOnLaunch, forKey: Keys.autoConnect)
        defaults.set(settings.showMenuBarExtra, forKey: Keys.menuBar)
        defaults.set(settings.menuBarContent.rawValue, forKey: Keys.menuBarContent)
        defaults.set(settings.hideDockIcon, forKey: Keys.hideDockIcon)
        defaults.set(settings.quitBehavior.rawValue, forKey: Keys.quitBehavior)
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
        if let raw = defaults.string(forKey: Keys.paceMode), let mode = PaceMode(rawValue: raw) {
            settings.paceMode = mode
        }
        if defaults.object(forKey: Keys.workAnchorRaw) != nil {
            settings.workAnchorRaw = defaults.integer(forKey: Keys.workAnchorRaw)
        }
        if defaults.object(forKey: Keys.meetingAnchorRaw) != nil {
            settings.meetingAnchorRaw = defaults.integer(forKey: Keys.meetingAnchorRaw)
        }
        if defaults.object(forKey: Keys.runningMode) != nil {
            settings.isRunningMode = defaults.bool(forKey: Keys.runningMode)
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
        if defaults.object(forKey: Keys.age) != nil {
            settings.ageYears = defaults.double(forKey: Keys.age)
        }
        if let raw = defaults.string(forKey: Keys.sex), let sex = BiologicalSex(rawValue: raw) {
            settings.sex = sex
        }
        if let raw = defaults.string(forKey: Keys.weightUnit), let unit = WeightUnit(rawValue: raw) {
            settings.weightUnit = unit
        }
        if defaults.object(forKey: Keys.netCalories) != nil {
            settings.showNetCalories = defaults.bool(forKey: Keys.netCalories)
        }
        if defaults.object(forKey: Keys.autoConnect) != nil {
            settings.autoConnectOnLaunch = defaults.bool(forKey: Keys.autoConnect)
        }
        if defaults.object(forKey: Keys.menuBar) != nil {
            settings.showMenuBarExtra = defaults.bool(forKey: Keys.menuBar)
        }
        if let raw = defaults.string(forKey: Keys.menuBarContent),
           let content = MenuBarReadout(rawValue: raw) {
            settings.menuBarContent = content
        }
        if defaults.object(forKey: Keys.hideDockIcon) != nil {
            settings.hideDockIcon = defaults.bool(forKey: Keys.hideDockIcon)
        }
        if let raw = defaults.string(forKey: Keys.quitBehavior),
           let behavior = QuitBehavior(rawValue: raw) {
            settings.quitBehavior = behavior
        }
        // Guard against nonsense persisted values.
        settings.speedCeilingKph = min(max(1, settings.speedCeilingKph), AppSettings.hardMaxSpeedKph)
        settings.startSpeedKph = min(max(0.5, settings.startSpeedKph), settings.speedCeilingKph)
        settings.weightKg = min(max(25, settings.weightKg), 250)
        settings.heightCm = min(max(100, settings.heightCm), 230)
        settings.ageYears = min(max(10, settings.ageYears), 100)
        // A corrupted anchor would put every algorithm's band in the wrong place, so round-trip
        // both through the mode's own range rather than trusting what was on disk.
        settings.setAnchorRaw(settings.workAnchorRaw, for: .work)
        settings.setAnchorRaw(settings.meetingAnchorRaw, for: .meeting)
        return settings
    }

    private enum Keys {
        static let unit = "unit"
        static let ceiling = "speedCeilingKph"
        static let runningMode = "isRunningMode"
        static let startSpeed = "startSpeedKph"
        static let weight = "weightKg"
        static let height = "heightCm"
        static let age = "ageYears"
        static let sex = "biologicalSex"
        static let weightUnit = "weightUnit"
        static let netCalories = "showNetCalories"
        static let autoConnect = "autoConnectOnLaunch"
        static let menuBar = "showMenuBarExtra"
        static let menuBarContent = "menuBarContent"
        static let hideDockIcon = "hideDockIcon"
        static let quitBehavior = "quitBehavior"
        static let paceMode = "paceMode"
        static let workAnchorRaw = "workAnchorRaw"
        static let meetingAnchorRaw = "meetingAnchorRaw"
        static let draftProgram = "draftProgram"
        static let savedPrograms = "savedPrograms"
    }
}
