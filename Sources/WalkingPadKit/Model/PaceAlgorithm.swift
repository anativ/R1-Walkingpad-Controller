import Foundation

/// What you are doing at the desk, which decides how fast the algorithms may walk you.
///
/// The same protocol is worth walking at two quite different bands. Typing and clicking need fine
/// motor control, so the band sits low; a call or a meeting leaves your hands free, so it can sit
/// where the intervals actually bite. One anchor pace per mode is all that has to be tuned — every
/// algorithm places its own band around it.
public enum PaceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case work
    case meeting

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .work: return "Working"
        case .meeting: return "Meeting"
        }
    }

    public var detail: String {
        switch self {
        case .work:
            return "Typing and clicking. Slow enough to keep your hands accurate."
        case .meeting:
            return "Listening or talking, hands free. Fast enough for the intervals to count."
        }
    }

    public var systemImage: String {
        switch self {
        case .work: return "keyboard"
        case .meeting: return "person.wave.2"
        }
    }

    /// The pace this mode is built around, in raw 0.1 km/h units.
    public var defaultAnchorRaw: Int {
        switch self {
        case .work: return 38      // 3.8 km/h — the middle of a comfortable typing range
        case .meeting: return 50   // 5.0 km/h — a real walking pace
        }
    }

    /// How far the anchor may be tuned, in raw 0.1 km/h units. Wide enough to suit anyone, narrow
    /// enough that "Working" cannot quietly become a jog.
    public var anchorRange: ClosedRange<Int> {
        switch self {
        case .work: return 20...50
        case .meeting: return 30...65
        }
    }
}

/// A research-backed pace algorithm: a named protocol, the evidence behind it, and the band it
/// wants around the current mode's anchor pace.
///
/// The catalogue is static data, not user state. What the user tunes is the mode anchor; each
/// algorithm derives its own band from that, so switching from Working to Meeting shifts every
/// algorithm together and keeps the shape each protocol was studied with.
public struct PaceAlgorithm: Identifiable, Sendable {
    public let kind: SpeedProgram.Kind
    /// One line: what this is for.
    public let goal: String
    /// The evidence, plainly, with the numbers that matter.
    public let evidence: String
    /// The dose one researched session is, in seconds of brisk/surge work. Nil where no trial has
    /// prescribed a dose.
    public let sessionWorkSeconds: Int?
    /// How often the trials had people do it, and anything worth knowing about the weekly total.
    public let cadence: String
    /// Bottom of the band, as an offset from the mode's anchor pace, in raw 0.1 km/h units.
    public let lowOffset: Int
    /// Top of the band, as an offset from the mode's anchor pace, in raw 0.1 km/h units.
    public let highOffset: Int

    public var id: String { kind.rawValue }
    public var name: String { kind.label }
    public var shape: String { kind.detail }

    /// The program this algorithm becomes at a given anchor pace.
    ///
    /// The band is only floored at the belt's own minimum; the app's speed ceiling is applied later,
    /// by the runner, so that the note explaining the clamp can name both numbers.
    public func program(anchorRaw: Int) -> SpeedProgram {
        let floorRaw = SpeedProgram.raw(SpeedLimits.minRunningKph)
        let low = max(floorRaw, anchorRaw + lowOffset)
        let high = max(low + 1, anchorRaw + highOffset)
        return SpeedProgram(
            name: kind.label,
            kind: kind,
            minRaw: low,
            maxRaw: high,
            // Only the drift reads these; the researched protocols carry their own block timings.
            stepRaw: 1,
            intervalSeconds: 120
        )
    }

