import Foundation

/// How hard one block of a program is meant to feel.
///
/// Belt speed is the only intensity dial the hardware has, so a tier always resolves to a speed
/// inside the program's own band. Tiers exist so the *shape* of a published protocol can be written
/// down once — "three minutes fast, three minutes slow" — and then walked at whatever band suits
/// the person and the moment: typing at a desk, or listening in a meeting.
public enum PaceTier: String, Codable, CaseIterable, Sendable {
    /// Recovery. The slow half of the interval-walking trials (~40% of peak aerobic capacity).
    case easy
    /// The middle of the band. Moving, but not the working end.
    case steady
    /// The working end of the band: the "fast" block the trials prescribe (~70% of peak).
    case brisk
    /// A short vigorous burst, held for a minute or two at most.
    case surge

    public var label: String {
        switch self {
        case .easy: return "easy"
        case .steady: return "steady"
        case .brisk: return "brisk"
        case .surge: return "surge"
        }
    }

    /// What this block should feel like, so the band can be tuned by feel rather than by guesswork.
    public var feel: String {
        switch self {
        case .easy: return "conversational — you could type through it"
        case .steady: return "purposeful, still comfortable"
        case .brisk: return "breathing noticeably; talking takes effort"
        case .surge: return "hard — short on purpose"
        }
    }

    /// Whether time in this tier counts toward the researched dose of *fast* walking.
    ///
    /// Only the deliberately hard tiers count. A gentle drift's upper half is variation, not
    /// interval training, so it is never labelled `brisk` and never inflates the dose.
    public var isWork: Bool {
        switch self {
        case .easy, .steady: return false
        case .brisk, .surge: return true
        }
    }
}

/// One block of a program: hold this speed for this long.
///
/// Speed is in raw 0.1 km/h units, the belt's own unit — see `SpeedProgram`.
public struct PaceBlock: Equatable, Sendable {
    public var raw: Int
    public var seconds: Int
    public var tier: PaceTier

    public init(raw: Int, seconds: Int, tier: PaceTier) {
        self.raw = raw
        self.seconds = seconds
        self.tier = tier
    }

    public var kph: Double { Double(raw) / 10 }
}

/// A speed program — an "algorithm" that drives the belt speed over time instead of you
/// touching the slider.
///
/// A program is a **cycle of timed blocks** that repeats for as long as it runs. That shape is what
/// the exercise-science literature actually prescribes: interval walking is "3 minutes fast,
/// 3 minutes slow, repeat", not a ramp. `SpeedProgram.Kind` picks the shape; `minRaw`/`maxRaw` set
/// the band it is walked in.
///
/// Every speed here is held in **raw 0.1 km/h units**, the same unit the belt's protocol uses.
/// That is deliberate: walking a program by repeatedly adding 0.1 to a `Double` accumulates
/// floating-point error, so after 30 steps you ask for 5.499999 and the belt rounds somewhere
/// you did not intend. Integers make every step exact.
public struct SpeedProgram: Codable, Equatable, Identifiable, Sendable {
    /// The shape of the program.
    ///
    /// Adding an algorithm means adding a case here and its blocks to `blueprint` — the runner and
    /// the UI need no changes, because they only ever see the resolved `cycle`.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Interval walking: 3 minutes brisk, 3 minutes easy, repeating (Nose & Masuki).
        case intervalWalk
        /// Mostly easy, with a short vigorous burst every ten minutes or so (VILPA).
        case microSurges
        /// A three-tier ladder — easy, steady, brisk — in a six-minute cycle (10-20-30, scaled).
        case threeTierWave
        /// One researched interval-walking dose, then half an hour of easy cruising, repeating.
        case longDeskSession
        /// Climb from min to max one small step at a time, then back down, forever.
        ///
        /// The raw value stays `upDown` so programs saved by earlier builds still decode.
        case gentleDrift = "upDown"

        public var label: String {
            switch self {
            case .intervalWalk: return "Interval walk"
            case .microSurges: return "Micro-surges"
            case .threeTierWave: return "Three-tier wave"
            case .longDeskSession: return "Long desk session"
            case .gentleDrift: return "Gentle drift"
            }
        }

        public var detail: String {
            switch self {
            case .intervalWalk:
                return "Three minutes brisk, three minutes easy, repeating."
            case .microSurges:
                return "Ten and a half minutes easy, then a ninety-second surge."
            case .threeTierWave:
                return "Three minutes easy, two steady, one brisk — a six-minute cycle."
            case .longDeskSession:
                return "Five brisk/easy intervals, then half an hour of easy cruising."
            case .gentleDrift:
                return "Drifts up to the maximum one small step at a time, then back down."
            }
        }

        /// Whether `stepRaw` and `intervalSeconds` mean anything for this kind.
        ///
        /// The block timings of the researched protocols are the protocol — they come from the
        /// trials, not from a slider — so only the freehand drift reads these fields.
        public var usesStepAndInterval: Bool { self == .gentleDrift }

