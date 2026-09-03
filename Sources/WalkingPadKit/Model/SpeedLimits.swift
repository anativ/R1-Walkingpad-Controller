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

    /// The ceiling once the belt's own reported maximum is taken into account.
    ///
    /// An FTMS belt states its range (the Z1F: 1–6 km/h). Asking for more is refused with an
    /// "invalid parameter", so the slider and presets should stop where the belt does rather than
    /// offer speeds that silently fail.
    public static func effectiveCeiling(
        walkingCeilingKph: Double, isRunningMode: Bool, beltMaxKph: Double?
    ) -> Double {
        let ceiling = effectiveCeiling(walkingCeilingKph: walkingCeilingKph, isRunningMode: isRunningMode)
        guard let beltMaxKph, beltMaxKph.isFinite, beltMaxKph >= minRunningKph else { return ceiling }
        return min(ceiling, beltMaxKph)
    }

    /// The speed below which a request is treated as a stop.
    ///
    /// The belt refuses anything under its minimum and never confirms it, so the UI would wait
    /// forever. Stopping is the honest reading of "slower than the belt can go". The request is
    /// never lifted *up* to the minimum: this must not command a faster speed than was asked for.
    public static func stopThreshold(beltMinKph: Double?) -> Double {
        guard let beltMinKph, beltMinKph.isFinite, beltMinKph > 0 else { return minRunningKph }
        return max(minRunningKph, beltMinKph)
    }

    /// Whether the app must itself command a lower speed after the ceiling changed.
    ///
    /// - Parameters:
    ///   - programStillDriving: a running program adopted the new ceiling and is driving the belt,
    ///     so it will command its own speeds; anything else means nobody else will.
    ///   - beltIsMovingOrAboutTo: includes a start still working through the command queue.
    ///   - commandedSpeedKph: the highest speed the belt is either running at **or** has already
    ///     been told to run at. Using only the belt's reported speed misses a faster command still
    ///     in flight — status frames arrive about once a second — and the ceiling would then be
    ///     enforced against a speed that is about to be superseded.
    public static func needsCorrectiveWrite(
        programStillDriving: Bool,
        isConnected: Bool,
        beltIsMovingOrAboutTo: Bool,
        commandedSpeedKph: Double,
        ceilingKph: Double
    ) -> Bool {
        guard !programStillDriving, isConnected, beltIsMovingOrAboutTo else { return false }
        guard commandedSpeedKph.isFinite else { return false }
        // Only ever to slow down: this must never raise a belt that is coasting below the ceiling.
        return commandedSpeedKph > ceilingKph
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
