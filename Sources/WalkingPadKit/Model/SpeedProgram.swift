import Foundation

/// A speed program — an "algorithm" that drives the belt speed over time instead of you
/// touching the slider.
///
/// Every speed here is held in **raw 0.1 km/h units**, the same unit the belt's protocol uses.
/// That is deliberate: walking a program by repeatedly adding 0.1 to a `Double` accumulates
/// floating-point error, so after 30 steps you ask for 5.499999 and the belt rounds somewhere
/// you did not intend. Integers make every step exact.
public struct SpeedProgram: Codable, Equatable, Identifiable, Sendable {
    /// The shape of the program. Adding a new algorithm means adding a case here and a branch
    /// in `SpeedSequence.next`.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Climb from min to max one step at a time, then walk back down, forever.
        case upDown

        public var label: String {
            switch self {
            case .upDown: return "Up / down"
            }
        }

        public var detail: String {
            switch self {
            case .upDown:
                return "Ramps up to the maximum one step at a time, then back down to the minimum, repeating."
            }
        }
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Lowest speed, raw 0.1 km/h units.
    public var minRaw: Int
    /// Highest speed, raw 0.1 km/h units.
    public var maxRaw: Int
    /// Speed change per step, raw 0.1 km/h units.
    public var stepRaw: Int
    /// Seconds between changes.
    public var intervalSeconds: Int

    public init(
        id: UUID = UUID(),
        name: String = "Up / down",
        kind: Kind = .upDown,
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

    /// The defaults from the original request: 4.0–5.5 km/h, 0.1 steps, every 2 minutes.
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

    // MARK: Validity

    public var isValid: Bool { validationError == nil }

    /// Why this program cannot run, if it cannot.
    public var validationError: String? {
        if stepRaw <= 0 { return "Step must be greater than zero." }
        if maxRaw <= minRaw { return "Maximum must be above minimum." }
        if minRaw <= 0 { return "Minimum must be above zero." }
        if intervalSeconds < 5 { return "Interval must be at least 5 seconds." }
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

    /// How many steps one full min -> max -> min lap takes.
    public var stepsPerLap: Int {
        guard isValid else { return 1 }
        let climb = Int(ceil(Double(maxRaw - minRaw) / Double(stepRaw)))
        return max(2, climb * 2)
    }

    /// How long one full lap takes.
    public var lapDuration: TimeInterval { Double(stepsPerLap) * Double(intervalSeconds) }

    /// The first few speeds, for a preview label in the UI.
    public func preview(count: Int = 6) -> [Double] {
        guard isValid else { return [] }
        var speeds: [Double] = []
        var state = SpeedSequence.State(raw: minRaw, ascending: true)
        speeds.append(Double(state.raw) / 10)
        for _ in 1..<max(1, count) {
            state = SpeedSequence.next(state, in: self)
            speeds.append(Double(state.raw) / 10)
        }
        return speeds
    }
}

/// The pure, side-effect-free heart of every program: given where you are, where do you go next.
public enum SpeedSequence {
    public struct State: Equatable, Sendable {
        /// Current speed in raw 0.1 km/h units.
        public var raw: Int
        /// Whether the program is currently climbing.
        public var ascending: Bool

        public init(raw: Int, ascending: Bool = true) {
            self.raw = raw
            self.ascending = ascending
        }
    }

    /// The starting point of a program.
    public static func start(of program: SpeedProgram) -> State {
        State(raw: program.minRaw, ascending: true)
    }

    /// The next step. Endpoints are visited exactly once per lap, so 4.0…5.5 with a 0.1 step
    /// yields 4.0, 4.1, … 5.4, 5.5, 5.4, … 4.1, 4.0, 4.1, … — no value repeated at a turn.
    public static func next(_ state: State, in program: SpeedProgram) -> State {
        guard program.isValid else { return state }
        let lo = program.minRaw, hi = program.maxRaw, step = program.stepRaw

        switch program.kind {
        case .upDown:
            if state.ascending {
                // Already at the top: turn around.
                if state.raw >= hi { return State(raw: max(lo, hi - step), ascending: false) }
                let candidate = state.raw + step
                // A step that would overshoot lands exactly on the maximum instead.
                return State(raw: min(candidate, hi), ascending: true)
            } else {
                if state.raw <= lo { return State(raw: min(hi, lo + step), ascending: true) }
                let candidate = state.raw - step
                return State(raw: max(candidate, lo), ascending: false)
            }
        }
    }
}
