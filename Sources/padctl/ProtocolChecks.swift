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

/// The exact series requested: 4.0, 4.1, 4.2 … 5.5, 5.4, 5.3 … 4.0, 4.1 …
/// with the endpoints visited once per lap, not twice.
func upDownProducesRequestedSeries() throws {
    let program = SpeedProgram.standard   // 4.0–5.5, 0.1 step, 2 min
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

    // One full lap is 30 steps for this configuration (15 up + 15 down).
    check(program.stepsPerLap == 30, "stepsPerLap was \(program.stepsPerLap)")
}

/// Integer units mean no floating-point drift: every value is an exact multiple of 0.1.
func upDownHasNoFloatingPointDrift() throws {
    let program = SpeedProgram.standard
    var state = SpeedSequence.start(of: program)
    for _ in 0..<500 {
        state = SpeedSequence.next(state, in: program)
        let kph = Double(state.raw) / 10
        check((kph * 10).rounded() == kph * 10, "non-exact speed \(kph)")
    }
}

/// A step that does not divide the band evenly must land exactly on the endpoints, not overshoot.
func upDownClampsUnevenSteps() throws {
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
    // An invalid program must not move.
    let stuck = SpeedSequence.next(SpeedSequence.State(raw: 40), in: p)
    check(stuck.raw == 40, "invalid program must not advance")
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
