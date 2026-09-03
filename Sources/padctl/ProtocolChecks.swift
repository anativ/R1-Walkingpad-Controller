import CoreBluetooth
import Foundation
import WalkingPadKit

/// Frame captured from a real belt upstream: 6.0 km/h, manual, 554 s, 0.79 km, 977 steps.
private let capturedStatus: [UInt8] = [
    0xf8, 0xa2, 0x01, 0x3c, 0x01, 0x00, 0x02, 0x2a, 0x00, 0x00,
    0x4f, 0x00, 0x03, 0xd1, 0xb4, 0x00, 0x00, 0x00, 0xe3, 0xfd,
]

func parsesCapturedStatusFrame() throws {
    let status = try require(PadStatus(data: capturedStatus))
    check(status.beltState == .running)
    check(status.speedKph == 6.0)
    check(status.mode == .manual)
    check(status.elapsed == 554)
    check(status.distanceRaw == 79)
    check(status.distanceKm == 0.79)
    check(status.steps == 977)
    check(status.appSpeedKph == 6.0)
    check(status.controllerButton == 0)
}

func rejectsForeignFrames() throws {
    check(PadStatus(data: [0xf8, 0xa7, 0x00]) == nil)
    check(PadStatus(data: capturedStatus.dropLast(5).map { $0 }) == nil)
    check(PadRecord(data: capturedStatus) == nil)
}

func classifiesFrames() throws {
    guard case .status = PadFrame(data: capturedStatus) else {
        fail("expected status frame"); return
    }
    guard case .unknown = PadFrame(data: [0x01, 0x02]) else {
        fail("expected unknown frame"); return
    }
}

/// The captured frame's own CRC byte must match what our sealer computes,
/// which proves the checksum covers the range we think it does.
func crcMatchesCapturedFrame() throws {
    let resealed = PadPacket.sealed(capturedStatus)
    check(resealed[resealed.count - 2] == capturedStatus[capturedStatus.count - 2])
}

func knownCommandEncodings() throws {
    // Upstream literals: ask stats, speed, mode, start, history.
    check(PadCommand.askStats.bytes == [0xF7, 0xA2, 0x00, 0x00, 0xA2, 0xFD])
    check(PadCommand.setSpeed(30).bytes == PadPacket.sealed([0xF7, 0xA2, 0x01, 30, 0x00, 0xFD]))
    check(PadCommand.setMode(.manual).bytes == [0xF7, 0xA2, 0x02, 0x01, 0xA5, 0xFD])
    check(PadCommand.start.bytes == [0xF7, 0xA2, 0x04, 0x01, 0xA7, 0xFD])
    check(PadCommand.askHistory.bytes == [0xF7, 0xA7, 0xAA, 0xFF, 0x50, 0xFD])
    // Every frame is header/footer delimited.
    for command in [PadCommand.askStats, .setSpeed(60), .setMode(.standby), .start, .askHistory,
                    .setPreference(.maxSpeed, type: 0, value: 60)] {
        check(command.bytes.first == 0xF7)
        check(command.bytes.last == 0xFD)
    }
}

func preferenceEncodesBigEndian24Bit() throws {
    let bytes = PadCommand.setPreference(.target, type: 3, value: 0x010203).bytes
    check(bytes == PadPacket.sealed([0xF7, 0xA6, 0x01, 0x03, 0x01, 0x02, 0x03, 0x00, 0xFD]))
}

func int24RoundTrips() throws {
    for value in [0, 1, 255, 256, 554, 977, 0xFFFFFF] {
        check(PadPacket.int24(PadPacket.bytes24(value)[0...]) == value)
    }
}

/// Idempotent commands share a coalesce key so repeats collapse; commands with different
/// meanings must never collapse into each other.
func idempotentCommandsShareACoalesceKey() throws {
    check(PadCommand.setSpeed(10).coalesceKey == PadCommand.setSpeed(40).coalesceKey)
    check(PadCommand.setMode(.manual).coalesceKey == PadCommand.setMode(.standby).coalesceKey)
    check(PadCommand.start.coalesceKey == PadCommand.start.coalesceKey)

    // Distinct kinds keep distinct keys.
    let keys = [
        PadCommand.setSpeed(10).coalesceKey,
        PadCommand.setMode(.manual).coalesceKey,
        PadCommand.start.coalesceKey,
        PadCommand.askStats.coalesceKey,
        PadCommand.askHistory.coalesceKey,
        PadCommand.setPreference(.maxSpeed, type: 0, value: 1).coalesceKey,
        PadCommand.setPreference(.childLock, type: 0, value: 1).coalesceKey,
    ].compactMap { $0 }
    check(Set(keys).count == keys.count, "coalesce keys must be distinct per command kind")
}

func parsesRecordFrame() throws {
    var frame = [UInt8](repeating: 0, count: 20)
    frame[0] = 0xF8; frame[1] = 0xA7
    frame[8] = 0; frame[9] = 0x02; frame[10] = 0x2A   // 554 s
    frame[11] = 0; frame[12] = 0; frame[13] = 0x4F    // 79 -> 0.79 km
    frame[14] = 0; frame[15] = 0x03; frame[16] = 0xD1 // 977 steps
    let record = try require(PadRecord(data: frame))
    check(record.elapsed == 554)
    check(record.distanceKm == 0.79)
    check(record.steps == 977)
}

func caloriesTrackSpeedAndStop() throws {
    let profile = UserProfile(weightKg: 80, heightCm: 180)
    let walking = Metrics.kcalPerMinute(speedKph: 5, profile: profile)
    let strolling = Metrics.kcalPerMinute(speedKph: 2, profile: profile)
    check(walking > strolling)
    check(Metrics.kcalPerMinute(speedKph: 0, profile: profile) == 0)
}

func paceAndDurationFormatting() throws {
    check(Metrics.formatPace(Metrics.pace(speedKph: 6)) == "10:00")
    check(Metrics.formatPace(Metrics.pace(speedKph: 0)) == "—")
    check(Metrics.formatDuration(554) == "9:14")
    check(Metrics.formatDuration(3725) == "1:02:05")
}

func trackerAccumulatesAndDetectsNewSession() throws {
    let tracker = SessionTracker(profile: UserProfile(weightKg: 80, heightCm: 180))
    func status(elapsed: Int, steps: Int, speed: UInt8) -> PadStatus {
        var frame = capturedStatus
        frame[3] = speed
        let t = PadPacket.bytes24(elapsed)
        frame[5] = t[0]; frame[6] = t[1]; frame[7] = t[2]
        let s = PadPacket.bytes24(steps)
        frame[11] = s[0]; frame[12] = s[1]; frame[13] = s[2]
        return PadStatus(data: frame)!
    }

    tracker.ingest(status(elapsed: 10, steps: 10, speed: 30))
    tracker.ingest(status(elapsed: 40, steps: 120, speed: 40))
    check(tracker.kcal > 0, "calories should accrue across a 30s gap")
    check(tracker.peakSpeedKph == 4.0)
    check(tracker.samples.count == 2)

    // Belt counters reset -> new session.
    tracker.ingest(status(elapsed: 1, steps: 1, speed: 20))
    check(tracker.samples.count == 1)
    check(tracker.kcal == 0)
}

func unitConversion() throws {
    check(DistanceUnit.kilometers.speed(fromKph: 6) == 6)
    let mph = DistanceUnit.miles.speed(fromKph: 6)
    check(mph > 3.7 && mph < 3.8)
    check(DistanceUnit.miles.distanceSuffix == "mi")
}

// MARK: - Command queue (regressions for the audited stuck-state bugs)

/// Repeated Start taps must not grow the queue: at one frame per 0.7 s an unbounded
/// mode+start+speed pileup pushes the real speed change seconds out and starves the status poll.
func repeatedStartDoesNotGrowQueue() throws {
    var queue = CommandQueue()
    for _ in 0..<5 {
        queue.enqueue(.setMode(.manual))
        queue.enqueue(.start)
        queue.enqueue(.setSpeed(30))
    }
    check(queue.controlCount == 3, "expected 3 coalesced frames, got \(queue.controlCount)")
}

/// Coalescing must replace in place. Re-appending would reorder this into start, speed, mode
/// and the belt would be told to change speed before it was started.
func coalescingPreservesSendOrder() throws {
    var queue = CommandQueue()
    queue.enqueue(.setMode(.manual))
    queue.enqueue(.start)
    queue.enqueue(.setSpeed(20))
    queue.enqueue(.setMode(.manual))   // repeat, must not jump to the tail
    queue.enqueue(.setSpeed(45))       // newest speed must win, in place

    check(queue.dequeue() == .setMode(.manual), "mode must be sent first")
    check(queue.dequeue() == .start, "start must be sent second")
    check(queue.dequeue() == .setSpeed(45), "newest speed, sent last")
    check(queue.dequeue() == nil)
}

/// A status poll must never delay a control frame, and only the newest poll is worth sending.
func controlFramesOutrankStatusPolls() throws {
    var queue = CommandQueue()
    queue.enqueue(.askStats)
    queue.enqueue(.askStats)
    queue.enqueue(.setSpeed(30))
    check(queue.dequeue() == .setSpeed(30), "control frame must jump the poll")
    check(queue.dequeue() == .askStats, "one poll remains")
    check(queue.dequeue() == nil, "duplicate polls must collapse")
}

/// Distinct preferences must not collapse into each other, but rewriting one must.
func preferencesCoalesceIndependently() throws {
    var queue = CommandQueue()
    queue.enqueue(.setPreference(.maxSpeed, type: 0, value: 60))
    queue.enqueue(.setPreference(.childLock, type: 0, value: 1))
    queue.enqueue(.setPreference(.maxSpeed, type: 0, value: 45))
    check(queue.controlCount == 2, "two distinct preferences, got \(queue.controlCount)")
    check(queue.pendingControl.first == .setPreference(.maxSpeed, type: 0, value: 45),
          "the newer max-speed write must supersede in place")
}

func queueClearsCompletely() throws {
    var queue = CommandQueue()
    queue.enqueue(.setSpeed(30))
    queue.enqueue(.askStats)
    queue.removeAll()
    check(queue.isEmpty)
    check(queue.dequeue() == nil)
}

/// The scan/connect phases each need a terminal state, and it must carry actionable guidance.
func notFoundIsTerminalAndExplained() throws {
    let notFound = PadConnectionState.notFound
    check(!notFound.isBusy, "notFound must not render as a spinner")
    check(!notFound.isConnected)
    check(notFound.hint != nil, "notFound must explain what to do next")
    check(PadConnectionState.scanning.isBusy, "scanning is still a busy state")
    check(PadConnectionState.connecting("x").isBusy)
    check(PadConnectionState.idle.hint == nil)
}

// MARK: - Speed programs ("algorithms")

/// The exact series the drift was specified with: 4.0, 4.1, 4.2 … 5.5, 5.4, 5.3 … 4.0, 4.1 …
/// with the endpoints visited once per cycle, not twice.
func driftProducesRequestedSeries() throws {
    let program = SpeedProgram.standard   // 4.0–5.5, 0.1 step, 2 min
    check(program.kind == .gentleDrift)
    check(program.minKph == 4.0)
    check(program.maxKph == 5.5)
    check(program.stepKph == 0.1)
    check(program.intervalSeconds == 120)

    var state = SpeedSequence.start(of: program)
    var series: [Int] = [state.raw]
    for _ in 0..<64 {
        state = SpeedSequence.next(state, in: program)
        series.append(state.raw)
    }

    // Climb 40...55, then descend to 40, then climb again — endpoints not repeated.
    let expectedClimb = Array(40...55)
    let expectedFall = Array((40...54).reversed())
    let expected = expectedClimb + expectedFall + Array(41...55)
    check(Array(series.prefix(expected.count)) == expected,
          "series diverged: \(Array(series.prefix(expected.count)))")

    // Never outside the configured band.
    check(series.allSatisfy { $0 >= 40 && $0 <= 55 }, "series left its band")

    // One full cycle is 30 blocks for this configuration (15 up + 15 down), each 2 minutes.
    check(program.blocksPerCycle == 30, "blocksPerCycle was \(program.blocksPerCycle)")
    check(program.cycleDuration == 3600, "cycleDuration was \(program.cycleDuration)")
    check(program.cycle.allSatisfy { $0.seconds == 120 }, "a drift's blocks are all one interval")
}

/// Integer units mean no floating-point drift: every value is an exact multiple of 0.1.
func driftHasNoFloatingPointDrift() throws {
    let program = SpeedProgram.standard
    var state = SpeedSequence.start(of: program)
    for _ in 0..<500 {
        state = SpeedSequence.next(state, in: program)
        let kph = Double(state.raw) / 10
        check((kph * 10).rounded() == kph * 10, "non-exact speed \(kph)")
    }
}

