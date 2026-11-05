# 003 — Acceptance test plan

Designed by the tester agent (2026-10-29) without reading the implementation. Type names are
placeholders; the assertions are what count. Lead defaults for the open decisions are in the
brief's "Engineering decisions" section.

## Fixtures
- **F1** Bundled example recording: montage `"international 10-10 (BCI2000 64-ch subset), cropped to 16"`,
  reference `"per dataset documentation"` (not a label), 16 labels FC3 FC1 FC2 FC4 C5 C3 C1 Cz C2 C4 C6
  CP3 CP1 CPz CP2 CP4 (already normalized from EDF `Fc3.`).
- **F2** In-memory manifest builders: montage, reference, labels.
- **F3** Isolated `UserDefaults(suiteName:)` per test for the first-run flag.
- **F4** Debug launch args: `-BCIIntroStep N`, `-BCIReduceMotion YES`, `-BCIResetFirstRun YES`,
  `-BCIMontageView top|left|right|front`, plus existing `-BCISnapshotDir`, `-BCIAppearance`, `-BCIQuitWhenDone`.

## A. Intro
| # | Criterion | Automated | Headless | Manual |
|---|---|---|---|---|
| 1 | First launch only (#7) | flag unset → intro step 0; set → welcome; no session opens during intro | two launches sharing a defaults suite | Release build, fresh defaults domain |
| 2 | 4 steps, specified content | order `[whatItDoes, honestUncertainty, tryExample, hardwarePhase2]`; non-empty title/body | snapshot each step, light + dark | PM reads copy |
| 3 | Ends on welcome, Explore focused | after Next ×4 mode = welcome, focus = exploreExample | snapshot shows focus ring | Return/Space triggers example |
| 4 | Skip / Back / Next / arrows / Return / Esc | next clamps; back at 0 no-op; skip from every step → welcome; key map | synthetic Esc on step 2 | Esc not swallowed; Return on focused Skip |
| 5 | Help ▸ Show Welcome Tour | replay → intro step 0, flag untouched | menu item present | with project window open (E3) |
| 6 | Neural-field motion | particle state deterministic per seed, in bounds; trace progress monotonic 0…1 | per-step snapshots | macOS 26 morph; macOS 15 cross-fade |
| 7 | 60 fps | frame-stats helper (p99, drops) on synthetic input | frame log: p99 ≤ 16.7 ms, none > 25 ms | Instruments Animation Hitches = 0, also in Low Power |
| 8 | Reduce Motion | policy disables particles/trace/morph; transition cross-fade or none; trace fully drawn | two snapshots 2 s apart identical | toggle live |
| 9 | Reduce Transparency | surface policy solid | snapshot pixel behind panel uniform | toggle live; Increase Contrast ≥ 4.5:1 |
| 10 | VoiceOver | step label = title then body; decoration hidden; Skip first | Accessibility Inspector audit | VoiceOver walk, no stray chatter |
| 11 | Own motifs (#9) | — | `grep -ri neuralink App Sources` empty | reviewer |
| 12 | ≤ 2 MB, no video/network | bundle has no mov/mp4/m4v | size measurement below | entitlements unchanged |
| 13 | No performance claims (#8) | step 2 has no claim words, shows a range, never labels CI as balanced accuracy | snapshot step 2 | PM reads |

## B. Live montage view
| # | Criterion | Automated | Headless | Manual |
|---|---|---|---|---|
| 14 | Standard positions, labels, reference | F1: 16 placed, 0 unplaced; Cz vertex, C3 left / C4 right mirrored, FC anterior, CP posterior; free-text reference marks nothing | example Recording snapshot | compare to a 10-10 chart |
| 15 | Only declared named montage + standard label | see B1 | "unspecified" snapshot | custom montage project |
| 16 | Cross-highlight | table → electrode, electrode → row, hover clears, unplaced selects nothing, by channel id not label | — | hover both ways |
| 17 | Orbit + presets, Reduce Motion snaps | presets yaw/pitch; reset; drag clamps pitch, wraps yaw; RM duration 0 | one snapshot per preset | keyboard, trackpad, mouse; drag doesn't scroll table |
| 18 | VoiceOver strings | `"Montage: 16 of 16 channels placed, <montage>"`; 14 of 16; unspecified → 0 of N; electrode button = label | — | VoiceOver walk |
| 19 | No per-channel colour (#17) | electrode style uniform except selected/hovered; model has no value field | pixel equality of two electrodes | review |
| 20 | Head from code | bundle has no usdz/usd/reality/obj/dae/scn | — | — |
| 21 | Intro map matches head | both read the same table and geometry | compare snapshots | A/B |
| 22 | intro + head ≤ 2 MB | — | measurement | — |

### B1. Recognizer adversarial cases
- Montage: `unspecified` in any case/whitespace, empty → undeclared. Free text mentioning 10-20
  (`"custom cap, roughly 10-20 but modified"`, `"not 10-20"`) → undeclared. Example string → 10-10.
  `international 10-5`, `10-10x` → not recognized. Full 10-20 label set under `unspecified` → still
  undeclared (never inferred from channel count). Recognized montage, 0 channels → "0 of 0", no crash.
- Labels: case variants, trailing dots (`Fc3.`, `Cz..`), outer whitespace per the rule; interior
  whitespace, `C3x`, `FC30`, `CP`, Cyrillic/full-width lookalikes → unplaced. `EOG`, `ECG1`, `X1` →
  unplaced, never snapped to nearest. FC3 under a 10-20 declaration → per the rule. T3/T7 resolve to one
  point. Non-EEG kinds excluded from M consistently. Duplicates: placed + unplaced == M (property test).
- Reference: equals a recorded placed label → marked; label not recorded, free text (`average`,
  `linked mastoids`), `A1+A2`, empty, or montage unspecified → no mark, caption shows declared text.

## C. First-run edge cases
E1 skip mid-step sets flag · E2 quit mid-intro then relaunch (flag set on first presentation → no replay) ·
E3 replay with a project open: sessions unchanged, no duplicate welcome window · E4 replay during intro
restarts at step 0, no overlapping timelines · E5 replay never clears flag · E6 closing welcome mid-intro
behaves like E2 · E7 opening the example cancels intro timelines (CPU idle) · E8 garbage defaults value
doesn't crash · E9 welcome stays 760×460 in both modes · E10 minimized/occluded pauses animation ·
E11 Low Power Mode reduces particle count.

## Bundle-size measurement
Build Release from the base commit and from the branch with the same `-derivedDataPath`-separated
setup and the same (or no) bundled worker; compare `du -sk` of the two `.app`s (delta ≤ 2048 KB), the
executable size, any `.metallib`, and a `find . -type f` diff of the bundles.

## Not CI-gateable
60 fps and VoiceOver stay manual (record the Instruments hitch count and the Inspector audit in the PR).
RealityView pixels aren't unit-tested; geometry goes through the pure table/camera models plus snapshots.
macOS 15 fallbacks need a macOS 15 machine or VM.
