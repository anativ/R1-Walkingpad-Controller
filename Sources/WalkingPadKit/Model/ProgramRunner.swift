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
    @Published public private(set) var state = SpeedSequence.State(
        index: 0, raw: 0, seconds: 0, tier: .easy, isRising: true
    )
    /// When the next speed change is due. Nil while paused or stopped.
    @Published public private(set) var nextChangeAt: Date?
    @Published public private(set) var stepsApplied = 0
    @Published public private(set) var isPaused = false
    /// Seconds spent in `brisk`/`surge` blocks — the dose the interval-walking trials prescribe.
    /// Paused time never counts, because you were standing still.
    @Published public private(set) var workSeconds: TimeInterval = 0
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

    /// The most one tick may add to the work-minute total. Status frames arrive at 1 Hz, so a
    /// larger gap means the stream stalled — crediting the whole gap would invent minutes you did
    /// not walk.
    public static let maxCreditedTickGap: TimeInterval = 5

    private var notMovingSince: Date?
    /// When the work-minute total was last credited. Nil while paused or stopped.
    private var lastCreditedAt: Date?

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
        workSeconds = 0
        lastCreditedAt = now
        nextChangeAt = now.addingTimeInterval(Double(state.seconds))
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
        lastCreditedAt = nil
        if let reason { onNote?("Program stopped: \(reason)") } else { onNote?("Program stopped") }
    }

    /// Re-apply the app's speed ceiling to a program that is already running — for instance when
    /// the user lowers the ceiling mid-session. Without this the program would keep stepping toward
    /// its old maximum while the belt silently clamped, so the displayed step and the belt's real
    /// speed would disagree.
    /// - Returns: whether a running program is still driving the belt within the new ceiling.
    ///   `false` means the caller must enforce the ceiling itself — either there was no program, or
    ///   there was one and it had to be stopped, and stopping commands no speed at all.
    @discardableResult
    public func applyCeiling(_ ceilingRaw: Int) -> Bool {
        guard isRunning, let authored = authoredProgram, let current = activeProgram else {
            return false
        }
        // Re-clamp the AUTHORED program, not the running (already clamped) one, so raising the
        // ceiling widens the range back out instead of leaving it stuck where it was cut.
        guard let runnable = authored.clamped(toCeilingRaw: ceilingRaw) else {
            stop(reason: "speed ceiling leaves no room for the program")
            return false
        }
        guard runnable != current else { return true }
        onNote?(String(format: "Program range now %.1f–%.1f km/h (speed ceiling)",
                       runnable.minKph, runnable.maxKph))
        adopt(runnable)
        return true
    }

    /// Move a running program to a new band without restarting it — the pace mode changed, or the
    /// anchor was nudged, but the walk did not stop.
    ///
    /// This exists so that a meeting starting mid-session does not zero the brisk-minute total. It
    /// deliberately refuses to change the *shape* of what is running: only the same algorithm at a
    /// different band, never a different protocol by the back door.
    @discardableResult
    public func reband(to program: SpeedProgram, ceilingRaw: Int) -> Bool {
        guard isRunning, let current = activeProgram, program.kind == current.kind,
              program.isValid, let runnable = program.clamped(toCeilingRaw: ceilingRaw)
        else { return false }
        authoredProgram = program
        guard runnable != current else { return true }
        adopt(runnable)
        return true
    }

    /// Take up a freshly clamped program in place of the running one.
    ///
    /// Clamping the band changes the cycle underneath us, so the position in it has to be re-found
    /// rather than reused: a narrower drift has fewer blocks, and every block's speed may have
    /// moved. `stepsApplied` and `workSeconds` carry over untouched — the session did not restart.
    private func adopt(_ runnable: SpeedProgram) {
        activeProgram = runnable
        let previous = state
        let moved = remapped(previous, into: runnable)
        guard moved != previous else { return }
        state = moved
        // Keep the deadline anchored where it was, adjusted for a block of a different length, so
        // a settings change cannot fire a speed change immediately or push one far into the future.
        let lengthDelta = Double(moved.seconds - previous.seconds)
        if let due = nextChangeAt, lengthDelta != 0 {
            nextChangeAt = due.addingTimeInterval(lengthDelta)
        }
        // While paused the belt is deliberately idle, so this must NOT command a speed: doing so
        // would physically start a stopped treadmill as a side effect of a settings change.
        // tick() re-asserts the speed on resume, so nothing is lost by staying quiet here.
        if moved.raw != previous.raw, !isPaused { onSpeed?(currentKph) }
    }

    /// Where to stand in a freshly rebanded cycle.
    ///
    /// The position is matched by *block*, not by speed. Moving to a faster band shifts every speed
    /// at once, so "the block nearest this speed" would drop you out of a fast interval and into
    /// recovery — the old band's easy pace is the new band's brisk one. When the same block still
    /// exists at this index, stay in it and let its speed change; only when the cycle's shape itself
    /// changed (a narrower drift has fewer, differently placed blocks) fall back to the nearest
    /// speed, which keeps the clamp from throwing away where you were entirely.
    private func remapped(
        _ state: SpeedSequence.State, into program: SpeedProgram
    ) -> SpeedSequence.State {
        let cycle = program.cycle
        guard !cycle.isEmpty else { return SpeedSequence.start(of: program) }
        if state.index >= 0, state.index < cycle.count {
            let block = cycle[state.index]
            if block.tier == state.tier, block.seconds == state.seconds {
                return SpeedSequence.state(at: state.index, in: program, wasRising: state.isRising)
            }
        }
        var bestIndex = 0
        var bestDistance = Int.max
        for (index, block) in cycle.enumerated() where abs(block.raw - state.raw) < bestDistance {
            bestDistance = abs(block.raw - state.raw)
            bestIndex = index
        }
        return SpeedSequence.state(at: bestIndex, in: program, wasRising: state.isRising)
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
                lastCreditedAt = nil
                onNote?("Program paused — belt is not moving")
            }
            return
        }
        notMovingSince = nil

        if isPaused {
            isPaused = false
            nextChangeAt = now.addingTimeInterval(Double(state.seconds))
            lastCreditedAt = now
            onNote?("Program resumed")
            // Re-assert the speed the program expects, in case it was changed while paused.
            onSpeed?(currentKph)
            return
        }

        // Credit the time just elapsed to the block we were actually in, before advancing out of it.
        creditWork(upTo: now)

        guard let due = nextChangeAt else {
            nextChangeAt = now.addingTimeInterval(Double(state.seconds))
            return
        }
        guard now >= due else { return }

        state = SpeedSequence.next(state, in: program)
        stepsApplied += 1
        // Schedule from the deadline, not from now, so a late tick does not drift the programme.
        // If that would already be in the past (a long stall), restart the clock from now.
        let nextDue = due.addingTimeInterval(Double(state.seconds))
        nextChangeAt = nextDue > now ? nextDue : now.addingTimeInterval(Double(state.seconds))
        onSpeed?(currentKph)
    }

    private func creditWork(upTo now: Date) {
        defer { lastCreditedAt = now }
        guard let last = lastCreditedAt, state.tier.isWork else { return }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed > 0 else { return }
        workSeconds += min(elapsed, ProgramRunner.maxCreditedTickGap)
    }

    /// Seconds until the next change, for the UI. Nil while paused or stopped.
    public func secondsUntilNextChange(now: Date = Date()) -> Int? {
        guard isRunning, !isPaused, let nextChangeAt else { return nil }
        return max(0, Int(nextChangeAt.timeIntervalSince(now).rounded(.up)))
    }

    public var currentKph: Double { Double(state.raw) / 10 }

    /// Progress through the current cycle, 0...1, for a progress bar. Measured in time rather than
    /// in speed, because a cycle's blocks are not all the same length.
    public func cycleProgress(now: Date = Date()) -> Double {
        guard let program = activeProgram else { return 0 }
        let cycle = program.cycle
        let total = program.cycleDuration
        guard total > 0, state.index >= 0, state.index < cycle.count else { return 0 }
        let before = cycle.prefix(state.index).reduce(0) { $0 + $1.seconds }
        let remaining = Double(secondsUntilNextChange(now: now) ?? state.seconds)
        let intoBlock = max(0, Double(state.seconds) - remaining)
        return min(1, max(0, (Double(before) + intoBlock) / total))
    }

    /// How much of the researched per-session dose of brisk walking has been done, 0...1.
    /// Nil for programs no trial has prescribed a dose for.
    public var doseProgress: Double? {
        guard let kind = activeProgram?.kind,
              let target = PaceAlgorithm.named(kind)?.sessionWorkSeconds, target > 0
        else { return nil }
        return min(1, workSeconds / Double(target))
    }
}
