# Onboarding — WalkingPad R1 Pro Controller

Deep orientation for someone (or some Claude Code session) starting cold on this repository. Read
this once and you should be able to make a correct, idiomatic change anywhere in the project without
re-deriving the architecture or rediscovering the traps.

## The four documents, and what each is for

| Document | Role |
| --- | --- |
| [`CLAUDE.md`](../CLAUDE.md) | Terse always-loaded working notes: git workflow, build commands, the six invariants, environment constraints. The thing you must not contradict. |
| [`README.md`](../README.md) | User-facing. What the app shows and controls, the algorithms and their evidence, troubleshooting, safety. Read it when you need to know what a feature is *for*. |
| [`docs/adr/`](adr/) | Decision records. [0001](adr/0001-macos-app-architecture.md) is why there is no Xcode project and no test target; [0002](adr/0002-research-backed-pace-algorithms.md) is why a program is a cycle of timed blocks. They explain *why*, once, at the time. |
| **This document** | The deep orientation behind all three: the file map, the two end-to-end data flows, the pace model, the scar tissue behind each invariant, and recipes for common changes. |

Cross-link rather than duplicate. If you find yourself restating an ADR here, link it instead.

---

## 1. Orientation

### What it is

A native macOS app that monitors and controls a KingSmith WalkingPad R1 Pro treadmill over
Bluetooth Low Energy. SwiftUI + CoreBluetooth, zero third-party dependencies, no vendor account, no
Xcode project. The BLE protocol was reverse engineered by
[ph4r05/ph4-walkingpad](https://github.com/ph4r05/ph4-walkingpad); this is an independent native
Swift implementation of it, not affiliated with KingSmith.

### What it does

- Live metrics from the belt: state, speed, mode, elapsed time, distance, steps, remote-button byte.
- Derived metrics the belt does not report: calories (ACSM walking equation, optionally net of a
  Mifflin-St Jeor resting baseline), cadence, average and peak speed, a speed chart.
- Speed control: slider, presets, Start/Stop, belt operating mode, Walk/Run ceiling switch.
- Five research-backed pace algorithms plus a freehand program editor, both driving one runner.
- Automatic walk recording and a History window with charts, averages, streaks and CSV export.
- A live menu-bar readout, and a menu-bar-only mode with no Dock icon.
- Write-only access to the belt's own stored preferences (max speed, start speed, sensitivity,
  child lock, units, intelligent start, session target).

### What it does not do

- No heart rate, no HealthKit, no cloud, no vendor account, no iOS app.
- No reading of belt-side preferences: the belt never reports them back, so the Belt settings tab
  shows what this app last *sent*, not what the belt holds.
- No control of the belt's beep. It is firmware acknowledgement of an accepted command and no
  reverse-engineered protocol exposes a mute. See the README's "The beep".
- No `swift test`. There is no test target at all — see §3.

### The three targets, and why the split exists

`Package.swift` declares three targets and nothing else.

| Target | Path | Why it is separate |
| --- | --- | --- |
| `WalkingPadKit` | `Sources/WalkingPadKit/` | Protocol, BLE, metrics, programs, history. **No UI.** This is what makes the check suite possible: anything pure lives here so `padctl selftest` can reach it headlessly. |
| `WalkingPad` | `Sources/WalkingPad/` | The SwiftUI app. Assembled into `dist/WalkingPad.app` by hand by `build.sh`. |
| `padctl` | `Sources/padctl/` | CLI diagnostics **and the check suite**. Ships as its own `dist/padctl.app` because macOS grants Bluetooth to no bare executable. |

The rule that follows from this split: **if a behaviour can only be exercised through the UI, it is
effectively untested.** Push logic down into `WalkingPadKit` as a pure function or value type and
add a check for it. `QuitPolicy` and `SpeedLimits` exist purely because of this rule — both are
decisions that would otherwise have been buried in an app delegate or a settings setter.

### File map

#### `Sources/WalkingPadKit/` — no UI, headlessly testable

| File | What lives there |
| --- | --- |
| `Protocol/PadPacket.swift` | Wire format: `PadPacket` (header/footer, `sealed`, `int24`, `bytes24`), the enums `PadMode`, `PadBeltState`, `PadTarget`, `PadPreference`, `PadSensitivity`, and `PadCommand` (every frame this app sends, plus its coalesce key). |
| `Protocol/PadStatus.swift` | Everything the belt sends: `PadStatus` (the 20-byte `F8 A2` live frame), `PadRecord` (the `F8 A7` stored session), and `PadFrame`, the enum that classifies an inbound buffer as one, the other, or unknown. |
| `BLE/PadController.swift` | `PadConnectionState`, `PadController` (the whole CoreBluetooth session: scan, connect, GATT discovery, notify handling, write pacing, deadlines, event log), `PadLogEntry`. |
| `BLE/CommandQueue.swift` | `CommandQueue` — the write queue as a pure value type, so its two ordering rules can be checked without CoreBluetooth. |
| `Model/SpeedProgram.swift` | `PaceTier`, `PaceBlock`, `SpeedProgram` (+ nested `Kind` with the block blueprints), `SpeedSequence` (the pure "where do I go next"). |
| `Model/PaceAlgorithm.swift` | `PaceMode` (Working/Meeting anchors and their ranges) and `PaceAlgorithm` (the static catalogue: evidence, dose, band offsets). |
| `Model/ProgramRunner.swift` | `ProgramRunner` — drives a `SpeedProgram` against the belt. Tick-driven, no timer of its own. |
| `Model/SpeedLimits.swift` | The ceiling resolution (`effectiveCeiling`, `presets`) and the hard maximum. Pure, therefore checked. |
| `Model/Metrics.swift` | `BiologicalSex`, `UserProfile`, `WeightUnit`, `DistanceUnit`, and `Metrics` (ACSM walking cost, Mifflin-St Jeor resting cost, net calories, pace, duration/pace formatting). |
| `Model/SessionTracker.swift` | `SpeedSample` and `SessionTracker` — live derived metrics for the *current* belt session: integrated calories, cadence window, peak, chart samples, and detection of the belt zeroing its counters. |
| `Model/SessionRecorder.swift` | `SessionRecorder` — turns the status stream into completed `WalkSession`s, recording **deltas against a baseline** because the belt's counters are cumulative. |
| `Model/WalkSession.swift` | `WalkSession`, `WalkTotals`, `WalkBucket`, `WalkPeriod`, and `WalkStats` (pure aggregation: totals, buckets, continuous buckets, averages per active period, day streak, bests, CSV). |
| `Model/SessionStore.swift` | `SessionStore` — the JSON history file in Application Support, atomic writes, and the quarantine path for an unreadable file. |
| `Model/QuitPolicy.swift` | `QuitBehavior`, `QuitAction`, `QuitPolicy` — what to do about a moving belt when the app quits, as a pure function plus one timeout constant. |

#### `Sources/WalkingPad/` — the SwiftUI app

| File | What lives there |
| --- | --- |
| `WalkingPadApp.swift` | `@main`, the scenes (main `Window`, History `Window`, `Settings`, `MenuBarExtra`), the `Belt` command menu with its shortcuts, `AppDelegate` (quit interception), `MenuBarLabel`/`MenuBarContent`, `MainWindowButton`, `HistoryWindowButton`. |
| `AppModel.swift` | ~1000 lines and the heart of the app: `MenuBarReadout`, `AppSettings`, and `AppModel` — owns `PadController`, `SessionTracker`, `ProgramRunner`, `SessionRecorder`, `SessionStore`; wires the status callback; holds every user intent; does all `UserDefaults` persistence (`Keys`, `load`, `persist`); implements the quit dance. |
| `UI/DashboardView.swift` | `DashboardView` (the scroll of cards) plus `ConnectionBar`, `HeroSpeedView`, `MetricsGrid`, `AllTimeSummaryView`, `StoredSessionView`. |
| `UI/SpeedControlView.swift` | `SpeedControlView` (Walk/Run switch, target readout, slider, presets, Start/Stop) and `ModePickerView`. |
| `UI/PaceAlgorithmsView.swift` | `PaceAlgorithmsView` (mode row, anchor slider, one box per algorithm), `AlgorithmBox`, `CycleStrip` (the to-scale cycle picture), and `PaceTier.tint` — tier colours live here, not in the kit. |
| `UI/ProgramView.swift` | `ProgramView` — the freehand editor, saved-program menu, and its own transport. |
| `UI/MetricTile.swift` | `MetricTile`, `StatusChip`, `CardSection`. The three reusable pieces every card is built from. |
| `UI/SpeedChartView.swift` | `SpeedChartView` — Swift Charts area+line of the current session. |
| `UI/HistoryView.swift` | `HistoryMetric`, `HistorySnapshot`, `SnapshotKey`, `HistoryView`, `CSVDocument`. The snapshot machinery exists because `AppModel` republishes ~1 Hz. |
| `UI/SettingsView.swift` | `SettingsView` and its three tabs: `AppPreferencesTab`, `CaloriesTab`, `BeltPreferencesTab`. |
| `UI/DiagnosticsView.swift` | Raw frame dump and the in-app event log. |