/// A step that does not divide the band evenly must land exactly on the endpoints, not overshoot.
func driftClampsUnevenSteps() throws {
    var program = SpeedProgram.standard
    program.stepRaw = 4               // 0.4 km/h across a 1.5 km/h band
    var state = SpeedSequence.start(of: program)
    var series: [Int] = [state.raw]
    for _ in 0..<10 {
        state = SpeedSequence.next(state, in: program)
        series.append(state.raw)
    }
    check(Array(series.prefix(6)) == [40, 44, 48, 52, 55, 51], "uneven step series: \(series)")
    check(series.allSatisfy { $0 >= 40 && $0 <= 55 }, "uneven step left the band")
    check(program.blocksPerCycle == 8, "blocksPerCycle was \(program.blocksPerCycle)")
}

/// A drift is variation, not interval training. Labelling its top step as brisk would quietly
/// inflate the researched hard-minute dose with minutes nobody prescribed.
func driftNeverClaimsBriskWork() throws {
    // Written out rather than chained: `named(...)?.sessionWorkSeconds == nil` compares the OUTER
    // optional of an Int??, so it would pass even if the drift did advertise a dose.
    let drift = try require(PaceAlgorithm.named(.gentleDrift))
    check(drift.sessionWorkSeconds == nil, "a drift must not advertise a researched dose")
    for anchor in [20, 38, 50, 65] {
        let program = SpeedProgram(kind: .gentleDrift, minRaw: anchor - 3, maxRaw: anchor + 3)
        check(program.workSecondsPerCycle == 0,
              "drift at \(anchor) claimed \(program.workSecondsPerCycle)s of work")
        check(program.cycle.allSatisfy { !$0.tier.isWork })
    }
    // Even a wide hand-authored drift stays out of the dose.
    var wide = SpeedProgram.standard
    wide.maxRaw = 80
    check(wide.workSecondsPerCycle == 0, "a wide drift must still claim no dose")
}

func programValidationRejectsNonsense() throws {
    var p = SpeedProgram.standard
    check(p.isValid)
    p.stepRaw = 0
    check(!p.isValid, "zero step must be rejected")
    p = SpeedProgram.standard; p.maxRaw = p.minRaw
    check(!p.isValid, "empty band must be rejected")
    p = SpeedProgram.standard; p.intervalSeconds = 1
    check(!p.isValid, "sub-5s interval must be rejected")
    // An invalid program must not move — not its speed, and not its place in the cycle.
    let stuck = SpeedSequence.next(
        SpeedSequence.State(index: 3, raw: 40, seconds: 120, tier: .easy, isRising: true), in: p
    )
    check(stuck.raw == 40, "invalid program must not advance")
    check(stuck.index == 3, "invalid program must not move in its cycle")
    check(p.cycle.isEmpty, "an invalid program has no cycle to run")

    // The researched protocols carry their own block timings, so a nonsense interval or step —
    // fields they never read — must not make them unrunnable.
    var interval = PaceAlgorithm.all[0].program(anchorRaw: 38)
    check(interval.kind != .gentleDrift)
    interval.intervalSeconds = 1
    interval.stepRaw = 0
    check(interval.isValid, "a protocol must not be invalidated by fields it does not use")
    check(!interval.cycle.isEmpty)
}

/// The app's speed ceiling must win over the program's maximum.
func programRespectsSpeedCeiling() throws {
    let program = SpeedProgram.standard
    let clamped = try require(program.clamped(toCeilingRaw: 50))
    check(clamped.maxRaw == 50, "ceiling must cap the maximum")
    check(clamped.minRaw == 40, "minimum unchanged when it fits")

    var state = SpeedSequence.start(of: clamped)
    for _ in 0..<40 {
        state = SpeedSequence.next(state, in: clamped)
        check(state.raw <= 50, "program exceeded the ceiling at \(state.raw)")
    }
    // A ceiling below the minimum leaves no runnable range at all.
    check(program.clamped(toCeilingRaw: 30) == nil, "ceiling under the band must not run")
}

// MARK: - Research-backed pace algorithms

/// Interval walking is the flagship, so its numbers must be the ones the trials used: three
/// minutes fast, three minutes slow, and five cycles to one researched session.
func intervalWalkMatchesTheResearchedProtocol() throws {
    let algorithm = try require(PaceAlgorithm.named(.intervalWalk))
    let program = algorithm.program(anchorRaw: PaceMode.work.defaultAnchorRaw)
    check(program.minRaw == 34 && program.maxRaw == 46,
          "working band was \(program.minRaw)–\(program.maxRaw)")

    let cycle = program.cycle
    check(cycle.count == 2, "cycle had \(cycle.count) blocks")
    check(cycle[0].tier == .brisk, "the fast block comes first")
    check(cycle[0].seconds == 180, "fast block was \(cycle[0].seconds)s, not the trials' 3 minutes")
    check(cycle[0].raw == 46, "fast block should sit at the top of the band")
    check(cycle[1].tier == .easy)
    check(cycle[1].seconds == 180, "slow block was \(cycle[1].seconds)s")
    check(cycle[1].raw == 34, "slow block should sit at the bottom of the band")
    check(program.cycleDuration == 360)
    check(program.workSecondsPerCycle == 180)

    // Nose and Masuki prescribed five cycles — 30 minutes — as a session.
    let dose = try require(algorithm.sessionWorkSeconds)
    check(dose == 900, "session dose was \(dose)s")
    check(dose / program.workSecondsPerCycle == 5, "a session should be five cycles")
}

/// VILPA measured bursts of one to two minutes, a few times a day. A burst outside that window is
/// either too short for the belt to reach the speed, or no longer the thing that was studied.
func microSurgesKeepBurstsInsideTheStudiedWindow() throws {
    let algorithm = try require(PaceAlgorithm.named(.microSurges))
    let program = algorithm.program(anchorRaw: PaceMode.work.defaultAnchorRaw)
    let cycle = program.cycle

    let surges = cycle.filter { $0.tier == .surge }
    check(surges.count == 1, "expected one burst per cycle, got \(surges.count)")
    for surge in surges {
        check(surge.seconds >= 60 && surge.seconds <= 120,
              "burst of \(surge.seconds)s is outside the studied 1–2 minute window")
    }
    check(program.cycleDuration == 720, "cycle was \(program.cycleDuration)s")
    check(program.workSecondsPerCycle == 90)

    // The whole point is that you can keep typing through nearly all of it.
    let easy = cycle.filter { $0.tier == .easy }.reduce(0) { $0 + $1.seconds }
    check(Double(easy) / program.cycleDuration >= 0.85,
          "only \(Double(easy) / program.cycleDuration) of the cycle is easy")

    // A 90-minute desk walk should land near the studied handful of bursts, not dozens.
    let burstsIn90Minutes = Int(90 * 60 / program.cycleDuration)
    check(burstsIn90Minutes >= 3 && burstsIn90Minutes <= 10,
          "\(burstsIn90Minutes) bursts in 90 minutes is not the studied dose")
}

/// The long session banks one researched dose and then stops adding hard minutes — the point of it
/// is that ninety unbroken minutes of brisk work is more than any trial prescribed.
func longDeskSessionBanksOneDoseThenCruises() throws {
    let algorithm = try require(PaceAlgorithm.named(.longDeskSession))
    let program = algorithm.program(anchorRaw: PaceMode.work.defaultAnchorRaw)
    check(program.cycleDuration == 3600, "cycle was \(program.cycleDuration)s")
    check(program.workSecondsPerCycle == 900, "work was \(program.workSecondsPerCycle)s")
    check(program.workSecondsPerCycle == algorithm.sessionWorkSeconds,
          "one cycle should be exactly one researched session")

    let cycle = program.cycle
    check(cycle.count == 16, "cycle had \(cycle.count) blocks")
    // The interval half comes first, so the dose is banked before the cruising starts.
    check(cycle.prefix(10).allSatisfy { $0.seconds == 180 }, "the dose is ten 3-minute blocks")
    check(cycle.prefix(10).filter { $0.tier.isWork }.count == 5, "five fast blocks")
    check(cycle.suffix(6).allSatisfy { !$0.tier.isWork }, "the cruise must add no hard minutes")
    // Two hours is two doses, not forty-five minutes of brisk walking.
    check(Int(2 * 3600 / program.cycleDuration) == 2)
}

/// No block may be shorter than the belt needs to actually get there. `CommandQueue` spaces writes
/// about 0.7s apart and the belt then ramps, so a 10-second block — the literal 10-20-30 protocol —
/// would be a speed the belt never reaches.
func everyBlockIsLongEnoughForTheBeltToReach() throws {
    for algorithm in PaceAlgorithm.all {
        for anchor in [PaceMode.work.defaultAnchorRaw, PaceMode.meeting.defaultAnchorRaw] {
            for block in algorithm.program(anchorRaw: anchor).cycle {
                check(block.seconds >= 60,
                      "\(algorithm.name) has a \(block.seconds)s block — too short to reach")
            }
        }
    }
}

/// Every block of every algorithm, at every anchor either mode allows, must sit inside the
/// program's own band — that is what makes clamping the band a complete guarantee.
func everyAlgorithmStaysInsideItsBand() throws {
    let floorRaw = SpeedProgram.raw(SpeedLimits.minRunningKph)
    let walkingCeiling = SpeedProgram.raw(SpeedLimits.defaultWalkingCeilingKph)
    let hardMax = SpeedProgram.raw(SpeedLimits.hardMaxKph)

    for algorithm in PaceAlgorithm.all {
        for mode in PaceMode.allCases {
            for anchor in [mode.anchorRange.lowerBound, mode.defaultAnchorRaw,
                           mode.anchorRange.upperBound] {
                let program = algorithm.program(anchorRaw: anchor)
                check(program.isValid, "\(algorithm.name) invalid at anchor \(anchor)")
                check(program.minRaw >= floorRaw,
                      "\(algorithm.name) at \(anchor) starts below the belt's minimum")
                for block in program.cycle {
                    check(block.raw >= program.minRaw && block.raw <= program.maxRaw,
                          "\(algorithm.name) block \(block.raw) is outside "
                          + "\(program.minRaw)–\(program.maxRaw)")
                }
                // Whatever the anchor, the ceiling in force is the last word.
                for ceiling in [walkingCeiling, hardMax] {
                    guard let fitted = program.clamped(toCeilingRaw: ceiling) else { continue }
                    for block in fitted.cycle {
                        check(block.raw <= ceiling,
                              "\(algorithm.name) commanded \(block.raw) above ceiling \(ceiling)")
                    }
                }
            }
        }
    }
}

/// Switching mode shifts every algorithm together and keeps the shape each protocol was studied
/// with: same blocks, same durations, same band width — just faster.
func paceModesShiftEveryAlgorithmTogether() throws {
    check(PaceMode.work.defaultAnchorRaw == 38, "Working mode is built around 3.8 km/h")
    check(PaceMode.meeting.defaultAnchorRaw == 50, "Meeting mode is built around 5.0 km/h")
    check(PaceMode.meeting.defaultAnchorRaw > PaceMode.work.defaultAnchorRaw,
          "a meeting is the faster mode")

    for mode in PaceMode.allCases {
        check(mode.anchorRange.contains(mode.defaultAnchorRaw),
              "\(mode.label) default anchor is outside its own range")
        check(mode.anchorRange.upperBound <= SpeedProgram.raw(SpeedLimits.hardMaxKph),
              "\(mode.label) anchor could exceed the hardware maximum")
    }

    for algorithm in PaceAlgorithm.all {
        let work = algorithm.program(anchorRaw: PaceMode.work.defaultAnchorRaw)
        let meeting = algorithm.program(anchorRaw: PaceMode.meeting.defaultAnchorRaw)
        check(meeting.minRaw > work.minRaw, "\(algorithm.name): meeting must be faster at the bottom")
        check(meeting.maxRaw > work.maxRaw, "\(algorithm.name): meeting must be faster at the top")
        check(meeting.maxRaw - meeting.minRaw == work.maxRaw - work.minRaw,
              "\(algorithm.name): the band width must survive the shift")
        check(meeting.cycle.count == work.cycle.count,
              "\(algorithm.name): the block count must survive the shift")
        let shapeSurvived = zip(work.cycle, meeting.cycle).allSatisfy { pair in
            pair.0.seconds == pair.1.seconds && pair.0.tier == pair.1.tier
        }
        check(shapeSurvived, "\(algorithm.name): the shape must survive the shift")
    }
}