        /// The blocks of one cycle, as (tier, seconds). Nil for kinds generated from the band.
        var blueprint: [(tier: PaceTier, seconds: Int)]? {
            switch self {
            case .intervalWalk:
                // Nose & Masuki: repeated 3-minute fast/slow intervals.
                return [(.brisk, 180), (.easy, 180)]
            case .microSurges:
                // VILPA: brief 1-2 minute vigorous bouts inside otherwise ordinary movement.
                // A 12-minute cycle puts ~7 of them in a 90-minute walk.
                return [(.easy, 630), (.surge, 90)]
            case .threeTierWave:
                // The 10-20-30 shape (low/moderate/high, 3:2:1) stretched to minutes. Ten-second
                // blocks are not reachable here: the belt needs seconds just to change speed.
                return [(.easy, 180), (.steady, 120), (.brisk, 60)]
            case .longDeskSession:
                // Five 3+3 intervals is exactly one researched 30-minute session; the half hour
                // that follows keeps you moving without adding to the hard-minute dose.
                let dose = (0..<5).flatMap { _ in [(tier: PaceTier.brisk, seconds: 180),
                                                   (tier: PaceTier.easy, seconds: 180)] }
                let cruise = (0..<3).flatMap { _ in [(tier: PaceTier.easy, seconds: 300),
                                                     (tier: PaceTier.steady, seconds: 300)] }
                return dose + cruise
            case .gentleDrift:
                return nil
            }
        }
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Bottom of the band — the easy pace. Raw 0.1 km/h units.
    public var minRaw: Int
    /// Top of the band — the working pace. Raw 0.1 km/h units.
    public var maxRaw: Int
    /// Speed change per step, raw 0.1 km/h units. Gentle drift only.
    public var stepRaw: Int
    /// Seconds between changes. Gentle drift only.
    public var intervalSeconds: Int

    public init(
        id: UUID = UUID(),
        name: String = "Gentle drift",
        kind: Kind = .gentleDrift,
        minRaw: Int = 40,
        maxRaw: Int = 55,
        stepRaw: Int = 1,
        intervalSeconds: Int = 120
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.minRaw = minRaw
        self.maxRaw = maxRaw
        self.stepRaw = stepRaw
        self.intervalSeconds = intervalSeconds
    }

    /// The freehand default: 4.0–5.5 km/h, 0.1 steps, every 2 minutes.
    public static let standard = SpeedProgram()

    // MARK: km/h views for the UI

    public var minKph: Double {
        get { Double(minRaw) / 10 }
        set { minRaw = SpeedProgram.raw(newValue) }
    }

    public var maxKph: Double {
        get { Double(maxRaw) / 10 }
        set { maxRaw = SpeedProgram.raw(newValue) }
    }

    public var stepKph: Double {
        get { Double(stepRaw) / 10 }
        set { stepRaw = max(1, SpeedProgram.raw(newValue)) }
    }

    public var intervalMinutes: Double {
        get { Double(intervalSeconds) / 60 }
        set { intervalSeconds = max(5, Int((newValue * 60).rounded())) }
    }

    public static func raw(_ kph: Double) -> Int { Int((kph * 10).rounded()) }

    // MARK: Tiers

    /// The speed a tier means for this program's band.
    ///
    /// Everything lands inside `minRaw...maxRaw`, which is what makes the app's speed ceiling a
    /// complete guarantee: clamp the band and no block can escape it.
    public func raw(for tier: PaceTier) -> Int {
        switch tier {
        case .easy: return minRaw
        case .steady: return minRaw + (maxRaw - minRaw) / 2
        case .brisk, .surge: return maxRaw
        }
    }

    // MARK: The cycle

    /// One full cycle of the program, which then repeats. Empty if the program cannot run.
    public var cycle: [PaceBlock] {
        guard isValid else { return [] }
        if let blueprint = kind.blueprint {
            return blueprint.map {
                PaceBlock(raw: raw(for: $0.tier), seconds: $0.seconds, tier: $0.tier)
            }
        }
        return driftCycle()
    }

    /// The ladder for `gentleDrift`: min up to max, then back down, with the endpoints visited
    /// exactly once per cycle — so 4.0…5.5 with a 0.1 step gives 4.0, 4.1, … 5.5, 5.4, … 4.1 and
    /// then wraps to 4.0 with no value repeated at a turn.
    private func driftCycle() -> [PaceBlock] {
        var raws = [minRaw]
        var climbing = minRaw
        while climbing < maxRaw {
            // A step that would overshoot lands exactly on the maximum instead.
            climbing = min(climbing + stepRaw, maxRaw)
            raws.append(climbing)
        }
        var falling = maxRaw - stepRaw
        while falling > minRaw {
            raws.append(falling)
            falling -= stepRaw
        }
        // A drift's job is variation, not intensity: its top step is never labelled brisk, so a
        // drift never contributes to the researched hard-minute dose.
        let middle = minRaw + (maxRaw - minRaw) / 2
        return raws.map {
            PaceBlock(raw: $0, seconds: intervalSeconds, tier: $0 > middle ? .steady : .easy)
        }
    }

