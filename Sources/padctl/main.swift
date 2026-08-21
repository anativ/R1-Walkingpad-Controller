import Foundation
import WalkingPadKit

let allChecks: [(String, () throws -> Void)] = [
    ("parses captured status frame", parsesCapturedStatusFrame),
    ("rejects foreign frames", rejectsForeignFrames),
    ("classifies frames", classifiesFrames),
    ("crc matches captured frame", crcMatchesCapturedFrame),
    ("known command encodings", knownCommandEncodings),
    ("preference encodes big-endian 24-bit", preferenceEncodesBigEndian24Bit),
    ("int24 round trips", int24RoundTrips),
    ("idempotent commands share a coalesce key", idempotentCommandsShareACoalesceKey),
    ("parses record frame", parsesRecordFrame),
    ("calories track speed", caloriesTrackSpeedAndStop),
    ("pace and duration formatting", paceAndDurationFormatting),
    ("tracker accumulates, detects new session", trackerAccumulatesAndDetectsNewSession),
    ("unit conversion", unitConversion),
    ("repeated start does not grow queue", repeatedStartDoesNotGrowQueue),
    ("coalescing preserves send order", coalescingPreservesSendOrder),
    ("control frames outrank status polls", controlFramesOutrankStatusPolls),
    ("preferences coalesce independently", preferencesCoalesceIndependently),
    ("queue clears completely", queueClearsCompletely),
    ("notFound is terminal and explained", notFoundIsTerminalAndExplained),
    ("gentle drift produces the requested series", driftProducesRequestedSeries),
    ("gentle drift has no floating-point drift", driftHasNoFloatingPointDrift),
    ("gentle drift clamps uneven steps", driftClampsUnevenSteps),
    ("gentle drift never claims brisk work", driftNeverClaimsBriskWork),
    ("program validation rejects nonsense", programValidationRejectsNonsense),
    ("program respects speed ceiling", programRespectsSpeedCeiling),
    ("interval walk matches the researched protocol", intervalWalkMatchesTheResearchedProtocol),
    ("micro-surges stay inside the studied window", microSurgesKeepBurstsInsideTheStudiedWindow),
    ("long desk session banks one dose then cruises", longDeskSessionBanksOneDoseThenCruises),
    ("every block is long enough for the belt", everyBlockIsLongEnoughForTheBeltToReach),
    ("every algorithm stays inside its band", everyAlgorithmStaysInsideItsBand),
    ("pace modes shift every algorithm together", paceModesShiftEveryAlgorithmTogether),
    ("working mode stays typeable", workingModeStaysTypeable),
    ("every algorithm is distinct and described", everyAlgorithmIsDistinctAndDescribed),
    ("runner honours variable block lengths", runnerHonoursVariableBlockLengths),
    ("runner counts only brisk minutes", runnerCountsOnlyBriskMinutes),
    ("cycle progress tracks time, not blocks", cycleProgressTracksTimeNotBlocks),
    ("ceiling remap keeps a brisk block brisk", ceilingRemapKeepsABriskBlockBrisk),
    ("reband keeps the dose, refuses a shape change", rebandKeepsTheDoseAndRefusesAShapeChange),
    ("runner pauses with belt, keeps schedule", runnerPausesWithBeltAndKeepsSchedule),
    ("runner does not drift on late ticks", runnerDoesNotDriftOnLateTicks),
    ("lowering ceiling reclamps running program", loweringCeilingReclampsRunningProgram),
    ("lowering ceiling while paused commands nothing", loweringCeilingWhilePausedCommandsNothing),
    ("start sequence keeps order after partial drain", startSequenceKeepsOrderAfterPartialDrain),
    ("repeated start batches do not grow queue", repeatedStartBatchesDoNotGrowQueue),
    ("controller clamps speed at the wire", controllerClampsSpeedAtTheWire),
    ("recorder uses deltas, not cumulative counters", recorderUsesDeltasNotCumulativeCounters),
    ("recorder closes session on counter reset", recorderClosesSessionOnCounterReset),
    ("recorder discards trivial walks", recorderDiscardsTrivialWalks),
    ("stats totals and averages", statsTotalsAndAverages),
    ("stats continuous buckets include empty periods", statsContinuousBucketsIncludeEmptyPeriods),
    ("stats day streak", statsDayStreak),
    ("stats csv export", statsCsvExport),
    ("session derived figures", sessionDerivedFigures),
    ("session store round trips through disk", sessionStoreRoundTripsThroughDisk),
    ("unreadable history is preserved, not overwritten", unreadableHistoryIsPreservedNotOverwritten),
    ("history stays sorted on insert", historyStaysSortedOnInsert),
    ("walk records the program that started it", walkRecordsTheProgramThatStartedIt),
    ("unmovable unreadable history goes read-only", unmovableUnreadableHistoryGoesReadOnly),
    ("weight drives the calorie estimate", weightDrivesTheCalorieEstimate),
    ("resting metabolism matches Mifflin-St Jeor", restingMetabolismMatchesMifflinStJeor),
    ("net calories subtract resting metabolism", netCaloriesSubtractRestingMetabolism),
    ("weight unit conversion round trips", weightUnitConversionRoundTrips),
    ("recalculating history applies new body data", recalculatingHistoryAppliesNewBodyData),
    ("quit is never blocked by a still belt", quitIsNeverBlockedByAStillBelt),
    ("quit behaviour applies to a running belt", quitBehaviourAppliesToARunningBelt),
    ("quit stop timeout is bounded", quitStopTimeoutIsBounded),
    ("running mode unlocks the hardware maximum", runningModeUnlocksTheHardwareMaximum),
    ("presets suit the ceiling in force", presetsSuitTheCeilingInForce),
    ("raising ceiling restores program range", raisingCeilingRestoresProgramRange),
    ("programs saved by earlier builds still decode", programsSavedByEarlierBuildsStillDecode),
]