/// Working mode has one job: stay slow enough to keep typing accurate. If an algorithm's easy pace
/// creeps up, the mode has stopped being a working mode.
func workingModeStaysTypeable() throws {
    for algorithm in PaceAlgorithm.all {
        let program = algorithm.program(anchorRaw: PaceMode.work.defaultAnchorRaw)
        check(program.raw(for: .easy) <= 40,
              "\(algorithm.name) types at \(program.raw(for: .easy)) — too fast for a keyboard")
        check(program.maxRaw <= 52,
              "\(algorithm.name) tops out at \(program.maxRaw) in Working mode")
        // And a meeting must not need Run mode just to exist at the default ceiling.
        let meeting = algorithm.program(anchorRaw: PaceMode.meeting.defaultAnchorRaw)
        check(meeting.clamped(
            toCeilingRaw: SpeedProgram.raw(SpeedLimits.defaultWalkingCeilingKph)
        ) != nil, "\(algorithm.name) cannot run in Meeting mode at the default ceiling")
    }
}

/// Every algorithm needs a distinct kind, a description, and a band — and every program kind needs
/// a box, or it is unreachable from the algorithm list.
func everyAlgorithmIsDistinctAndDescribed() throws {
    check(PaceAlgorithm.all.count >= 3, "the point was several algorithms to choose between")
    check(Set(PaceAlgorithm.all.map(\.kind)).count == PaceAlgorithm.all.count,
          "two algorithms share a kind")
    for kind in SpeedProgram.Kind.allCases {
        check(PaceAlgorithm.named(kind) != nil, "\(kind.label) has no algorithm entry")
    }
    for algorithm in PaceAlgorithm.all {
        check(!algorithm.goal.isEmpty, "\(algorithm.name) has no goal")
        check(!algorithm.evidence.isEmpty, "\(algorithm.name) has no evidence")
        check(!algorithm.cadence.isEmpty, "\(algorithm.name) has no cadence note")
        check(algorithm.highOffset > algorithm.lowOffset, "\(algorithm.name) has an empty band")
    }
    // Programs saved by earlier builds decode by raw value; renaming this orphans all of them.
    check(SpeedProgram.Kind.gentleDrift.rawValue == "upDown",
          "the drift's raw value must not change")
}

/// The runner must honour each block's own length. A cycle of 10½ minutes easy and 90 seconds hard
/// is the whole point of the block model — a single shared interval could not express it.
func runnerHonoursVariableBlockLengths() throws {
    let runner = ProgramRunner()
    var applied: [Double] = []
    runner.onSpeed = { applied.append($0) }
    let t0 = Date(timeIntervalSince1970: 5_000_000)
    let program = try require(PaceAlgorithm.named(.microSurges))
        .program(anchorRaw: PaceMode.work.defaultAnchorRaw)   // 3.5 easy / 5.0 surge

    check(runner.start(program, ceilingRaw: 100, now: t0))
    check(applied == [3.5], "must start on the easy block, got \(applied)")
    check(runner.state.tier == .easy)

    // The easy stretch is 10½ minutes, not a drift's two.
    runner.tick(beltIsMoving: true, now: t0.addingTimeInterval(629))
    check(applied.count == 1, "surged early")
    runner.tick(beltIsMoving: true, now: t0.addingTimeInterval(630))
    check(applied.last == 5.0, "expected the surge, got \(String(describing: applied.last))")
    check(runner.state.tier == .surge)

    // And the surge is 90 seconds, not another 10½ minutes.
    runner.tick(beltIsMoving: true, now: t0.addingTimeInterval(719))
    check(applied.count == 2, "surge ended early")
    runner.tick(beltIsMoving: true, now: t0.addingTimeInterval(720))
    check(applied.last == 3.5, "the surge must end after 90s")
    check(runner.state.index == 0, "the cycle must wrap round")
}

/// The brisk-minute total is the researched dose, so only genuinely hard blocks may count — and
/// standing still may never count, however long you stand.
func runnerCountsOnlyBriskMinutes() throws {
    let runner = ProgramRunner()
    let t0 = Date(timeIntervalSince1970: 6_000_000)
    let program = try require(PaceAlgorithm.named(.intervalWalk))
        .program(anchorRaw: PaceMode.work.defaultAnchorRaw)
    check(runner.start(program, ceilingRaw: 100, now: t0))
    check(runner.state.tier == .brisk, "an interval walk starts on the fast block")
    check(runner.workSeconds == 0)

    // One tick per second, as the belt's own 1 Hz status stream delivers them.
    for second in 1...180 {
        runner.tick(beltIsMoving: true, now: t0.addingTimeInterval(Double(second)))
    }
    check(abs(runner.workSeconds - 180) < 1.5,
          "expected ~180 brisk seconds, got \(runner.workSeconds)")
    check(runner.state.tier == .easy, "should have handed over to the easy block")

    // The easy block adds nothing.
    for second in 181...360 {
        runner.tick(beltIsMoving: true, now: t0.addingTimeInterval(Double(second)))
    }
    check(abs(runner.workSeconds - 180) < 1.5,
          "easy minutes must not count: \(runner.workSeconds)")

    // Nor does standing still, however long for.
    let stopped = t0.addingTimeInterval(361)
    runner.tick(beltIsMoving: false, now: stopped)
    runner.tick(beltIsMoving: false, now: stopped.addingTimeInterval(30))
    check(runner.isPaused)
    runner.tick(beltIsMoving: true, now: stopped.addingTimeInterval(3600))
    check(abs(runner.workSeconds - 180) < 1.5,
          "paused time was credited: \(runner.workSeconds)")

    // A stalled status stream must not invent minutes either.
    let stalled = ProgramRunner()
    check(stalled.start(program, ceilingRaw: 100, now: t0))
    stalled.tick(beltIsMoving: true, now: t0.addingTimeInterval(120))
    check(stalled.workSeconds <= ProgramRunner.maxCreditedTickGap,
          "a 120s gap credited \(stalled.workSeconds)s of walking that did not happen")

    // The dose readout is a fraction of the researched session, never more than complete.
    check(runner.doseProgress != nil, "an interval walk has a researched dose")
    check(try require(runner.doseProgress) <= 1)
    let drift = ProgramRunner()
    check(drift.start(SpeedProgram.standard, ceilingRaw: 100, now: t0))
    check(drift.doseProgress == nil, "a drift must not report progress toward a dose")
}

/// Progress through a cycle has to be measured in time. Counting blocks would show a micro-surge
/// jumping from 0% to 50% after ten minutes and then to 100% ninety seconds later.
func cycleProgressTracksTimeNotBlocks() throws {
    let runner = ProgramRunner()
    let t0 = Date(timeIntervalSince1970: 8_000_000)
    let program = try require(PaceAlgorithm.named(.microSurges))
        .program(anchorRaw: PaceMode.work.defaultAnchorRaw)
    check(runner.start(program, ceilingRaw: 100, now: t0))
    check(runner.cycleProgress(now: t0) == 0)

    let halfway = runner.cycleProgress(now: t0.addingTimeInterval(315))
    check(abs(halfway - 315.0 / 720.0) < 0.02,
          "315s into a 720s cycle read as \(halfway)")

    runner.tick(beltIsMoving: true, now: t0.addingTimeInterval(630))
    let intoSurge = runner.cycleProgress(now: t0.addingTimeInterval(675))
    check(abs(intoSurge - 675.0 / 720.0) < 0.02,
          "675s into a 720s cycle read as \(intoSurge)")
}

/// Clamping the band must not move you to a different *kind* of block. Dropping out of Run mode
/// during a fast interval should slow the interval, not cut it short or turn it into recovery.
func ceilingRemapKeepsABriskBlockBrisk() throws {
    let runner = ProgramRunner()
    var applied: [Double] = []
    runner.onSpeed = { applied.append($0) }
    let t0 = Date(timeIntervalSince1970: 7_000_000)
    let program = try require(PaceAlgorithm.named(.intervalWalk))
        .program(anchorRaw: PaceMode.meeting.defaultAnchorRaw)   // 4.6 – 5.8

    check(runner.start(program, ceilingRaw: 100, now: t0))
    check(runner.state.tier == .brisk)
    check(applied == [5.8], "expected the fast block, got \(applied)")

    runner.applyCeiling(50)
    check(runner.state.tier == .brisk, "a ceiling change must not change the kind of block")
    check(runner.currentKph == 5.0, "expected the clamped fast pace, got \(runner.currentKph)")
    check(applied.last == 5.0, "the belt has to be told about the clamp")
    // Same block, same length, so the schedule is untouched.
    check(runner.secondsUntilNextChange(now: t0.addingTimeInterval(60)) == 120,
          "the deadline moved: \(String(describing: runner.secondsUntilNextChange(now: t0.addingTimeInterval(60))))")
}

/// Switching mode mid-walk must reband the running algorithm, not restart it: the brisk minutes
/// already walked are the researched dose, and losing them would misreport the session.
func rebandKeepsTheDoseAndRefusesAShapeChange() throws {
    let runner = ProgramRunner()
    var applied: [Double] = []
    runner.onSpeed = { applied.append($0) }
    let t0 = Date(timeIntervalSince1970: 10_000_000)
    let interval = try require(PaceAlgorithm.named(.intervalWalk))
    let working = interval.program(anchorRaw: PaceMode.work.defaultAnchorRaw)      // 3.4 – 4.6
    let meeting = interval.program(anchorRaw: PaceMode.meeting.defaultAnchorRaw)   // 4.6 – 5.8

    check(runner.start(working, ceilingRaw: 100, now: t0))
    for second in 1...120 {
        runner.tick(beltIsMoving: true, now: t0.addingTimeInterval(Double(second)))
    }
    let banked = runner.workSeconds
    check(abs(banked - 120) < 1.5, "expected ~120 brisk seconds, got \(banked)")
    let stepsBefore = runner.stepsApplied

    // A meeting starts: same protocol, faster band.
    check(runner.reband(to: meeting, ceilingRaw: 100))
    check(try require(runner.activeProgram).maxRaw == 58, "band did not move")
    check(abs(runner.workSeconds - banked) < 0.01, "rebanding reset the dose")
    check(runner.stepsApplied == stepsBefore, "rebanding restarted the cycle")
    check(runner.state.tier == .brisk, "rebanding must keep the block")
    check(applied.last == 5.8, "the new band has to reach the belt")
    // The block was 2 of its 3 minutes in; it must still finish on time, not start over.
    check(runner.secondsUntilNextChange(now: t0.addingTimeInterval(120)) == 60,
          "the deadline moved: \(String(describing: runner.secondsUntilNextChange(now: t0.addingTimeInterval(120))))")

    // Rebanding may only change the band. A different protocol has to go through start().
    let surges = try require(PaceAlgorithm.named(.microSurges))
        .program(anchorRaw: PaceMode.work.defaultAnchorRaw)
    check(!runner.reband(to: surges, ceilingRaw: 100),
          "rebanding must not smuggle in a different algorithm")
    check(try require(runner.activeProgram).kind == .intervalWalk)

    // And the ceiling still wins over a reband.
    check(runner.reband(to: meeting, ceilingRaw: 50))
    check(try require(runner.activeProgram).maxRaw == 50, "the ceiling must clamp a reband")
    check(!runner.reband(to: meeting, ceilingRaw: 20),
          "a ceiling with no room must refuse rather than run out of range")

    // A stopped runner has nothing to reband.
    runner.stop()
    check(!runner.reband(to: meeting, ceilingRaw: 100))
}