    /// How many blocks one full cycle takes.
    public var blocksPerCycle: Int { max(1, cycle.count) }

    /// How long one full cycle takes.
    public var cycleDuration: TimeInterval { Double(cycle.reduce(0) { $0 + $1.seconds }) }

    /// Seconds of `brisk`/`surge` work in one cycle — the dose the trials actually prescribe.
    public var workSecondsPerCycle: Int {
        cycle.reduce(0) { $1.tier.isWork ? $0 + $1.seconds : $0 }
    }

    // MARK: Validity

    public var isValid: Bool { validationError == nil }

    /// Why this program cannot run, if it cannot.
    public var validationError: String? {
        if maxRaw <= minRaw { return "Maximum must be above minimum." }
        if minRaw <= 0 { return "Minimum must be above zero." }
        if kind.usesStepAndInterval {
            if stepRaw <= 0 { return "Step must be greater than zero." }
            if intervalSeconds < 5 { return "Interval must be at least 5 seconds." }
        }
        return nil
    }

    /// A copy that fits inside the app's speed ceiling, or nil if the ceiling leaves no room.
    public func clamped(toCeilingRaw ceiling: Int) -> SpeedProgram? {
        guard ceiling > 0 else { return nil }
        var copy = self
        copy.maxRaw = min(maxRaw, ceiling)
        copy.minRaw = min(minRaw, copy.maxRaw)
        guard copy.maxRaw > copy.minRaw else { return nil }
        copy.stepRaw = min(max(1, copy.stepRaw), copy.maxRaw - copy.minRaw)
        return copy
    }

    // MARK: Previews for the UI

    /// The first few speeds, for a one-line preview label.
    public func preview(count: Int = 6) -> [Double] {
        previewBlocks(count: count).map(\.kph)
    }

    /// The first few blocks, so the UI can show durations as well as speeds.
    public func previewBlocks(count: Int = 6) -> [PaceBlock] {
        let cycle = self.cycle
        guard !cycle.isEmpty else { return [] }
        return (0..<max(1, count)).map { cycle[$0 % cycle.count] }
    }
}

/// The pure, side-effect-free heart of every program: given where you are, where do you go next.
///
/// A program is a repeating cycle of blocks, so "where you are" is an index into that cycle. The
/// speed, the tier and how long the block lasts all come along with it, which is what lets one
/// program hold 3 minutes brisk and 3 minutes easy while another holds 10½ minutes easy and 90
/// seconds hard.
public enum SpeedSequence {
    public struct State: Equatable, Sendable {
        /// Position in the program's cycle.
        public var index: Int
        /// Current speed in raw 0.1 km/h units.
        public var raw: Int
        /// How long this block lasts.
        public var seconds: Int
        /// How hard this block is meant to feel.
        public var tier: PaceTier
        /// Whether this block is faster than the one before it, for the UI's arrow.
        public var isRising: Bool

        public init(index: Int, raw: Int, seconds: Int, tier: PaceTier, isRising: Bool) {
            self.index = index
            self.raw = raw
            self.seconds = seconds
            self.tier = tier
            self.isRising = isRising
        }
    }

    /// The starting point of a program: the first block of its cycle.
    public static func start(of program: SpeedProgram) -> State {
        guard let first = program.cycle.first else {
            // An unrunnable program still needs a state the UI can render without special-casing.
            return State(index: 0, raw: program.minRaw, seconds: max(5, program.intervalSeconds),
                         tier: .easy, isRising: true)
        }
        return State(index: 0, raw: first.raw, seconds: first.seconds,
                     tier: first.tier, isRising: true)
    }

    /// The next block, wrapping round the end of the cycle. An invalid program never moves.
    public static func next(_ state: State, in program: SpeedProgram) -> State {
        let cycle = program.cycle
        guard !cycle.isEmpty else { return state }
        let index = (max(0, state.index) + 1) % cycle.count
        let block = cycle[index]
        return State(index: index, raw: block.raw, seconds: block.seconds, tier: block.tier,
                     isRising: block.raw == state.raw ? state.isRising : block.raw > state.raw)
    }

    /// The state for a given index, used when a program's band is re-clamped underneath it.
    public static func state(at index: Int, in program: SpeedProgram, wasRising: Bool) -> State {
        let cycle = program.cycle
        guard !cycle.isEmpty else { return start(of: program) }
        let wrapped = ((index % cycle.count) + cycle.count) % cycle.count
        let block = cycle[wrapped]
        return State(index: wrapped, raw: block.raw, seconds: block.seconds, tier: block.tier,
                     isRising: wasRising)
    }
}