func usage() -> Never {
    print("""
    padctl — WalkingPad diagnostics

      padctl selftest       Verify the protocol encode/decode layer (no hardware needed)
      padctl watch          Connect to the belt and print live status frames
      padctl speed <kph>    Connect, set speed, keep printing status (Ctrl-C to stop)
      padctl stop           Connect and stop the belt

    The watch/speed/stop commands need Bluetooth permission for the terminal app.
    If they hang at "Searching", grant it in System Settings > Privacy & Security > Bluetooth.
    """)
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }

switch command {
case "selftest":
    print("padctl selftest\n")
    exit(runSelfTest(allChecks))

case "watch", "speed", "stop":
    let controller = PadController()
    var targetSpeed: Double?
    if command == "speed" {
        guard arguments.count > 1, let kph = Double(arguments[1]), kph.isFinite else {
            print("speed needs a km/h value, e.g. padctl speed 3.5"); exit(2)
        }
        let safe = min(max(0, kph), PadController.maxSafeSpeedKph)
        if safe != kph {
            print("note: \(kph) km/h is outside the belt's range — using \(safe) km/h")
        }
        targetSpeed = safe
    }

    var didAct = false
    var lastLine = ""
    controller.onStatus = { status in
        let line = String(
            format: "%@  %.1f km/h  %.2f km  %5d steps  %@  mode=%@ app=%.1f btn=%d",
            Metrics.formatDuration(status.elapsed),
            status.speedKph, status.distanceKm, status.steps,
            status.beltState.label,
            status.mode?.label ?? "raw \(status.modeRaw)",
            status.appSpeedKph, Int(status.controllerButton)
        )
        if line != lastLine { print(line); lastLine = line }

        guard !didAct else { return }
        didAct = true
        if let targetSpeed {
            print("→ starting belt at \(targetSpeed) km/h")
            controller.startWalking(at: targetSpeed)
        } else if command == "stop" {
            print("→ stopping belt")
            controller.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
        }
    }

    print("Connecting…  (Ctrl-C to quit)")
    controller.connect()

    // Surface connection progress from the controller's log.
    var reported = 0
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        while reported < controller.log.count {
            print("[ble] \(controller.log[reported].text)")
            reported += 1
        }
    }
    RunLoop.main.run()

default:
    usage()
}
