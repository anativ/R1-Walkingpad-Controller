import Foundation

/// One completed walk, stored on disk.
///
/// Distance, duration and steps come from the belt's own counters (authoritative); calories are
/// this app's estimate, since the belt does not report them.
public struct WalkSession: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date
    /// Time the belt was actually running, seconds. Not wall-clock between start and end.
    public var durationSeconds: Int
    public var distanceKm: Double
    public var steps: Int
    public var kcal: Double
    public var peakSpeedKph: Double
    /// Name of the program that drove this walk, if any.
    public var programName: String?

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        durationSeconds: Int,
        distanceKm: Double,
        steps: Int,
        kcal: Double,
        peakSpeedKph: Double,
        programName: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.distanceKm = distanceKm
        self.steps = steps
        self.kcal = kcal
        self.peakSpeedKph = peakSpeedKph
        self.programName = programName
    }

    /// Average speed over the time the belt was moving.
    public var averageSpeedKph: Double {
        guard durationSeconds > 0 else { return 0 }
        return distanceKm / (Double(durationSeconds) / 3600)
    }

    /// Average stride length, in metres.
    public var strideMetres: Double {
        guard steps > 0 else { return 0 }
        return (distanceKm * 1000) / Double(steps)
    }
}

/// Aggregate figures over a set of sessions.
public struct WalkTotals: Equatable, Sendable {
    public var sessionCount: Int = 0
    public var distanceKm: Double = 0
    public var durationSeconds: Int = 0
    public var steps: Int = 0
    public var kcal: Double = 0
    public var peakSpeedKph: Double = 0

    /// Average speed across all recorded walking time.
    public var averageSpeedKph: Double {
        guard durationSeconds > 0 else { return 0 }
        return distanceKm / (Double(durationSeconds) / 3600)
    }

    public init() {}
}

/// One bucket of a time series (a day, week, or month).
public struct WalkBucket: Identifiable, Equatable, Sendable {
    /// Start of the bucket's period.
    public var date: Date
    public var totals: WalkTotals
    public var id: Date { date }

    public init(date: Date, totals: WalkTotals) {
        self.date = date
        self.totals = totals
    }
}

/// The period a history view is grouped by.
public enum WalkPeriod: String, CaseIterable, Sendable {
    case day, week, month

    public var label: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        }
    }

    /// The unit an average is expressed per.
    public var perLabel: String {
        switch self {
        case .day: return "per day"
        case .week: return "per week"
        case .month: return "per month"
        }
    }

    public var component: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }
}

/// Pure aggregation over sessions. No storage, no UI, so it is all covered by `padctl selftest`.
public enum WalkStats {
    public static func totals(_ sessions: [WalkSession]) -> WalkTotals {
        var out = WalkTotals()
        for session in sessions {
            out.sessionCount += 1
            out.distanceKm += session.distanceKm
            out.durationSeconds += session.durationSeconds
            out.steps += session.steps
            out.kcal += session.kcal
            out.peakSpeedKph = max(out.peakSpeedKph, session.peakSpeedKph)
        }
        return out
    }

    /// The start of the period a date falls in.
    public static func periodStart(
        of date: Date, period: WalkPeriod, calendar: Calendar = .current
    ) -> Date {
        switch period {
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            let components = calendar.dateComponents(
                [.yearForWeekOfYear, .weekOfYear], from: date
            )
            return calendar.date(from: components) ?? calendar.startOfDay(for: date)
        case .month:
            let components = calendar.dateComponents([.year, .month], from: date)
            return calendar.date(from: components) ?? calendar.startOfDay(for: date)
        }
    }

    /// Group sessions into buckets, newest last. Only periods with activity appear.
    public static func buckets(
        _ sessions: [WalkSession], period: WalkPeriod, calendar: Calendar = .current
    ) -> [WalkBucket] {
        var grouped: [Date: [WalkSession]] = [:]
        for session in sessions {
            let key = periodStart(of: session.startedAt, period: period, calendar: calendar)
            grouped[key, default: []].append(session)
        }
        return grouped
            .map { WalkBucket(date: $0.key, totals: totals($0.value)) }
            .sorted { $0.date < $1.date }
    }

