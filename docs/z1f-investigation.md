# WalkingPad Z1F — investigation report

Status as of 3 September 2026, app v1.7. The belt under test is on another Mac; every fact
below comes from its diagnostics logs, from public reverse-engineering work, or from the code.

## Summary

The KingSmith WalkingPad Z1F (model WP400F4, Bluetooth name `KS-HD-Z1D`, firmware V0.0.6)
connects to the app cleanly: services are discovered, every read returns data, every
notification subscription is confirmed by macOS, and every write is accepted. It then sends
**nothing at all** — no live data, no command acknowledgements, no replies on the vendor
channel — across seven builds and four distinct approaches. The KS Fit phone app and the
belt's remote work, so the belt is healthy and something in the exchange is missing.

The strongest remaining explanation is that firmware V0.0.6 does not use the standard
Fitness Machine Service for anything and is driven instead over a second, obfuscated text
protocol on the vendor service — the path the KS Fit APK takes on newer belts. v1.6 speaks
that protocol; whether this belt has the characteristic pair for it, and answers, is what the
next log will show.

## The device

| Fact | Value | Source |
| --- | --- | --- |
| Model | WalkingPad Z1F, WP400F4, 2025 | Label photo |
| Bluetooth name | `KS-HD-Z1D` | Log, v1.2 onward |
| Firmware | `V0.0.6` | Software Revision read, v1.3 |
| FTMS features | machine `0x00001244`, target `0x00000001` | Feature read, v1.3 |
| Speed range | 1.0–6.0 km/h, 0.10 steps | Supported Speed Range read |
| Signal | −59 to −67 dBm | Log |
| Services seen | FTMS `1826`, vendor `24E2521C-…-C5330A00FDF7`, Device Information `180A` | Discovery |
| Characteristics confirmed | `2ACC` `2ACD` `2AD3` `2AD4` `2AD9` `2ADA`, vendor `…0B00` (notify) `…0D00` (write), `2A28` | Discovery (only requested UUIDs were listed before v1.6) |

The other Z1F on public record — mcdax/walkingpad-controller issue 3 — has the **same
firmware and the same feature bits**, and failed the same way with a different library:
connected, reads fine, every Control Point command timed out, belt never started.

## What is confirmed

- **Scan, connect, discovery all work.** Found at once on the FTMS service filter.
- **Reads work.** Features, speed range and firmware all came back with sensible values.
- **Subscriptions are really on.** macOS reported the descriptor written for `2ADA`, `2AD3`,
  `2AD9`, `2ACD` and the vendor notify characteristic. This was verified after v1.2 made the
  bring-up wait for each confirmation instead of running on timers.
- **Writes are accepted at the Bluetooth level.** No write error was ever logged, including
  Control Point writes with response.
- **The belt sends nothing.** Not a Treadmill Data frame at idle, not the stale
  Fitness Machine Status replay the firmware normally emits the instant you subscribe, not a
  Control Point result code (even to Request Control), not a reply to any vendor frame.
- **The belt itself works** with the KS Fit app and the remote (reported by the owner).
- **The app's own machinery works.** The classic R1 Pro path is unchanged and in daily use;
  88 selftest checks cover the FTMS codec, the vendor frames, the text protocol codec, the
  handshake against a simulated belt, and the safety clamps.

## What was tried, in order

| Build | Hypothesis | Change | Belt's answer |
| --- | --- | --- | --- |
| v1.1 | Z1 speaks standard FTMS like other `KS-HD` belts | FTMS dialect: subscribe, request control, start, speed held until moving | Silence (log tail only; first report was a screenshot) |
| v1.2 | "Ready" declared before notifications were on | Confirmation-driven bring-up; every enable waited for | Silence; all five enables confirmed |
| v1.3 | Parser dropped frames with the "More Data" flag set | Length-based speed detection; unreadable frames logged | Silence; not one unreadable frame either |
| v1.3 | Firmware wants the KS Fit "property list" handshake (an MC-21 frame) | `01 00 0d 00 06 0b 0f 0d` and `20 00 00 00 20` on the vendor write char | No reply |
| v1.5 | Belt is in standby and ignores FTMS until woken | Vendor **wake** `72 01 03 0a 00 00 80` and status query `72 00 00 72` | No reply |
| v1.6 | V0.0.6 does not talk FTMS at all; KS Fit uses the obfuscated **text protocol** on the vendor service's second pair (`…0E00` / `…0F00`) | Discover every vendor characteristic; eight-step handshake; `props` commands; polled status | **Not yet tested on the belt** |
| v1.7 | — | One-click diagnostics report to the Desktop | — |

Two things were fixed along the way that were real but not the cause: the timer-based
bring-up (v1.2) and the strict "More Data" handling (v1.3). A code review also closed two
safety gaps unrelated to the Z1F, where a speed above the ceiling could have reached a belt.

## Why the earlier explanations fell

- **Timing race.** The owner's diagnosis; plausible, fixed in v1.2. The v1.2 log then showed
  every enable confirmed *before* "Ready", and still no data. Not the cause.
- **Parser too strict.** A Z1F that set the "More Data" flag on every frame would have been
  parsed as silence. v1.3 reads by length and logs anything unreadable. Nothing was logged.
  Not the cause: frames are not arriving.
- **Property-list handshake.** Borrowed from the MC-21 model's ODM channel. The KS Fit
  decompilation says the same frame builder serves the `KS-HD` supplement channel, but the
  frame drew no reply. Either the wrong bytes or the wrong channel.
