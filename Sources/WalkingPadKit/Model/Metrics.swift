import Foundation

/// Used by the resting-metabolism formula, which is defined in these terms.
public enum BiologicalSex: String, CaseIterable, Sendable {
    case male, female

    public var label: String {
        switch self {
        case .male: return "Male"
        case .female: return "Female"
        }
    }
}

/// Body data used for the calorie estimate. The belt itself never reports calories.
///
/// Weight dominates the result, height shapes the walking cost, and age plus sex are needed only
/// for the resting-metabolism baseline used to convert gross calories into net.
public struct UserProfile: Equatable, Sendable {
    public var weightKg: Double
    public var heightCm: Double
    public var ageYears: Double
    public var sex: BiologicalSex

    public init(
        weightKg: Double = 75,
        heightCm: Double = 175,
        ageYears: Double = 35,
        sex: BiologicalSex = .male
    ) {
        self.weightKg = weightKg
        self.heightCm = heightCm
        self.ageYears = ageYears
        self.sex = sex
    }
}

/// How weight is entered and displayed.
public enum WeightUnit: String, CaseIterable, Sendable {
    case kilograms, pounds

    public var suffix: String { self == .kilograms ? "kg" : "lb" }
    public var label: String { self == .kilograms ? "Kilograms" : "Pounds" }

    private static let poundsPerKg = 2.2046226218

    public func fromKilograms(_ kg: Double) -> Double {
        self == .kilograms ? kg : kg * WeightUnit.poundsPerKg
    }

    public func toKilograms(_ value: Double) -> Double {
        self == .kilograms ? value : value / WeightUnit.poundsPerKg
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

    /// Largest gap in the belt's clock that still counts toward accumulated figures.
    ///
    /// Reconnecting to a belt already mid-session shows up as a huge jump, and crediting it would
    /// invent calories nobody burned. One definition, shared by the live tracker and the recorder.
    public static let maxCreditedGapSeconds: Double = 120

    /// Resting energy expenditure, kcal per minute, from the Mifflin-St Jeor equation.
    ///
    /// This is the baseline your body burns anyway. Subtracting it turns the gross figure into the
    /// *extra* calories the walk cost, which is the honest number to compare against food.
    public static func restingKcalPerMinute(profile: UserProfile) -> Double {
        let base = 10 * profile.weightKg
            + 6.25 * profile.heightCm
            - 5 * profile.ageYears
        let bmrPerDay = profile.sex == .male ? base + 5 : base - 161
        return max(0, bmrPerDay) / (24 * 60)
    }

    /// Calories attributable to the walk itself, i.e. gross minus what resting would have cost.
    public static func netKcalPerMinute(speedKph: Double, profile: UserProfile) -> Double {
        max(0, kcalPerMinute(speedKph: speedKph, profile: profile)
            - restingKcalPerMinute(profile: profile))
    }

    /// Convert a stored gross figure to net, given how long the walk lasted.
    public static func netKcal(gross: Double, durationSeconds: Int, profile: UserProfile) -> Double {
        let resting = restingKcalPerMinute(profile: profile) * (Double(durationSeconds) / 60)
        return max(0, gross - resting)
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
