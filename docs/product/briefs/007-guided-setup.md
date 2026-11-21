# 007 — Guided setup: goals, a step guide, and "?" help

**Status:** approved · **Owner:** PM · **PR:** — · **Updated:** 2026-11-21

## Problem
The app now covers the whole experiment (record → evaluate → freeze → replay → live), but nothing
tells a newcomer which of the five sidebar sections to use, in what order, or what a number like
"held-out accuracy 0.62 [0.48, 0.75]" means. The first-run intro (brief 003) explains the idea once
and then goes away. Hover tooltips exist on about 30 buttons, but they say what a button does, not
what to do next. PRD §5 asks for the stages to "remain a guided path for new users" without
becoming a mandatory wizard. Today that path isn't in the app.

## Who it's for
- A first-time user who opens the example or a new project and doesn't know where to start.
- Someone partway through (for example, recorded but unsure what to do next) who gets stuck on a
  screen or on a number.

## What success looks like
- When a project opens, the user is asked what they want to do, and from then on always sees the
  next step and a "Show me" button that takes them to it.
- When a concept stops them (stream health, chance level, model confidence), a "?" next to it
  explains it in plain words, without leaving the app.
- Experienced users can dismiss all of it in one click, and it never blocks or covers data.

## Acceptance criteria
**Goal picker (decision #43)**
- [ ] When a project opens with no goal chosen, a sheet asks "What do you want to do?" and offers
  four goals, each with a one-line description: *See how it works on the example*, *Record EEG from
  a headset*, *Train and check a decoder*, *Run live feedback with a participant*. It also has
  "Not now".
- [ ] "Not now" closes the sheet. The sheet doesn't ask again for that project. Help ▸ Guide… and
  the guide card both bring it back.
- [ ] The choice is remembered per project across relaunches and can be changed at any time
  ("Change goal").

**Sidebar guide (decisions #44, #45)**
- [ ] With a goal chosen, the bottom of the project sidebar shows a "Guide" card: the goal name,
  "Step k of n", the step list (done ✓ / current ● / to do), the current step's one-sentence
  instruction, a **Show me** button, and buttons to collapse or hide the card.
- [ ] Steps tick off **automatically** from the project's real state or from what the user has
  actually done in the app. A step is never shown as done unless that's true. Every step has
  "Skip step", and a skipped step is marked as skipped, not done.
- [ ] **Show me** switches to the right section or tab and briefly highlights the control to use (a
  pulsing ring for about 2 s; under Reduce Motion, a static ring). If the control is disabled, the
  card says why, using the same reason the button's tooltip gives.
- [ ] When the last step is done, the card says so and offers "Choose another goal" or "Hide guide".
- [ ] Hiding the card is remembered per project. Help ▸ Show Guide brings it back.
- [ ] The card is fully usable with VoiceOver and the keyboard. Step state is read out ("done",
  "current", "skipped").

**Steps per goal** (wording is final in `GuideModels.swift`; "done when" is the rule)

| Goal | Steps (done when …) |
|---|---|
| Example | Open a recording (one is selected) → Check its signal (Quality tab opened) → Look at the head montage (Channels tab with the montage opened) → Evaluate (a result exists) → Read the result (a result opened in Results) |
| Record | Connect a source (streaming) → Confirm the channel map (map declared, or "without positions") → Check the live signal (preview streamed ≥ 10 s) → Record (a live recording saved) → Review its quality (that recording's Quality tab opened) |
| Train | Connect → Choose a protocol (one exists) → Record cued runs (≥ 1 saved protocol run; the step's text recommends 4, decision #37) → Evaluate (a result on a cued recording) → Read the result |
| Live feedback | the Train steps → Freeze a model (a frozen model exists) → Check replay (a replay run whose parity passed) → Run a live test (a live run saved) → Read the live results (a live-run card opened) |

**"?" help (decision #46)**
- [ ] A small "?" button (native help-button style) opens a popover of 2–4 plain sentences:
  what it is, what a good value looks like, and what to do if it's bad. It needs no network.
- [ ] It appears at these spots only: stream health · channel map · Quality checks · signal
  trace/lane height · head montage · protocol trial timing · held-out accuracy and its interval ·
  chance level and the baseline comparison · evaluation parameters · freeze · replay parity ·
  model confidence and the 0.6 threshold · the live-run card's interval.
- [ ] The copy follows the scientific rules: no overclaiming, chance level is named, and "model
  confidence" is described as the model's own uncalibrated estimate.
- [ ] Every "?" has an accessibility label ("Help: Stream health") and closes with Esc.

## Out of scope
- A Help Book or longer articles (decision #46).
- Coach-mark overlays or a mandatory wizard (decision #44; PRD §5).
- Goals beyond the four (for example comparing pipelines). They can be added later as data.
- Telemetry on where people get stuck.

## Open product questions
1. **Which goals?** → *Answer:* the four above (#43).
2. **Where does the guide live?** → *Answer:* a sidebar checklist card with "Show me" (#44).
3. **How do steps tick off?** → *Answer:* automatically from real state; skippable (#45).
4. **How deep is the "?" help?** → *Answer:* short popovers at about 12 concept-heavy spots (#46).

## PR plan
1. Docs: this brief and decisions #43–#46.
2. `GuideModel`: goals, steps, and the completion rules as a pure function of a project/UI
   snapshot; per-project persistence (goal, skipped steps, hidden, visited marks). Unit tests only.
3. Goal picker sheet, sidebar Guide card, Help ▸ Guide… / Show Guide, and the wiring to
   `ProjectSession`. Debug launch argument `-BCIGuideGoal <goal>` for screenshots.
4. "Show me": section/tab navigation and a highlight anchor on each target control (Reduce Motion
   aware).
5. "?" help: a `HelpButton` component, a `HelpTopics` copy table with tests, and placement at the
   listed spots.
6. Docs: README, screenshots, brief status.

## Engineering decisions (filled in by the lead while building)
- Guide state is per-user app state, not experiment data. It goes in `UserDefaults`, keyed by the
  project's stable id, so it never touches the `.bciproj` format or its immutability rules.

## Risks / what could go wrong for users
- A step that ticks off wrongly would mislead. Every rule comes from real state and is
  unit-tested per goal.
- Too much help is noise. The "?" spots are capped at the list above, and the whole guide can be
  hidden.
