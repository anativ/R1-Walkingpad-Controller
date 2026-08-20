# WalkingPad R1 Pro Controller — working notes

A native macOS app (SwiftUI + CoreBluetooth) that monitors and controls a KingSmith WalkingPad
treadmill over BLE. No dependencies, no vendor account.

## Git workflow for this repo

**Push directly to `main`. No branch, no pull request, no review gate required.**

This is a deliberate exception to the global "never commit or push to main" rule — it applies to
this repository only, and it was set by the repo owner. Just commit and push.

## Build, run, verify

```bash
./build.sh --run        # verify + build + assemble dist/WalkingPad.app + launch
./build.sh --install    # also copy to /Applications
./dist/padctl selftest  # protocol + program checks, no hardware needed
```

`build.sh` runs `padctl selftest` before every build; if it fails, the build stops.

## Environment constraints (they shape the design — do not "fix" them)

- This machine has the Xcode **Command Line Tools only**, no full Xcode. The CLT SDK ships AppKit,
  SwiftUI, Charts and CoreBluetooth but **neither XCTest nor swift-testing**, so `swift test`
  cannot run. Tests live in `Sources/padctl/ProtocolChecks.swift` and run as `padctl selftest`,
  which exits non-zero on failure. **Add a check there for every behaviour you fix.**
- There is no Xcode project by design; `build.sh` assembles and ad-hoc signs the bundle by hand.
- CoreBluetooth needs a signed bundle whose Info.plist carries `NSBluetoothAlwaysUsageDescription`.
  macOS grants Bluetooth to **no** bare executable, which is why `padctl` ships as its own
  `dist/padctl.app` with a wrapper script. Its hardware subcommands only work from an interactive
  terminal that holds the Bluetooth permission — never from a script or an agent shell.
- Ad-hoc signing means the signature changes every rebuild, so macOS may re-ask for Bluetooth
  permission after a rebuild.
- **Never `--install` while the app is running.** Replacing the bundle of a running, ad-hoc-signed
  app makes macOS terminate it, which kills a walk or program in progress. `build.sh --install`
  now refuses to do this unless `FORCE_INSTALL=1`. To hand over a new build without disturbing a
  running session, build only (`./build.sh`) and let the user quit and relaunch.

## Verifying GUI behaviour

Screen Recording and Accessibility are not granted here, so `screencapture` and System Events
cannot see the app. Verify through unified logging instead:

```bash
/usr/bin/log show --predicate 'subsystem == "io.nativ.walkingpad"' --last 5m --info --debug
```

`ps -o %cpu` catches render loops; `sample <pid>` finds the hot stack; crash causes are in
`~/Library/Logs/DiagnosticReports/*.ips` (JSON after the first line).

## Invariants — break these and the app looks broken

1. **Every asynchronous phase needs a deadline and a terminal state.** Scanning, connecting + GATT
   discovery, and waiting for a speed confirmation each have a budget that lands in a state the UI
   can explain. A phase with no deadline reads to the user as a frozen app.
2. **Never expose observable state as `@Published` when a custom `Binding(get:set:)` writes to it.**
   `@Published` publishes on *no-op* writes too, and SwiftUI writes bindings back during body
   evaluation — that combination pegs a core at 100% forever and the app stops responding even to
   a quit event. Back such properties by hand and drop equal writes before `objectWillChange.send()`.
   See `AppModel.settings` and `AppModel.program`.
3. **The belt drops commands sent less than ~0.7 s apart.** All writes go through
   `CommandQueue`, which spaces them, lets control frames outrank status polls, and coalesces
   repeats **in place** (re-appending would reorder a `mode → start → speed` sequence).
4. **Speed changes only apply in manual mode on a running belt**, so setting a speed from a
   standstill must send mode → start → speed.
5. **Speeds are integers in 0.1 km/h units** wherever they are stored or stepped, never `Double`
   km/h — a program stepping by 0.1 for an hour must not drift off the grid.
6. **The user's speed ceiling always wins** (default 6.0, hard max 10.0). This drives a motorised
   treadmill someone is standing on; clamp at the last moment before the write.

## Layout

```
Sources/WalkingPadKit/   protocol, BLE controller, metrics, programs, history  (no UI)
Sources/WalkingPad/      SwiftUI app
Sources/padctl/          CLI diagnostics + the check suite
Support/                 Info.plist for the app and for padctl
tools/MakeIcon.swift     draws AppIcon.icns
docs/adr/                architecture decision records — add one for consequential decisions
```

The BLE protocol was reverse engineered by
[ph4r05/ph4-walkingpad](https://github.com/ph4r05/ph4-walkingpad); this is an independent native
Swift implementation. Not affiliated with KingSmith.