/// The runner pauses with the belt, resumes where it left off, and never drifts its schedule.
func runnerPausesWithBeltAndKeepsSchedule() throws {
    let runner = ProgramRunner()
    var applied: [Double] = []
    runner.onSpeed = { applied.append($0) }
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    check(runner.start(SpeedProgram.standard, ceilingRaw: 100, now: t0))
    check(applied == [4.0], "must apply the minimum immediately, got \(applied)")

    // Not yet due.
    runner.tick(beltIsMoving: true, now: t0.addingTimeInterval(119))
    check(applied.count == 1, "changed early")

    // Due at the interval.
    runner.tick(beltIsMoving: true, now: t0.addingTimeInterval(120))
    check(applied.last == 4.1, "expected 4.1, got \(String(describing: applied.last))")

    // A brief dip in reported speed (spin-up, or a momentary zero during a change) must NOT pause.
    runner.tick(beltIsMoving: false, now: t0.addingTimeInterval(125))
    check(!runner.isPaused, "paused during the grace period")
    runner.tick(beltIsMoving: true, now: t0.addingTimeInterval(128))
    check(!runner.isPaused, "a recovered belt must not be left paused")

    // Belt genuinely stops -> program pauses and stops counting down.
    runner.tick(beltIsMoving: false, now: t0.addingTimeInterval(130))
    check(!runner.isPaused, "grace period restarts after the belt recovers")
    runner.tick(beltIsMoving: false, now: t0.addingTimeInterval(141))
    check(runner.isPaused, "must pause once the belt has been still past the grace period")
    check(runner.secondsUntilNextChange(now: t0.addingTimeInterval(141)) == nil)
    runner.tick(beltIsMoving: false, now: t0.addingTimeInterval(600))
    check(applied.count == 2, "program advanced while the belt was stopped")

    // Resuming re-asserts the expected speed and restarts the interval from now.
    runner.tick(beltIsMoving: true, now: t0.addingTimeInterval(700))
    check(!runner.isPaused)
    check(applied.last == 4.1, "resume should re-assert the current step")
    runner.tick(beltIsMoving: true, now: t0.addingTimeInterval(819))
    check(applied.count == 3, "advanced before the resumed interval elapsed")
    runner.tick(beltIsMoving: true, now: t0.addingTimeInterval(820))
    check(applied.last == 4.2, "expected 4.2 after resume, got \(String(describing: applied.last))")

    runner.stop()
    check(!runner.isRunning)
    runner.tick(beltIsMoving: true, now: t0.addingTimeInterval(2000))
    check(applied.count == 4, "a stopped program must not advance")
}

/// A late tick must not shift the whole programme later (no cumulative drift).
func runnerDoesNotDriftOnLateTicks() throws {
    let runner = ProgramRunner()
    var applied: [Double] = []
    runner.onSpeed = { applied.append($0) }
    let t0 = Date(timeIntervalSince1970: 2_000_000)
    runner.start(SpeedProgram.standard, ceilingRaw: 100, now: t0)

    // Tick 3s late each time; the schedule should stay anchored to multiples of 120s.
    runner.tick(beltIsMoving: true, now: t0.addingTimeInterval(123))
    check(applied.last == 4.1)
    runner.tick(beltIsMoving: true, now: t0.addingTimeInterval(241))
    check(applied.last == 4.2, "second change should be due at 240s, not 246s")
}

/// Lowering the app's speed ceiling must pull a running program down with it, not let it keep
/// stepping toward a maximum the belt will never be allowed to reach.
func loweringCeilingReclampsRunningProgram() throws {
    let runner = ProgramRunner()
    var applied: [Double] = []
    runner.onSpeed = { applied.append($0) }
    let t0 = Date(timeIntervalSince1970: 3_000_000)
    runner.start(SpeedProgram.standard, ceilingRaw: 100, now: t0)   // 4.0-5.5

    // Climb to the top of the band.
    var now = t0
    for _ in 0..<20 {
        now = now.addingTimeInterval(120)
        runner.tick(beltIsMoving: true, now: now)
    }
    // 20 steps from 4.0: climbs to 5.5 in 15, then back down to 5.0.
    check(runner.currentKph == 5.0, "expected 5.0 after 20 steps, got \(runner.currentKph)")
    check(runner.currentKph > 4.8, "must be above the ceiling we are about to set")

    // Ceiling drops to 4.8 km/h.
    runner.applyCeiling(48)
    let active = try require(runner.activeProgram)
    check(active.maxRaw == 48, "program max must follow the ceiling, got \(active.maxRaw)")
    check(runner.currentKph <= 4.8, "current step must be pulled into the band, got \(runner.currentKph)")

    // And it must stay inside the new band from then on.
    for _ in 0..<40 {
        now = now.addingTimeInterval(120)
        runner.tick(beltIsMoving: true, now: now)
        check(runner.currentKph <= 4.8, "program exceeded the lowered ceiling: \(runner.currentKph)")
        check(runner.currentKph >= 4.0, "program dropped below its minimum: \(runner.currentKph)")
    }
    check(applied.allSatisfy { $0 <= 4.8 || $0 <= 5.5 })

    // A ceiling below the whole band stops the program rather than running it out of range.
    runner.applyCeiling(20)
    check(!runner.isRunning, "an impossible ceiling must stop the program")
}

// MARK: - Regressions for the audited safety and ordering bugs

/// Lowering the ceiling while a program is PAUSED must not command a speed: that reached
/// startWalking() and physically started a stopped treadmill from a settings change.
func loweringCeilingWhilePausedCommandsNothing() throws {
    let runner = ProgramRunner()
    var applied: [Double] = []
    runner.onSpeed = { applied.append($0) }
    let t0 = Date(timeIntervalSince1970: 4_000_000)
    runner.start(SpeedProgram.standard, ceilingRaw: 100, now: t0)

    // Climb into the upper half of the band.
    var now = t0
    for _ in 0..<20 {
        now = now.addingTimeInterval(120)
        runner.tick(beltIsMoving: true, now: now)
    }
    let beforePause = applied.count
    check(runner.currentKph > 4.5)

    // Belt goes idle long enough to pause the program.
    runner.tick(beltIsMoving: false, now: now.addingTimeInterval(1))
    runner.tick(beltIsMoving: false, now: now.addingTimeInterval(30))
    check(runner.isPaused, "program should be paused")
    check(runner.isRunning, "a paused program is still running")

    // Now lower the ceiling underneath the current step.
    runner.applyCeiling(45)
    check(applied.count == beforePause,
          "applyCeiling must not command a speed while paused (would start a stopped belt)")
    check(runner.currentKph <= 4.5, "the step must still be pulled into the new band")

    // On resume it re-asserts the corrected speed, so nothing is lost.
    runner.tick(beltIsMoving: true, now: now.addingTimeInterval(60))
    check(applied.count == beforePause + 1, "resume should re-assert the speed exactly once")
    check(applied.last! <= 4.5, "re-asserted speed must respect the new ceiling")
}

/// A second start sequence must not be able to reorder itself behind an in-flight one.
/// Enqueued one-by-one this produced `start, speed, mode` — speed before manual mode.
func startSequenceKeepsOrderAfterPartialDrain() throws {
    var queue = CommandQueue()
    let startBatch: [PadCommand] = [.setMode(.manual), .start, .setSpeed(25)]
    queue.enqueue(batch: startBatch)

    // The leading mode frame has already gone out to the belt.
    check(queue.dequeue() == .setMode(.manual))

    // Impatient second press, while start+speed are still queued.
    queue.enqueue(batch: [.setMode(.manual), .start, .setSpeed(30)])

    check(queue.dequeue() == .setMode(.manual), "mode must lead the new batch")
    check(queue.dequeue() == .start, "start must precede the speed")
    check(queue.dequeue() == .setSpeed(30), "newest speed last")
    check(queue.dequeue() == nil, "nothing stale left behind")
}

/// Batching must still collapse repeats rather than growing without bound.
func repeatedStartBatchesDoNotGrowQueue() throws {
    var queue = CommandQueue()
    for _ in 0..<5 {
        queue.enqueue(batch: [.setMode(.manual), .start, .setSpeed(30)])
    }
    check(queue.controlCount == 3, "expected 3 frames, got \(queue.controlCount)")
    check(queue.pendingControl == [.setMode(.manual), .start, .setSpeed(30)],
          "order must survive repeats: \(queue.pendingControl)")
}

/// The controller clamps speed itself, so no entry point — padctl included — can ask the belt
/// for more than the hardware maximum.
func controllerClampsSpeedAtTheWire() throws {
    check(PadController.rawSpeed(3.0) == 30)
    check(PadController.rawSpeed(0) == 0)
    check(PadController.rawSpeed(-5) == 0, "negative speed must clamp to zero")
    check(PadController.rawSpeed(20) == UInt8(PadController.maxSafeSpeedKph * 10),
          "20 km/h must clamp to the hardware maximum")
    check(PadController.rawSpeed(.infinity) == UInt8(PadController.maxSafeSpeedKph * 10),
          "a nonsense value must clamp, not trap")
    check(PadController.maxSafeSpeedKph == 10.0)
}

// MARK: - Session recording and history stats

/// Build a status frame with chosen counters.
private func frame(elapsed: Int, distanceRaw: Int, steps: Int, speedRaw: UInt8) -> PadStatus {
    var bytes = capturedStatus
    bytes[3] = speedRaw
    let t = PadPacket.bytes24(elapsed);   bytes[5] = t[0];  bytes[6] = t[1];  bytes[7] = t[2]
    let d = PadPacket.bytes24(distanceRaw); bytes[8] = d[0]; bytes[9] = d[1]; bytes[10] = d[2]
    let s = PadPacket.bytes24(steps);     bytes[11] = s[0]; bytes[12] = s[1]; bytes[13] = s[2]
    return PadStatus(data: bytes)!
}

/// A second walk on the same belt session must record only its own distance. The belt's counters
/// are cumulative and do NOT reset when you merely stop, so a naive recorder double-counts.
func recorderUsesDeltasNotCumulativeCounters() throws {
    let recorder = SessionRecorder(idleTimeout: 60, minimumDuration: 30, minimumSteps: 20)
    let t0 = Date(timeIntervalSince1970: 5_000_000)

    // Walk one: 0 -> 600s, 0 -> 1.00 km, 0 -> 1200 steps, fed in realistic increments (the
    // calorie integrator deliberately ignores jumps over 120s, which is what a reconnect looks like).
    check(recorder.ingest(frame(elapsed: 0, distanceRaw: 0, steps: 0, speedRaw: 30), now: t0) == nil)
    check(recorder.isRecording, "movement should open a session")
    for i in 1...10 {
        check(recorder.ingest(
            frame(elapsed: i * 60, distanceRaw: i * 10, steps: i * 120, speedRaw: 30),
            now: t0.addingTimeInterval(Double(i * 60))) == nil)
    }

    // Belt stops; after the idle timeout the walk is closed out.
    _ = recorder.ingest(frame(elapsed: 600, distanceRaw: 100, steps: 1200, speedRaw: 0),
                        now: t0.addingTimeInterval(601))
    let first = try require(recorder.ingest(
        frame(elapsed: 600, distanceRaw: 100, steps: 1200, speedRaw: 0),
        now: t0.addingTimeInterval(700)))
    check(first.durationSeconds == 600, "duration \(first.durationSeconds)")
    check(first.distanceKm == 1.0, "distance \(first.distanceKm)")
    check(first.steps == 1200, "steps \(first.steps)")
    check(first.kcal > 0, "calories should have accrued")
    check(!recorder.isRecording, "session should be closed")

    // Walk two, WITHOUT the belt resetting: counters continue from 600s / 1.00 km / 1200 steps.
    _ = recorder.ingest(frame(elapsed: 601, distanceRaw: 100, steps: 1201, speedRaw: 30),
                        now: t0.addingTimeInterval(800))
    _ = recorder.ingest(frame(elapsed: 900, distanceRaw: 150, steps: 1800, speedRaw: 30),
                        now: t0.addingTimeInterval(1100))
    let second = try require(recorder.finish(now: t0.addingTimeInterval(1100)))
    check(second.durationSeconds == 299, "second walk duration \(second.durationSeconds)")
    check(abs(second.distanceKm - 0.50) < 0.0001, "second walk distance \(second.distanceKm)")
    check(second.steps == 599, "second walk steps \(second.steps)")
}

/// When the belt resets its counters mid-stream, the open walk is closed with the old numbers.
func recorderClosesSessionOnCounterReset() throws {
    let recorder = SessionRecorder(idleTimeout: 600, minimumDuration: 30, minimumSteps: 20)
    let t0 = Date(timeIntervalSince1970: 6_000_000)
    _ = recorder.ingest(frame(elapsed: 0, distanceRaw: 0, steps: 0, speedRaw: 30), now: t0)
    _ = recorder.ingest(frame(elapsed: 400, distanceRaw: 60, steps: 800, speedRaw: 30),
                        now: t0.addingTimeInterval(400))
    // Belt reset: counters go backwards.
    let closed = try require(recorder.ingest(
        frame(elapsed: 2, distanceRaw: 0, steps: 3, speedRaw: 30), now: t0.addingTimeInterval(500)))
    check(closed.durationSeconds == 400, "duration \(closed.durationSeconds)")
    check(closed.steps == 800, "steps \(closed.steps)")
    // And a fresh walk is already open from the reset frame.
    check(recorder.isRecording, "a new session should have opened")
}

