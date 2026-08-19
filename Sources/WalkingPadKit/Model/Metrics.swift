import Foundation

/// Body data used for the calorie estimate. The belt itself never reports calories.
public struct UserProfile: Equatable, Sendable {
    public var weightKg: Double
    public var heightCm: Double

    public init(weightKg: Double = 75, heightCm: Double = 175) {
        self.weightKg = weightKg
        self.heightCm = heightCm
    }
}

public enum Metrics {
    /// ACSM walking equation, kcal per minute.
    /// `(0.035 x kg) + ((v m/s)^2 / height m) x 0.029 x kg`
    /// This is an estimate — treat it as indicative, not measured.
    public static func kcalPerMinute(speedKph: Double, profile: UserProfile) -> Double {
        guard speedKph > 0 else { return 0 }
        let velocity = speedKph * 1000 / 3600
        let heightM = max(0.5, profile.heightCm / 100)
        return (0.035 * profile.weightKg)
            + ((velocity * velocity) / heightM) * 0.029 * profile.weightKg
    }

    /// Minutes per km. Returns nil when stopped.
    public static func pace(speedKph: Double) -> Double? {
        guard speedKph > 0.05 else { return nil }
        return 60.0 / speedKph
    }

    public static func formatDuration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    public static func formatPace(_ minutesPerKm: Double?) -> String {
        guard let minutesPerKm, minutesPerKm.isFinite, minutesPerKm < 100 else { return "—" }
        let whole = Int(minutesPerKm)
        let secs = Int((minutesPerKm - Double(whole)) * 60)
        return String(format: "%d:%02d", whole, secs)
    }
}

/// Distance/speed display units.
public enum DistanceUnit: String, CaseIterable, Sendable {
    case kilometers, miles

    public var speedSuffix: String { self == .kilometers ? "km/h" : "mph" }
    public var distanceSuffix: String { self == .kilometers ? "km" : "mi" }
    public var paceSuffix: String { self == .kilometers ? "min/km" : "min/mi" }

    private static let milesPerKm = 0.621371

    public func speed(fromKph kph: Double) -> Double {
        self == .kilometers ? kph : kph * DistanceUnit.milesPerKm
    }

    public func distance(fromKm km: Double) -> Double {
        self == .kilometers ? km : km * DistanceUnit.milesPerKm
    }

    /// Pace given in min/km, converted to the display unit.
    public func pace(fromMinPerKm value: Double?) -> Double? {
        guard let value else { return nil }
        return self == .kilometers ? value : value / DistanceUnit.milesPerKm
    }

    public var label: String { self == .kilometers ? "Kilometers" : "Miles" }
}