    /// The catalogue, in the order the boxes appear. Interval walking leads because it has by far
    /// the strongest evidence for exactly this question.
    public static let all: [PaceAlgorithm] = [
        PaceAlgorithm(
            kind: .intervalWalk,
            goal: "The best-evidenced way to raise VO₂ max by walking.",
            evidence: """
                Nose and Masuki's interval walking training at Shinshu University. In their \
                five-month randomised trial of 246 adults (mean age 63), alternating three minutes \
                fast with three minutes slow beat continuous walking on peak aerobic capacity, \
                thigh strength and blood pressure — roughly 9% more aerobic gain, 13–17% more leg \
                strength, and about 9/5 mmHg off blood pressure. A later cohort of 679 people saw \
                peak aerobic capacity rise about 14%.
                """,
            sessionWorkSeconds: 900,   // five 3-minute fast blocks — one researched session
            cadence: "Four sessions a week. The gains plateau near 50 minutes of fast walking per "
                + "week, so five cycles is a full dose — not ninety minutes of it.",
            lowOffset: -4,
            highOffset: 8
        ),
        PaceAlgorithm(
            kind: .microSurges,
            goal: "Mostly easy, so you can keep typing. The health comes from short bursts.",
            evidence: """
                Stamatakis and colleagues in Nature Medicine (2022) tracked brief vigorous bursts \
                inside ordinary daily movement — VILPA — in UK Biobank wearable data. Three bouts \
                of one to two minutes a day were associated with about 40% lower cancer mortality \
                and roughly half the cardiovascular mortality; the median 4.4 minutes a day tracked \
                with 26–30% lower all-cause mortality.
                """,
            sessionWorkSeconds: 270,   // three 90-second bursts
            cadence: "Three to four bursts is the studied dose. A ninety-minute walk gives you "
                + "about seven, and you spend seven-eighths of it at an easy typing pace.",
            lowOffset: -3,
            highOffset: 12
        ),
        PaceAlgorithm(
            kind: .threeTierWave,
            goal: "Three intensities in a short cycle — variety without a long hard block.",
            evidence: """
                Adapted from Gunnarsson and Bangsbo's 10-20-30 concept (Journal of Applied \
                Physiology, 2012): 30 seconds easy, 20 moderate, 10 hard improved VO₂ max and 5 km \
                time on roughly half the training volume, and lowered resting blood pressure and \
                cholesterol. The 3:2:1 shape is kept but stretched to minutes — a belt needs several \
                seconds just to change speed, so ten-second blocks cannot be walked here.
                """,
            sessionWorkSeconds: 300,   // five one-minute brisk blocks across half an hour
            cadence: "A gentler way in than a three-minute fast block, and the shortest cycle here: "
                + "the pace changes every one to three minutes.",
            lowOffset: -4,
            highOffset: 9
        ),
        PaceAlgorithm(
            kind: .longDeskSession,
            goal: "For a ninety-minute to two-hour walk: get the dose, then cruise.",
            evidence: """
                One researched interval-walking session — five three-minute fast blocks — then half \
                an hour of easy cruising, repeating. The 679-person interval-walking cohort found \
                benefits plateauing near 50 minutes of fast walking per week, so ninety unbroken \
                minutes of brisk work is dose you do not need and load you may not want: \
                treadmill-desk guidance is consistent that soreness comes from doing too much too \
                soon.
                """,
            sessionWorkSeconds: 900,
            cadence: "Built for the full working session. Two hours gives you two complete doses "
                + "with easy cruising in between.",
            lowOffset: -4,
            highOffset: 8
        ),
        PaceAlgorithm(
            kind: .gentleDrift,
            goal: "Never the same stride twice — the least distracting way to keep moving.",
            evidence: """
                The weakest evidence here, and worth saying so: no trial has tested a ±0.3 km/h \
                drift. The reasoning is load, not fitness — two hours of an identical stride works \
                the same tissues in the same way, and treadmill-desk practice is to nudge the speed \
                every so often rather than hold one number. Cadence research (CADENCE-Adults) puts \
                moderate intensity near 100 steps per minute, so small speed changes move you around \
                that threshold rather than parking under it.
                """,
            sessionWorkSeconds: nil,
            cadence: "No hard blocks at all, so it adds nothing to your weekly dose. Use it when "
                + "you need to concentrate, or on a day off from the intervals.",
            lowOffset: -3,
            highOffset: 3
        ),
    ]

    public static func named(_ kind: SpeedProgram.Kind) -> PaceAlgorithm? {
        all.first { $0.kind == kind }
    }
}