/// A nudge of the belt is not a walk and must not litter the history.
func recorderDiscardsTrivialWalks() throws {
    let recorder = SessionRecorder(idleTimeout: 30, minimumDuration: 30, minimumSteps: 20)
    let t0 = Date(timeIntervalSince1970: 7_000_000)
    _ = recorder.ingest(frame(elapsed: 0, distanceRaw: 0, steps: 0, speedRaw: 20), now: t0)
    _ = recorder.ingest(frame(elapsed: 5, distanceRaw: 1, steps: 6, speedRaw: 20),
                        now: t0.addingTimeInterval(5))
    check(recorder.finish(now: t0.addingTimeInterval(6)) == nil, "5s walk must be discarded")
}

private func session(_ day: String, km: Double, seconds: Int, steps: Int, kcal: Double = 100) -> WalkSession {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    formatter.timeZone = TimeZone(identifier: "UTC")
    let date = formatter.date(from: day)!
    return WalkSession(
        startedAt: date, endedAt: date.addingTimeInterval(Double(seconds)),
        durationSeconds: seconds, distanceKm: km, steps: steps, kcal: kcal, peakSpeedKph: 5.5
    )
}

private var utcCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

func statsTotalsAndAverages() throws {
    let sessions = [
        session("2026-08-10 08:00", km: 2.0, seconds: 1800, steps: 2500),
        session("2026-08-10 18:00", km: 1.0, seconds: 900, steps: 1300),
        session("2026-08-12 08:00", km: 3.0, seconds: 2700, steps: 3800),
    ]
    let totals = WalkStats.totals(sessions)
    check(totals.sessionCount == 3)
    check(totals.distanceKm == 6.0)
    check(totals.durationSeconds == 5400)
    check(totals.steps == 7600)
    // 6 km in 1.5 h = 4 km/h.
    check(abs(totals.averageSpeedKph - 4.0) < 0.0001, "avg \(totals.averageSpeedKph)")

    // Two active days, so the per-day average divides by 2 — not by the 3 days spanned.
    check(WalkStats.activePeriodCount(sessions, period: .day, calendar: utcCalendar) == 2)
    let perDay = WalkStats.averagePerActivePeriod(sessions, period: .day, calendar: utcCalendar)
    check(perDay.distanceKm == 3.0, "per-day distance \(perDay.distanceKm)")
    check(perDay.durationSeconds == 2700, "per-day duration \(perDay.durationSeconds)")

    // Both days fall in one month.
    check(WalkStats.activePeriodCount(sessions, period: .month, calendar: utcCalendar) == 1)
    let perMonth = WalkStats.averagePerActivePeriod(sessions, period: .month, calendar: utcCalendar)
    check(perMonth.distanceKm == 6.0)

    let best = try require(WalkStats.best(sessions, period: .day, calendar: utcCalendar))
    check(best.totals.distanceKm == 3.0, "best day should be the 3 km one")
}

/// Charts must show the days you did not walk, not silently close the gap.
func statsContinuousBucketsIncludeEmptyPeriods() throws {
    let sessions = [
        session("2026-08-10 08:00", km: 2.0, seconds: 1800, steps: 2500),
        session("2026-08-12 08:00", km: 3.0, seconds: 2700, steps: 3800),
    ]
    let now = session("2026-08-12 12:00", km: 0, seconds: 0, steps: 0).startedAt
    let buckets = WalkStats.continuousBuckets(
        sessions, period: .day, count: 4, endingAt: now, calendar: utcCalendar)
    check(buckets.count == 4, "expected 4 buckets, got \(buckets.count)")
    check(buckets.map { $0.totals.distanceKm } == [0, 2.0, 0, 3.0],
          "series \(buckets.map { $0.totals.distanceKm })")
    // Oldest first, so a chart reads left to right.
    check(buckets.first!.date < buckets.last!.date)
}

func statsDayStreak() throws {
    let today = session("2026-08-12 08:00", km: 1, seconds: 600, steps: 900).startedAt
    let threeInARow = [
        session("2026-08-10 08:00", km: 1, seconds: 600, steps: 900),
        session("2026-08-11 08:00", km: 1, seconds: 600, steps: 900),
        session("2026-08-12 08:00", km: 1, seconds: 600, steps: 900),
    ]
    check(WalkStats.currentDayStreak(threeInARow, now: today, calendar: utcCalendar) == 3)

    // A gap breaks it.
    let withGap = [
        session("2026-08-08 08:00", km: 1, seconds: 600, steps: 900),
        session("2026-08-11 08:00", km: 1, seconds: 600, steps: 900),
        session("2026-08-12 08:00", km: 1, seconds: 600, steps: 900),
    ]
    check(WalkStats.currentDayStreak(withGap, now: today, calendar: utcCalendar) == 2)

    // Yesterday still counts, so the streak is not lost before today is over.
    let endedYesterday = [session("2026-08-11 08:00", km: 1, seconds: 600, steps: 900)]
    check(WalkStats.currentDayStreak(endedYesterday, now: today, calendar: utcCalendar) == 1)

    // A stale streak does not.
    let stale = [session("2026-08-01 08:00", km: 1, seconds: 600, steps: 900)]
    check(WalkStats.currentDayStreak(stale, now: today, calendar: utcCalendar) == 0)
    check(WalkStats.currentDayStreak([], now: today, calendar: utcCalendar) == 0)
}

func statsCsvExport() throws {
    let sessions = [session("2026-08-10 08:00", km: 2.0, seconds: 1800, steps: 2500)]
    let csv = WalkStats.csv(sessions)
    let lines = csv.split(separator: "\n")
    check(lines.count == 2, "header plus one row, got \(lines.count)")
    check(lines[0].hasPrefix("started,ended,duration_seconds"))
    check(lines[1].contains("1800"))
    check(lines[1].contains("2.000"))
    // Every row must have the same column count as the header.
    check(lines[0].split(separator: ",", omittingEmptySubsequences: false).count
          == lines[1].split(separator: ",", omittingEmptySubsequences: false).count)
}

func sessionDerivedFigures() throws {
    let s = session("2026-08-10 08:00", km: 3.0, seconds: 3600, steps: 4000)
    check(s.averageSpeedKph == 3.0, "3 km in an hour is 3 km/h")
    check(abs(s.strideMetres - 0.75) < 0.0001, "stride \(s.strideMetres)")
    let empty = WalkSession(startedAt: Date(), endedAt: Date(), durationSeconds: 0,
                            distanceKm: 0, steps: 0, kcal: 0, peakSpeedKph: 0)
    check(empty.averageSpeedKph == 0, "no divide-by-zero")
    check(empty.strideMetres == 0)
    check(WalkStats.totals([]).averageSpeedKph == 0)
}

/// The history must survive a real encode -> disk -> decode round trip, not just in memory.
func sessionStoreRoundTripsThroughDisk() throws {
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("walkingpad-selftest-\(UInt32.random(in: 0...UInt32.max))")
        .appendingPathComponent("sessions.json")
    defer { try? FileManager.default.removeItem(at: temp.deletingLastPathComponent()) }

    let store = SessionStore(fileURL: temp)
    check(store.sessions.isEmpty, "a fresh store starts empty")
    check(store.lastError == nil, "a missing file is not an error")

    let a = session("2026-08-10 08:00", km: 2.0, seconds: 1800, steps: 2500)
    let b = session("2026-08-11 09:30", km: 3.5, seconds: 2400, steps: 4100)
    store.append(a)
    store.append(b)
    check(store.sessions.count == 2)
    check(store.lastError == nil, "save reported: \(store.lastError ?? "")")
    check(FileManager.default.fileExists(atPath: temp.path), "the file should exist on disk")

    // A second store reading the same file must see exactly the same history.
    let reopened = SessionStore(fileURL: temp)
    check(reopened.sessions.count == 2, "reopened count \(reopened.sessions.count)")
    check(reopened.lastError == nil, "reopen reported: \(reopened.lastError ?? "")")
    check(Set(reopened.sessions.map(\.id)) == Set([a.id, b.id]), "ids must survive the round trip")
    let restored = try require(reopened.sessions.first { $0.id == b.id })
    check(restored.distanceKm == 3.5)
    check(restored.steps == 4100)
    check(restored.durationSeconds == 2400)
    check(abs(restored.startedAt.timeIntervalSince(b.startedAt)) < 1, "dates must round trip")

    // Newest first ordering, and deletion persists.
    check(reopened.sessionsNewestFirst.first?.id == b.id, "newest first")
    reopened.delete(a)
    check(SessionStore(fileURL: temp).sessions.count == 1, "deletion must persist")

    // Totals over the restored data agree with the originals.
    check(WalkStats.totals(reopened.sessions).distanceKm == 3.5)
}

/// An unreadable history file must never be overwritten by the next walk.
/// Previously: load() failed, sessions went empty, and the next append() atomically replaced the
/// whole file with a single entry — silent, total data loss.
func unreadableHistoryIsPreservedNotOverwritten() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("walkingpad-corrupt-\(UInt32.random(in: 0...UInt32.max))")
    let file = dir.appendingPathComponent("sessions.json")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // A file that is definitely not decodable as [WalkSession].
    let garbage = "{ this is not json at all "
    try Data(garbage.utf8).write(to: file)

    let store = SessionStore(fileURL: file)
    check(store.sessions.isEmpty, "an unreadable file yields an empty in-memory history")
    check(store.quarantineNotice != nil, "the user must be told their history was set aside")
    check(store.quarantineNotice?.contains("sessions-unreadable-") == true,
          "the notice must name the preserved file so it can be found")

    // The original bytes must still exist somewhere.
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    let preserved = files.filter { $0.hasPrefix("sessions-unreadable-") }
    check(preserved.count == 1, "the unreadable file must be kept aside, found \(files)")
    let keptURL = dir.appendingPathComponent(preserved[0])
    check(try String(decoding: Data(contentsOf: keptURL), as: UTF8.self) == garbage,
          "the preserved copy must be byte-identical")

    // Now a new walk arrives: it must not disturb the preserved copy.
    store.append(session("2026-08-12 08:00", km: 1.0, seconds: 600, steps: 900))
    check(store.sessions.count == 1)
    check(try String(decoding: Data(contentsOf: keptURL), as: UTF8.self) == garbage,
          "appending must not touch the preserved copy")
    check(SessionStore(fileURL: file).sessions.count == 1, "the new history reloads cleanly")
    // The notice must survive the save, or the first walk after a quarantine silently erases the
    // only sign that the old history was archived.
    check(store.quarantineNotice != nil, "the notice must outlive the next successful save")
}

/// Sessions are kept newest-first as they are inserted, so reads do not re-sort the history.
func historyStaysSortedOnInsert() throws {
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("walkingpad-sort-\(UInt32.random(in: 0...UInt32.max))")
        .appendingPathComponent("sessions.json")
    defer { try? FileManager.default.removeItem(at: temp.deletingLastPathComponent()) }
    let store = SessionStore(fileURL: temp)

    // Insert out of order.
    store.append(session("2026-08-11 08:00", km: 1, seconds: 600, steps: 900))
    store.append(session("2026-08-13 08:00", km: 1, seconds: 600, steps: 900))
    store.append(session("2026-08-12 08:00", km: 1, seconds: 600, steps: 900))

    let dates = store.sessionsNewestFirst.map(\.startedAt)
    check(dates == dates.sorted(by: >), "history must be newest-first: \(dates)")
    check(store.sessions.first?.startedAt == dates.max(), "newest session first")
    check(store.revision >= 3, "each save should bump the revision for view caching")
}

/// A walk is attributed to the program that was driving when it STARTED, not whatever happens to
/// be active as it closes.
func walkRecordsTheProgramThatStartedIt() throws {
    let recorder = SessionRecorder(idleTimeout: 30, minimumDuration: 30, minimumSteps: 20)
    let t0 = Date(timeIntervalSince1970: 8_000_000)

    recorder.programName = "Interval walk"
    _ = recorder.ingest(frame(elapsed: 0, distanceRaw: 0, steps: 0, speedRaw: 30), now: t0)
    for i in 1...5 {
        _ = recorder.ingest(
            frame(elapsed: i * 60, distanceRaw: i * 10, steps: i * 120, speedRaw: 30),
            now: t0.addingTimeInterval(Double(i * 60)))
    }
    // The program ends part-way through; the person keeps walking.
    recorder.programName = nil
    let walk = try require(recorder.finish(now: t0.addingTimeInterval(400)))
    check(walk.programName == "Interval walk",
          "expected the starting program, got \(walk.programName ?? "nil")")
}

