# 001 — PR 3 screen spec (native macOS, from the designer agent, 2026-10-20)

Binding for the PR 3 writer unless the brief or DECISIONS.md says otherwise. macOS 15+, SwiftUI, Swift 6, system components only.

## Headline-metric wording (decided for the PM; reversible)
The contract's 95 % Clopper-Pearson interval is on **accuracy** over held-out trials; balanced accuracy only has a run-level bootstrap interval, which is `null` when a single run is held out (the bundled example's case). Therefore:
- Headline: **Balanced accuracy 0.68**
- Directly under, same size class: **Accuracy 0.70 · 95 % CI 0.51–0.84 (trial-level, n = 14)**
- Third line: the BA bootstrap interval if present, else "Balanced-accuracy interval: unavailable (one held-out run)".
Never label the trial-level CI as a balanced-accuracy interval.

## 1. App structure
- `Window("Welcome", id: "welcome")` + `WindowGroup(for: URL.self)` for project windows, manual open. **Not** `DocumentGroup`: the store is append-only/immutable with atomic commits and owns persistence; there is no dirty state or save; DocumentGroup fights "nothing auto-opens".
- Declare UTType `com.hshwang34.bciproj` (exported, conforms to `com.apple.package`) so Finder treats `.bciproj` as a package.
- Recents via `NSDocumentController.shared.noteNewRecentDocumentURL` on every open/create; welcome list reads `recentDocumentURLs`. Verify File ▸ Open Recent populates; else build it manually.
- Open: `NSOpenPanel` (`canChooseDirectories`, `allowedContentTypes = [bciproj]`, enable `canChooseFiles` if the panel won't select a package); validate `project.json`; alert "Not a BCI Workspace project." on failure.
- Menus (`.commands`): File ▸ New Project… ⌘N (NSSavePanel, empty `.bciproj`) · Open Project… ⌘O · Open Recent · Explore Example ⇧⌘E · Export Result… ⇧⌘X (enabled only with a result selected). Pipeline ▸ Evaluate ⌘R (needs a recording selected); Cancel ⌘. while running. Window ▸ Welcome ⇧⌘0. View ▸ Show Inspector ⌥⌘I.
- Closing the last project window does not quit; Welcome stays reachable.

## 2. Welcome window (~640×400, `.windowResizability(.contentSize)`, hidden title bar)
```
┌──────────────────────────────────────────────┐
│ ● ● ●                                         │
│  [app icon 64]  BCI Workspace                 │
│                 Version 0.1                   │
│ ┌────────────────────┬──────────────────────┐ │
│ │ ▸ Explore an example│ Recent Projects      │ │
│ │   Public EEG data,  │ ▢ MyExperiment       │ │
│ │   no hardware.      │   ~/Documents/…  2d  │ │
│ │ ▸ Open project…     │ ▢ Pilot-02           │ │
│ │   A .bciproj folder │ (empty: "No recent   │ │
│ │ ▸ Connect hardware  │  projects.")         │ │
│ │   (dim) Available   │                      │ │
│ │   in phase 2.       │                      │ │
│ └────────────────────┴──────────────────────┘ │
└──────────────────────────────────────────────┘
```
- Left: three large plain-style buttons, SF Symbol + headline + one-line caption.
  - Explore an example (`sparkles.rectangle.stack`): "A public motor-imagery recording (PhysioNet, subject S001). Creates a project in Documents." → NSSavePanel defaulting to `~/Documents/BCI Example.bciproj`; bundle-only, offline.
  - Open project… (`folder`): "Open a .bciproj folder."
  - Connect hardware (`cable.connector`, disabled): "Cyton + Daisy acquisition arrives in phase 2. Recorded data works today." Same text in `.help`; dim state never relies on colour alone.
- Right: `List` of recents (`shippingbox`), name, abbreviated path (`.secondary`), relative date; double-click opens; context menu Show in Finder / Remove from Recents; missing path → `exclamationmark.triangle` "Not found".

## 3. Project window
`NavigationSplitView` sidebar / list / detail, `.inspector(isPresented:)` trailing. Toolbar: Evaluate (`play.fill`), Parameters…, inspector toggle (`sidebar.trailing`). Title = project name, subtitle = selection. Sidebar status line: "No hardware connected · Replay mode".
Sidebar `List(selection:)`, `Section("Project")`: Recordings (`waveform`, count badge) · Protocols (`list.bullet.clipboard`) · Pipelines (`slider.horizontal.3`) · Results (`chart.bar.doc.horizontal`, count) · Live Test (`bolt.horizontal.circle`).
Placeholders are `ContentUnavailableView`: "Protocols arrive in phase 2. Needs a connected board or the cue protocol." / "Live Test arrives in phase 3. Needs a frozen pipeline from phase 2." Pipelines: two read-only rows (CSP+rLDA reference, log-variance baseline) with config.
```
┌─────────┬───────────────────────────────────────────┬────────────┐
│Recordngs│ ◀ S001 runs 4/8/12      [▶ Evaluate] [⎙]  │ Inspector  │
│•S001    │ ⚠ Public dataset, not your device.        │ (see 3b)   │
│Protocols│ Source ─────────────────────────────      │            │
│Pipelines│  Dataset  PhysioNet EEGMMIDB  Subject S001│            │
│Results 2│  Runs 4, 8, 12   License ODC-BY           │            │
│Live Test│  Cite  Schalk 2004; Goldberger 2000       │            │
│         │ Channels (16)  Montage: <name|undeclared> │            │
│         │ ID   Label Unit Kind                      │            │
│         │ Segments (3) | Events (66) [sortable]     │            │
└─────────┴───────────────────────────────────────────┴────────────┘
```
### 3b. Inspector for Evaluate (grouped `Form`, every claim derived from the record)
- "What this changes": runs CSP+rLDA and the log-variance baseline on this recording; the recording is not modified; the result is stored as a new record.
- "What would make this misleading" bullets from data: trials per class ("small samples give wide intervals; 70 % here is compatible with chance"); evidence type (same-/unknown-session, one subject — no transfer claim); data source (public recording, not your device); exclusions count if non-zero; held-out runs = 1 → run-level interval unavailable.
- "How the split works" popover showing the split policy.

## 4. Recording detail (grouped `Form` + `Table`s switched by a segmented `Picker`: Channels / Segments / Events)
- Source: first line `Label` with `exclamationmark.triangle.fill` (`.orange` icon, `.primary` text): "Public recording (PhysioNet EEGMMIDB) — not recorded on your device." Then Dataset, Subject, Runs, Sample rate, Reference, License, Citations (selectable, links), Montage ("undeclared" if empty).
- Channels `Table`: ID (monospaced), Label, Unit, Kind; missing → "undeclared" secondary italic; never guess; sortable (`KeyPathComparator`).
- Segments `Table`: Segment, Run, Session ("—"), Duration, Samples, Gaps, End reason.
- Events `Table`: Label, Onset (s, 3 dp, from `sampleAssociation.sampleIndex / rate`), Run, Trial; default sort by onset; `.alternatingRowBackgrounds()`.

## 5. Evaluate flow
- Evaluate: toolbar `play.fill` + ⌘R + recording context menu. Parameters… popover `Form` with Reset: Seed ("Changes the bootstrap draws. The split stays the same."), CSP components ("More components capture more variance patterns but overfit sooner on few trials."), Window offset s ("When after the cue the analysis window starts. Earlier risks cue-onset artefacts."), Window length s ("Longer windows average more noise out but dilute short-lived changes."). Defaults come from the worker, shown as placeholders; never invented.
- Progress: determinate `ProgressView(value:total:)` with stage label "Loading · Fit · Cross-validation · Holdout", updated at least once per stage; Cancel ⌘. → "Cancelled — nothing saved."
- Worker death: banner at top of content, `exclamationmark.octagon`, "Analysis unavailable. The analysis worker stopped. Your recording is unchanged." Prominent Retry; "Show details" disclosure with stderr tail. Recording stays browsable.
- Success: select Results and the new row; status "Result saved to project". Same-seed rerun: "Reproduced — identical to <time> original"; if not byte-identical, surface "Differs from original" as a warning (that is a bug).

## 6. Result detail
Results list sorted by date; reproductions are child rows under their original (`OutlineGroup`, `arrow.triangle.2.circlepath`, "Reproduction of 14:02"); new seed = new top-level row.
```
┌ Results ──────────┬────────────────────────────────────────────┐
│ ▾ Seed 0   14:02  │ Balanced accuracy        0.68              │
│    ↻ Repro 14:09  │ Accuracy 0.70  95% CI 0.51–0.84 (trial)    │
│   Seed 1   14:20  │ n = 14 held-out trials · same-session      │
│                   │ ⚠ Public dataset, not your device.         │
│                   │ [↻ Reproduction of 14:02 ▸]      [Export…] │
│                   │ ┌ Confusion ┐  Class counts (train/test/hold)│
│                   │ │ L R       │  Per-run holdout: run 12 0.71  │
│                   │ │ 5 2 / 2 5 │  Baseline: logvar 0.57         │
│                   │ └───────────┘  Δ +0.11 (CI …) paired         │
│                   │ Split policy: grouped by run; holdout run 12;│
│                   │  folds 2; seed 0; evidence same-session      │
│                   │ Exclusions (0)                               │
└───────────────────┴────────────────────────────────────────────┘
```
Grouped `Form`, order: headline (per wording above, `.largeTitle.monospacedDigit()`), warning, reproduction badge, confusion matrix (2×2 `Grid`, class names from `evaluation.json`, single accent-opacity shading, every cell numbered, accessibility label per cell + one full-sentence summary), class counts `Table` (train/test/holdout), per-run holdout `Table`, baseline comparison (paired difference + CI or "unavailable (one held-out run)", plus both/ref-only/baseline-only/neither counts), split policy `LabeledContent` (unit, grouping, holdout runs, folds, seed, evidence — `unknown-session` gets `questionmark.circle` + "Session unknown — this is not evidence of cross-session transfer."), exclusions disclosure in plain language ("window starts before filter warm-up"; empty → "None."). Export… toolbar `square.and.arrow.up` + ⇧⌘X → NSSavePanel → "Exported to …" + Show in Finder.

## 7. Accessibility / appearance
System colours only; light/dark free. Meaning never by colour alone (symbol + text). Warning icon `.orange`, text `.primary` (yellow text fails contrast in light mode). Tables give keyboard nav + VoiceOver headers. Progress has an accessibility value ("Cross-validation, 2 of 3"); post `AccessibilityNotification.Announcement` on completion/failure/cancel. Disabled "Connect hardware" stays focusable with the explanation as hint. No custom animations. No hard-coded numbers in explanatory text.

## Reuse vs new
Replace the single `WindowGroup` in `App/BCIWorkspaceApp.swift`; keep `FeasibilityView` behind a Debug menu item. New: `WelcomeView`, `ProjectWindow`, `RecordingDetailView`, `EvaluateInspector`, `ResultDetailView`, `ProjectSession` (`@Observable @MainActor` over the store, runner and worker client).

Open items for the engineer: real parameter defaults from the worker; whether event onset is stored or derived; exact JSON keys for class names in `evaluation.json`.
