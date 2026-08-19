import Foundation

public struct SpeedSample: Identifiable, Equatable, Sendable {
    public let id = UUID()
    /// Belt elapsed time, seconds.
    public let elapsed: Int
    public let speedKph: Double
    public let at: Date
}

/// Derives everything the belt does not report: calories, cadence, averages, and a
/// speed history for the chart. Also detects when the belt has started a new session
/// (its counters reset to zero).
public final class SessionTracker: ObservableObject {
    @Published public private(set) var samples: [SpeedSample] = []
    @Published public private(set) var kcal: Double = 0
    /// Steps per minute over the recent window.
    @Published public private(set) var cadence: Double = 0
    @Published public private(set) var peakSpeedKph: Double = 0
    @Published public private(set) var sessionStartedAt: Date?

    public var profile: UserProfile

    private var lastStatus: PadStatus?
    private static let maxSamples = 3600
    /// Window used for the cadence estimate.
    private static let cadenceWindow: TimeInterval = 20
    /// Largest belt-clock gap we will still count toward calories.
    private static let maxCreditedGapSeconds: Double = 120

    public init(profile: UserProfile = UserProfile()) {
        self.profile = profile
    }

    public func ingest(_ status: PadStatus) {
        defer { lastStatus = status }

        if let previous = lastStatus, isNewSession(previous: previous, current: status) {
            reset()
        }
        if sessionStartedAt == nil, status.elapsed > 0 || status.steps > 0 {
            sessionStartedAt = status.receivedAt.addingTimeInterval(-Double(status.elapsed))
        }

        // Integrate calories over the belt's own clock so pausing the belt pauses the burn.
        if let previous = lastStatus {
            let deltaSeconds = Double(status.elapsed - previous.elapsed)
            // Ignore implausible jumps (e.g. reconnecting to a belt already mid-session),
            // which would otherwise credit a large burst of calories at the current speed.
            if deltaSeconds > 0, deltaSeconds <= SessionTracker.maxCreditedGapSeconds {
                let perMinute = Metrics.kcalPerMinute(speedKph: status.speedKph, profile: profile)
                kcal += perMinute * (deltaSeconds / 60)
            }
        }

        peakSpeedKph = max(peakSpeedKph, status.speedKph)
        appendSample(status)
        recomputeCadence(now: status)
    }

    private func isNewSession(previous: PadStatus, current: PadStatus) -> Bool {
        // The belt zeroes its counters on a fresh session.
        current.elapsed < previous.elapsed || current.steps < previous.steps
    }

    private func appendSample(_ status: PadStatus) {
        // One sample per belt-second; repeated polls at the same second just update the last.
        if let last = samples.last, last.elapsed == status.elapsed {
            samples[samples.count - 1] = SpeedSample(
                elapsed: status.elapsed, speedKph: status.speedKph, at: status.receivedAt
            )
        } else {
            samples.append(
                SpeedSample(elapsed: status.elapsed, speedKph: status.speedKph, at: status.receivedAt)
            )
        }
        if samples.count > SessionTracker.maxSamples {
            samples.removeFirst(samples.count - SessionTracker.maxSamples)
        }
    }

    private var stepHistory: [(at: Date, steps: Int)] = []

    private func recomputeCadence(now status: PadStatus) {
        stepHistory.append((status.receivedAt, status.steps))
        stepHistory.removeAll { status.receivedAt.timeIntervalSince($0.at) > SessionTracker.cadenceWindow }
        guard let first = stepHistory.first, stepHistory.count > 1 else { cadence = 0; return }
        let seconds = status.receivedAt.timeIntervalSince(first.at)
        let steps = status.steps - first.steps
        cadence = seconds > 1 && steps >= 0 ? Double(steps) / seconds * 60 : 0
    }

    public func reset() {
        samples.removeAll()
        stepHistory.removeAll()
        kcal = 0
        cadence = 0
        peakSpeedKph = 0
        sessionStartedAt = nil
        lastStatus = nil
    }

    /// Average speed over the session, from the belt's own distance and time.
    public func averageSpeedKph(status: PadStatus?) -> Double {
        guard let status, status.elapsed > 0 else { return 0 }
        return status.distanceKm / (Double(status.elapsed) / 3600)
    }
}
