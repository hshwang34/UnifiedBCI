# 003 — First-run intro with motion

**Status:** building · **Owner:** PM · **PR:** — · **Updated:** 2026-10-29

## Problem
A first-time user opens a plain welcome window with three buttons. Nothing there tells them:
- what the app is for;
- why its numbers carry wide intervals;
- that they can try it with no hardware.

The PRD's usability gate is to reach a reproducible evaluation in under 15 minutes. That depends on the user understanding those three things before they click.

## Who it's for
A Mac-using student or independent BCI developer on the very first launch, before any project exists. It is also for anyone who replays the intro from the Help menu.

## What success looks like
- On first launch the user sees a short, striking animated intro (≤ 4 steps). It makes the app feel alive and leaves them knowing what to click.
- It never blocks them: they can skip at any moment, and it never plays again unless they ask.
- It degrades gracefully: with Reduce Motion, the same content appears as still frames; with Reduce Transparency, the glass becomes solid.

## Acceptance criteria
- [ ] On the very first launch, the welcome window plays the intro. On every later launch it opens straight to the normal welcome screen (decision #7 still holds: no project auto-opens).
- [ ] The intro has 3–4 steps:
  1. What BCI Workspace does.
  2. Results come with honest uncertainty.
  3. Try it without hardware (the example).
  4. Optionally: Connect hardware arrives in phase 2.
- [ ] The last step ends on the normal welcome screen with "Explore an example" focused.
- [ ] Every step has Skip, plus Back/Next (arrow keys and Return work). Esc skips. Skipping lands on the welcome screen.
- [ ] Help ▸ "Show Welcome Tour" replays the intro at any time.
- [ ] Motion is an expressive "neural field" (PM choice):
  - A scalp map whose electrodes light up.
  - A signal trace that draws itself.
  - Particles drifting between electrodes.
  - Glass panels morphing between steps.
- [ ] The intro runs at a steady 60 fps on an Apple Silicon Mac, with no dropped frames at step transitions (checked with Instruments or a frame-time log).
- [ ] Reduce Motion: no particle drift, trace or morph; each step is a still, designed frame and transitions are a cross-fade or instant. Reduce Transparency: glass becomes solid.
- [ ] VoiceOver:
  - Each step is announced with its title and body.
  - Decorative animation is hidden from accessibility.
  - Skip is reachable first.
- [ ] Every motif is the app's own (decision #9). No Neuralink or other third-party imagery, shapes or wordmarks.
- [ ] The intro adds ≤ 2 MB to the app. It is built in SwiftUI (Canvas / TimelineView / phase and keyframe animators / Metal shaders), with no video files and no network.
- [ ] Nothing in the intro claims performance. The uncertainty step uses the same wording rules as decision #8 and shows a range, not a promise.

### Live montage view (decisions #16–#18, added 2026-10-23)
- [ ] The Recording screen shows a stylized 3D head above the channel table. Each declared electrode sits at its standard 10-10 (or 10-20) position and carries its label; the reference is marked.
- [ ] Positions come only from a declared named montage plus a matching standard label. A recording whose montage is "unspecified", or a label with no standard position, shows "Positions undeclared" (listing the unplaced labels) — never a guess from channel count.
- [ ] Hovering or selecting a channel in the table highlights its electrode, and vice versa.
- [ ] Drag orbits the head; Top / Left / Right / Front / Reset buttons do the same from the keyboard and VoiceOver. Reduce Motion snaps to the chosen view instead of animating.
- [ ] VoiceOver reads the view as "Montage: N of M channels placed, <montage name>", and each electrode button reads its label.
- [ ] No per-channel colour or value is shown (decision #17).
- [ ] The intro's scalp map uses the same head and positions, so the two visibly match.
- [ ] The head is built from code (no model files); the intro + head together still add ≤ 2 MB.
- [ ] The head looks like study A4 in `003-glass-studies.html` (decision #20): thick-glass dome with a faint 10-10 grid and polished rim, cup electrodes, labels on leader lines that don't overlap, a faint glowing head outline beneath. Reduce Transparency makes the dome frosted-solid; Increase Contrast strengthens the outline and grid.

## Out of scope
- Account creation, telemetry or analytics of tour completion.
- Hardware setup flows (phase 2).
- Tooltips inside the project window.
- Localization beyond English.
- Sound.

## Open product questions
1. **What should the onboarding be?** Options: A, an animated first-run intro; B, motion on the welcome screen only; C, a guided in-app walkthrough. **Recommendation:** A.
   → *Answer:* A, the animated first-run intro.
2. **How bold should the motion be?** Options: A, calm and clinical; B, an expressive showpiece. **Recommendation:** A.
   → *Answer:* B, expressive showpiece. It must still honour Reduce Motion and stay at 60 fps.
3. **When should it ship?** Options: A, the next PR after PR 3 merges; B, folded into PR 3. **Recommendation:** A.
   → *Answer:* A.
4. **Step 4 (Connect hardware, phase 2):** include it, or end on "try the example"? **Recommendation:** include it as a short, honest "coming in phase 2" frame, because it sets expectations.
   → *Answer:* Include it: four steps.

## Engineering decisions (filled in by the lead while building)
- 3D: RealityKit `RealityView` with procedurally generated meshes (macOS 15+). SceneKit is in maintenance mode (WWDC25 288); USDZ assets would break the 2 MB budget.
- Intro particles/trace: `TimelineView` + `Canvas` with value-type state, paused under Reduce Motion, when occluded, and reduced in Low Power Mode. Step panels morph via `glassEffectID` inside one `GlassEffectContainer` (macOS 26), cross-fade on 15.
- Electrode coordinates: a committed table of standard 10-10 positions keyed by label (a published standard, not inference).
- Intro is a mode inside the Welcome window at its fixed 760×460 size, so `.contentSize` doesn't jump.
- Help ▸ Show Welcome Tour via `CommandGroup`; first-run flag in `@AppStorage`. Esc via `.keyboardShortcut(.cancelAction)` on Skip.
- Frame-time signposts added before shaders, to check the 60 fps criterion.
- *Writer, 2026-10-29 — lead defaults 1–7, each pinned by a test in `Tests/MontageTests.swift` / `Tests/IntroTests.swift`:*
  1. **Label lookup:** case-insensitive after trimming outer whitespace and trailing dots (`Fc3.` → FC3). Interior whitespace and Unicode lookalikes stay unplaced. The button shows the stored label verbatim. Never snapped to the nearest site.
  2. **Montage recognizer:** an explicit allow-list (`international 10-20|10-10`, optional ` system`, `/` spelling too), matched at the start of the string. Only nothing, or a suffix opening with `(`, `,`, `;` or `:`, may follow, so the example's "…(BCI2000 64-ch subset), cropped to 16" is recognized. No substring match; `unspecified` or empty means undeclared.
  3. **10-20 vs 10-10:** a 10-20 declaration places only the 21 10-20 sites (FC3 is unplaced there). A 10-10 declaration places all 86 10-10 sites.
  4. **Old names:** the table uses T7/T8/P7/P8. T3/T4/T5/T6 resolve to them only under 10-20. A second channel naming an already-placed site is listed as unplaced (duplicate), never stacked.
  5. **Reference:** marked only when the declared reference text, under rule 1, equals a recorded *and placed* label. Otherwise the declared text is shown as a caption ("average", "A1+A2" and the example's "per dataset documentation" mark nothing).
  6. **First-run flag** (`BCIHasSeenWelcomeTour` in `UserDefaults.standard`, through a small `FirstRun` type so tests can use an isolated suite rather than `@AppStorage`): set when the intro is first presented. Replay never clears it.
  7. **M counts EEG-kind channels only.** Others, including undeclared kinds, are named in the caption ("N non-EEG channels not counted (…)").
- *Writer additions:*
  - **Position source:** the 10 % grid (86 sites) of Oostenveld & Praamstra 2001, as shipped in FieldTrip/MNE `standard_1005`, committed as millimetre literals in `App/Models/StandardPositions.swift`. MNE was used once, dev-side, to export it and never ships. The head is an axis-aligned ellipsoid least-squares-fitted to those sites (largest residual 5.5 %). Markers sit where each site's direction from the centre meets that surface, so they move under 6 mm.
  - **Rendering split:** RealityKit draws only the head. Electrodes, labels, particles and the trace are a SwiftUI/Canvas overlay placed with the same camera maths (`HeadCamera.project`, a perspective camera on an orbit). That keeps every electrode a real, focusable SwiftUI button for VoiceOver and hover. `HeadStage` is `Animatable` on the orbit, so the camera and overlay interpolate together. Reduce Motion passes no animation, so views snap. The head's *look* is on hold for a PM direction; everything visual sits behind `HeadStage`/`HeadModel` so it can be swapped.
  - **Occlusion:** the intro's timeline pauses when the Welcome window is occluded or minimized (`WindowVisibilityReader`) and under Reduce Motion. Low Power Mode drops the particles from 64 to 20.
  - **Frame timing:** `FrameClock` emits an os_signpost event per frame interval ("IntroFrame") and an interval per draw ("IntroDraw"), subsystem `com.hshwang34.BCIWorkspace`, category `IntroFrames`. Debug `-BCIFrameLog <file>` appends p50/p99/max/drops plus the time of each long frame. That flag also ignores occlusion, so a measurement can run while the window is on another Space.
  - **Step 2 illustration:** a real Clopper-Pearson interval (28 of 45 trials: 0.62, CI 0.47–0.76, which includes chance), captioned "Illustration, not a result" in decision #8's form.
  - **Help menu:** `CommandGroup(replacing: .help)`, because the app has no help book. "Show Welcome Tour" restarts the intro at step 0 and opens the Welcome window if it is closed.
  - **Keyboard:** Return = Next (default action), Esc = Skip (cancel action), ←/→ via `onKeyPress` on the focused intro. After the intro, "Explore an example" gets keyboard focus (`.focusable` + `FocusState`) and VoiceOver focus, and Return/Space activate it.
  - **Debug launch args added:** `-BCIResetFirstRun YES`, `-BCIIntroStep N`, `-BCIIntroTour YES` (steps through the intro with the real commands, snapshotting each step when `-BCISnapshotDir` is set), `-BCIReduceMotion YES`, `-BCIMontageView top|left|right|front`, `-BCIFrameLog <file>`.

## Risks / what could go wrong for users
- **Distraction.** Expressive motion can feel like marketing in a scientific tool. Mitigations: ≤ 4 steps, Skip is always visible, and the intro never replays uninvited.
- **Performance on older or low-power Macs.** Particles and Metal shaders cost frame time. Mitigation: a frame budget, plus a lower particle count when Low Power Mode is on.
- **Vestibular sensitivity.** Mitigation: Reduce Motion gives fully still frames.