/// If an unreadable history cannot even be moved aside, the store must go read-only rather than
/// overwrite bytes it could not parse. This is the safety-critical half of the quarantine fix.
func unmovableUnreadableHistoryGoesReadOnly() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("walkingpad-readonly-\(UInt32.random(in: 0...UInt32.max))")
    let file = dir.appendingPathComponent("sessions.json")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let garbage = "definitely not json"
    try Data(garbage.utf8).write(to: file)

    // Make the directory unwritable so the quarantine rename cannot succeed.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)

    let store = SessionStore(fileURL: file)
    check(store.isReadOnly, "the store must refuse to write when it could not preserve the file")
    check(store.lastError != nil, "the user must be told")
    check(store.sessions.isEmpty)

    // A completed walk must NOT be able to overwrite the unreadable file.
    store.append(session("2026-08-12 08:00", km: 1.0, seconds: 600, steps: 900))
    check(store.revision > 0, "a mutation must bump the revision even when the write is refused")
    let onDisk = try String(decoding: Data(contentsOf: file), as: UTF8.self)
    check(onDisk == garbage, "the original bytes must be intact, found: \(onDisk)")

    // Restore permissions and confirm the file was never rewritten behind our back.
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
    check(try String(decoding: Data(contentsOf: file), as: UTF8.self) == garbage)
}

// MARK: - Body data and calorie accuracy

/// Weight is what dominates the walking-calorie estimate, so it must actually move the number.
func weightDrivesTheCalorieEstimate() throws {
    let light = UserProfile(weightKg: 55, heightCm: 175)
    let heavy = UserProfile(weightKg: 110, heightCm: 175)
    let lightBurn = Metrics.kcalPerMinute(speedKph: 5, profile: light)
    let heavyBurn = Metrics.kcalPerMinute(speedKph: 5, profile: heavy)
    check(heavyBurn > lightBurn, "a heavier walker must burn more: \(heavyBurn) vs \(lightBurn)")
    // The formula is linear in mass, so doubling weight doubles the figure.
    check(abs(heavyBurn / lightBurn - 2.0) < 0.01,
          "expected the ratio to track the weight ratio, got \(heavyBurn / lightBurn)")
    // A plausible hour of walking should land in a sane range, not orders of magnitude out.
    let perHour = Metrics.kcalPerMinute(speedKph: 5, profile: UserProfile(weightKg: 75)) * 60
    check(perHour > 120 && perHour < 500, "an hour at 5 km/h should be plausible, got \(perHour)")
}

/// Mifflin-St Jeor, checked against its published form.
func restingMetabolismMatchesMifflinStJeor() throws {
    // Male, 80 kg, 180 cm, 30 y: 10*80 + 6.25*180 - 5*30 + 5 = 1780 kcal/day.
    let male = UserProfile(weightKg: 80, heightCm: 180, ageYears: 30, sex: .male)
    let malePerDay = Metrics.restingKcalPerMinute(profile: male) * 24 * 60
    check(abs(malePerDay - 1780) < 0.5, "expected 1780 kcal/day, got \(malePerDay)")

    // Female, same body: 1780 - 5 - 161 = 1614 kcal/day.
    let female = UserProfile(weightKg: 80, heightCm: 180, ageYears: 30, sex: .female)
    let femalePerDay = Metrics.restingKcalPerMinute(profile: female) * 24 * 60
    check(abs(femalePerDay - 1614) < 0.5, "expected 1614 kcal/day, got \(femalePerDay)")

    // Older means lower.
    let older = UserProfile(weightKg: 80, heightCm: 180, ageYears: 60, sex: .male)
    check(Metrics.restingKcalPerMinute(profile: older)
          < Metrics.restingKcalPerMinute(profile: male), "age must lower resting burn")
    // Never negative, even for nonsense input.
    let absurd = UserProfile(weightKg: 25, heightCm: 100, ageYears: 100, sex: .female)
    check(Metrics.restingKcalPerMinute(profile: absurd) >= 0, "resting burn must not go negative")
}

/// Net is gross minus what resting would have cost, and never negative.
func netCaloriesSubtractRestingMetabolism() throws {
    let profile = UserProfile(weightKg: 80, heightCm: 180, ageYears: 30, sex: .male)
    let gross = Metrics.kcalPerMinute(speedKph: 5, profile: profile)
    let net = Metrics.netKcalPerMinute(speedKph: 5, profile: profile)
    let resting = Metrics.restingKcalPerMinute(profile: profile)
    check(net < gross, "net must be below gross")
    check(abs(net - (gross - resting)) < 0.0001, "net must be exactly gross minus resting")

    // Over an hour of walking, converting a stored gross figure agrees with the per-minute maths.
    let grossHour = gross * 60
    let netHour = Metrics.netKcal(gross: grossHour, durationSeconds: 3600, profile: profile)
    check(abs(netHour - net * 60) < 0.001, "stored-gross conversion must match, got \(netHour)")

    // Standing still: resting exceeds the walking cost, and net floors at zero rather than going
    // negative and reading as "you un-burned calories".
    check(Metrics.netKcalPerMinute(speedKph: 0, profile: profile) == 0)
    check(Metrics.netKcal(gross: 0, durationSeconds: 3600, profile: profile) == 0)
}

func weightUnitConversionRoundTrips() throws {
    check(WeightUnit.kilograms.fromKilograms(80) == 80)
    let pounds = WeightUnit.pounds.fromKilograms(80)
    check(abs(pounds - 176.37) < 0.01, "80 kg is about 176.4 lb, got \(pounds)")
    check(abs(WeightUnit.pounds.toKilograms(pounds) - 80) < 0.0001, "must round trip")
    check(WeightUnit.pounds.suffix == "lb")
    for kg in [25.0, 75.0, 250.0] {
        let unit = WeightUnit.pounds
        check(abs(unit.toKilograms(unit.fromKilograms(kg)) - kg) < 0.0001, "round trip \(kg)")
    }
}

/// Correcting your weight later must be able to fix walks already recorded.
func recalculatingHistoryAppliesNewBodyData() throws {
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("walkingpad-recalc-\(UInt32.random(in: 0...UInt32.max))")
        .appendingPathComponent("sessions.json")
    defer { try? FileManager.default.removeItem(at: temp.deletingLastPathComponent()) }

    let store = SessionStore(fileURL: temp)
    // One hour, 5 km -> 5 km/h average. Calories recorded against a 60 kg profile.
    var walk = session("2026-08-12 08:00", km: 5.0, seconds: 3600, steps: 6000)
    walk.kcal = Metrics.kcalPerMinute(speedKph: 5, profile: UserProfile(weightKg: 60)) * 60
    store.append(walk)
    let before = try require(store.sessions.first).kcal

    // The user corrects their weight upward.
    let changed = store.recalculateCalories(profile: UserProfile(weightKg: 100, heightCm: 175))
    check(changed == 1, "one walk should have been updated, got \(changed)")
    let after = try require(store.sessions.first).kcal
    check(after > before, "a heavier profile must raise the figure: \(after) vs \(before)")
    let expected = Metrics.kcalPerMinute(
        speedKph: 5, profile: UserProfile(weightKg: 100, heightCm: 175)) * 60
    check(abs(after - expected) < 0.5, "expected \(expected), got \(after)")

    // Running it again with the same body data changes nothing.
    check(store.recalculateCalories(profile: UserProfile(weightKg: 100, heightCm: 175)) == 0,
          "a second pass must be a no-op")
    // And it persisted.
    check(abs(try require(SessionStore(fileURL: temp).sessions.first).kcal - expected) < 0.5,
          "the recalculated value must be saved")
}

// MARK: - Quit behaviour

/// A quit must never be delayed or questioned over a belt that is not running.
func quitIsNeverBlockedByAStillBelt() throws {
    for behavior in QuitBehavior.allCases {
        check(QuitPolicy.action(behavior: behavior, isConnected: false, beltIsMoving: false) == .quitNow,
              "\(behavior) must quit immediately when disconnected")
        check(QuitPolicy.action(behavior: behavior, isConnected: true, beltIsMoving: false) == .quitNow,
              "\(behavior) must quit immediately when the belt is still")
        // A stale "moving" flag with no connection must not hold the quit either.
        check(QuitPolicy.action(behavior: behavior, isConnected: false, beltIsMoving: true) == .quitNow,
              "\(behavior) must quit immediately when not connected")
    }
}

/// With the belt genuinely running, each setting does what it says.
func quitBehaviourAppliesToARunningBelt() throws {
    check(QuitPolicy.action(behavior: .ask, isConnected: true, beltIsMoving: true) == .askUser)
    check(QuitPolicy.action(behavior: .leaveRunning, isConnected: true, beltIsMoving: true) == .quitNow)
    check(QuitPolicy.action(behavior: .stopBelt, isConnected: true, beltIsMoving: true) == .stopThenQuit)

    // Asking is the default: quitting must not silently change what the hardware is doing.
    check(QuitBehavior.allCases.first == .ask, "ask should lead the list of options")
    check(QuitBehavior.allCases.count == 3)
    for behavior in QuitBehavior.allCases {
        check(!behavior.label.isEmpty && !behavior.detail.isEmpty,
              "\(behavior) needs a label and an explanation")
    }
}

/// The stop wait must be bounded: quitting can never hang on hardware that stopped answering.
func quitStopTimeoutIsBounded() throws {
    check(QuitPolicy.stopConfirmationTimeout > 1,
          "must allow for the command queue's 0.7s spacing plus the belt's ramp down")
    check(QuitPolicy.stopConfirmationTimeout <= 10,
          "must not leave the user staring at an app that will not quit")
}

// MARK: - Running mode and the speed ceiling

/// Running mode unlocks the belt's maximum; nothing may ever exceed it.
func runningModeUnlocksTheHardwareMaximum() throws {
    check(SpeedLimits.effectiveCeiling(walkingCeilingKph: 6, isRunningMode: false) == 6,
          "walking uses the configured ceiling")
    check(SpeedLimits.effectiveCeiling(walkingCeilingKph: 6, isRunningMode: true) == 10,
          "running unlocks the hardware maximum")
    check(SpeedLimits.effectiveCeiling(walkingCeilingKph: 3, isRunningMode: true) == 10,
          "running ignores a lower walking ceiling")
    // The hard maximum is the last word, whatever the settings claim.
    check(SpeedLimits.effectiveCeiling(walkingCeilingKph: 25, isRunningMode: false) == 10,
          "an absurd walking ceiling must still clamp to the hardware maximum")
    // Non-finite input is nonsense, and this is a safety limit: fall back to the most restrictive
    // value rather than clamping upward to the maximum.
    check(SpeedLimits.effectiveCeiling(walkingCeilingKph: .infinity, isRunningMode: false)
          == SpeedLimits.minRunningKph, "an infinite ceiling must fail safe, not fail fast")
    check(SpeedLimits.effectiveCeiling(walkingCeilingKph: .nan, isRunningMode: false)
          == SpeedLimits.minRunningKph, "a NaN ceiling must not escape into the UI")
    // Running mode is unaffected by a nonsense walking ceiling, since it uses the maximum directly.
    check(SpeedLimits.effectiveCeiling(walkingCeilingKph: .nan, isRunningMode: true) == 10)
    // Never below what the belt can actually run.
    check(SpeedLimits.effectiveCeiling(walkingCeilingKph: 0, isRunningMode: false)
          == SpeedLimits.minRunningKph)
    check(SpeedLimits.effectiveCeiling(walkingCeilingKph: -5, isRunningMode: false)
          == SpeedLimits.minRunningKph)
    check(SpeedLimits.hardMaxKph == 10.0, "the R1 Pro's maximum")
}

/// Presets must stay inside the ceiling, and offer useful values in each mode.
func presetsSuitTheCeilingInForce() throws {
    let walking = SpeedLimits.presets(forCeiling: 6)
    check(walking == [1, 2, 3, 4, 5, 6], "walking ladder: \(walking)")

    let running = SpeedLimits.presets(forCeiling: 10)
    check(running == [2, 4, 6, 7, 8, 10], "running ladder: \(running)")
    check(running.count <= 6, "too many buttons is not a choice")

    // A lowered ceiling must drop the presets above it, in either mode.
    for ceiling in [0.5, 1.0, 2.5, 3.0, 6.0, 7.5, 10.0] {
        let presets = SpeedLimits.presets(forCeiling: ceiling)
        check(presets.allSatisfy { $0 <= ceiling },
              "preset above the ceiling \(ceiling): \(presets)")
    }
    check(SpeedLimits.presets(forCeiling: 0.5).isEmpty,
          "no preset is valid below the belt's minimum")
}