    /// Buckets covering every period in the range, including empty ones — so a chart shows the
    /// days you did not walk rather than silently closing the gap.
    public static func continuousBuckets(
        _ sessions: [WalkSession],
        period: WalkPeriod,
        count: Int,
        endingAt now: Date,
        calendar: Calendar = .current
    ) -> [WalkBucket] {
        guard count > 0 else { return [] }
        let existing = Dictionary(
            uniqueKeysWithValues: buckets(sessions, period: period, calendar: calendar)
                .map { ($0.date, $0.totals) }
        )
        let currentStart = periodStart(of: now, period: period, calendar: calendar)
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(
                byAdding: period.component, value: -offset, to: currentStart
            ) else { return nil }
            let key = periodStart(of: date, period: period, calendar: calendar)
            return WalkBucket(date: key, totals: existing[key] ?? WalkTotals())
        }
    }

    /// Average totals per period that actually had activity. Averaging over calendar periods with
    /// no walking would quietly answer a different question than the user asked.
    public static func averagePerActivePeriod(
        _ sessions: [WalkSession], period: WalkPeriod, calendar: Calendar = .current
    ) -> WalkTotals {
        let active = buckets(sessions, period: period, calendar: calendar)
        guard !active.isEmpty else { return WalkTotals() }
        let all = totals(sessions)
        let divisor = Double(active.count)
        var out = WalkTotals()
        out.sessionCount = active.count
        out.distanceKm = all.distanceKm / divisor
        out.durationSeconds = Int(Double(all.durationSeconds) / divisor)
        out.steps = Int(Double(all.steps) / divisor)
        out.kcal = all.kcal / divisor
        out.peakSpeedKph = all.peakSpeedKph
        return out
    }

    /// Number of periods with any activity.
    public static func activePeriodCount(
        _ sessions: [WalkSession], period: WalkPeriod, calendar: Calendar = .current
    ) -> Int {
        buckets(sessions, period: period, calendar: calendar).count
    }

    /// Consecutive days with a walk, counting back from today. Yesterday still counts as a live
    /// streak so that a streak is not lost before the day is over.
    public static func currentDayStreak(
        _ sessions: [WalkSession], now: Date, calendar: Calendar = .current
    ) -> Int {
        let days = Set(sessions.map { calendar.startOfDay(for: $0.startedAt) })
        guard !days.isEmpty else { return 0 }
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return 0 }

        var cursor: Date
        if days.contains(today) {
            cursor = today
        } else if days.contains(yesterday) {
            cursor = yesterday
        } else {
            return 0
        }

        var streak = 0
        while days.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    /// The single period with the most distance.
    public static func best(
        _ sessions: [WalkSession], period: WalkPeriod, calendar: Calendar = .current
    ) -> WalkBucket? {
        buckets(sessions, period: period, calendar: calendar)
            .max { $0.totals.distanceKm < $1.totals.distanceKm }
    }

    /// Comma-separated export, newest first.
    public static func csv(_ sessions: [WalkSession]) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = ["started,ended,duration_seconds,distance_km,steps,kcal,avg_speed_kph,peak_speed_kph,program"]
        for session in sessions.sorted(by: { $0.startedAt > $1.startedAt }) {
            let program = (session.programName ?? "").replacingOccurrences(of: ",", with: " ")
            lines.append([
                formatter.string(from: session.startedAt),
                formatter.string(from: session.endedAt),
                String(session.durationSeconds),
                String(format: "%.3f", session.distanceKm),
                String(session.steps),
                String(format: "%.1f", session.kcal),
                String(format: "%.2f", session.averageSpeedKph),
                String(format: "%.1f", session.peakSpeedKph),
                program,
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }
}
