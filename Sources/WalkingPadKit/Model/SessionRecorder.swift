import Foundation

/// Turns the belt's live status stream into completed `WalkSession` records.
///
/// The belt reports **cumulative** counters for its own session: they keep their values after you
/// stop walking and only reset when the belt sleeps or is reset. So a session is recorded as a
/// delta against a baseline captured when walking began — otherwise a second walk on the same belt
/// session would include the first walk's distance all over again.
///
/// A session ends when the belt's counters reset, when the belt has been idle past `idleTimeout`,
/// or when `finish` is called (disconnect, or the app quitting).
public final class SessionRecorder {
    /// Belt idle time after which the current walk is considered finished.
    public var idleTimeout: TimeInterval
    /// Walks shorter than this are discarded rather than cluttering the history.
    public var minimumDuration: Int
    public var minimumSteps: Int
    /// Body data for the calorie estimate.
    public var profile: UserProfile
    /// Name of the program driving the belt, recorded with the session.
    public var programName: String?

    private struct Baseline {
        var elapsed: Int
        var distanceRaw: Int
        var steps: Int
    }

    private var baseline: Baseline?
    private var startedAt: Date?
    private var lastStatus: PadStatus?
    private var lastMovingAt: Date?
    private var kcal: Double = 0
    private var peakSpeedKph: Double = 0

    public init(
        profile: UserProfile = UserProfile(),
        idleTimeout: TimeInterval = 120,
        minimumDuration: Int = 30,
        minimumSteps: Int = 20
    ) {
        self.profile = profile
        self.idleTimeout = idleTimeout
        self.minimumDuration = minimumDuration
        self.minimumSteps = minimumSteps
    }

    /// True while a walk is being recorded.
    public var isRecording: Bool { baseline != nil }

    /// Live totals for the walk in progress, if any.
    public var openSession: (duration: Int, distanceKm: Double, steps: Int, kcal: Double)? {
        guard let baseline, let status = lastStatus else { return nil }
        return (
            max(0, status.elapsed - baseline.elapsed),
            max(0, Double(status.distanceRaw - baseline.distanceRaw) / 100),
            max(0, status.steps - baseline.steps),
            kcal
        )
    }

    /// Feed one status frame. Returns a session if one just completed.
    public func ingest(_ status: PadStatus, now: Date = Date()) -> WalkSession? {
        var completed: WalkSession?

        // The belt zeroed its counters: whatever was open ended with the old counters.
        if let previous = lastStatus,
           status.elapsed < previous.elapsed || status.steps < previous.steps {
            completed = finish(now: now)
        }

        // Accumulate calories over the belt's own clock, so a pause pauses the burn.
        if baseline != nil, let previous = lastStatus {
            let delta = Double(status.elapsed - previous.elapsed)
            if delta > 0, delta <= 120 {
                kcal += Metrics.kcalPerMinute(speedKph: status.speedKph, profile: profile) * (delta / 60)
            }
        }

        lastStatus = status

        if status.isMoving {
            lastMovingAt = now
            peakSpeedKph = max(peakSpeedKph, status.speedKph)
            if baseline == nil {
                // Walking has begun: everything the belt has counted so far is not ours.
                baseline = Baseline(
                    elapsed: status.elapsed, distanceRaw: status.distanceRaw, steps: status.steps
                )
                startedAt = now
                kcal = 0
                peakSpeedKph = status.speedKph
            }
        } else if baseline != nil, let idleSince = lastMovingAt,
                  now.timeIntervalSince(idleSince) >= idleTimeout {
            // Idle long enough that the walk is over.
            completed = finish(now: now) ?? completed
        }

        return completed
    }

    /// Close any open walk — on disconnect, or when the app is quitting.
    /// Returns the session if it was substantial enough to keep.
    @discardableResult
    public func finish(now: Date = Date()) -> WalkSession? {
        defer { reset() }
        guard let baseline, let status = lastStatus, let startedAt else { return nil }

        let duration = max(0, status.elapsed - baseline.elapsed)
        let steps = max(0, status.steps - baseline.steps)
        let distanceKm = max(0, Double(status.distanceRaw - baseline.distanceRaw) / 100)

        // Discard trivial blips: a nudge of the belt is not a walk.
        guard duration >= minimumDuration, steps >= minimumSteps else { return nil }

        return WalkSession(
            startedAt: startedAt,
            endedAt: now,
            durationSeconds: duration,
            distanceKm: distanceKm,
            steps: steps,
            kcal: kcal,
            peakSpeedKph: peakSpeedKph,
            programName: programName
        )
    }

    private func reset() {
        baseline = nil
        startedAt = nil
        lastMovingAt = nil
        kcal = 0
        peakSpeedKph = 0
        // lastStatus is deliberately kept: it is the baseline reference for the next walk.
    }

    /// Forget everything, including the last status (used when the belt disconnects).
    public func clear() {
        reset()
        lastStatus = nil
    }
}