#### `Sources/padctl/` — CLI and the check suite

| File | What lives there |
| --- | --- |
| `main.swift` | `allChecks` — the ordered list of (name, function) pairs — and the `selftest` / `watch` / `speed` / `stop` subcommands. |
| `ProtocolChecks.swift` | Every check function (currently 69), the captured status frame they are verified against, and the small `frame(...)`/`session(...)` builders. |
| `Harness.swift` | `Check`, `check(...)`, `fail(...)`, `require(...)`, `runSelfTest(...)`. Thirty lines standing in for XCTest. |

#### Everything else

| Path | What it is |
| --- | --- |
| `build.sh` | Verify, build, generate the icon, assemble and ad-hoc sign both bundles, optionally install/launch. |
| `Support/Info.plist` | The app's plist. Carries `NSBluetoothAlwaysUsageDescription` — mandatory. |
| `Support/padctl-Info.plist` | `padctl`'s plist. Linked into `__TEXT,__info_plist` *and* copied into `padctl.app`. |
| `tools/MakeIcon.swift` | A `swift`-script that draws the icon with CoreGraphics paths and writes an `.iconset`; `build.sh` runs `iconutil` over it. |
| `docs/adr/` | ADRs plus their index. Add one for consequential decisions. |

---

## 2. Build, run, verify

```bash
./build.sh                  # verify + build + assemble dist/WalkingPad.app and dist/padctl.app
./build.sh --run            # ...then launch it
./build.sh --install        # ...then copy to /Applications  (refuses if the app is running)
UNIVERSAL=1 ./build.sh      # arm64 + x86_64
FORCE_INSTALL=1 ./build.sh --install   # override the running-app guard (kills a live walk)
./dist/padctl selftest      # the check suite, no hardware needed
```

What `build.sh` actually does, in order:

1. `swift run -c release padctl selftest` — **the build stops here if any check fails.**
2. `swift build -c release`, then `--show-bin-path` to find the products.
3. `swift tools/MakeIcon.swift build/icon` + `iconutil` → `AppIcon.icns`.
4. Assemble `dist/WalkingPad.app` by hand: binary, `Info.plist`, `.icns`, `PkgInfo`.
5. Ad-hoc `codesign` with identifier `io.nativ.walkingpad`, then `codesign --verify`.
6. Assemble `dist/padctl.app` (plist patched by `PlistBuddy` to add `CFBundleExecutable`,
   `CFBundlePackageType`, `LSUIElement`), sign it, and write the `dist/padctl` wrapper script.

Two small gotchas: only `$1` is inspected, so `./build.sh --install --run` installs but does not
launch; and the icon step needs AppKit in script mode, so it will not work on a machine without the
CLT.

### Why `padctl selftest` and not XCTest

This machine has the Xcode **Command Line Tools only**. The CLT SDK ships AppKit, SwiftUI, Charts
and CoreBluetooth but **neither XCTest nor swift-testing**, so `swift test` cannot run at all. The
assertions are therefore compiled into a normal executable that exits non-zero on failure, and
`build.sh` runs it before every build. See [ADR 0001](adr/0001-macos-app-architecture.md) §4.

Consequences to accept rather than fix: no coverage tooling, no fixtures, no mocking library.
Assertions stay plain and explicit, and each check prints `✓`/`✗` with a name.

### Adding a check — exactly two places

1. **A function in `Sources/padctl/ProtocolChecks.swift`.** Signature `func name() throws {}`. Use
   `check(condition, "message")` for assertions and `try require(optional)` where a nil should abort
   that one check. Put it under the right `// MARK:` section and give it a doc comment that says
   *what failure it prevents*, not what it calls — that is the house style, and it is what makes the
   suite readable as a list of scars.
2. **An entry in `allChecks` in `Sources/padctl/main.swift`.** A `(name, function)` tuple. Forgetting
   this compiles fine and silently never runs your check.

Then run `./dist/padctl selftest` (or `swift run -c release padctl selftest`).

House rules for checks:

- Inject time. Every date-taking API in the kit has a `now:` parameter for exactly this reason
  (`ProgramRunner.tick(beltIsMoving:now:)`, `SessionRecorder.ingest(_:now:)`,
  `WalkStats.currentDayStreak(_:now:)`). Never call `Date()` inside a check's subject.
- Prefer a real round trip to a mock. `sessionStoreRoundTripsThroughDisk` writes an actual file in
  `temporaryDirectory` and reopens it; `unmovableUnreadableHistoryGoesReadOnly` chmods a directory
  to 0500. Clean up with `defer`.
- **CLAUDE.md's standing rule: add a check for every behaviour you fix.** Most of the suite is
  regression tests named after the bug they prevent.

### Verifying GUI behaviour

Screen Recording and Accessibility are not granted, so `screencapture` and System Events cannot see
the app. Verify through unified logging:

```bash
/usr/bin/log show --predicate 'subsystem == "io.nativ.walkingpad"' --last 5m --info --debug
```

Two categories exist: `ble` (from `PadController`, which mirrors every event-log entry — state
transitions at `notice`, warnings at `warning`, TX/RX hex at `debug`) and `menubar` (one `notice`
when the status item renders, which is the only way to confirm it was created at all).

Also: `ps -o %cpu` catches render loops, `sample <pid>` finds the hot stack, and crash causes are in
`~/Library/Logs/DiagnosticReports/*.ips` (JSON after the first line).

---

## 3. Verifying when there is no Swift toolchain

### Where the session actually runs

**A Claude Code web/app session does not run on the user's Mac.** It runs in an ephemeral Linux
container in the cloud, and the repository was cloned into it fresh. This catches people out,
because the user *is* sitting at a Mac — but the agent is not on it, and cannot reach it. One
command settles it:

```bash
uname -s -m        # Linux x86_64   — not Darwin arm64
sw_vers            # command not found
ls /System/Library/Frameworks   # No such file or directory
```

What follows from that, and none of it is fixable from inside the container:

| Missing | Consequence |
| --- | --- |
| `swift`, `swiftc`, `xcrun` (not preinstalled) | `swift build` and `./build.sh` cannot run |
| The macOS SDK — AppKit, SwiftUI, CoreBluetooth, `os` | The app target cannot compile *at all*, on any toolchain |
| A Mac, and a physical belt | No hardware path can be exercised, ever |

So in a remote session the Mac is the only real gate, and `./build.sh --run` there is the only thing
that proves the tree compiles. Do not spend turns discovering this, and do not tell the user "it
builds".

### A real Swift type-checker *is* obtainable, for part of the code

`swift` is not preinstalled, but a Linux toolchain downloads and unpacks in about two minutes:

```bash
curl -sSL -o swift.tar.gz \
  https://download.swift.org/swift-6.1.2-release/ubuntu2404/swift-6.1.2-RELEASE/swift-6.1.2-RELEASE-ubuntu24.04.tar.gz
mkdir -p swift && tar xzf swift.tar.gz -C swift --strip-components=1
./swift/usr/bin/swift --version    # Swift version 6.1.2, x86_64-unknown-linux-gnu
```

That costs ~880 MB down and ~2.8 GB unpacked — fine against the container's allowance, but put it in
the scratchpad, never in the repo. It cannot build the project (`Package.swift` declares
`platforms: [.macOS(.v14)]`, and the app needs Apple frameworks). What it *can* do is type-check the
Foundation-only part of `WalkingPadKit`, which is where most of the logic lives:

| Reach | Files | Route |
| --- | --- | --- |
| Type-checks as-is | 11 of 14 kit files — `SpeedProgram`, `PaceAlgorithm`, `SpeedLimits`, `Metrics`, `CommandQueue`, `SessionTracker`, `SessionRecorder`, `WalkSession`, `QuitPolicy`, `PadPacket`, `PadStatus` | Copy into a throwaway SPM package in the scratchpad |
| Needs a small shim | `ProgramRunner`, `SessionStore` — `import Combine` only | ~30 lines: an `ObservableObject` protocol and a `@Published` property wrapper |
| Out of reach | `PadController` (CoreBluetooth + `os`), all 11 `Sources/WalkingPad` files (SwiftUI/AppKit) | Mac only |

`Harness.swift` and `ProtocolChecks.swift` import only Foundation and `WalkingPadKit`, so with the
Combine shim a large slice of the real check suite could be compiled and *run* on Linux — everything
except the checks that touch `PadController`. That would close exactly the gap the Python port below
leaves open: real syntax, real types, real exhaustiveness.

**This route was identified but not carried through** — the toolchain was downloaded and verified to
run, and the per-file breakdown above is measured, but no package was assembled and no Swift was
compiled. Treat it as a promising lead, not a proven workflow. If you take it, the payoff is that
"the logic is right but it may not compile" stops being a caveat you have to ship.

Until then, the technique below is what has actually been used.

### The technique that worked

The pace-algorithm work (commit `b7757a9`) was written and validated in a remote session like this:

1. **Port the pure logic to a throwaway Python reference implementation** in the scratchpad — not
   the whole kit, only what the change touches. For that work it was `SpeedProgram` (`Kind.blueprint`,
   `cycle`, `driftCycle`, `raw(for:)`, `clamped(toCeilingRaw:)`, the validity rules), `SpeedSequence`
   (`start`, `next`, `state(at:)`) and `ProgramRunner` (`start`, `tick`, `creditWork`, `applyCeiling`,
   `reband`, `adopt`, `remapped`, `cycleProgress`).
2. **Translate the assertions, both directions.** Port the *pre-existing* checks from
   `ProtocolChecks.swift` first: if the port cannot reproduce the behaviour the suite already pins
   down, the port is wrong and nothing it says about your new code is worth anything. Then write the
   new assertions against it.
3. Iterate in Python until every assertion passes, then transcribe the logic back to Swift and write
   the real checks in `ProtocolChecks.swift` + `allChecks`.

This is genuinely effective for this codebase because the pace model is pure integer arithmetic over
small data structures — exactly the kind of thing a Python port reproduces faithfully.

### What it does and does not prove

It validates **arithmetic and logic**: block timings, band offsets, cycle wrap-around, dose
accounting, clamping, remap-by-block, schedule anchoring.

It validates **nothing about Swift**: not syntax, not types, not overload resolution, not exhaustive
switches, not SwiftUI view builders, not `Codable` synthesis, not actor isolation.

So a remote session must say so plainly in its report. Something like:

> The checks were not run — there is no Swift toolchain in this container. The logic was validated
> against a Python port of `SpeedProgram`/`SpeedSequence`/`ProgramRunner` (both the pre-existing and
> the new assertions pass there). `./build.sh --run` on the Mac is the real gate.

Never imply the suite passed. `build.sh` runs the suite before every build, so the user will find
out within one command either way — but a confident "checks pass" in a report is a lie.

### Swift constructs to be extra careful with when you cannot compile

These three actually bit during the pace-algorithm work:

1. **Comparing a double optional.** `PaceAlgorithm.named(.gentleDrift)?.sessionWorkSeconds == nil`
   looks like it tests the dose. It does not: `sessionWorkSeconds` is itself `Int?`, so optional
   chaining produces `Int??` and `== nil` tests the *outer* optional — true only when `named(...)`
   returned nil. It compiles, and it passes for the wrong reason. The fix is to unwrap first:
   `let drift = try require(PaceAlgorithm.named(.gentleDrift)); check(drift.sessionWorkSeconds == nil)`.
   There is a comment on `driftNeverClaimsBriskWork` in `ProtocolChecks.swift` saying exactly this.
2. **Mixing `CGFloat` and `Double` inline in SwiftUI geometry.** `frame(width:)` and `offset(x:)`
   take `CGFloat`; `PaceBlock.seconds` is `Int` and durations are `Double`. Compute the whole
   expression in `Double` and convert once at the boundary. `CycleStrip` does this deliberately and
   says so in a comment.
3. **A multi-parameter closure where the parameter is one tuple.**
   `ForEach(Array(blocks.enumerated()), id: \.offset) { i, e in … }` does not compile: the element is
   a single `(offset:element:)` tuple, not two arguments. `CycleStrip` binds `item` and uses
   `item.offset` / `item.element`.

Also worth care, by inspection of this codebase:

4. **Adding an enum case breaks every exhaustive switch over it.** `SpeedProgram.Kind` is switched
   on three times in `SpeedProgram.swift` alone (`label`, `detail`, `blueprint`) and none has a
   `default`. Adding a case is a compile error in each — grep for every switch over the type before
   you claim the change is complete.
5. **`String(format:)` is not type-checked.** `%@` with a Swift `String` is fine; `%.1f` with an
   `Int`, or `%d` with a `Double`, compiles and prints garbage. This file is full of `String(format:)`
   — check each conversion by eye.
6. **Integer division.** `minRaw + (maxRaw - minRaw) / 2` is deliberate (raw units are integers by
   invariant 5), but the same shape elsewhere silently truncates.
7. **`@ViewBuilder` bodies are not statement lists.** `let` bindings are allowed; assignments, loops
   and early `return`s are not. Several views here compute values above an explicit `return` for this
   reason (`AllTimeSummaryView.body`, `PaceAlgorithmsView.anchorRow`).
8. **`@MainActor` isolation.** `AppModel` is `@MainActor`; the quit timer and backstop closures reach
   it via `MainActor.assumeIsolated { … }`. A new escaping closure that touches `AppModel` needs the
   same treatment or it will not compile.
9. **`Codable` synthesis.** Adding a non-optional stored property to `SpeedProgram` or `WalkSession`
   changes the synthesized `init(from:)` and makes every previously saved copy fail to decode. See
   §10.

---

## 4. Environment constraints, and why they shape the design

Do not "fix" these. Each one is load-bearing.

| Constraint | Consequence in the code |
| --- | --- |
| **Command Line Tools only, no full Xcode.** | No `.xcodeproj` (`build.sh` assembles the bundle by hand). The package still opens in Xcode as a package if one is installed later. |
| **The CLT SDK ships no XCTest and no swift-testing.** | No test target. `padctl selftest` is the suite; `Harness.swift` is the framework. Anything worth checking has to be reachable without UI, which is why `WalkingPadKit` exists. |
| **CoreBluetooth requires a signed bundle whose `Info.plist` carries `NSBluetoothAlwaysUsageDescription`.** | The app is signed and carries the string. `padctl` ships as its own `dist/padctl.app` with a wrapper script, because macOS grants Bluetooth to **no** bare executable — measured, not assumed: a plain binary aborts under TCC, and still aborts with the usage string linked into `__TEXT,__info_plist`, ad-hoc signed, and even placed inside the app's `Contents/MacOS`. Only being a bundle's `CFBundleExecutable` satisfies TCC. |
| **TCC attributes Bluetooth permission to the app you run a tool *from*.** | `padctl watch/speed/stop` work only from an interactive terminal that holds the permission. From a script, a CI job or an agent shell there is no responsible app, and the process is killed rather than prompted. `padctl selftest` is unaffected and is the only subcommand an agent can use. |
| **Ad-hoc signing.** | The signature changes on every rebuild, so macOS may re-ask for Bluetooth permission after a rebuild. A real signing identity would fix it. |
| **Replacing a running ad-hoc-signed bundle terminates it.** | `build.sh --install` refuses while the app is running unless `FORCE_INSTALL=1`. This actually killed a live session during development. To hand over a new build without disturbing a running walk: build only, and let the user quit and relaunch. |
| **No Screen Recording / Accessibility.** | GUI verification goes through unified logging (§2), not screenshots. `MenuBarLabel` logs on appear purely so its existence can be confirmed. |
| **No Swift toolchain in remote containers.** | §3. |

---

## 5. The BLE protocol

Service `FE00`, notify `FE01`, write `FE02` — full 128-bit forms are in `PadController.serviceUUID`
/ `notifyUUID` / `writeUUID`.

### Frame layout and sealing

Every outbound frame is `F7 <cmd> <payload…> <crc> FD`. The CRC is the low byte of the sum of
everything after the header up to (not including) the CRC byte itself:

```swift
PadPacket.sealed(_ bytes: [UInt8]) -> [UInt8]   // fills in bytes[count-2] in place
```

`sealed` is total: it returns the input unchanged for anything shorter than 4 bytes. Multi-byte
integers are big-endian 24-bit, via `PadPacket.int24(_:)` and `PadPacket.bytes24(_:)`.

`crcMatchesCapturedFrame` proves the checksum covers the range we think it does, by re-sealing a
real captured frame and comparing against its own CRC byte.

### The command set — `PadCommand`

| Case | Frame | Notes |
| --- | --- | --- |
| `.askStats` | `F7 A2 00 00 A2 FD` | The status poll. Belt replies `F8 A2 …`. Silent (no beep). |
| `.setSpeed(UInt8)` | `F7 A2 01 <raw> <crc> FD` | Raw is **0.1 km/h units**. `0` is the stop command. |
| `.setMode(PadMode)` | `F7 A2 02 <mode> <crc> FD` | `0` auto, `1` manual, `2` standby. |
| `.start` | `F7 A2 04 01 A7 FD` | Wakes the belt. |
| `.askHistory` | `F7 A7 AA FF 50 FD` | Belt replies `F8 A7 …`. |
| `.setPreference(PadPreference, type:value:)` | `F7 A6 <key> <type> <b2 b1 b0> <crc> FD` | Value as big-endian 24-bit. `PadPreference` keys: target 1, maxSpeed 3, startSpeed 4, intelligentStart 5, sensitivity 6, display 7, units 8, childLock 9. |

Two derived properties matter to the queue, not to the wire:

- `coalesceKey` — `"speed"`, `"stats"`, `"history"`, `"mode"`, `"start"`, `"pref-<key>"`. Repeats of
  the same kind collapse; distinct preferences keep distinct keys so they never collapse into each
  other (`preferencesCoalesceIndependently`).
- `isStatusPoll` — true only for `.askStats`. This is what lets control frames outrank polls.

### Inbound frames

`PadFrame(data:)` classifies a buffer as `.status`, `.record` or `.unknown`, in that order.

**`PadStatus`** — the `F8 A2` live frame, 20 bytes, parsed by byte index (accepts ≥18):

