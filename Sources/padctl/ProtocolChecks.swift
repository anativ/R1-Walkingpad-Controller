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

    recorder.programName = "Up / down"
    _ = recorder.ingest(frame(elapsed: 0, distanceRaw: 0, steps: 0, speedRaw: 30), now: t0)
    for i in 1...5 {
        _ = recorder.ingest(
            frame(elapsed: i * 60, distanceRaw: i * 10, steps: i * 120, speedRaw: 30),
            now: t0.addingTimeInterval(Double(i * 60)))
    }
    // The program ends part-way through; the person keeps walking.
    recorder.programName = nil
    let walk = try require(recorder.finish(now: t0.addingTimeInterval(400)))
    check(walk.programName == "Up / down",
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