- **Asleep belt.** Three projects drive a `KS-HD-Z1D` with plain FTMS, and the Swift one
  ships a wake command for this vendor service. A sleeping belt would explain total silence.
  The wake frame was accepted and changed nothing — and the owner has surely tried with the
  display awake. Very likely not the cause, though "belt awake, display on" is still worth
  stating explicitly in the next test.

## Current best understanding

1. **Firmware V0.0.6 does not speak FTMS in practice.** Two independent implementations on
   two operating systems (this app on macOS; walkingpad-controller on Linux) get nothing from
   a V0.0.6 belt. The implementations that succeed with a `KS-HD-Z1D` never state a firmware
   version and are presumably on different firmware.
2. **KS Fit drives newer belts over a text protocol.** The c3p0 project, built from the KS
   Fit APK, documents it: ASCII commands (`props runState 1`, `props CurrentSpeed 3.5`,
   `servers getProp 1 2 3 …`), base64-encoded, each character swapped through one of seven
   substitution tables, terminated by a carriage return, written in 16-byte pieces. An
   eight-step greeting (`""` → "format error", `shake`, `net`, `get_dn`, `get_pk`,
   `time_posix <epoch>`, `version`, `servers getProp …`) reveals which table the belt uses.
   The reply fields — `runState`, `ControlMode`, `CurrentSpeed`, `RunningTotalTime`,
   `RunningDistance`, `RunningSteps` — are the classic WalkingPad status frame under text
   names, which strongly suggests this is the same firmware lineage behind a new transport.
3. **The pair for it lives on the vendor service** as `…C5330E00FDF7` (notify) and
   `…C5330F00FDF7` (write). The FTMS reverse-engineering notes list exactly these two as
   present "in v6 only". The belt's firmware is V0.0.**6**. Until v1.6 the app never asked
   the belt whether it had them.

## What is not known

- **Whether this belt exposes the `…0E00` / `…0F00` pair.** Discovery before v1.6 asked only
  for named UUIDs. The v1.7 report lists every characteristic per service with its properties.
- **Whether the greeting is complete.** c3p0's sequence may assume prior state (a bonded
  phone, a previous `time_posix`), and the substitution-table list may not include this
  belt's table. The report shows every decoded reply, or "not decodable" with the raw bytes.
- **Whether KS Fit on the owner's phone still holds a connection.** KS Fit has a
  "stay connected" mode that reconnects in the background. A belt with two centrals may
  serve reads to both but talk to only one. Every test so far assumed the phone was out of
  the picture; that was never confirmed.
- **Whether macOS is serving a stale GATT cache.** CoreBluetooth caches a peripheral's
  service table. If the belt's firmware was updated after the Mac first saw it, new
  characteristics can stay hidden until Bluetooth is turned off and on.
- **Whether the vendor init frames matter.** The Swift SDK sends `71 00 05 64 91 5A 31 44 …`
  (a model identifier ending in "Z1D") and a timestamp frame before its legacy queries. The
  app does not send these; they may be what unlocks the `WLR` status replies on the
  `…0B00` / `…0D00` pair.
- **What the belt does with FTMS at all on this firmware.** Perhaps nothing; perhaps only
  after the text greeting. Unknown until something answers.

## Next steps, in order

1. **Run v1.7 on the belt and send the report.** Belt awake, display on, KS Fit fully
   closed on the phone (better: phone Bluetooth off). Connect, press Start, press
   *Save diagnostics…*, send the Desktop file. Three lines decide the next move:
   - `Service 24E2521C-…: …` — does it list `…0E00` and `…0F00`?
   - `KingSmith text channel present — starting its handshake` followed by `KS: …` replies.
   - `Handshake not completed within 10s` — pair present, belt not answering.
2. **If the pair is missing:** turn Bluetooth off and on (clears the GATT cache), retry once.
   If still missing, the belt has no text channel and the answer must come from a capture.
3. **If the pair answers but stops mid-greeting:** the reply text shows which step; compare
   against c3p0's expected tokens; the table list may need a new entry.
4. **If nothing answers on any channel:** capture what KS Fit sends. On Android: Developer
   options → *Enable Bluetooth HCI snoop log*, run KS Fit, start and stop the belt once, pull
   the log with `adb bugreport`. On iPhone: Apple's Bluetooth logging profile and
   PacketLogger. One capture ends the guessing.
5. **Then try the vendor init frames** (`71 00 …Z1D`, `71 01 …timestamp`) before the
   status query, if the capture shows KS Fit doing so.
6. **Consider a firmware update through KS Fit** and re-read `2A28`. If the belt moves off
   V0.0.6, the plain FTMS path may simply start working, as it does for other owners.

## References

- mcdax/walkingpad-controller — FTMS reference and issue 3 (the other Z1F, same firmware)
- mcdax/walkingpad-controller `docs/ftms-protocol-reference.md` and
  `docs/ks-fit-reverse-engineering.md` — KS Fit decompilation, "v6 only" characteristics
- kkz6/WalkingPadSDK — vendor frame layout, wake/sleep/init commands, tested on a `KS-HD-Z1D`
- while-loop/c3p0 — the KS Fit text protocol: tables, greeting, `props` commands
- jrosskopf/padctl — plain FTMS verified on a `KS-HD-Z1D`; a real Treadmill Data capture
- raine/WalkingMate and TreadmillTrace — Z1 support added after user reports; probe tool
- ph4r05/ph4-walkingpad — the classic protocol this app was built on