| Byte | Field |
| --- | --- |
| 0–1 | `F8 A2` signature |
| 2 | belt state → `PadBeltState` (0 stopped, 1 running, 5 standby, 9 starting, else `.other(raw)`) |
| 3 | speed, 0.1 km/h units → `speedRaw` / `speedKph` |
| 4 | mode byte → `modeRaw` / `mode: PadMode?` |
| 5–7 | elapsed seconds, big-endian 24-bit |
| 8–10 | distance in **10 m units** (100 == 1 km) |
| 11–13 | steps |
| 14 | last app-requested speed, in **1/30 km/h units** → `appSpeedKph = raw / 30` |
| 16 | remote/controller button byte |

The reference frame the parser is verified against, in `ProtocolChecks.swift`:

```
f8 a2 01 3c 01 00 02 2a 00 00 4f 00 03 d1 b4 00 00 00 e3 fd
→ running, 6.0 km/h, manual, 554 s, 0.79 km, 977 steps, app speed 6.0
```

Note byte 14 = `0xb4` = 180 = 6.0 × 30. The `/30` scaling for byte 14 is odd next to the `/10` of
byte 3, but it is what the captured frame says and what upstream documents; it is only shown in
Diagnostics and `padctl watch`.

**`PadRecord`** — the `F8 A7` stored-session summary (accepts ≥17): elapsed at 8–10, distance at
11–13, steps at 14–16. Only surfaced in the "Belt's stored session" card.

**`.unknown`** — logged as hex to the event log and dropped. There is no framing/reassembly layer:
each notification is assumed to be one complete frame, which has held in practice.

### Relationships, in one line each

- `PadPacket` — stateless codec helpers (seal, int24).
- `PadCommand` — what we send. Owns its own bytes and its own queueing policy.
- `PadStatus` / `PadRecord` — what we receive, as value types with derived unit conversions.
- `PadFrame` — the discriminator between them.

---

## 6. Data flow, end to end

These two traces are the most useful thing in this document. Follow them once with the files open.

### Inbound: one status frame

```
belt → notify FE01
  PadController.peripheral(_:didUpdateValueFor:error:)
    PadFrame(data: [UInt8](characteristic.value))            → .status(s)
    self.status = s                                          (@Published)
    if inFlightSpeedRaw == s.speedRaw { clear it, invalidate speedConfirmTimer }
    onStatus?(s)
      ↓  (the closure installed in AppModel.init)
    AppModel:
      tracker.ingest(s)          SessionTracker: new-session detection, integrate calories over the
                                 BELT's clock (skip gaps > 120 s), peak, chart sample, cadence window
      runner.tick(beltIsMoving: s.isMoving)
                                 ProgramRunner: pause/resume, credit brisk seconds, advance the
                                 block if due → may call onSpeed (see the outbound trace)
      recorder.programName = runner.activeProgram?.name
      recorder.ingest(s)         SessionRecorder: open a baseline on first movement, accumulate
                                 calories, close the walk on a counter reset or idle timeout
        → if a WalkSession came back:  store.append(finished)  +  controller.appendLog("Saved walk…")
      if !hasAlignedTargetWithBelt:
                                 one-shot per connection: align desiredSpeedKph to the belt, and if
                                 the belt is running above the ceiling, slow it (see §9)
  ↓
  @Published status changed → controller.objectWillChange
  → AppModel's Combine sink (merged with tracker/runner/store) → AppModel.objectWillChange
  → every view observing AppModel re-renders (~1 Hz)
```

Two consequences of that last step worth internalising:

- **The whole UI re-renders about once a second while connected.** Anything expensive in a `body`
  runs once a second. `HistoryView` exists in its snapshotted form (`HistorySnapshot` +
  `SnapshotKey` + `.task(id:)`) precisely because it used to re-sort the entire history and run a
  dozen grouping passes every second just for being open.
- **The belt's status stream is the program's only clock.** `ProgramRunner` owns no timer, so a
  program structurally cannot advance while disconnected, and a stopped belt pauses it.

### Outbound: one speed change

```
user drags the Slider in SpeedControlView
  $app.desiredSpeedKph updates live (local only — no write yet)
  onEditingChanged(false)  →  app.commitSpeed(app.desiredSpeedKph)

AppModel.commitSpeed(_ kph:)
  guard isConnected                          ← bails BEFORE touching the displayed target
  if runner.isRunning { runner.stop(reason: "manual speed change") }   ← taking over by hand
  let speed = clamp(kph)                     ← round to 0.1, clamp to effectiveMaxSpeed (USER ceiling)
  if speed < 0.5 { desiredSpeedKph = 0; controller.stop(); return }    ← belt ignores sub-minimum
  desiredSpeedKph = speed
  sendSpeedToBelt(speed, mayStartBelt: true)

AppModel.sendSpeedToBelt(_:mayStartBelt:)    ← the ONE place a speed reaches the belt
  if !isMoving {
      guard mayStartBelt else { return }     ← a background correction must not start a belt
      controller.startWalking(at: kph)       ← mode → start → speed, as one batch
  } else {
      controller.setSpeed(kph: kph)
  }

PadController.startWalking(at:) / setSpeed(kph:)
  PadController.rawSpeed(kph)                ← the HARDWARE clamp: min(max(0,kph),10) × 10, rounded
  send(batch:) / send(_:)
    guard state.isConnected (control frames)
    remember inFlightSpeedRaw
    queue.enqueue(batch:) / enqueue(_:)      ← CommandQueue: coalesce in place, control before poll
    scheduleDrain()
      delay = max(0, 0.7 - since(lastSendAt))
      DispatchQueue.main.asyncAfter → sendNext(); scheduleDrain()

PadController.sendNext()
  queue.dequeue()                            ← all control frames first, then the newest poll
  peripheral.writeValue(Data(command.bytes), for: writeCharacteristic,
                        type: properties.contains(.write) ? .withResponse : .withoutResponse)
  lastSendAt = Date()
  if .setSpeed → armSpeedConfirmDeadline()   ← 4 s, or the UI spinner never clears
```

The program's path in is the same helper, one call earlier:

```
ProgramRunner.tick → onSpeed?(kph)
  → AppModel.applyProgramSpeed(kph)
      let speed = clamp(kph)                            ← user ceiling, again, last thing
      desiredSpeedKph = speed
      sendSpeedToBelt(speed, mayStartBelt: !runner.isPaused)   ← a paused program never starts a belt
```

Note the deliberate asymmetry: `commitSpeed` cancels a running program (a hand on the slider means
you have taken over), while `applyProgramSpeed` goes to `sendSpeedToBelt` directly so the program's
own writes are not mistaken for a manual override. Settings-driven corrections do the same, for the
same reason — see the comment in the `AppModel.settings` setter.

---

## 7. The pace / program model

The newest and largest subsystem. [ADR 0002](adr/0002-research-backed-pace-algorithms.md) records
*why* it is shaped this way — the published protocols are cycles of timed blocks, not ramps, and the
belt cannot do seconds. This section is the mechanics.

### The types

```
PaceTier      easy | steady | brisk | surge          — intensity, resolved inside a band
                 .isWork == true only for brisk/surge

PaceBlock     (raw: Int, seconds: Int, tier: PaceTier)  — "hold this speed for this long"

SpeedProgram  id, name, kind, minRaw, maxRaw, stepRaw, intervalSeconds
                 .cycle -> [PaceBlock]                 — one lap, then it repeats
                 .raw(for: tier)                       — easy→minRaw, steady→midpoint, brisk/surge→maxRaw
                 .clamped(toCeilingRaw:) -> Self?       — THE place the ceiling is applied to a program
                 .isValid / .validationError
                 .blocksPerCycle / .cycleDuration / .workSecondsPerCycle

SpeedProgram.Kind   intervalWalk | microSurges | threeTierWave | longDeskSession | gentleDrift
                 .blueprint -> [(tier, seconds)]?      — the trials' timings; nil = generated
                 .usesStepAndInterval                  — true only for gentleDrift

SpeedSequence  pure. State(index, raw, seconds, tier, isRising)
                 .start(of:) / .next(_:in:) / .state(at:in:wasRising:)

PaceMode      work (anchor 38, range 20…50) | meeting (anchor 50, range 30…65)
PaceAlgorithm kind, goal, evidence, sessionWorkSeconds?, cadence, lowOffset, highOffset
                 .program(anchorRaw:) -> SpeedProgram
                 .all  (the catalogue)   .named(_ kind:)

ProgramRunner  tick-driven. isRunning, isPaused, state, nextChangeAt, stepsApplied,
               workSeconds, activeProgram (clamped) + authoredProgram (private, unclamped)
```

### How a band is decided

One number per mode — the **anchor pace** — is all the user tunes. Each algorithm places its own
band around it via fixed offsets, so switching mode shifts all five together and preserves the shape
each protocol was studied with:

