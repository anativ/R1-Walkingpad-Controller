# 0001 — Native SwiftUI app built without an Xcode project

Status: Accepted

## Context

The goal is a macOS app that shows all live data from a KingSmith WalkingPad R1 Pro and
changes the belt speed. The belt exposes a BLE GATT service (`FE00`) with a notify
characteristic (`FE01`) and a write characteristic (`FE02`).

Constraints discovered while setting up:

- The machine has the Xcode **Command Line Tools** only, no full Xcode. The CLT SDK does ship
  AppKit, SwiftUI, Charts and CoreBluetooth, but ships **neither XCTest nor swift-testing**,
  so `swift test` cannot run at all.
- CoreBluetooth refuses to operate unless the code runs from a signed app bundle whose
  `Info.plist` carries `NSBluetoothAlwaysUsageDescription`.
- The belt silently drops commands that arrive closer together than roughly 0.7 s.

## Decision

1. **Native SwiftUI + CoreBluetooth**, no third-party dependencies and no Electron/web layer.
2. **Swift Package Manager, not an `.xcodeproj`.** A `build.sh` script compiles with
   `swift build` and assembles `dist/WalkingPad.app` by hand (binary + `Info.plist` + `.icns`),
   then ad-hoc code-signs it. The project stays buildable from a terminal with only the CLT
   installed, and can still be opened in Xcode as a package if one is installed later.
3. **Three targets.** `WalkingPadKit` holds the protocol, BLE and metrics code with no UI, so
   it can be exercised headlessly. `WalkingPad` is the SwiftUI app. `padctl` is a CLI that runs
   the protocol self-test and can drive the belt from a terminal for troubleshooting. `padctl`
   ships as its own minimal `.app` bundle, because macOS grants Bluetooth to no bare executable
   — measured, not assumed: a plain binary aborts under TCC, and it still aborts with the usage
   string linked into `__TEXT,__info_plist`, ad-hoc signed, and even when placed inside the main
   app's `Contents/MacOS`. Only being the `CFBundleExecutable` of a bundle satisfies TCC.
4. **`padctl selftest` replaces a unit-test target.** Because no test framework exists on this
   toolchain, the protocol assertions are compiled into `padctl` and run as a normal program
   that exits non-zero on failure. `build.sh` runs it before every build.
5. **A spaced, coalescing command queue** sits in front of the write characteristic. Speed
   commands supersede any earlier queued speed command, control commands take priority over
   status polls, and no two writes leave less than 0.7 s apart.
6. **Calories are computed in the app**, using the ACSM walking equation over the belt's own
   clock, and are labelled as estimates.
7. **Every asynchronous phase has a deadline and a terminal state.** Scanning, connecting +
   GATT discovery, and waiting for the belt to confirm a speed each get an explicit budget, and
   expiry lands in a state the UI can explain (`.notFound`, with a hint and a retry button)
   rather than an indefinite spinner. This is a standing invariant for this codebase: a phase
   with no deadline reads to the user as a frozen app.
8. **Speed programs are integer-valued and clocked by the belt.** Program speeds are stored as
   whole 0.1 km/h units (the protocol's own unit) rather than `Double` km/h, so a program that
   steps by 0.1 for an hour cannot drift off the grid. The runner owns no timer: it is advanced by
   the belt's ~1 Hz status stream, which means a program structurally cannot run while
   disconnected, and pausing the belt pauses the program. Manual speed control cancels a running
   program rather than fighting it. Adding an algorithm is one `SpeedProgram.Kind` case plus one
   branch in `SpeedSequence.next`; the sequence logic is pure and therefore covered by
   `padctl selftest`.
9. **Walk history is delta-recorded and stored as JSON in Application Support.** The belt's
   counters are cumulative and reset only when it sleeps, so each session is recorded as a delta
   against a baseline captured when walking began; recording the raw counters would re-count an
   earlier walk every time someone resumed without resetting the belt. History lives in a file
   rather than `UserDefaults` because the dataset grows without bound, and writes are atomic so an
   interrupted save cannot truncate it. Aggregation (`WalkStats`) is pure and therefore covered by
   `padctl selftest`, including the disk round trip.
10. **The write queue is a separate value type** (`CommandQueue`), so its two correctness rules —
   control frames outrank status polls, and coalescing replaces *in place* — are verified in
   `padctl selftest` without a CoreBluetooth session.

## Rationale

- The protocol is small and fully understood, so a dependency-free native app is less work to
  maintain than any cross-platform shell, and it gets Charts, menu-bar integration and correct
  window behaviour for free.
- Hand-assembling the bundle avoids committing a large generated `.xcodeproj` and keeps the
  build reproducible from the command line, which matters because the machine cannot currently
  build one anyway.
- Splitting the protocol into `WalkingPadKit` is what makes the self-test possible: the parsing
  and framing logic is verified against a real captured status frame with no hardware attached.
- The command queue is not an optimisation but a correctness requirement: writing on every
  slider tick makes the belt ignore most of the writes, which reads as an unresponsive app.
- The belt reports no calories at all, so estimating them in the app is the only option; naming
  the formula and marking the number "estimated" keeps it honest.

## Consequences

- Ad-hoc signing means the code signature changes on every rebuild, so macOS may ask for
  Bluetooth permission again after a rebuild. A real signing identity would fix this.
- Without a test framework, the self-test carries no coverage tooling and cannot use test
  fixtures or mocking libraries; assertions stay plain and explicit.
- Belt-side preferences are write-only: the belt never reports them back, so the settings UI
  shows what this app last sent rather than the belt's true state.
- Two classes of defect dominated the bugs found after the first build, and both are worth
  watching for in review: SwiftUI bindings written back during body evaluation (`@Published`
  publishes even on no-op writes, which loops forever at 100% CPU), and asynchronous phases with
  no deadline. Neither is visible in a happy-path test with hardware attached.
- `padctl`'s hardware commands only work from an interactive terminal that holds the Bluetooth
  permission. In a non-interactive shell there is no responsible app for macOS to attribute the
  prompt to, and the process is terminated rather than prompted. `padctl selftest` is unaffected.
