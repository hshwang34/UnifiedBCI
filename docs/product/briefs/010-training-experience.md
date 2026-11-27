# 010 — Training experience (participant window, operator panel, Start run…, Live Test)

**Status:** in review · **Owner:** PM · **PR:** — · **Updated:** 2026-11-27

## Problem
The PM ran a cued motor-imagery session and called the experience "awful UX". On the
participant screen the left cue was a crude flat arrow drawn straight over the fixation cross,
so the cross poked through the arrow's shaft. Nothing on either screen gave a sense of phase,
hierarchy or progress: the participant saw a blank screen whenever the run paused or ended,
and the operator read a column of plain text lines with the keyboard shortcuts buried in a
caption. The flow works and is scientifically careful (briefs 005, 006); it does not look or
feel like a native macOS 26 app.

## Who it's for
- **Participant**, on a second display (or the only one), seated a metre or more away: needs
  a calm, legible rhythm (get ready → fixation → cue/imagine → rest) and to know when a break
  is a break.
- **Operator**, at the project window: needs the run's state at a glance, the next action
  obvious, and the keys visible, including when the participant window covers their screen.

## Audit (every screen in the flow, before this brief)
Participant window
1. The cue arrow was drawn over the fixation cross; the cross's vertical bar showed through the
   arrow shaft (the PM's screenshot). Cue and cross were never composed as one design.
2. The arrow was a hand-made 7-point polygon: hard corners, a thin shaft, no relation to the
   platform's symbol set.
3. The instructions screen was plain body text in the middle of a black screen: no title, no
   run number, no legend of what each arrow means, no hint of who starts the run.
4. Pause, between runs and session end were all a plain blank screen, identical to a rest. A
   participant could not tell "rest, the next trial is coming" from "break" from "done"
   (brief 005 promised an optional break screen; it was never built).
5. No progress at all: the participant never learnt how many runs were left.
6. The feedback bar was a hard rectangle in the same ink as the cue, so in a live run the cue
   and the bar read as one white mass.

Operator panel
7. No state at a glance: "Running" vs "Paused" vs "Complete" was a sentence among others.
8. The phase was one word ("Cue · Left hand") with no sense of where it sits in the trial or
   how long it lasts.
9. No run or trial progress except a text counter; elapsed and remaining time in a caption.
10. Shortcuts (Space, Esc, ⌘.) were a caption under the buttons; the buttons themselves didn't
    show their keys. With one display, this is the only way to drive the run.
11. Timing summaries stacked as unframed grids under the controls; hard to tell one run's
    from the next.

Start run… sheet
12. A bare form: no header or explanation, the protocol summary a single dense sentence, no
    picture of a trial, no idea how long the session will take.
13. "New Seed" as a text button next to a monospaced field; the one-display warning as plain
    text with the keys spelled out in prose.

Live Test
14. The operator's mirror of the feedback bar animated with a 0.3 s spring, so it drew lengths
    the participant never saw and lagged the real bar.
15. The run controls (Begin/Pause/Abort) sat below the stat tiles, often below the fold while a
    live run was on.
16. The setup reused the Start run… form's weaknesses (no trial picture, prose key hints).

## What success looks like
- The participant sees a clean centre: the cross, then the arrow *in place of* the cross, then
  nothing, with no overlap and no motion during a cue.
- A participant can always tell a rest from a pause from a break from the end of the session.
- The operator can tell the run's state, its progress and the current phase from across the
  desk, and sees which key does what on each button.
- Cue onset timing, presentation callbacks and every recorded event are unchanged.

## Acceptance criteria
- [x] The cue replaces the fixation cross on the same refresh; the cross and cue are never on
      screen together (decision #57). Cue glyphs are SF Symbols (`arrowshape.*.fill`),
      pre-rendered at layout; onset only reveals a finished layer at full contrast.
- [x] The cue is static from onset to cue end: no fade, scale, slide, pulse or symbol effect.
      Fixation, cue and rest onsets are instant swaps with implicit layer actions disabled.
- [x] `presentedAt` is reported exactly as before (same display-link path, same
      `CueFrameScheduler`/`CueDisplay`/`PresentationSink` protocols, unchanged).
- [x] The instructions screen shows the run ("Run 2 of 4"), the protocol's instructions, a
      legend of each class's arrow, run-progress dots and "The run starts when the operator is
      ready." It fades out the moment Space is pressed, inside the 250 ms start lead, so the
      first fixation appears on a clean screen.
- [x] Operator pause shows a "Paused" card; between runs a "Run complete / Run ended" break
      card with run dots; after the last run "All runs done". Rests stay blank. Cards appear
      only over instructions or blank frames and are hidden on the refresh that shows a
      fixation or a cue.
- [x] No progress indicator is shown during fixation, cue or rest (decision #58).
- [x] The feedback bar keeps decision #40's semantics (only windows wholly inside the
      imagery period) and jumps to each reported length with no interpolation, on the
      participant's screen and the operator's mirror (decision #59). It is a capsule in its
      own calm blue, clear of every arrow.
- [x] Operator panel: a state badge (Ready / Running / Paused / Complete / Ended early /
      Couldn't start), run dots and a trial progress bar, the trial drawn to scale with the
      current phase highlighted (and the cued class with its arrow during a cue), the next
      action as the prominent button, and key caps (Space, esc, ⌘.) on every run button.
- [x] Start run…: header, sections (Protocol / Session / Participant), one trial drawn to
      scale, the session's length, the one-display note with key caps.
- [x] Live Test: the run controls sit directly under the feedback card; the setup shows the
      trial to scale and the key-cap note.
- [x] Reduce Motion (system or `-BCIReduceMotion YES`): every animation in this brief is off
      (cards appear and go instantly; strip, badge and summaries change without motion).
      Increase Contrast: participant secondary text and the bar's track get stronger; operator
      hairlines become borders. VoiceOver: the badge, phase strip, progress and every run
      button have labels or hints; key caps are hidden from VoiceOver (the hint names the key).
      Operator text uses text styles and `@ScaledMetric`.
- [x] Debug snapshots: `run-rest`, `run-paused`, `run-fixation` and offscreen
      `participant-<card>.png` join `run-instructions` / `run-cue`.

## Out of scope
- Audio cues, countdowns before each trial, or any change to phase timing.
- Changes to the run plan, events, markers, the runner or the scheduler.
- The live acquisition screen (another session owns `AcquisitionView.swift`) and the project
  window layout.
- A per-display preview of the participant window inside the operator panel.
- Redesigning the Live run card (the evidence card) beyond what it inherits.

## Scientific constraints (blocking if broken)
- Cue onset is a measured stimulus: `CueFrameScheduler`/`CueDisplay` report presented-at
  frame callbacks; lateness goes into the run plan and timing summary.
- The cue appears at full contrast on the scheduled frame — no fade-in, scale-in or slide-in;
  its onset is the event marker.
- Once shown it stays static until cue end — no motion, pulsing or symbol effects (motion
  evokes visual responses that contaminate motor-imagery EEG).
- Animate only between phases: the instructions screen, cards over blank frames, and the
  operator UI. The cross is swapped out instantly at cue onset (no cross-fade).
- `presentedAt` keeps firing exactly as before; `CueSurface`/`CueDisplay` stay compatible.
- The feedback bar shows only for windows wholly inside the imagery period (decision #40); its
  motion reflects the data with no invented values.
- Second-display full-screen behaviour (decision #36), keyboard shortcuts, abort/pause
  semantics (#34, #35) and copy-in-Models are unchanged.

## Open product questions
None: the PM delegated the design calls to the lead (2026-11-27); they are decisions #57–#61.

## Engineering decisions (filled in by the lead while building)
- **Layers for stimuli, SwiftUI for words.** The participant window stays an `NSView` with
  `CAShapeLayer`s driven by the display link; stimuli never go through SwiftUI. The cards
  between trials are a SwiftUI `NSHostingView` (`ParticipantCardHost`) over the layers. The
  cue view hides it (`isHidden`) inside the same `CATransaction` that reveals a cross or a
  cue, and clears its content with animations disabled, so no card, and no card's
  animation, can share a refresh with a measured phase.
- **Cue glyphs are pre-rendered.** `layout()` renders the four `arrowshape.*.fill` symbols to
  `CGImage`s at the display's backing scale; cue onset sets `contents`/`frame` on a hidden layer
  and un-hides it, with actions disabled. If a symbol ever fails to render, the old drawn
  arrow is the fallback.
- **The instructions card is a frame like any other.** The runner still sends
  `.instructions(text)` and gets its presentation callback on the refresh that sets it; the
  card's SwiftUI fade-in may finish a few frames later. That is acceptable for instructions
  (not a measured stimulus) and documented here.
- **Who decides the card.** `RunController` sets `ParticipantScreen` through a new
  `CueSurface.showParticipant(_:context:)` (default no-op, so test fakes still conform):
  `.instructions` at run start, `nil` the moment Space or Resume is pressed (Resume only when
  the stream is up, since the runner ignores it otherwise), `.paused` from the status poll,
  `.betweenRuns`/`.sessionDone` when a run ends. A dismissed card stays gone until the run
  state changes.
- **Cards fade, stimuli don't.** Cards fade in with a 12 pt rise over 0.45 s (`.smooth`) and
  fade out; Reduce Motion makes them instant. Card symbols are static (no symbol effects in
  the participant window at all).
- **Fixation cross** is two round-ended capsules (same size and stroke as before).
- **Operator motion** uses `Theme.motion` (nil under Reduce Motion): `matchedGeometryEffect`
  moves the phase highlight, `contentTransition(.numericText())` on counters and times,
  `.symbolEffect(.replace)` on badge and phase symbols, and a repeating `.pulse` on the
  Running badge's record symbol (operator only, off under Reduce Motion).
- **Key caps don't add shortcuts.** The keys stay in `RunController`'s local event monitor
  (decision #36's focus rules); `KeyCap`/`ShortcutLabel` (App/Design/KeyCap.swift) only show
  them, and each button's help and accessibility hint name the key.
- **Operator feedback gauge** no longer animates at all (it mirrors the participant's bar
  exactly). The feedback state card has no transitions either: it is rebuilt 20 times a
  second, and the first snapshot pass showed a cross-fade drawing two states and two
  confidences at once.
- **Trial progress** on the operator panel is trials started ÷ trials; between trials (no trial
  index) it falls back to planned elapsed time, so the bar never jumps back.

## Risks / what could go wrong for users
- Recordings made before and after this change saw different cue glyphs (stimulus appearance
  is not part of the protocol record or its content hash). Combining sessions across the
  change mixes two cue looks; for left/right motor imagery this is unlikely to matter, but it
  is a difference a careful reader should know about.
- The participant window now hosts a SwiftUI view. It is hidden during trials and never
  hit-tested, but a regression that leaves it visible during a cue would put text on screen
  with a stimulus; the card model refuses to build a card for a blank frame without a
  between-trials screen, and the tests check it.
- Still unverified on the real kit (brief 005 appendix): two-display behaviour on the PM's
  setup, and lateness with the board streaming.