| Kind | Offsets (raw) | Working (38) | Meeting (50) | Blueprint |
| --- | --- | --- | --- | --- |
| `intervalWalk` | −4 / +8 | 3.4–4.6 | 4.6–5.8 | brisk 180 s, easy 180 s |
| `microSurges` | −3 / +12 | 3.5–5.0 | 4.7–6.2 | easy 630 s, surge 90 s |
| `threeTierWave` | −4 / +9 | 3.4–4.7 | 4.6–5.9 | easy 180 s, steady 120 s, brisk 60 s |
| `longDeskSession` | −4 / +8 | 3.4–4.6 | 4.6–5.8 | 5 × (brisk 180, easy 180) then 3 × (easy 300, steady 300) — 16 blocks, 3600 s |
| `gentleDrift` | −3 / +3 | 3.5–4.1 | 4.7–5.3 | *none* — generated from `stepRaw`/`intervalSeconds` |

`PaceAlgorithm.program(anchorRaw:)` floors the band at the belt's own minimum but deliberately does
**not** apply the app ceiling: the runner does that, so `AppModel.ceilingNote(for:)` can name both
numbers instead of silently rewriting the user's band.

`gentleDrift` is the old ramp, kept. `driftCycle()` generates min → max → back down with the
endpoints visited exactly once per lap (4.0, 4.1 … 5.5, 5.4 … 4.1, wrap), a step that would overshoot
lands exactly on the maximum, and **its blocks are only ever `easy`/`steady`** — a drift is variation,
not interval training, so it must never contribute to the brisk-minute dose.

### `ProgramRunner`, in the order things happen

- **`start(_:ceilingRaw:now:)`** — validates, clamps, stores *both* the authored and the clamped
  program, resets `workSeconds`/`stepsApplied`, sets `nextChangeAt = now + state.seconds`, notes the
  clamp if there was one, and immediately calls `onSpeed`. Returns `false` and does nothing if the
  program cannot run.
- **`tick(beltIsMoving:now:)`** — called once per status frame.
  - Belt not moving: start (or continue) the grace period; after `pauseGraceSeconds` (10 s) set
    `isPaused`, clear `nextChangeAt` and stop crediting. The grace exists because a belt reports zero
    briefly during spin-up and during a speed change, and pausing on the first such frame would
    stall the program before it started.
  - Belt moving again while paused: unpause, restart the block clock from now, re-assert the expected
    speed (in case it changed while paused), and return.
  - Otherwise: `creditWork(upTo: now)` **before** advancing, so the elapsed time is credited to the
    block you were actually in; then if `now >= nextChangeAt`, advance via `SpeedSequence.next`,
    schedule the next deadline **from the old deadline** (so a late tick does not drift the
    programme), and `onSpeed`.
- **`applyCeiling(_ ceilingRaw:)`** — re-clamps the **authored** program, never the already-clamped
  one, so raising the ceiling widens the band back out instead of leaving it stuck where it was cut.
  If the ceiling leaves no room, the program stops.
- **`reband(to:ceilingRaw:)`** — same algorithm, different band, without restarting: the dose and
  `stepsApplied` carry over. It **refuses** if the kind differs, so a different protocol has to go
  through `start`.
- **`adopt(_:)`** (private) — takes up a freshly clamped program: remaps the position, shifts
  `nextChangeAt` by the difference in block length (so a settings change cannot fire a change
  immediately or push one far into the future), and commands the new speed **only if not paused**.
- **`remapped(_:into:)`** (private) — where to stand in the new cycle. If the block at the same index
  still has the same tier and length, stay there and let its speed change. Only if the cycle's
  *shape* changed does it fall back to nearest speed. Matching by speed alone would drop you out of
  a fast interval into recovery, because the old band's easy pace is the new band's brisk one.
