import Foundation

/// The speed ceiling actually in force, and where it comes from.
///
/// Two limits stack. The **walking ceiling** is the everyday cap the user sets (6.0 km/h by
/// default) so a stray drag cannot ask for a jog. **Running mode** lifts that to the belt's own
/// hardware maximum. Neither can ever exceed `hardMaxKph`, which is the last word — this drives a
/// motorised treadmill someone is standing on.
public enum SpeedLimits {
    /// The fastest the R1 Pro will go. Nothing may exceed this, whatever the settings say.
    public static let hardMaxKph: Double = 10.0
    /// Default everyday ceiling, comfortably a walking pace.
    public static let defaultWalkingCeilingKph: Double = 6.0
    /// Below this the belt will not run at all, and ignores the request.
    public static let minRunningKph: Double = 0.5

    /// Resolve the ceiling in force. Running mode unlocks the hardware maximum; otherwise the
    /// user's walking ceiling applies. The result is always within the belt's real range.
    public static func effectiveCeiling(
        walkingCeilingKph: Double, isRunningMode: Bool
    ) -> Double {
        let requested = isRunningMode ? hardMaxKph : walkingCeilingKph
        guard requested.isFinite else { return minRunningKph }
        return min(max(minRunningKph, requested), hardMaxKph)
    }

    /// Speed presets to offer for a given ceiling. Running mode needs a different ladder: the
    /// walking steps are useless above 6, and ten buttons in a row is not a choice.
    public static func presets(forCeiling ceiling: Double) -> [Double] {
        let ladder: [Double] = ceiling > defaultWalkingCeilingKph
            ? [2, 4, 6, 7, 8, 10]
            : [1, 2, 3, 4, 5, 6]
        return ladder.filter { $0 <= ceiling }
    }
}
