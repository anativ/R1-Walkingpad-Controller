# 0002 — Research-backed pace algorithms, as a cycle of timed blocks

Status: Accepted

## Context

The app could already drive the belt with one algorithm: a ramp from a minimum to a maximum in
fixed steps at a fixed interval (`Up / down`). That is a good fidget-reducer, but it answers the
wrong question for the actual use case — walking 90 minutes to two hours at a desk, while typing and
while in meetings, and wanting the walk to be *worth* something rather than merely long.

Two things forced a redesign rather than another set of parameters.

**1. Published protocols are not ramps.** Almost every exercise-science result about varying walking
pace is expressed as a cycle of timed blocks at different intensities:

- **Interval walking training** (Nose & Masuki, Shinshu University; foundational 2007 RCT, n=246,
  mean age 63): three minutes fast (~70% of peak aerobic capacity) alternating with three minutes
  slow (~40%), five cycles, four days a week. Against continuous moderate walking it produced
  roughly 9% more gain in peak aerobic capacity, 13–17% more knee-extension/flexion strength, and
  about 9/5 mmHg lower blood pressure. A later 679-person cohort saw peak aerobic capacity rise
  ~14% and a lifestyle-disease score fall ~17%, **with benefits plateauing near 50 minutes of fast
  walking per week**. Karstoft et al. (2013) reproduced the fitness and glycaemic-control effects in
  type 2 diabetes.
- **VILPA** (Stamatakis et al., *Nature Medicine*, 2022; UK Biobank wearables): brief vigorous
  bursts of one to two minutes inside ordinary daily movement. Three bursts a day were associated
  with ~40% lower cancer mortality and roughly half the cardiovascular mortality; the sample median
  of 4.4 min/day tracked with 26–30% lower all-cause mortality.
- **10-20-30** (Gunnarsson & Bangsbo, *J Appl Physiol*, 2012): 30 s easy / 20 s moderate / 10 s hard,
  improving VO₂ max and 5 km time on roughly half the training volume, and lowering resting systolic
  blood pressure and cholesterol.

A single `(min, max, step, interval)` tuple cannot express "ten and a half minutes easy, then ninety
seconds hard". It can only express a ramp.

**2. The belt cannot do seconds.** `CommandQueue` spaces writes ~0.7 s apart and the belt then ramps
its motor. A literal 10-20-30 block would be a speed the belt never actually reaches, so the dose
would be imaginary. Any block short enough to be interesting has to be long enough to be real.

There is also a plain ergonomic constraint the research does not address: at 3.5–4 km/h you can type
accurately, and at 5+ km/h you cannot. The same protocol is worth walking at two different bands
depending on whether your hands are on the keyboard or you are listening in a meeting.

## Decision

1. **A program is a repeating cycle of timed blocks**, not a ramp. `SpeedProgram.cycle` resolves to
   `[PaceBlock]` — `(speed, seconds, tier)` — and `SpeedSequence.State` is a position in that cycle.
   The ramp did not go away: `gentleDrift` (formerly `upDown`) generates its ladder as a cycle whose
   blocks all share one interval, and reproduces the previous series exactly, endpoints visited once
   per lap. Its raw value stays `"upDown"` so programs saved by earlier builds still decode.

2. **Block timings come from the trials, not from a slider.** `Kind.blueprint` holds them. Only
   `gentleDrift` reads `stepRaw`/`intervalSeconds`; the editor hides those fields for the others, and
   validation ignores them, so a nonsense interval cannot invalidate a protocol that never reads it.
   The 10-20-30 shape is kept as a 3:2:1 ratio stretched to minutes and **labelled as scaled**, since
   the literal protocol is unreachable on this hardware.

3. **Intensity is expressed as a tier that resolves inside the program's own band.** `PaceTier`
   (`easy`/`steady`/`brisk`/`surge`) maps to `minRaw`, the band midpoint, or `maxRaw`. Nothing can
   land outside `minRaw...maxRaw`, which is what makes clamping the band a *complete* guarantee:
   the existing `clamped(toCeilingRaw:)` remains the only place the speed ceiling has to be applied.
   Algorithms differ in intensity by having different default bands, not by escaping their own.

4. **A pace mode supplies one anchor pace; each algorithm places its own band around it.**
   `PaceMode.work` (3.8 km/h) and `.meeting` (5.0 km/h) are the two things the user tunes — one
   slider each — and every algorithm derives its band from the anchor via fixed offsets. Switching
   mode therefore shifts all five algorithms together and preserves the shape each was studied with.

5. **Switching mode rebands a running program instead of restarting it** (`ProgramRunner.reband`).
   A meeting starting mid-walk must not zero the accumulated dose or restart the cycle.
   `reband` refuses to change the program's *kind*, so a different protocol still has to go through
   `start`.

6. **The runner counts brisk minutes, and only brisk minutes.** `workSeconds` accrues in
   `brisk`/`surge` blocks only, never while paused, and a gap in the status stream is credited at
   most `maxCreditedTickGap` (5 s) so a stalled stream cannot invent minutes. This exists because the
   50-minutes-per-week plateau is the single most actionable number in the literature, and it is
   about *fast* minutes, not total walking. A drift's upper half is deliberately never labelled
   `brisk`: variation is not interval training, and letting it count would inflate the dose with
   minutes nobody prescribed.

7. **`longDeskSession` exists because the plateau cuts both ways.** Ninety unbroken minutes of
   3-min-on/3-min-off is roughly three times the researched per-session dose, on a body that is also
   standing at a desk all day. So that algorithm banks one full dose (five intervals, 30 minutes) and
   then cruises easy for half an hour before repeating — two hours is two doses, not 45 minutes of
   brisk work.

8. **Re-finding your place after a band change is matched by block, not by speed.** Moving to a
   faster band shifts every speed at once, so "nearest speed" would drop you out of a fast interval
   into recovery — the old band's easy pace is the new band's brisk one. Nearest-speed remains the
   fallback for when the cycle's *shape* changed (a narrower drift genuinely has fewer, differently
   placed blocks).

9. **Each algorithm gets its own box with its own Start button**, and carries its evidence with it —
   goal, what was measured, and how often the trials had people do it — rather than presenting five
   protocols as five opaque names. The weakest-evidenced one (`gentleDrift`) says so in its own box.

## Consequences

- Adding an algorithm means adding a `Kind` case, its blocks, and a `PaceAlgorithm` entry. The runner
  and the UI need no changes, because they only ever see the resolved cycle. A check enforces that
  every `Kind` has a catalogue entry, so a kind cannot become unreachable from the algorithm list.
- Progress through a cycle has to be measured in time (`cycleProgress`), not in blocks: counting
  blocks would show a micro-surge jump from 0% to 50% after ten minutes and then to 100% ninety
  seconds later.
- The freehand editor and the algorithm boxes share one `ProgramRunner`, so `AppModel` tracks which
  of them started the current run (`isFreehandProgramRunning`) or both would claim it.
- `blocksPerCycle`/`cycleDuration` replace `stepsPerLap`/`lapDuration`, and `SpeedSequence.State`
  gained `index`/`seconds`/`tier` and renamed `ascending` to `isRising`.
- Meeting mode plus a wide band can exceed the 6.0 km/h walking ceiling. That is not silently
  rewritten: the box says which numbers it will be limited to, per the existing ceiling-note rule.
- The dose figure is an estimate of *scheduled* intensity, not of physiological effort. The app has
  no heart rate. Cadence (CADENCE-Adults puts moderate intensity near 100 steps/min) is displayed
  alongside but deliberately not used to drive the schedule.