/// Raising the ceiling again must restore the program's authored range, not leave it stuck where
/// it was cut. Re-clamping the already-clamped copy loses the original band permanently.
func raisingCeilingRestoresProgramRange() throws {
    let runner = ProgramRunner()
    var applied: [Double] = []
    runner.onSpeed = { applied.append($0) }
    let t0 = Date(timeIntervalSince1970: 9_000_000)

    // Authored 4.0-8.0, started while the walking ceiling is 6.0.
    var authored = SpeedProgram.standard
    authored.maxRaw = 80
    check(runner.start(authored, ceilingRaw: 60, now: t0))
    var active = try require(runner.activeProgram)
    check(active.maxRaw == 60, "should start clamped to the ceiling, got \(active.maxRaw)")

    // Switching to Run lifts the ceiling to 10.0: the authored 8.0 should come back.
    runner.applyCeiling(100)
    active = try require(runner.activeProgram)
    check(active.maxRaw == 80, "authored maximum must be restored, got \(active.maxRaw)")
    check(active.minRaw == 40, "minimum unchanged")

    // And back to Walk clamps it again, without corrupting the authored range.
    runner.applyCeiling(60)
    active = try require(runner.activeProgram)
    check(active.maxRaw == 60, "should clamp again, got \(active.maxRaw)")
    runner.applyCeiling(100)
    check(try require(runner.activeProgram).maxRaw == 80,
          "the authored range must survive repeated clamping")

    // The program must never step outside the ceiling in force.
    runner.applyCeiling(60)
    var now = t0
    for _ in 0..<40 {
        now = now.addingTimeInterval(120)
        runner.tick(beltIsMoving: true, now: now)
        check(runner.currentKph <= 6.0, "stepped above the ceiling: \(runner.currentKph)")
    }
    check(applied.allSatisfy { $0 <= 6.0 }, "commanded above the ceiling: \(applied)")
}

/// A real payload written by an earlier build, captured from a live install. The block model was a
/// substantial rewrite of `SpeedProgram`; if this stops decoding, everyone's saved programs are
/// silently replaced by defaults on upgrade.
func programsSavedByEarlierBuildsStillDecode() throws {
    let legacy = """
    {"stepRaw":1,"maxRaw":55,"minRaw":45,"kind":"upDown","name":"Meetings",\
    "id":"6F049688-41B2-4EAE-BED2-2405EF2E6FE8","intervalSeconds":90}
    """
    let program = try require(
        try? JSONDecoder().decode(SpeedProgram.self, from: Data(legacy.utf8))
    )
    check(program.name == "Meetings")
    check(program.kind == .gentleDrift, "the old \"upDown\" kind must map to the drift")
    check(program.minRaw == 45 && program.maxRaw == 55, "band must survive: \(program.minRaw)-\(program.maxRaw)")
    check(program.stepRaw == 1)
    check(program.intervalSeconds == 90)
    check(program.isValid, "a program that used to run must still be runnable")
    check(program.id == UUID(uuidString: "6F049688-41B2-4EAE-BED2-2405EF2E6FE8"),
          "identity must survive, or Save overwrites the wrong entry")

    // And it must still walk its original series: 4.5 -> 5.5 in 0.1 steps, endpoints once per lap.
    var state = SpeedSequence.start(of: program)
    var series = [state.raw]
    for _ in 0..<24 {
        state = SpeedSequence.next(state, in: program)
        series.append(state.raw)
    }
    check(Array(series.prefix(11)) == Array(45...55), "climb diverged: \(Array(series.prefix(11)))")
    check(series[11] == 54, "must turn around without repeating the top: \(series[11])")
    check(series.allSatisfy { $0 >= 45 && $0 <= 55 }, "left its band: \(series)")

    // A list of them decodes too, which is how savedPrograms is stored.
    let list = "[\(legacy)]"
    let programs = try require(
        try? JSONDecoder().decode([SpeedProgram].self, from: Data(list.utf8))
    )
    check(programs.count == 1)
}

/// `applyCeiling` must tell the caller whether a program is still driving the belt.
///
/// This is the hole the previous check left: it asserted the program stopped, but never that
/// anything then slowed the belt. Stopping a program commands no speed, so if the caller skips its
/// own enforcement (as `AppModel` used to when a program was running) the belt keeps its old pace
/// while the UI shows the new, lower ceiling — invariant 6 failing exactly when it matters.
func applyCeilingReportsWhoDrivesTheBelt() throws {
    let t0 = Date(timeIntervalSince1970: 11_000_000)

    // Case 1: no program running — the caller is always responsible.
    let idle = ProgramRunner()
    check(idle.applyCeiling(60) == false, "with no program, the caller must enforce the ceiling")

    // Case 2: the band still fits, so the program keeps driving.
    let fits = ProgramRunner()
    var applied: [Double] = []
    fits.onSpeed = { applied.append($0) }
    var program = SpeedProgram.standard          // 4.0-5.5
    program.maxRaw = 55
    check(fits.start(program, ceilingRaw: 100, now: t0))
    check(fits.applyCeiling(50) == true, "a program that fits the new ceiling still drives")
    check(try require(fits.activeProgram).maxRaw == 50, "and it adopted the ceiling")

    // Case 2b: the band already fits, so nothing changes — the early-out must still report that
    // the program is driving. An unchanged band is by definition already within the ceiling.
    let unchanged = ProgramRunner()
    check(unchanged.start(program, ceilingRaw: 55, now: t0))
    let bandBefore = try require(unchanged.activeProgram)
    check(unchanged.applyCeiling(100) == true, "an unchanged band still means the program drives")
    check(try require(unchanged.activeProgram).maxRaw == bandBefore.maxRaw,
          "a raised ceiling cannot push the band above what was authored")

    // Case 3: the ceiling leaves no room — the program stops, and it must say so, because it
    // commands nothing on the way out.
    let squeezed = ProgramRunner()
    var squeezedSpeeds: [Double] = []
    squeezed.onSpeed = { squeezedSpeeds.append($0) }
    check(squeezed.start(program, ceilingRaw: 100, now: t0))
    let commandsBefore = squeezedSpeeds.count
    check(squeezed.applyCeiling(20) == false,
          "a stopped program must report that the caller has to slow the belt")
    check(!squeezed.isRunning, "and it must actually have stopped")
    check(squeezedSpeeds.count == commandsBefore,
          "stopping commands no speed — which is exactly why the caller must be told")
}

/// The ceiling must reach the belt in every case where nothing else will — including when a faster
/// speed has been commanded but not yet confirmed by a status frame.
func ceilingCorrectionCoversTheInFlightRace() throws {
    // The original bug: a program stopped by a too-low ceiling commands nothing, so the app must.
    check(SpeedLimits.needsCorrectiveWrite(
        programStillDriving: false, isConnected: true, beltIsMovingOrAboutTo: true,
        commandedSpeedKph: 8.0, ceilingKph: 6.0), "a belt above the ceiling must be slowed")

    // The race: a 9 km/h command is in flight, the belt still reports 3, and Run mode is turned
    // off. Judging by the belt's reported speed alone would miss it and leave the belt at 9.
    check(SpeedLimits.needsCorrectiveWrite(
        programStillDriving: false, isConnected: true, beltIsMovingOrAboutTo: true,
        commandedSpeedKph: 9.0, ceilingKph: 6.0),
        "an unconfirmed faster command must still be caught")

    // A running program that adopted the new ceiling drives its own speeds; do not fight it.
    check(!SpeedLimits.needsCorrectiveWrite(
        programStillDriving: true, isConnected: true, beltIsMovingOrAboutTo: true,
        commandedSpeedKph: 8.0, ceilingKph: 6.0), "must not fight a program that is in charge")

    // Never raise a belt that is already below the ceiling — this only ever slows.
    check(!SpeedLimits.needsCorrectiveWrite(
        programStillDriving: false, isConnected: true, beltIsMovingOrAboutTo: true,
        commandedSpeedKph: 3.0, ceilingKph: 6.0), "must never speed a belt up")
    check(!SpeedLimits.needsCorrectiveWrite(
        programStillDriving: false, isConnected: true, beltIsMovingOrAboutTo: true,
        commandedSpeedKph: 6.0, ceilingKph: 6.0), "exactly at the ceiling needs no correction")

    // Nothing to correct when the belt is still, or unreachable.
    check(!SpeedLimits.needsCorrectiveWrite(
        programStillDriving: false, isConnected: true, beltIsMovingOrAboutTo: false,
        commandedSpeedKph: 8.0, ceilingKph: 6.0), "a still belt needs no correction")
    check(!SpeedLimits.needsCorrectiveWrite(
        programStillDriving: false, isConnected: false, beltIsMovingOrAboutTo: true,
        commandedSpeedKph: 8.0, ceilingKph: 6.0), "cannot command a belt we are not connected to")

    // Garbage must not trigger a write.
    check(!SpeedLimits.needsCorrectiveWrite(
        programStillDriving: false, isConnected: true, beltIsMovingOrAboutTo: true,
        commandedSpeedKph: .nan, ceilingKph: 6.0))
}

// MARK: - Belt families and the FTMS (Z1 / Z1F) protocol

/// A Z1 frame with the fields KingSmith sends: speed, total distance, elapsed time, steps.
/// 3.50 km/h, 1234 m, 554 s, 977 steps.
private let ftmsFrame: [UInt8] = FTMS.TreadmillData.encode(
    speedHundredths: 350, totalDistanceMetres: 1234, elapsedSeconds: 554, steps: 977
)

func ftmsTreadmillDataBecomesAStatus() throws {
    // Layout check against hand-assembled bytes: flags 0x2404 = distance | elapsed | KS steps.
    check(ftmsFrame == [0x04, 0x24, 0x5E, 0x01, 0xD2, 0x04, 0x00, 0x2A, 0x02, 0xD1, 0x03, 0x00],
          "encoder must match the FTMS field order")

    var assembler = FTMS.StatusAssembler()
    let status = try require(assembler.ingest(ftmsFrame))
    check(status.speedRaw == 35, "3.50 km/h is 35 tenths")
    check(status.speedKph == 3.5)
    check(status.beltState == .running)
    check(status.mode == .manual, "FTMS belts are always under manual (app) control")
    check(status.elapsed == 554)
    check(status.distanceRaw == 123, "1234 m is 123 units of 10 m")
    check(status.steps == 977)
    check(status.isMoving)
    check(status.raw == ftmsFrame, "diagnostics show the FTMS bytes as received")

    // A stopped belt reports speed 0, and counters carry over from the last frame that had them.
    let idle = try require(assembler.ingest(FTMS.TreadmillData.encode(speedHundredths: 0)))
    check(idle.beltState == .stopped)
    check(!idle.isMoving)
    check(idle.elapsed == 554 && idle.distanceRaw == 123 && idle.steps == 977,
          "omitted fields keep their last value rather than dropping to zero")
}

/// The spec allows one update to be split over several notifications: the parts flagged
/// "more data" carry no speed, and the final packet completes the update.
func ftmsMoreDataPacketsAreMergedIntoOneStatus() throws {
    var assembler = FTMS.StatusAssembler()
    let part = FTMS.TreadmillData.encode(moreData: true, totalDistanceMetres: 2500, elapsedSeconds: 1800)
    check(assembler.ingest(part) == nil, "a continuation packet must not produce a status")
    let final = FTMS.TreadmillData.encode(speedHundredths: 500, steps: 3000)
    let status = try require(assembler.ingest(final))
    check(status.speedRaw == 50)
    check(status.distanceRaw == 250)
    check(status.elapsed == 1800)
    check(status.steps == 3000)

    // Garbage in, nothing out — never a crash on a short packet.
    check(FTMS.TreadmillData(bytes: [0x04]) == nil)
    check(FTMS.TreadmillData(bytes: [0x04, 0x24, 0x5E]) == nil, "speed field cut short")
    let truncated = try require(FTMS.TreadmillData(bytes: [0x04, 0x24, 0x5E, 0x01, 0xD2]))
    check(truncated.speedHundredths == 350 && truncated.totalDistanceMetres == nil,
          "a truncated optional field is dropped, the ones before it kept")
}

/// FTMS speaks in 0.01 km/h; the app in integer tenths. Every tenth must survive the round trip
/// exactly — a program stepping by 0.1 km/h for an hour cannot be allowed to drift.
func ftmsSpeedUnitsRoundTripWithoutDrift() throws {
    for tenths in UInt8(0)...UInt8(100) {
        let bytes = FTMS.setSpeedBytes(raw: tenths)
        check(bytes.count == 3 && bytes[0] == 0x02)
        let hundredths = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
        check(hundredths == UInt16(tenths) * 10)
        check(FTMS.tenths(fromHundredths: hundredths) == tenths, "tenth \(tenths) drifted")
    }
    check(FTMS.setSpeedBytes(raw: 40) == [0x02, 0x90, 0x01], "4.0 km/h is 0x0190 little-endian")
    // Odd hundredths from the belt round half up onto the grid.
    check(FTMS.tenths(fromHundredths: 344) == 34)
    check(FTMS.tenths(fromHundredths: 345) == 35)
    check(FTMS.tenths(fromHundredths: 349) == 35)
    check(FTMS.tenths(fromHundredths: 65535) == 255, "clamped, never trapped")
    check(FTMS.thirtieths(fromHundredths: 400) == 120, "4.0 km/h is 120 thirtieths")
}

