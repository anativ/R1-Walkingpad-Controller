# 0004 — Two belt families behind a dialect interface, chosen by the user

Status: Accepted

## Context

The app was written against the KingSmith R1 Pro, whose protocol (a vendor service `FE00`,
`F7 … FD` frames) is shared by the A1, C1, C2, P1 and X21. The 2025 Z1 generation — the Z1 and
the Z1F (model WP400F4) — drops that service entirely and speaks the Bluetooth SIG Fitness
Machine Service (`1826`) instead, with a KingSmith step-count extension. A Z1F is invisible to
the app's scan and would never connect.

The two protocols differ in more than framing:

- FTMS pushes status unprompted (about 1 Hz idle, 10 Hz moving); the classic belt is polled.
- FTMS has no mode byte, no stored-session query and no preference channel.
- FTMS speeds are 0.01 km/h little-endian; the app's grid is integer tenths.
- The FTMS firmware has three quirks documented by mcdax/walkingpad-controller's analysis of the
  KS Fit app: it drops notification enables sent within ~30 ms of each other; it drops the BLE
  link if a speed target arrives while the motor is spinning up; and it usually refuses
  "request control" yet honours the commands that follow.

A friend's patch for the same feature arrived while this was being built. It scanned for both
services at once and picked the protocol from whatever answered, with no user-facing choice.

## Decision

1. **A `BeltDialect` protocol carries everything protocol-specific**: scan filter, GATT layout,
   the ordered bring-up sequence (with pauses), command encoding, notification decoding.
   `PadController` keeps only scanning, connecting, deadlines and the command queue. There are
   two dialects, `ClassicDialect` and `FTMSDialect`, in `Sources/WalkingPadKit/BLE/BeltDialect.swift`.
2. **The user picks the family** in Settings › General › Belt model. It is persisted, defaults to
   the classic family so existing installs change nothing, and changing it reconnects with the
   new dialect at once. The "No belt found" and "Searching" hints name the family in force.
3. **FTMS data is translated into the existing `PadStatus`** (`FTMS.StatusAssembler`), so
   metrics, programs, recording, history and every view need no second code path. Multi-packet
   "more data" updates are merged; omitted fields keep their last value.
4. **The FTMS quirks are handled in the dialect and the controller**: subscriptions are
   staggered 100 / 200 / 300 ms; a speed target is held until the belt reports movement and for
   `startSettleDelay` (2 s) after, cancelled by a stop or a newer speed, and bounded by a 15 s
   deadline; a refused request-control is logged, not treated as failure.
5. **The belt's reported speed range is a hard limit on top of the app's ceiling**, never a
   loosening of it, and it is applied once more at the wire so a speed that waited in the queue
   or for the motor goes out under the limit in force at the moment of the write. A request
   below the belt's minimum is treated as a stop — never lifted, because the app must not
   command a faster speed than was asked for.
6. **`PadCommand` stays the app-facing vocabulary.** A dialect that lacks a command returns no
   write for it, and the controller drops it before it reaches the queue, so `mode → start →
   speed` becomes `start → speed` on FTMS without touching the callers or the queue's ordering
   rules. The UI hides the mode buttons, the belt-settings tab and the stored-session card for a
   family that lacks them.

## Rationale

- **Explicit choice over auto-detection.** Scanning for both services is easy, but the failure
  mode is worse: a misdetected or unreachable belt reports "No belt found" with nothing to act
  on. A remembered choice makes the scan narrow, the hint specific, and the diagnostics honest.
  Auto-detection can be added later as a third option on top of the same dialect layer.
- **A dialect, not a branch.** The friend's patch threaded `if padProtocol == .ftms` through
  the controller and put FTMS parsing on `PadStatus`. That works for two protocols and gets
  worse with each; it also let a "more data" continuation packet decode as a speed-0 status,
  which would have flickered the belt to "stopped" mid-walk. Keeping the codec pure also keeps
  it under `padctl selftest`.
- **Integer speed conversion** (×10 / ÷10 with half-up rounding) keeps invariant 5: an hour of
  0.1 km/h program steps must land exactly on the grid.
- **The settle delay** is borrowed from the friend's patch. The reference Python controller
  waits only for movement; two more seconds costs nothing on a treadmill and widens the margin
  against the one failure that drops the link.
- **The hardware range as a limit** is also from that patch. Run mode would otherwise offer
  10 km/h on a belt that refuses anything above 6.

## Consequences

- The FTMS path was built from the specification and published reverse engineering, not from a
  Z1F in hand. `./dist/padctl --z1 watch` is the first thing to run against real hardware; the
  event log shows every frame, response and held speed. Two things to confirm there: that the
  belt sets the elapsed-time flag in Treadmill Data (the recorder and calorie estimate run on
  the belt's clock, and would sit at zero without it), and how the belt behaves on start.
- **On FTMS the belt necessarily starts before it hears the speed.** Start comes first, then the
  hold for movement, then the settle, then the target. During that window the belt runs at its
  own remembered start speed, which the app cannot see or cap. That is inherent to the protocol;
  the settle delay lengthens the window by two seconds. The app's own ceiling is enforced at the
  wire the moment the target does go out.
- A belt that pushes status is watched: ten seconds of silence on a moving belt drops the link
  and the reconnect logic takes over, so a stalled stream never shows as a running belt.
- **The Z1F refused every Control Point command on the first hardware test** (connected, live
  data, no response to start). The same failure is on record for another Z1F in the reference
  project, unresolved there. The decompiled vendor app writes a "property list" request to the
  belt's supplement service before each command, which the firmware treats as the handshake
  that unlocks control. The dialect now does the same, on setup and before every command, and
  logs the replies raw. Unverified until the belt answers; the Diagnostics "Copy" button exists
  so that answer can travel from whoever has the belt to whoever has the code.
- Existing users see one new setting, defaulted to what they had.
- Belt-side preferences, modes and the stored-session card do not exist for the Z1 family. The
  Z1's own vendor "supplement" service could carry some of them and is a candidate for later.
- A third protocol (KingSmith's MC-21 needs a vendor pre-amble before each command, for example)
  is a new dialect plus a `PadFamily` case, with no controller changes.
