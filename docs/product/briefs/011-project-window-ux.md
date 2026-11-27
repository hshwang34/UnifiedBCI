# 011 — Project window UX pass

**Status:** in review · **Owner:** lead (PM delegated design calls, 2026-11-27) · **PR:** — · **Updated:** 2026-11-27

## Problem
The PM is unhappy with the project window. A designer's review of every screen (verify run
`20261127-075808`) found a toolbar that shows Evaluate and Parameters everywhere, a result
hero whose biggest element is a bare point estimate, raw identifiers (`cue_left_fist`,
`csp_rlda_v1`, run UUIDs, SHA prefixes) in primary text, monospace used for numbers, the same
caveat repeated two or three times on one screen, a quality trace that repeats "Large
deflections" on 15 of 16 lanes, an error banner that crowds the title, a protocol editor that
stacks its errors in a footer, a freeze sheet with three notices, a 3D head that pushes the
tables below the fold, release-planning copy ("Read-only in phase 1") and a welcome screen
whose "New" card takes the hero spot.

## Who it's for
Researchers running motor-imagery experiments (not ML engineers), at the moment they read a
result, inspect a recording or prepare a live session.

## What success looks like
- The first thing a researcher reads on a result is an interval, never a bare number.
- Primary text uses researcher words; exact stored values are one click away in Details.
- Each caveat appears once per screen; the toolbar only offers what the screen can do.

## Audit summary (designer review → fix)
| # | Finding | Fix |
|---|---|---|
| 1 | Toolbar shows Evaluate/Parameters on every section | Contextual toolbar per section; every disabled control explains why |
| 2 | Bare 0.62 above a small caveat | Interval is the headline; a point estimate without interval says so; reference rate readable |
| 3 | Raw ids and jargon in primary text | Display names, recipe names, run names; ids in Details |
| 4 | Mono numbers | SF Pro + `.monospacedDigit()`; mono only for ids in Details |
| 5 | 15 lanes repeat the same flag | One summary line, one marker per lane, detail in tooltip |
| 6 | "Pipelines", "Read-only in phase 1", empty model pane | "Models", no release copy, a useful empty state |
| 7 | Error banner crowds the title, Retry looks disabled | Own slot with spacing, prominent Retry |
| 8 | Editor errors stacked in a footer | Inline under each field; "Nothing changed" is neutral |
| 9 | Freeze sheet: three notices | One notice + Model vs Baseline explainer; 2 s advice as guidance for next time |
| 10 | Head 340 pt, tables clipped, cramped at 1100 pt | Head 260 pt, table bottom margin, inspector starts collapsed under 1200 pt |
| 11 | "2026-11-27 07:58" everywhere | Localized "Today, 7:58 AM" for display; stored names unchanged |
| 12 | Agent "New" card in the hero spot; bare "No recent projects." | Slim row under Recent Projects; empty state with a next step |
| 13 | Window title shows through the toolbar when scrolled | Hard scroll-edge effect on the detail column (macOS 26) |

## Acceptance criteria
- [ ] Recordings: toolbar shows Evaluate and Parameters…; Results with a selection: Freeze for live use… and Export…; Protocols, Models, Live Test: neither. Live view: no Evaluate/Parameters.
- [ ] Every disabled toolbar control has a `.help` reason.
- [ ] Result hero with a run-level interval: the interval is the display text, the point estimate sits inside it.
- [ ] Result hero without one: "Point estimate · no interval" is said in words beside the number, and the trial-level interval is shown as the larger figure.
- [ ] Larger-class reference reads at callout size in SF Pro.
- [ ] Dataset/synthetic warning appears once on the recording screen; the reproduction notice appears once on a result.
- [ ] Class names, recipe names and run names replace ids in primary text; exact values remain in a Details disclosure.
- [ ] Quality trace: when every flagged lane shares the same flags, one summary line names them and lanes carry a marker only.
- [ ] Sidebar says "Models"; no "phase 1" copy anywhere in the window.
- [ ] Protocol editor shows each error under its field with the field tinted; "Nothing changed" is neutral; units sit beside the numbers.
- [ ] Freeze sheet: one evidence notice, one Model vs Baseline sentence, window advice phrased for next time.
- [ ] Montage head ≤ 260 pt; events table never clips its last row; inspector starts hidden below 1200 pt.
- [ ] Display dates read "Today, 7:58 AM"; tests stay deterministic (fixed locale/time zone/now).
- [ ] Welcome: agent card below Recent Projects as a slim row; empty recents state offers "Explore an example".

## Out of scope
- The live screen (`AcquisitionView`, `LiveModels`) — the lead's area.
- The cue window, run views, live-test views and their models — the training-experience writer's area. The live-run card (`LiveTestViews` / `LiveRunModels`) still leads with a bare live accuracy: it should follow decision #62 (interval headline, "point estimate · no interval" in words); `RangeBar`'s readable reference label already applies to it.
- Agent control and scripts.

## Engineering decisions (filled in by the lead while building)
Product-level calls are decisions #62–#68 in `DECISIONS.md` (#57–#61 are the training-experience brief's).
- `SidebarSection.pipelines` keeps its raw value (agent control and launch arguments use it); only `title` changes to "Models".
- Freeze for live use… stays in the result hero as well as the toolbar, the same pattern as Evaluate (toolbar + inspector): the guide's "Show me" ring needs an in-content anchor. Export… leaves the hero (toolbar and ⇧⌘X).
- Inspector auto-collapse is decided from window width without animation (a `Transaction` with animations disabled), only on the Recordings section and never while the live view shows; widening back reopens it only if it was auto-collapsed.
- `Fmt.relativeDateTime` takes `now`, `locale`, `timeZone` and `calendar` so tests pin all four. `Fmt.dateTime` stays for stored names (model default names, run names) and exports.
- Tables of stored data (events, segments, channels) keep the stored values verbatim but in SF Pro; run/session UUIDs show as "Run 1"/"Session 1" with the stored id in the tooltip.
- `ProtocolEditor.Issue` gains a `field` (where to show it) and a `.status` kind; `canSave` also refuses an unchanged draft.

## Risks / what could go wrong for users
- Hiding ids behind Details could slow down someone cross-checking a file; the tooltip and Details keep the exact value one hover or click away.