func ftmsDialectEncodesOnlyWhatTheBeltHas() throws {
    let z1 = FTMSDialect()
    let cp = FTMSDialect.controlPointUUID
    check(z1.encode(.start) == BeltWrite(characteristic: cp, bytes: [0x07]))
    check(z1.encode(.setSpeed(0)) == BeltWrite(characteristic: cp, bytes: [0x08, 0x01]),
          "speed 0 is the app's stop, and becomes the FTMS stop")
    check(z1.encode(.setSpeed(35)) == BeltWrite(characteristic: cp, bytes: [0x02, 0x5E, 0x01]))
    check(z1.encode(.setMode(.manual)) == nil, "no mode byte on FTMS")
    check(z1.encode(.askStats) == nil, "status is pushed, never polled")
    check(z1.encode(.askHistory) == nil)
    check(z1.encode(.setPreference(.maxSpeed, type: 0, value: 60)) == nil)
    check(!z1.pollsForStatus)
    check(z1.holdsSpeedUntilBeltMoves)

    // The start sequence keeps its order once the frames the belt lacks are dropped.
    let sequence = z1.supported([.setMode(.manual), .start, .setSpeed(30)])
    check(sequence == [.start, .setSpeed(30)])

    // The classic belt is untouched by all of this.
    let classic = ClassicDialect()
    for command in [PadCommand.askStats, .setSpeed(30), .setMode(.standby), .start, .askHistory,
                    .setPreference(.childLock, type: 0, value: 1)] {
        check(classic.encode(command) == BeltWrite(characteristic: ClassicDialect.writeUUID, bytes: command.bytes))
    }
    check(classic.pollsForStatus)
    check(!classic.holdsSpeedUntilBeltMoves)
    check(classic.supported([.setMode(.manual), .start, .setSpeed(30)]).count == 3)
}

func ftmsResponsesAndEventsAreUnderstood() throws {
    let z1 = FTMSDialect()
    let now = Date()

    // Control Point indication: speed accepted.
    let accepted = z1.decode(characteristic: FTMSDialect.controlPointUUID, bytes: [0x80, 0x02, 0x01], now: now)
    check(accepted.contains(.speedCommandAccepted))
    check(accepted.contains { if case .note(_, let warn) = $0 { return !warn }; return false })

    // A refused "request control" is routine and must not be shouted about.
    let refused = z1.decode(characteristic: FTMSDialect.controlPointUUID, bytes: [0x80, 0x00, 0x04], now: now)
    check(refused.contains { if case .note(_, let warn) = $0 { return !warn }; return false })
    check(!refused.contains(.speedCommandAccepted))

    // An invalid speed is a warning the user should see.
    let rejected = z1.decode(characteristic: FTMSDialect.controlPointUUID, bytes: [0x80, 0x02, 0x03], now: now)
    check(rejected.contains { if case .note(let text, let warn) = $0 { return warn && text.contains("speed range") }; return false })

    // Machine status: the very first event is the firmware replaying stale state — swallowed.
    let replay = z1.decode(characteristic: FTMSDialect.machineStatusUUID, bytes: [0x02, 0x01], now: now)
    check(replay.isEmpty, "first machine event is a replay, not news")
    let started = z1.decode(characteristic: FTMSDialect.machineStatusUUID, bytes: [0x04], now: now)
    check(started.contains { if case .note(let text, _) = $0 { return text.contains("started") }; return false })

    // Target speed changed carries the value, which confirms the in-flight speed early.
    let target = z1.decode(characteristic: FTMSDialect.machineStatusUUID, bytes: [0x05, 0x90, 0x01], now: now)
    check(target.contains(.speedAccepted(40)))

    // The safety key is always a warning.
    let safety = z1.decode(characteristic: FTMSDialect.machineStatusUUID, bytes: [0x03], now: now)
    check(safety.contains { if case .note(_, let warn) = $0 { return warn }; return false })

    // Speed range read: 0.50–6.00 km/h in 0.10 steps.
    let range = z1.decode(characteristic: FTMSDialect.speedRangeUUID, bytes: [0x32, 0x00, 0x58, 0x02, 0x0A, 0x00], now: now)
    check(range.contains { event in
        if case .speedRange(let r) = event { return r.minKph == 0.5 && r.maxKph == 6.0 && r.incrementKph == 0.1 }
        return false
    })

    // Treadmill data flows through to a status; unknown characteristics are surfaced raw.
    let status = z1.decode(characteristic: FTMSDialect.treadmillDataUUID, bytes: ftmsFrame, now: now)
    check(status.count == 1)
    if case .status(let s)? = status.first { check(s.speedRaw == 35) } else { fail("expected a status") }
    check(z1.decode(characteristic: CBUUID(string: "2A00"), bytes: [1, 2], now: now) == [.unknown([1, 2])])

    // A new connection forgets the replay flag and the counters.
    z1.resetConnectionState()
    check(z1.decode(characteristic: FTMSDialect.machineStatusUUID, bytes: [0x02, 0x01], now: now).isEmpty)
}

/// FTMS firmware crashes the link if a speed target lands while the motor is spinning up, so a
/// speed waits for the belt to report movement. Classic belts take mode → start → speed as-is.
func ftmsHoldsSpeedUntilTheBeltMoves() throws {
    check(SpeedGate.shouldHold(.setSpeed(30), beltIsMoving: false, dialectHolds: true))
    check(!SpeedGate.shouldHold(.setSpeed(30), beltIsMoving: true, dialectHolds: true))
    check(!SpeedGate.shouldHold(.setSpeed(0), beltIsMoving: false, dialectHolds: true),
          "a stop is never held back")
    check(!SpeedGate.shouldHold(.start, beltIsMoving: false, dialectHolds: true))
    check(!SpeedGate.shouldHold(.setSpeed(30), beltIsMoving: false, dialectHolds: false),
          "the classic belt never holds")
}

func ftmsSetupIsStaggeredAndEndsWithRequestControl() throws {
    let steps = FTMSDialect().setupSteps
    var subscribed: [CBUUID] = []
    var lastPause: TimeInterval = 0
    for step in steps {
        if case .subscribe(let uuid, let pause) = step {
            subscribed.append(uuid)
            check(pause >= 0.1, "every subscription is followed by a pause the firmware needs")
            check(pause >= lastPause, "pauses grow the way the vendor app staggers them")
            lastPause = pause
        }
    }
    check(subscribed == [FTMSDialect.treadmillDataUUID, FTMSDialect.machineStatusUUID, FTMSDialect.controlPointUUID])
    check(steps.contains(.read(FTMSDialect.speedRangeUUID)))
    check(steps.last == .write(BeltWrite(characteristic: FTMSDialect.controlPointUUID, bytes: [0x00])),
          "control is requested once everything is subscribed")
    check(FTMSDialect().requiredCharacteristicUUIDs.contains(FTMSDialect.controlPointUUID))

    let classic = ClassicDialect().setupSteps
    check(classic == [.subscribe(ClassicDialect.notifyUUID, pauseAfter: 0)])
    check(ClassicDialect().requiredCharacteristicUUIDs == [ClassicDialect.writeUUID])
}

func beltFamilyIsRememberedAndExplained() throws {
    check(PadFamily.default == .classic, "existing installs keep working unchanged")
    for family in PadFamily.allCases {
        check(PadFamily(rawValue: family.rawValue) == family)
        check(!family.label.isEmpty && !family.detail.isEmpty)
        check(makeDialect(for: family).family == family)
    }
    check(PadFamily(rawValue: "garbage") == nil, "a corrupted preference falls back to the default")
    check(Set(PadFamily.allCases.map(\.label)).count == PadFamily.allCases.count)

    check(PadFamily.classic.supportsModes && PadFamily.classic.supportsBeltPreferences
          && PadFamily.classic.supportsStoredSession)
    check(!PadFamily.ftms.supportsModes && !PadFamily.ftms.supportsBeltPreferences
          && !PadFamily.ftms.supportsStoredSession)

    // The scan filter and the name fallback differ per family, so the wrong choice has to be
    // explained where the user is looking.
    check(FTMSDialect().scanServiceUUIDs == [CBUUID(string: "1826")])
    check(ClassicDialect().scanServiceUUIDs == [CBUUID(string: "FE00")])
    check(FTMSDialect().looksLikeBelt(name: "KS-HD-Z1F-3A2B"))
    check(!ClassicDialect().looksLikeBelt(name: "KS-HD-Z1F-3A2B"), "a Z1 is not a classic belt")
    check(ClassicDialect().looksLikeBelt(name: "WalkingPad"))
    check(!FTMSDialect().looksLikeBelt(name: nil))

    let notFound = PadConnectionState.notFound.hint(for: .ftms) ?? ""
    check(notFound.contains(PadFamily.ftms.label) && notFound.contains("Settings"),
          "no-belt hint names the family being looked for and where to change it")
    let scanning = PadConnectionState.scanning.hint(for: .classic) ?? ""
    check(scanning.contains(PadFamily.classic.label))
    check(PadConnectionState.scanning.hint == nil, "the family-less hint is unchanged")
    check(PadConnectionState.connected("x").hint(for: .ftms) == nil)
}

/// An FTMS belt states its own range, and refuses speeds outside it. The app's ceiling stops
/// where the belt does, and a request slower than the belt can go becomes a stop — never a
/// faster speed than was asked for.
func beltReportedRangeTightensTheCeiling() throws {
    // Z1F: 1.0–6.0 km/h. Run mode would otherwise offer 10.
    check(SpeedLimits.effectiveCeiling(walkingCeilingKph: 6, isRunningMode: true, beltMaxKph: 6.0) == 6.0)
    check(SpeedLimits.effectiveCeiling(walkingCeilingKph: 4, isRunningMode: false, beltMaxKph: 6.0) == 4.0,
          "the user's lower ceiling still wins")
    check(SpeedLimits.effectiveCeiling(walkingCeilingKph: 6, isRunningMode: true, beltMaxKph: nil) == 10.0,
          "a classic belt reports no range and keeps the hardware maximum")
    check(SpeedLimits.effectiveCeiling(walkingCeilingKph: 6, isRunningMode: true, beltMaxKph: 0) == 10.0,
          "a nonsense range is ignored, not obeyed")
    check(SpeedLimits.effectiveCeiling(walkingCeilingKph: 6, isRunningMode: true, beltMaxKph: .nan) == 10.0)

    check(SpeedLimits.stopThreshold(beltMinKph: nil) == SpeedLimits.minRunningKph)
    check(SpeedLimits.stopThreshold(beltMinKph: 1.0) == 1.0, "0.6 km/h on a Z1F is a stop, not 1.0")
    check(SpeedLimits.stopThreshold(beltMinKph: 0.2) == SpeedLimits.minRunningKph,
          "a belt minimum below the app's own never lowers the threshold")
    check(SpeedLimits.stopThreshold(beltMinKph: .infinity) == SpeedLimits.minRunningKph)
}

/// The last clamp happens at the wire, so a speed that waited in the queue or for the motor
/// while the ceiling dropped underneath it still goes out under the new limit.
func wireClampAppliesEveryLimitAndOnlyLowers() throws {
    check(PadController.wireSpeed(50, ceilingRaw: 30, beltMaxKph: nil) == 30, "ceiling lowered to 3.0 while 5.0 waited")
    check(PadController.wireSpeed(25, ceilingRaw: 30, beltMaxKph: nil) == 25, "never raised")
    check(PadController.wireSpeed(80, ceilingRaw: 100, beltMaxKph: 6.0) == 60, "the belt's own maximum caps run mode")
    check(PadController.wireSpeed(80, ceilingRaw: 100, beltMaxKph: nil) == 80)
    check(PadController.wireSpeed(255, ceilingRaw: 255, beltMaxKph: nil) == 100, "the hard maximum is the last word")
    check(PadController.wireSpeed(50, ceilingRaw: 60, beltMaxKph: 0) == 50, "a nonsense belt range is ignored")
    check(PadController.wireSpeed(0, ceilingRaw: 30, beltMaxKph: 6) == 0, "stop is always allowed")
}
