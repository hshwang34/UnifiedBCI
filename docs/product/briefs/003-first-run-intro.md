# 003 — First-run intro with motion

**Status:** approved · **Owner:** PM · **PR:** — · **Updated:** 2026-10-23

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

## Risks / what could go wrong for users
- **Distraction.** Expressive motion can feel like marketing in a scientific tool. Mitigations: ≤ 4 steps, Skip is always visible, and the intro never replays uninvited.
- **Performance on older or low-power Macs.** Particles and Metal shaders cost frame time. Mitigation: a frame budget, plus a lower particle count when Low Power Mode is on.
- **Vestibular sensitivity.** Mitigation: Reduce Motion gives fully still frames.
