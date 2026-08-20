# WalkingPad for macOS

A native macOS app to monitor and control a KingSmith WalkingPad treadmill (R1 Pro, and the
A1/C1/P1 family — they all speak the same Bluetooth protocol) over BLE. No dependencies, no
vendor account, no phone required.

![built with SwiftUI + CoreBluetooth](https://img.shields.io/badge/SwiftUI-CoreBluetooth-blue)

## What it shows

Everything the belt reports, plus what can be derived from it:

Plus a full walk history: every session saved automatically, with per-day/week/month stats,
charts and CSV export — see [History](#history).

Calorie estimates use your own body data — see [Calories](#calories).

| From the belt | Derived in the app |
| --- | --- |
| Current speed, belt state, mode | Pace (min/km or min/mi) |
| Elapsed time, distance, steps | Cadence (steps per minute) |
| Last app-requested speed | Calories (estimated — the belt reports none) |
| Controller button, raw frames | Average speed, peak speed, session speed chart |
| The belt's own last stored session | |

## What it controls

- Speed, via slider, ±0.5 buttons, or one-tap presets — in 0.1 km/h steps, finer than the
  belt's own remote allows
- **Walk / Run** — Run unlocks the belt's full range up to 10 km/h
- Automatic speed programs — see [Programs](#programs-speed-algorithms)
- Start / stop, with Space bar as a panic stop and ⌘. as an emergency stop
- Mode: manual, automatic, standby
- Belt-side settings: max speed, start speed, sensitivity, child lock, display units,
  intelligent start, and a distance/calorie/time session target
- A live speed readout in the menu bar — see [Menu bar](#menu-bar)

## Walk and Run

The speed card has a **Walk / Run** switch. Walk caps the slider, presets and programs at your
configured ceiling (6.0 km/h by default) so a stray drag cannot ask for a jog. **Run** lifts that to
10 km/h, the R1 Pro's hardware maximum, and swaps the presets for a running ladder
(2 · 4 · 6 · 7 · 8 · 10).

Switching to Run only unlocks the range — it never changes the belt's current speed, so it cannot
make the belt speed up under you. Switching back to Walk *does* pull anything above the walking
ceiling back down, including a running program, because a lowered limit has to reach the hardware.

10 km/h is the last word regardless of settings: a nonsense or corrupted ceiling falls back to the
belt's minimum rather than upward, since this is a safety limit.

## Menu bar

The live speed sits in the macOS menu bar as a plain number, in place of an icon, so it stays
visible whether the window is focused, minimised, closed, or hidden entirely. Pick what it shows in
Settings › App › **Menu bar shows**:

| Option | Example |
| --- | --- |
| Icon only | 🚶 |
| Speed (default) | `5.0` |
| Speed and distance | `5.0 · 1.24 km` |
| Speed and time | `5.0 · 22:14` |
| Speed and steps | `5.0 · 2841 steps` |

The icon appears only when there is nothing to report — no belt connected, or "Icon only" chosen.
Clicking it gives the speed with its unit, elapsed time, steps, distance, calories, program status,
start/stop, faster/slower, and a way back to the window or the history.

Turn on **Menu bar only (hide Dock icon)** to run it as a pure menu-bar app with no Dock icon and no
app-switcher entry. Enabling it keeps the menu-bar item on, since hiding both would leave a running
app with no icon, no window and no menu to quit from.

### The beep

The belt beeps every time it accepts a command, and that **cannot be turned off from this app**.
Neither reverse-engineered protocol implementation
([ph4r05/ph4-walkingpad](https://github.com/ph4r05/ph4-walkingpad),
[darnfish/walkingpad](https://github.com/darnfish/walkingpad)) exposes a sound, volume or mute
preference — the belt's settable preferences are limited to max speed, start speed, intelligent
start, sensitivity, display, units, child lock and session target — and KingSmith's own app has no
mute either. The beep is firmware-level acknowledgement of a received command, not something the
protocol controls.

Status polling is silent, so an idle connection makes no noise. The only lever from software is how
often a program changes speed: a larger `Change by` over a longer interval means fewer beeps per hour
for the same walk. Beyond that the reported fixes are physical — damping or removing the panel
speaker.

## Programs (speed algorithms)

A **program** drives the belt speed for you. The built-in `Up / down` algorithm ramps from a minimum
to a maximum one step at a time, then back down, repeating — every parameter editable and savable:

| Parameter | Default | Meaning |
| --- | --- | --- |
| Minimum | 4.0 km/h | Bottom of the band, and where the program starts |
| Maximum | 5.5 km/h | Top of the band |
| Change by | 0.1 km/h | Speed change per step |
| Every | 2:00 | Time between changes |

With the defaults that produces exactly:

```
4.0 → 4.1 → 4.2 → … → 5.4 → 5.5 → 5.4 → 5.3 → … → 4.1 → 4.0 → 4.1 → …
```

Endpoints are visited once per lap, not twice. A lap is 30 steps, one hour at the default interval.
Set `Change by` equal to the whole band and you get a plain two-speed interval program instead.

**Save** stores the current parameters as that program's defaults; **Save as…** keeps them under a new
name, and the *Saved* menu loads or deletes them. Everything persists across launches.

Rules worth knowing:

- Speeds are held in whole 0.1 km/h units — the belt's native step — so a long program can never
  drift to 5.499999. Programs are always set in km/h even if the app displays miles, because 0.1 mph
  is not representable on this hardware.
- The program is clocked by the belt's own status stream, so it cannot advance while disconnected.
- Pausing the belt pauses the program (after a 10s grace, so spin-up doesn't trip it) and it resumes
  from the same step rather than burning through the schedule while you stand still.
- **Changing speed by hand, or stopping the belt, ends the program.** That is deliberate: otherwise
  the next step would override you, and a Stop press would look ignored.
- Your app speed ceiling always wins. Lower it mid-program and the program is pulled down with it;
  lower it below the whole band and the program stops.

Adding another algorithm means one case in `SpeedProgram.Kind` and one branch in `SpeedSequence.next`.

## History

Every walk is saved automatically — no button to press. The dashboard shows an **All time** row
(total distance, total walk time, average speed, walk count) and **⌘Y** opens the History window:

- Lifetime totals, including the walk currently in progress
- Distance / time / steps / calories charted per **day, week or month**, with the days you did not
  walk shown as gaps rather than closed up
- Averages per active day, week and month, plus how many active periods there were
- Highlights: current day streak, best day, best month, longest walk
- A sortable, selectable table of every walk, with delete and **CSV export**

Sessions are stored as JSON in `~/Library/Application Support/WalkingPad/sessions.json`, written
atomically so an interrupted save cannot truncate your history.

A walk starts when the belt begins moving and ends when the belt's counters reset, when it has been
idle for two minutes, or when the app disconnects or quits. Walks under 30 seconds or 20 steps are
discarded so a nudge of the belt does not become an entry.

One subtlety worth knowing: the belt's counters are **cumulative** and only reset when it sleeps, so
each walk is recorded as a delta against a baseline captured when walking began. Without that, a
second walk on the same belt session would silently re-count the first walk's distance. There is a
check pinning exactly that.

Averages are taken over periods that *had* a walk, not over the whole calendar — "average per day"
answers "on days I walked" rather than being diluted by rest days.

## Quitting, and closing the window

These are different, and the difference matters when a treadmill is involved.

**Closing the window** (red X or ⌘W) changes nothing. The app keeps running in the menu bar, the
speed readout keeps updating, a running program keeps stepping, and the walk keeps recording.

**Quitting** (⌘Q) never stops the belt by itself — a remote going away does not change what the
machine is doing. Settings › App › **When quitting** decides what happens when the belt is actually
running:

| Option | Behaviour |
| --- | --- |
| Ask me (default) | Confirms, showing the current speed: *Stop Belt and Quit* / *Leave Running* / *Cancel* |
| Leave the belt running | Quits silently, belt keeps going |
| Stop the belt | Sends a stop and waits for the belt to confirm before quitting |

Stopping waits up to 6 seconds — enough for the command queue's spacing plus the belt's ramp down —
and then quits regardless. A quit must never hang on hardware.

Either way, quitting ends any running **program**, so the belt holds its last speed rather than
continuing to change. The prompt says so when a program is active. The walk in progress is always
saved first.

None of this applies when the belt is already stopped or not connected: the quit is immediate, with
no prompt.

## Calories

The belt reports no calories at all, so the app estimates them from your body data in
Settings › App › **Body data**. Every field can be typed directly or stepped:

Find it under Settings (**⌘,**) › **Calories**.

| Field | Affects |
| --- | --- |
| Weight (kg or lb) | The walking cost itself — this is the number that matters most |
| Height | The walking cost, via the ACSM equation |
| Age, Sex | Only the resting-metabolism baseline, so only the net figure |

**Gross vs net.** Gross counts everything burned while walking, including what you would have burned
sitting still. Net subtracts resting metabolism (Mifflin-St Jeor) and is the extra the walk actually
cost you — the honest number to compare against food. Toggle **Show net calories** to switch; every
display follows it, and the tile says which one you are looking at.

The stored figure is always gross, integrated against the belt's own clock while you walk, so
switching to net never loses data — it is derived on the fly.

**Correcting your weight later.** Stored calories were computed against whatever body data was set at
the time, so fixing your weight afterwards would otherwise only affect future walks. **Recalculate
calories** in the same settings section recomputes every recorded walk from its duration and average
speed using your current body data, and tells you how many changed.

These are estimates from a published formula, not measurements. Treat them as indicative.

## Build and run

Requires only the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is optional.

```bash
./build.sh --run
```

That verifies the protocol layer, compiles, generates the icon, assembles and ad-hoc signs
`dist/WalkingPad.app`, and launches it.

```bash
./build.sh              # just build
./build.sh --install    # build and copy to /Applications
UNIVERSAL=1 ./build.sh  # universal arm64 + x86_64 binary
```

**First launch:** macOS asks for Bluetooth permission. Allow it, or the app cannot see the belt.
Because the app is ad-hoc signed, its signature changes on every rebuild, so macOS may ask
again after you rebuild. Grant it under System Settings › Privacy & Security › Bluetooth.

Turn the belt on and put it in standby (not off) before connecting. The app scans for the
WalkingPad BLE service, and falls back to matching on device name after a few seconds.

## Troubleshooting with padctl

`dist/padctl` is a CLI for when the GUI cannot find the belt:

```bash
./dist/padctl selftest      # verify the protocol layer, no hardware needed
./dist/padctl watch         # connect and stream live status frames
./dist/padctl speed 3.0     # start the belt at 3.0 km/h
./dist/padctl stop          # stop the belt
```

`selftest` runs anywhere. The hardware commands need Bluetooth permission, which macOS grants
to the *terminal app you run them from* — so run them from Terminal or iTerm and allow the
prompt. They will not work from a non-interactive shell (a script, a CI job, an agent), because
there is no app for macOS to attribute the permission to; the process is killed on the spot.

For the same reason `padctl` ships as `dist/padctl.app` with a thin `dist/padctl` wrapper:
macOS refuses Bluetooth to a bare executable even when the usage description is linked into its
`__TEXT,__info_plist` section, so the tool has to be the main executable of a real bundle.

## How it works

The belt exposes a BLE service `FE00` with notify `FE01` and write `FE02`. Frames are
`F7 <cmd> <payload…> <crc> FD`, where the CRC is the low byte of the sum of everything
between the header and the CRC.

| Command | Frame |
| --- | --- |
| Ask for status | `F7 A2 00 00 A2 FD` |
| Set speed (0.1 km/h units) | `F7 A2 01 <speed> <crc> FD` |
| Set mode (0 auto, 1 manual, 2 standby) | `F7 A2 02 <mode> <crc> FD` |
| Start belt | `F7 A2 04 01 A7 FD` |
| Ask for stored session | `F7 A7 AA FF 50 FD` |
| Set preference | `F7 A6 <key> <type> <b2 b1 b0> <crc> FD` |

Status frames arrive as `F8 A2 …`: belt state at byte 2, speed×10 at byte 3, mode at byte 4,
then big-endian 24-bit elapsed seconds, distance in 10 m units, and steps. The parser is
verified against a real captured frame in `padctl selftest`.

Two behaviours worth knowing, both handled by the app:

- **The belt ignores commands sent less than ~0.7 s apart.** All writes go through a spaced,
  coalescing queue; dragging the slider commits once on release rather than spamming writes.
- **Speed changes only apply in manual mode on a running belt.** Setting a speed while stopped
  transparently sends mode → start → speed.

## Layout

```
Sources/WalkingPadKit/   protocol, BLE controller, metrics  (no UI, headlessly testable)
Sources/WalkingPad/      SwiftUI app
Sources/padctl/          CLI diagnostics + protocol self-test
Support/                 Info.plist for the app and the CLI
tools/MakeIcon.swift     draws AppIcon.icns
docs/adr/                architecture decision records
```

There is no test target: this toolchain's SDK ships neither XCTest nor swift-testing, so the
protocol assertions are compiled into `padctl selftest`, which `build.sh` runs on every build.
See [ADR 0001](docs/adr/0001-macos-app-architecture.md).

## Safety

This app drives a motorised treadmill. The in-app speed slider is capped by a configurable
ceiling (default 6.0 km/h, hard limit 10.0 km/h). Space bar always stops the belt. Don't set a
speed you are not ready to walk at, and keep the belt's own remote within reach.

## Credit

The BLE protocol was reverse engineered by
[ph4r05/ph4-walkingpad](https://github.com/ph4r05/ph4-walkingpad); this app is an independent
native Swift implementation of it. Not affiliated with KingSmith.
