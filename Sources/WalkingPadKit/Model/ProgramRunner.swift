import Combine
import Foundation

/// Drives a `SpeedProgram` against the belt.
///
/// The runner holds no timer of its own. It is advanced by `tick(...)`, which the app calls from
/// the belt's own 1 Hz status stream — so a program can only progress while the belt is actually
/// connected and reporting, and it cannot silently march on after a dropout.
///
/// The schedule pauses whenever the belt is not moving. Pausing the belt therefore pauses the
/// program rather than burning through its steps while you stand still.
public final class ProgramRunner: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var state = SpeedSequence.State(raw: 0)
    /// When the next speed change is due. Nil while paused or stopped.
    @Published public private(set) var nextChangeAt: Date?
    @Published public private(set) var stepsApplied = 0
    @Published public private(set) var isPaused = false
    /// The program actually running, already clamped to the app's ceiling.
    @Published public private(set) var activeProgram: SpeedProgram?
    /// The program as the user wrote it. Kept so that raising the ceiling can restore the range
    /// it was authored with — re-clamping the already-clamped copy would lose it permanently.
    private var authoredProgram: SpeedProgram?

    /// Called when the program wants the belt at a new speed, in km/h.
    public var onSpeed: ((Double) -> Void)?
    /// Called with a human-readable note worth showing in the event log.
    public var onNote: ((String) -> Void)?

    /// A belt takes a few seconds to spin up after a start command, and briefly reports zero speed
    /// during a speed change. Pausing on the first such frame would stall the program before it
    /// ever got going, so the belt must be still for this long before the program pauses.
    public static let pauseGraceSeconds: TimeInterval = 10

    private var notMovingSince: Date?

    public init() {}

    /// Begin a program. Returns false (and does nothing) if the program cannot run.
    @discardableResult
    public func start(_ program: SpeedProgram, ceilingRaw: Int, now: Date = Date()) -> Bool {
        guard program.isValid, let runnable = program.clamped(toCeilingRaw: ceilingRaw) else {
            onNote?("Program cannot run: \(program.validationError ?? "speed ceiling leaves no range")")
            return false
        }
        if runnable != program {
            onNote?(String(
                format: "Program limited to %.1f–%.1f km/h by the app's speed ceiling",
                runnable.minKph, runnable.maxKph
            ))
        }
        authoredProgram = program
        activeProgram = runnable
        state = SpeedSequence.start(of: runnable)
        stepsApplied = 1
        isRunning = true
        isPaused = false
        notMovingSince = nil
        nextChangeAt = now.addingTimeInterval(Double(runnable.intervalSeconds))
        onNote?(String(format: "Program “%@” started at %.1f km/h", runnable.name, currentKph))
        onSpeed?(currentKph)
        return true
    }

    public func stop(reason: String? = nil) {
        guard isRunning else { return }
        isRunning = false
        isPaused = false
        nextChangeAt = nil
        activeProgram = nil
        authoredProgram = nil
        notMovingSince = nil
        if let reason { onNote?("Program stopped: \(reason)") } else { onNote?("Program stopped") }
    }

    /// Re-apply the app's speed ceiling to a program that is already running — for instance when
    /// the user lowers the ceiling mid-session. Without this the program would keep stepping toward
    /// its old maximum while the belt silently clamped, so the displayed step and the belt's real
    /// speed would disagree.
    public func applyCeiling(_ ceilingRaw: Int) {
        guard isRunning, let authored = authoredProgram, let current = activeProgram else { return }
        // Re-clamp the AUTHORED program, not the running (already clamped) one, so raising the
        // ceiling widens the range back out instead of leaving it stuck where it was cut.
        guard let runnable = authored.clamped(toCeilingRaw: ceilingRaw) else {
            stop(reason: "speed ceiling leaves no room for the program")
            return
        }
        guard runnable != current else { return }
        activeProgram = runnable
        onNote?(String(format: "Program range now %.1f–%.1f km/h (speed ceiling)",
                       runnable.minKph, runnable.maxKph))
        // Pull the current step back into the new band, heading away from the boundary.
        //
        // While paused the belt is deliberately idle, so this must NOT command a speed: doing so
        // would physically start a stopped treadmill as a side effect of a settings change.
        // tick() re-asserts the speed on resume, so nothing is lost by staying quiet here.
        if state.raw > runnable.maxRaw {
            state = SpeedSequence.State(raw: runnable.maxRaw, ascending: false)
            if !isPaused { onSpeed?(currentKph) }
        } else if state.raw < runnable.minRaw {
            state = SpeedSequence.State(raw: runnable.minRaw, ascending: true)
            if !isPaused { onSpeed?(currentKph) }
        }
    }

    /// Advance the program. Call once per belt status frame.
    ///
    /// - Parameters:
    ///   - beltIsMoving: whether the belt is actually running; a stopped belt pauses the schedule.
    ///   - now: current time, injected so the behaviour is testable.
    public func tick(beltIsMoving: Bool, now: Date = Date()) {
        guard isRunning, let program = activeProgram else { return }

        guard beltIsMoving else {
            // Freeze the countdown while the belt is idle, but only once it has been idle long
            // enough that this is not just spin-up or a momentary dip during a speed change.
            let since = notMovingSince ?? now
            notMovingSince = since
            if !isPaused, now.timeIntervalSince(since) >= ProgramRunner.pauseGraceSeconds {
                isPaused = true
                nextChangeAt = nil
                onNote?("Program paused — belt is not moving")
            }
            return
        }
        notMovingSince = nil

        if isPaused {
            isPaused = false
            nextChangeAt = now.addingTimeInterval(Double(program.intervalSeconds))
            onNote?("Program resumed")
            // Re-assert the speed the program expects, in case it was changed while paused.
            onSpeed?(currentKph)
            return
        }

        guard let due = nextChangeAt else {
            nextChangeAt = now.addingTimeInterval(Double(program.intervalSeconds))
            return
        }
        guard now >= due else { return }

        state = SpeedSequence.next(state, in: program)
        stepsApplied += 1
        // Schedule from the deadline, not from now, so a late tick does not drift the programme.
        // If we are more than one interval late (a long stall), restart the clock from now.
        let interval = Double(program.intervalSeconds)
        let nextDue = due.addingTimeInterval(interval)
        nextChangeAt = nextDue > now ? nextDue : now.addingTimeInterval(interval)
        onSpeed?(currentKph)
    }

    /// Seconds until the next change, for the UI. Nil while paused or stopped.
    public func secondsUntilNextChange(now: Date = Date()) -> Int? {
        guard isRunning, !isPaused, let nextChangeAt else { return nil }
        return max(0, Int(nextChangeAt.timeIntervalSince(now).rounded(.up)))
    }

    public var currentKph: Double { Double(state.raw) / 10 }

    /// Progress through the current lap, 0...1, for a progress bar.
    public func lapProgress() -> Double {
        guard let program = activeProgram, program.maxRaw > program.minRaw else { return 0 }
        let span = Double(program.maxRaw - program.minRaw)
        return min(1, max(0, Double(state.raw - program.minRaw) / span))
    }
}