- **Brisk-minute accounting** — `creditWork` adds elapsed time only when `state.tier.isWork`, never
  while paused (`lastCreditedAt` is nil'd on pause), and credits at most `maxCreditedTickGap` (5 s)
  per tick so a stalled stream cannot invent minutes. `doseProgress` divides by the algorithm's
  `sessionWorkSeconds` and returns nil where no trial prescribed a dose.
- **`cycleProgress(now:)`** — measured in **time**, not blocks. Counting blocks would show a
  micro-surge jump from 0% to 50% after ten minutes and then to 100% ninety seconds later.

### Two callers, one runner

`PaceAlgorithmsView` (a box per algorithm) and `ProgramView` (the freehand editor) share one
`ProgramRunner`. `AppModel.startedFromAlgorithmBox` decides which one owns the current run, and
feeds `runningAlgorithm` / `isFreehandProgramRunning` so the two do not each claim the other's Stop
button. Starting from either place takes over from the other, which is what pressing Start on a
different program plainly means.

### Recipe: add a pace algorithm

1. **`SpeedProgram.Kind`** — add a case. Give it a `label`, a `detail`, and its blocks in
   `blueprint` as `[(tier, seconds)]`. All three switches are exhaustive, so the compiler will find
   them for you. Every block must be **≥ 60 s** (`everyBlockIsLongEnoughForTheBeltToReach`); the belt
   needs seconds just to change speed, so a shorter block is a dose that never happens.
2. **`PaceAlgorithm.all`** — add the catalogue entry: `goal`, `evidence` (with the numbers that
   matter, and say so if the evidence is weak), `sessionWorkSeconds` (nil if no trial prescribed a
   dose), `cadence`, and `lowOffset`/`highOffset` relative to the mode anchor.
3. **Nothing else.** The runner and every view only ever see the resolved `cycle`. The box, the
   cycle strip, the menu-bar entry and the `Belt ▸ Pace algorithm` menu item all come from
   `PaceAlgorithm.all` automatically.
4. **Checks** — a function in `ProtocolChecks.swift` pinning the numbers your protocol is defined by
   (see `intervalWalkMatchesTheResearchedProtocol` for the shape), plus its entry in `allChecks`. The
   existing sweeps will already cover you for band containment
   (`everyAlgorithmStaysInsideItsBand`), block length, mode shifting
   (`paceModesShiftEveryAlgorithmTogether`), typeability in Working mode
   (`workingModeStaysTypeable`) and catalogue completeness
   (`everyAlgorithmIsDistinctAndDescribed`, which fails if a `Kind` has no entry).
5. **ADR** — if the addition changes the *model* rather than adding data to it, add an ADR.

Do not add a new tuning knob to `SpeedProgram` for it. Timings come from the trials; only
`gentleDrift` reads `stepRaw`/`intervalSeconds`, and `validationError` deliberately ignores those
fields for every other kind so a nonsense interval cannot invalidate a protocol that never reads it.

---

## 8. The invariants, and the bug each one is a scar from

`CLAUDE.md` lists six. Here is what upholds each, and what breaks if you don't.

### 1. Every asynchronous phase needs a deadline and a terminal state

**Where:** `PadController` — `armScanDeadline` (15 s → `giveUpScanning` → `.notFound`),
`armConnectDeadline` (12 s → `abandonConnectAttempt`), `armSpeedConfirmDeadline` (4 s → clear
`inFlightSpeedRaw` and explain why), `broadScanFallbackDelay` (6 s → widen the scan to name matching),
and `QuitPolicy.stopConfirmationTimeout` (6 s) with an independent `DispatchWorkItem` backstop.

**The failure:** CoreBluetooth's `connect(_:options:)` never times out, and a GATT discovery that
yields no write characteristic simply never calls back. `stopScan()` also discards the scan budget
the moment a belt is discovered. Without these, the UI sits on "Connecting…" forever, which reads as
a frozen app. `notFound` carries a `hint` so the terminal state can explain itself, and
`didDisconnectPeripheral` deliberately does **not** overwrite a `.notFound` state with a bare
"Not connected" — that erased the reason the user needed to see. Also: dropping below `.poweredOn`
invalidates every `CBPeripheral` without a promised disconnect callback, so
`handleBluetoothUnavailable` tears down the stale reference — otherwise a Bluetooth off/on cycle
defeated both guards (they test `peripheral == nil`) and left the UI scanning forever.

### 2. Never expose observable state as `@Published` when a custom `Binding(get:set:)` writes to it

**Where:** `AppModel.settings`, `AppModel.program`, `AppModel.savedPrograms` — all three are backed
by private `stored…` properties, drop equal writes, and call `objectWillChange.send()` by hand.

**The failure, concretely:** `MenuBarExtra(isInserted:)` in `WalkingPadApp` writes its binding back
on *every* body evaluation. `@Published` publishes on assignment whether or not the value changed. So
a no-op write from inside `body` invalidated the view that had just written it, the App body
re-evaluated, wrote again… a core pegged at 100% forever and the app stopped responding even to a
quit event. Dropping equal writes breaks the cycle.

The pattern to copy:

```swift
var settings: AppSettings {
    get { storedSettings }
    set {
        guard newValue != storedSettings else { return }   // ← the whole fix
        objectWillChange.send()
        storedSettings = newValue
        …side effects…
    }
}
```

`@Published var desiredSpeedKph` is *not* a violation: the slider binds to it directly and every
write is a real change, driven by user input rather than by body evaluation.

### 3. The belt drops commands sent less than ~0.7 s apart

**Where:** `PadController.minimumCommandSpacing` + `scheduleDrain`, and `CommandQueue`.

**The failure:** writing on every slider tick makes the belt ignore most of the writes, which reads
as an unresponsive app. The queue is a correctness requirement, not an optimisation. Three rules:

- **Control frames outrank status polls** — a 1 Hz poll must never delay a speed change.
  `CommandQueue` keeps them in separate storage and only ever holds the newest poll.
- **Coalescing replaces in place** — `control[index] = command`, never remove-and-append. Re-appending
  would turn a queued `mode → start → speed` into `start → speed → mode`, telling the belt to change
  speed before it is in manual mode.
- **A sequence goes in as one batch** — `enqueue(batch:)` removes every coalescable member first and
  then appends the whole batch, because coalescing can only replace a frame that is *still queued*.
  If the leading `mode` has already been sent, a second `mode` has nothing to replace and lands at
  the tail. `startSequenceKeepsOrderAfterPartialDrain` is the regression test.

A useful side effect: because `.setSpeed(0)` shares the `"speed"` coalesce key, a panic stop
*replaces* a queued speed-up rather than queueing behind it.

### 4. Speed changes only apply in manual mode on a running belt

**Where:** `PadController.startWalking(at:)` sends `[.setMode(.manual), .start, .setSpeed(raw)]` as
one batch; `AppModel.sendSpeedToBelt` chooses between `startWalking` and `setSpeed` based on
`isMoving`.

**The failure:** a bare `setSpeed` to a stopped or automatic-mode belt is silently ignored, and since
the belt never acknowledges a speed it will not honour, `inFlightSpeedRaw` stays set and the UI shows
a confirmation spinner that never clears (hence the deadline in invariant 1).

### 5. Speeds are integers in 0.1 km/h units

**Where:** `SpeedProgram.minRaw`/`maxRaw`/`stepRaw`, `PaceBlock.raw`, `SpeedSequence.State.raw`,
`PadCommand.setSpeed(UInt8)`, `PaceMode.defaultAnchorRaw`/`anchorRange`,
`AppSettings.workAnchorRaw`/`meetingAnchorRaw`. `Double` km/h exists only as a computed view for the
UI (`minKph`, `maxKph`, `currentKph`) and for the calorie maths.

**The failure:** repeatedly adding 0.1 to a `Double` accumulates error, so after thirty steps you ask
for 5.499999 and the belt rounds somewhere you did not intend. A program stepping by 0.1 for an hour
must not drift off the grid. `driftHasNoFloatingPointDrift` walks 500 steps and asserts every value
is an exact multiple of 0.1.

### 6. The user's speed ceiling always wins

**Where, in layers:**

| Layer | Code | Purpose |
| --- | --- | --- |
| Resolution | `SpeedLimits.effectiveCeiling(walkingCeilingKph:isRunningMode:)` | Walk uses the user's ceiling; Run unlocks `hardMaxKph` (10.0). Non-finite input fails **safe** to `minRunningKph`, not to the maximum. |
| App-level clamp | `AppModel.clamp(_:)` | Rounds to 0.1 and clamps to `effectiveMaxSpeed`. Called by `commitSpeed`, `applyProgramSpeed`, `start`. |
| Program-level clamp | `SpeedProgram.clamped(toCeilingRaw:)` | The single place a program's band is capped. Because `PaceTier` always resolves inside `minRaw…maxRaw`, clamping the band is a **complete** guarantee — no block can escape it. |
| Wire clamp | `PadController.rawSpeed(_:)` | `min(max(0,kph),10) × 10`. The floor of the safety story: `padctl speed 20` used to go straight through. |

**The failure:** more than one. Lowering the ceiling once updated the on-screen target but never
slowed a belt already running above it — a safety limit has to reach the hardware, not just the
label. And `applyCeiling` once re-clamped the already-clamped program, so a program authored 4–8 and
started under a 6 ceiling stayed capped at 6 even after switching to Run.

> **This invariant currently has a known hole.** One case of that first failure is still live:
> lowering the ceiling *below a running program's whole band* stops the program without slowing the
> belt. See §13 — do not assume this invariant is fully upheld in the `settings` setter.

### Further invariants the code enforces but `CLAUDE.md` does not name

7. **A paused program must never command a speed.** It is paused precisely because the belt is idle,
   and the user did not ask for it to move. Upheld in `ProgramRunner.adopt` (`if moved.raw !=
   previous.raw, !isPaused`) and in `AppModel.applyProgramSpeed` (`mayStartBelt: !runner.isPaused`).
   The original bug: lowering the ceiling while a program was paused reached `startWalking()` and
   would have physically started a stopped treadmill from a Settings change.
   Regression: `loweringCeilingWhilePausedCommandsNothing`.
8. **All speed writes go through one gated helper.** `AppModel.sendSpeedToBelt(_:mayStartBelt:)` is
   the only path, and `mayStartBelt` is true only for an explicit user action or a program genuinely
   beginning. Add a new entry point and route it through this, not around it.
9. **A program is clocked by the belt, never by a local timer.** `ProgramRunner` has no timer;
   `AppModel`'s `onStatus` closure calls `tick`. This is what makes "cannot run while disconnected"
   and "pausing the belt pauses the program" structural rather than defensive.
10. **The recorder records deltas against a baseline.** The belt's counters are cumulative and reset
    only when it sleeps, so recording raw counters re-counts an earlier walk every time someone
    resumes without resetting the belt.
11. **An unreadable history file is preserved, never overwritten** (§10).
12. **Every quit path replies to AppKit exactly once, and a quit never hangs on hardware.**
    `finishQuit` is idempotent (`hasRepliedToQuit`) because the timer and the backstop race.
13. **A timer that must fire while AppKit waits for a terminate reply has to be registered in
    `.common`.** `Timer.scheduledTimer` registers only in the default mode; AppKit runs
    `NSModalPanelRunLoopMode` while waiting for `reply(toApplicationShouldTerminate:)`. See the
    comment in `beginStopThenQuit`.
14. **The menu-bar item can never be hidden while the Dock icon is hidden.** The `settings` setter
    forces `showMenuBarExtra = true` whenever `hideDockIcon` is set, because hiding both leaves a
    running app with no icon, no window and no menu to quit from — recoverable only by Force Quit.
15. **Every `SpeedProgram.Kind` must have a `PaceAlgorithm` entry**, or it is unreachable from the
    algorithm list. Enforced by `everyAlgorithmIsDistinctAndDescribed`.
16. **Belt-side preferences are write-only.** The belt never reports them back, so the Belt tab's
    controls are actions with Apply buttons, not two-way bindings, and the tab says so.
17. **`isProgramRunning` and the two owners.** Exactly one of `runningAlgorithm` /
    `isFreehandProgramRunning` may be true at a time; both derive from `startedFromAlgorithmBox`.

---

## 9. Safety-critical paths

This drives a motorised treadmill someone is standing on. Treat everything in this section as
requiring a check.

### Where the ceiling is applied, and why it must be last

The clamp belongs **immediately before the write**, not at the point of intent, because the ceiling
can change between the two. Concretely:

- `AppModel.clamp(_:)` is called inside `commitSpeed` and `applyProgramSpeed`, one line before
  `sendSpeedToBelt`.
- `SpeedProgram.clamped(toCeilingRaw:)` is applied by the runner at `start`, `applyCeiling` and
  `reband` — never earlier. `PaceAlgorithm.program(anchorRaw:)` deliberately returns an *unclamped*
  band so `ceilingNote(for:)` can tell the user which numbers will be limited instead of silently
  rewriting their intent.
- `PadController.rawSpeed(_:)` clamps again at the wire, so no caller — `padctl`, a future entry
  point, a mistake — can exceed 10 km/h.

Lowering the ceiling must reach the hardware, in three situations:

1. **Belt running, no program:** the `settings` setter pulls `desiredSpeedKph` down and calls
   `sendSpeedToBelt(ceiling, mayStartBelt: false)`.
2. **Belt running, program running:** `runner.applyCeiling` re-clamps and `adopt` commands the new
   speed.
3. **Reconnecting to a belt already above the ceiling** (after a dropout, or after leaving Run mode
   while disconnected): the one-shot alignment branch in `onStatus` logs a warning and calls
   `sendSpeedToBelt(ceiling, mayStartBelt: false)`.

### Panic stops

| Route | Path |
| --- | --- |
| **Space bar** (no modifier) | `SpeedControlView` Stop button. Always stops, moving or not. |
| **⌘.** "Emergency stop" | `Belt` menu → `AppModel.stop()`. |
| **⌘S** | Start/Stop toggle, in the window and the menu. |
| Menu-bar "Stop belt" | `MenuBarContent` → `toggleStartStop()`. |
| Quit with `quitBehavior == .stopBelt` | `beginStopThenQuit()`. |

`AppModel.stop()` ends the program first (otherwise it would restart the belt on its next step and
the Stop press would look ignored), then `controller.stop()` → `.setSpeed(0)`. It goes through the
queue like everything else, so it can be delayed up to the 0.7 s spacing — but because it shares the
`"speed"` coalesce key it *replaces* any queued speed-up rather than waiting behind it.

### Rules that are not obvious

- **A paused program must never command a speed** (invariant 7). This is the one that would
  physically start a stopped belt.
- **A background correction must never start a stopped belt.** `mayStartBelt: false` for every
  ceiling enforcement and reconnect alignment.
- **Switching to Run only unlocks the range; it never changes the current speed**, so it cannot make
  the belt speed up under you. `setRunningMode` just writes the setting.
- **A speed below `minRunningKph` (0.5) is treated as a stop**, because the belt ignores such a
  request outright and the UI would otherwise wait forever for a confirmation.
- **Quitting is not a stop.** `leaveRunning` is a legitimate choice — quitting a remote does not
  change the machine — but it must never be silent by accident. If a stop is requested and the belt
  does not confirm within 6 s, the user is asked whether to quit anyway rather than the app quitting
  and leaving them believing a treadmill is stopped. Losing the connection mid-wait ends the wait but
  is explicitly **not** treated as confirmation.
- **A belt told to start but not yet reporting counts as moving** (`beltIsMovingOrAboutTo`), because
  a start sequence takes ~1.4 s to clear the queue and quitting in that window would skip the prompt
  entirely.

---

## 10. Persistence

Two stores, chosen for different reasons.

### `UserDefaults` — settings and programs

Written by `AppModel.persist()` and `AppModel.persistPrograms()`, read by `AppModel.load(from:)`,
`loadDraftProgram(from:)` and `loadSavedPrograms(from:)`. Key strings live in the private `Keys` enum
at the bottom of `AppModel.swift`:

| Group | Keys |
| --- | --- |
| Display | `unit`, `showMenuBarExtra`, `menuBarContent`, `hideDockIcon` |
| Control | `speedCeilingKph`, `isRunningMode`, `startSpeedKph`, `autoConnectOnLaunch`, `quitBehavior` |
| Pace | `paceMode`, `workAnchorRaw`, `meetingAnchorRaw` |
| Body | `weightKg`, `heightCm`, `ageYears`, `biologicalSex`, `weightUnit`, `showNetCalories` |
| Programs | `draftProgram`, `savedPrograms` (both JSON `Data`) |

Three things to know:

1. **Everything is read defensively.** Scalars go through `defaults.object(forKey:) != nil` so an
   unset key keeps the struct default rather than reading `0`; enums go through
   `Enum(rawValue: defaults.string(...))`.
2. **There is a sanitiser at the end of `load(from:)`.** Persisted values are clamped —
   `speedCeilingKph` to 1…10, `startSpeedKph` to 0.5…ceiling, weight 25…250, height 100…230, age
   10…100 — and both anchors are round-tripped through `setAnchorRaw(_:for:)` so a corrupted anchor
   cannot put every algorithm's band in the wrong place. Add a new persisted number and add its
   clamp here.
3. **Programs are JSON, and validity-filtered on load.** `loadDraftProgram` falls back to
   `.standard` if the stored draft cannot decode *or* is invalid; `loadSavedPrograms` filters to
   `\.isValid`. A decode failure is silent — `try?` — which means a `Codable` change quietly deletes
   the user's saved programs. See the traps in §12.

`isBodyDataConfigured` reads `UserDefaults.standard.object(forKey: Keys.weight) != nil` directly, to
tell "the user entered 75 kg" apart from "the default is 75 kg". A calorie figure derived from a
default weight looks identical to a real one, which is the worst of both.

### On disk — walk history

`SessionStore`, JSON at `~/Library/Application Support/WalkingPad/sessions.json`
(`SessionStore.defaultFileURL()`; the check suite injects a temp URL). Not `UserDefaults`, because the
dataset grows without bound. Writes are `.atomic`, so a crash mid-save cannot truncate it. Sessions
are kept newest-first **on insert** (`append` finds the index) so reads are free.

`revision` is bumped on **every** mutation, before the write, so a view that caches derived
statistics against it cannot show fresh totals over a stale table even if the write is refused.

**The unreadable-file path is the important part.** Starting empty and carrying on is not enough: the
next completed walk would `save()` and atomically replace the file with a single entry — silent, total
data loss. So `load()` failing calls `quarantineUnreadableFile`:

- **Move the file aside** to `sessions-unreadable-<ISO8601>.json`, start a fresh history, and set the
  **sticky** `quarantineNotice`. Sticky because a later successful save must not erase the only
  notification that the old history was archived — otherwise the user just sees "no history".
  `HistoryView` shows the notice above everything and *not* gated on having any sessions, because
  after a quarantine the history is empty, which is exactly when it must be visible.
- **If even the move fails**, set `isReadOnly` and `lastError`. `save()` then refuses to write at all,
  because overwriting data we could not read is worse than not saving.

Both halves have checks: `unreadableHistoryIsPreservedNotOverwritten` and
`unmovableUnreadableHistoryGoesReadOnly`.

Sessions store the **gross** calorie figure; net is derived at display time from the current body
data (`AppModel.displayKcal(...)`), so nothing is lost by switching the preference.
`SessionStore.recalculateCalories(profile:)` re-derives stored gross figures from each walk's
duration and average speed, which is how a corrected weight reaches walks already recorded.

---

## 11. Common tasks, as recipes

### Add a metric tile to the dashboard

1. If the number is derived, add it to `SessionTracker` (live, per belt session) or as a computed
   property on `AppModel`. Pure maths goes in `Metrics` in the kit.
2. Add a `MetricTile(label:value:unit:systemImage:tint:footnote:)` to `MetricsGrid` in
   `UI/DashboardView.swift`. The grid is a 4-column `LazyVGrid`; keep the count a multiple of 4 or
   the last row goes ragged.
3. Format through `app.settings.unit` (`speed(fromKph:)`, `distance(fromKm:)`, `pace(fromMinPerKm:)`
   and the matching `…Suffix`). **Never print a raw km value** — this app supports miles.
4. Use `Metrics.formatDuration` / `formatPace` rather than hand-rolling. They handle the `—` case.
5. **What will bite:** the tile re-renders ~1 Hz, so nothing expensive in the value expression. If
   you need aggregation over history, snapshot it the way `HistoryView` does.

### Add an app setting

1. A stored property on `AppSettings` **with a default** (it is `Equatable`; keep it so).
2. A key in `AppModel.Keys`, a line in `persist()`, a read in `load(from:)` guarded by
   `object(forKey:) != nil` or `Enum(rawValue:)`, and — if it is a number — a clamp in the sanitiser
   block at the end of `load`.
3. A control in the right `SettingsView` tab, bound with `Binding(get:set:)` against
   `app.settings.<field>`. Never make `settings` `@Published` (invariant 2).
4. If it needs a side effect, add it to the `settings` setter, comparing against `oldValue` — that is
   how `hideDockIcon` triggers `applyDockIconPolicy` and how the ceiling reaches the belt.
5. **What will bite:** side effects in the setter run on every change to *any* field, so gate them on
   an actual difference. And a setting that changes the speed ceiling must reach the hardware, not
   just the label (§9).

### Add a belt-side preference

1. A case in `PadPreference` with the right key byte (the known keys are in §5). Check
   [ph4r05/ph4-walkingpad](https://github.com/ph4r05/ph4-walkingpad) before guessing.
2. An `apply…` method on `AppModel` calling `controller.setPreference(_:value:type:)`.
3. A row in `BeltPreferencesTab` — `@State` local + an **Apply** button, not a two-way binding,
   because the belt never reports these back (invariant 16).
4. A check that the frame encodes as expected (`preferenceEncodesBigEndian24Bit` is the model).
5. **What will bite:** the coalesce key is `"pref-<rawValue>"`, so a duplicated raw value would make
   two preferences collapse into each other in the queue.
   `idempotentCommandsShareACoalesceKey` catches that.

### Add a pace algorithm

See §7. Two files, no runner or UI changes, plus a check.

### Add a check

See §2. `ProtocolChecks.swift` for the function, `allChecks` in `main.swift` for the entry.

### Change the BLE protocol layer

1. `PadCommand` for outbound (bytes + `coalesceKey` + `isStatusPoll`), `PadStatus`/`PadRecord`/
   `PadFrame` for inbound.
2. A check with real bytes. The suite's currency is captured frames and literal expected arrays, not
   round-trips through your own encoder.
3. **What will bite:** `PadStatus.matches` gates on a length, and the initialiser then indexes fixed
   byte offsets — widen the length guard if you read further into the frame.

---

## 12. Traps and gotchas

- **`@Published` + custom `Binding` = 100% CPU forever.** Invariant 2. The specific offender is any
  binding SwiftUI writes back during body evaluation, `MenuBarExtra(isInserted:)` above all.
- **`Codable` raw-value stability.** `SpeedProgram.Kind.gentleDrift` has raw value `"upDown"` **on
  purpose** — it was renamed from `upDown` and programs saved by earlier builds still decode by raw
  value. `everyAlgorithmIsDistinctAndDescribed` asserts it. The same applies to every enum persisted
  by `rawValue` in `UserDefaults`: `DistanceUnit`, `WeightUnit`, `BiologicalSex`, `MenuBarReadout`,
  `QuitBehavior`, `PaceMode`.
- **Adding a stored property to a `Codable` model silently deletes user data.** The synthesized
  `init(from:)` requires every non-optional key, and both program loaders use `try?` and fall back to
  defaults. Add new fields as optional, or with an explicit `init(from:)` that tolerates their
  absence. Same hazard for `WalkSession` and the whole history file — with the mitigation that
  `SessionStore` quarantines rather than overwrites (§10).
- **Speeds are integers.** Invariant 5. If you find yourself writing `Double` km/h into a program or
  stepping by `0.1`, you are on the wrong path. `SpeedProgram.raw(_:)` and the `…Kph` computed
  properties are the only bridge.
- **The belt beeps on every accepted command.** It is firmware acknowledgement and cannot be muted
  from software. Status polls are silent, so the only lever is *how often you change the speed* —
  which is why the algorithms differ by an order of magnitude here (micro-surges twice per 12 min,
  interval walk twice per 6, gentle drift every 2). Anything that writes speeds more often than the
  design does is an audible regression, not just a protocol one.
- **`AppModel` republishes about once a second.** Any `body` that does real work runs 60× a minute.
  Snapshot derived aggregates (`HistorySnapshot` + `.task(id:)`).
- **A `Slider` whose value sits outside its own range renders a pinned thumb and inert steppers.**
  Two places work around this: `AppModel.settings` pulls `desiredSpeedKph` down when the ceiling
  drops, and `ProgramView.editorMaxSpeed` stretches the editor's range to fit a saved program that
  exceeds the current ceiling rather than rewriting the user's numbers.
- **Programs are always edited in km/h**, even when the display unit is miles, because a step is
  exactly 0.1 km/h — offering 0.1 mph steps would promise precision the hardware does not have.
  `ProgramView` says so in the UI when the unit is miles.
- **`padctl`'s hardware subcommands cannot run from an agent shell.** No responsible app for TCC to
  attribute the prompt to, so the process is killed rather than prompted. `selftest` is fine.
- **Never `--install` while the app is running.** It terminates the app and kills a walk in progress.
- **A rebuild may re-trigger the Bluetooth permission prompt**, because the ad-hoc signature changes.
- **`build.sh` only looks at `$1`.** `--install --run` installs and does not launch.
- **`PadStatus.appSpeedKph` divides by 30, not 10.** Byte 14 is in 1/30 km/h units. It is diagnostic
  only; do not use it as a speed.
- **Belt state bytes beyond 0/1/5/9 are transitional** and deliberately not over-labelled
  (`PadBeltState.other`). Don't invent semantics for them.
- **`SessionRecorder.programName` is sampled once, when a walk begins** (`programAtStart`). Reading
  it at completion attributed the whole walk to whatever happened to be active at the final frame —
  often nothing. `walkRecordsTheProgramThatStartedIt` pins this.
- **`SessionTracker` and `SessionRecorder` both integrate calories, separately.** The tracker feeds
  the live dashboard for the belt's whole session; the recorder feeds the stored `WalkSession` for
  one walk. They are not interchangeable and both cap credited gaps at 120 s.
- **`startedFromAlgorithmBox` is only cleared by `startProgram`/`stopProgram`.** A run ended by a
  disconnect, a manual speed change or a belt stop leaves the flag set; that is currently harmless
  because both consumers also test `runner.isRunning`, but it is a sharp edge — if you add a consumer
  that does not, clear the flag where the runner stops instead.
- **`ProgramRunner.stepsApplied` starts at 1**, not 0, and the UI labels it "block".

---

## 13. Gaps and things I could not settle

Written down rather than guessed at.

- **Lowering the ceiling below a running program's band leaves the belt above the new ceiling.** In
  the `AppModel.settings` setter the "slow the belt" branch is guarded by `if !runner.isRunning`, and
  `runner.applyCeiling` is called afterwards. If the new ceiling leaves no room, `applyCeiling` stops
  the program and never commands a speed — so nothing slows the belt, while `desiredSpeedKph` has
  already been pulled down to the ceiling. Reproduce: run any program, then drag the app speed limit
  below the program's minimum while the belt is moving. **Confirmed by reading, not on hardware:**
  the only other place that re-asserts the ceiling against a moving belt is the `controller.onStatus`
  closure, and that branch sits inside `if !hasAlignedTargetWithBelt`, which runs once per
  connection — so nothing catches this mid-session. The UI then shows the new ceiling while the belt
  holds its old pace, which is precisely what invariant 6 exists to prevent. Not changed here.
  A fix wants both halves: `applyCeiling` reporting that it stopped (or the setter re-asserting the
  ceiling unconditionally afterwards), plus a check — the existing
  `loweringCeilingReclampsRunningProgram` asserts `!runner.isRunning` for an impossible ceiling but
  never asserts that a speed was commanded, which is why this got through.
- **`startProgram()` does not stop a running program first**, unlike `startAlgorithm()`, which calls
  `runner.stop(reason: "switching program")`. `runner.start` resets everything anyway, so the
  observable behaviour is a restart either way — but the event log loses the "Program stopped" line.
  Cosmetic, and possibly deliberate.
- **`Metrics.pace`'s doc comment is stranded.** The line `/// Minutes per km. Returns nil when
  stopped.` sits immediately above `restingKcalPerMinute`, two functions away from `pace`. Harmless,
  but it reads as a wrong doc comment on the resting-metabolism function.
- **`handleBluetoothUnavailable` also handles `.resetting`/`.unknown`** via the `default` branch,
  which paints a "Bluetooth unavailable" state for what may be a transient startup value. I could not
  determine whether that is observable in practice without hardware.
- **The 120 s calorie gap cap is duplicated**: `SessionTracker.maxCreditedGapSeconds` and a bare
  `delta <= 120` literal in `SessionRecorder.ingest`. They agree today by coincidence of maintenance.
- **`lifetimeTotalsIncludingCurrent` folds in the open walk's distance, duration, steps and
  calories but not its peak speed.** Probably intentional (peak is a max over stored sessions), but I
  did not find it stated anywhere.
- **No framing/reassembly for BLE notifications.** Each `didUpdateValueFor` is assumed to carry one
  complete frame. That has evidently held for this belt; I have no evidence about whether it can
  fragment.
- **Assertion counts in commit messages drift.** The suite is currently 69 check functions
  (`allChecks`) over 374 `check(...)` call sites; the runtime assertion count is higher because many
  are inside loops. It was not run — no Swift toolchain was installed at the time of writing (see
  §3) — so this quotes structure, not results.

---

## 14. Session log — what landed, and how far it was verified

Kept because the most urgent question for a session picking this up is not "how does it work" but
"what state is this in". Newest first.

### 2026-08-21 — pace algorithms, modes, and this document

Two commits, both on `main` (`b7757a9`, `475536d`), written entirely in a remote Linux session.

**What changed.** `SpeedProgram` stopped being a ramp with `(min, max, step, interval)` and became a
repeating cycle of `PaceBlock`s, because every published protocol for varied walking is expressed
that way. Five algorithms ship in `PaceAlgorithm.all` — interval walk, micro-surges, three-tier wave,
long desk session, gentle drift — each with its band offsets, its evidence, and its researched dose.
`PaceMode` (Working 3.8 / Meeting 5.0) supplies one anchor pace that every algorithm places its band
around. `ProgramRunner` gained per-block durations, `reband` (change band without restarting, so a
meeting starting mid-walk does not zero the session), brisk-minute accounting, and remap-by-block.
`PaceAlgorithmsView` puts each algorithm in its own box; the menu bar got a mode picker and an
algorithm submenu. 19 new checks, taking `allChecks` to 69. Full rationale in
`docs/adr/0002-research-backed-pace-algorithms.md`.

**How far it was verified — read this part.**

| | |
| --- | --- |
| Compiled | **No.** Never type-checked, on any toolchain. |
| `padctl selftest` | **Never run.** |
| Logic | Validated against a Python port — all pre-existing program/runner checks plus all 19 new assertions pass there (§3). |
| Hardware | Never touched a belt. |

So the pace model's arithmetic is well tested and its Swift is not tested at all. Expect syntax and
type errors rather than behavioural ones, and look first at the places where the Python port could
not help: the SwiftUI result builders in `CycleStrip`, the labelled tuple arrays in `Kind.blueprint`,
the `Picker`/`Menu` nested in a `CommandMenu`, and `Codable` synthesis on the reshaped
`SpeedProgram`. §3 lists the specific constructs that bit while writing it.

**Deliberately not done.** A confirmed defect was found while writing this document and left alone:
lowering the app speed ceiling below a running program's whole band stops the program without
slowing the belt. It is described in §13 and cross-referenced from invariant 6 in §8. It predates
these commits. Fixing it wants two things — `applyCeiling` reporting that it stopped (or the
`settings` setter re-asserting the ceiling unconditionally afterwards), and the missing assertion in
`loweringCeilingReclampsRunningProgram`, which today checks `!runner.isRunning` for an impossible
ceiling but never checks that a speed was commanded. That omission is why the bug got through.

**Also attempted, then stopped.** Installing a Swift Linux toolchain to type-check the
Foundation-only subset. The toolchain downloads and runs (verified, Swift 6.1.2); no package was
assembled. §3 records the route and the per-file reach.
