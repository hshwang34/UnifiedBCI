# 001 - Visual spec (designer agent, 2026-10-22)

Binding for the next writer. Implements decision #9, which supersedes "system components only" in 001-ui-spec.md. The structure and copy in 001-ui-spec.md still hold. Decisions #7, #8 and #10 are unchanged. macOS 15 stays the minimum; macOS 26 gets real Liquid Glass. Built with the Xcode 26 SDK; do NOT set `UIDesignRequiresCompatibility`.

## 0. Principles
1. Glass is the navigation and control layer: window chrome, buttons, the hero card, the floating status panel, popovers. Content sits on solid surfaces. (Apple: glass floats above content; no glass on glass; group nearby glass in a `GlassEffectContainer`.)
2. Honesty rules beat style.
   - Uncertainty is as prominent as the number.
   - Warnings are solid and full-size, with a symbol and text.
   - Meaning is never carried by colour alone.
   - Nothing animates a number.
3. Do not restyle system chrome on macOS 26. With the Xcode 26 SDK, the sidebar, toolbar, inspector and popovers already adopt glass and scroll-edge effects.
   - No custom backgrounds on the sidebar, columns or toolbar.
   - No `.glassEffect` on toolbar items.
   - No glass buttons inside the sidebar or inspector; use `.bordered` / `.borderedProminent` there.
4. All `#available` branching lives in the four wrappers in Section 1.8. Call sites never write `#available`.

## 1. Design tokens
Implement the tokens as asset-catalog colour sets. Any/Dark plus High Contrast variants give Increase Contrast for free. Read them through `enum Theme` in `App/Design/Theme.swift`.

### 1.1 Colour (hex; Light / Dark)
| Token | Light | Dark | Use |
|---|---|---|---|
| canvas | #F3F6FA | #0E1116 | window and detail background |
| surface1 | #FFFFFF | #171B22 | content cards, tables, recents |
| surface2 | #EAEFF5 | #1E232C | wells, table header, track |
| hairline | black 8% | white 10% | card borders, dividers |
| textPrimary | #0F1722 | #F2F5F9 | |
| textSecondary | #4A5565 | #A7B0BD | |
| textTertiary | #5D697B | #8892A2 | non-essential only |
| accentFill | #0A5FCF | #2A74D6 | filled controls, selected cells (white label >= 4.5:1) |
| accentInk | #0A5FCF | #5AA9FF | accent text, icons, range bar, links |
| aurora | #1CA7C4 | #58E0D6 | backdrop glow, icon, bar gradient end only |
| warning (icon/border) | #B25E00 | #FFB340 | text is always textPrimary |
| warningFill | #FFF1DA | #FFB340 @14% | |
| danger | #C4261D | #FF7A70 | fill @10–12% |
| positive | #1B7F4B | #5BD08A | |

High Contrast variants:
- textSecondary: light #2F3948, dark #C5CCD6.
- hairline: 30%.
- accentInk: light #0847A0, dark #8EC5FF.

The AccentColor asset is accentFill. The user may override it with a system accent; all tokens still hold.

Contrast test: add a Swift Testing test that computes WCAG contrast for every text/background pair above, in both modes. It fails below 4.5 for text and below 3 for UI and graphics.

Note: the system's `.glassProminent` tint may shift label contrast. Verify by screenshot. If white-on-tint falls below 4.5:1 in dark mode, fall back to `.borderedProminent` there.

### 1.2 Ambient backdrop (what the glass refracts)
`AmbientBackdrop` sits behind the detail column and the Welcome window.
- A canvas fill plus two blurred radial gradients:
  - Top-leading: accentInk @ 14% light / 20% dark, radius 420.
  - Top-trailing: aurora @ 10% / 14%, radius 360.
  - Both fade to canvas by y = 420.
- Static, never animated.
- On macOS 26 the Result hero's backdrop also gets `.backgroundExtensionEffect()`, once per window, so the glow continues under the sidebar and inspector.
- Hidden when Reduce Transparency is on (plain canvas).

### 1.3 Radii
control 8 · row 10 · chip 12 · matrix cell 14 · card 20 · hero/floating panel 28. Use `.rect(cornerRadius:)` / `RoundedRectangle(style: .continuous)`.

### 1.4 Spacing (pt)
Scale: 2, 4, 8, 12, 16, 24, 32, 48. Card padding 20; hero padding 28; gap between cards 16; page margin 24; minimum hit target 28.

### 1.5 Type (system fonts only)
| Role | SwiftUI |
|---|---|
| display (hero BA number) | `.system(size: 64, weight: .semibold, design: .rounded).monospacedDigit()` via `@ScaledMetric(relativeTo: .largeTitle)` |
| heroLabel | `.system(.title3, design: .rounded).weight(.semibold)` |
| title | `.system(.title2, design: .rounded).weight(.semibold)` |
| sectionHeader | `.system(.headline, design: .rounded)` |
| matrixNumber | `.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit()` |
| body / callout / caption | `.body` / `.callout` / `.caption` (never `.caption2` for meaning) |
| mono (IDs, onsets, raw labels, paths) | `.system(.callout, design: .monospaced)`; caption variant `.system(.caption, design: .monospaced)` |
| numbers in text/tables | add `.monospacedDigit()` |

Rounded is only for display, titles and numbers. Table and body text stay SF Pro.

### 1.6 Glass values
- **Hero:** `Glass.regular.tint(accentInk @ 10% light / 14% dark)`, shape `.rect(cornerRadius: 28)`. Apply a solid scrim, `surface1 @ 60% light / 55% dark`, as a `.background` of the content, so the glass sits behind text and contrast is deterministic.
- **Floating status panel:** `.regular`, untinted, radius 28.
- **Controls:** `.regular.interactive()` only on the tappable Welcome cards.
- **Prominent action:** `.glassProminent` with `.tint(accentFill)`.
- **macOS 15 fallback:** `.ultraThinMaterial` + scrim 35% + the rim stroke below.
- **Rim stroke** (fallback and hero): a 1pt `LinearGradient` from top-leading to bottom-trailing.
  - Dark: white 35% → 5%.
  - Light: white 90% → 20%, plus an outer black 6%.
  - Increase Contrast: solid fill with a 1.5pt textTertiary border.
- **Reduce Transparency:** solid surface1, 1pt hairline, no backdrop, no material.

### 1.7 Shadow / elevation
- **Level 0:** flat content.
- **Level 1 (card):**
  - Dark: black 35%, r 24, y 12.
  - Light: #0F1722 10%, r 20, y 8, plus a contact shadow of black 6%, r 2, y 1.
- **Level 2 (floating panel):**
  - Dark: black 45%, r 32, y 16.
  - Light: 14%, r 28, y 12.
- On macOS 26 glass supplies its own shadow, so don't add one to glass surfaces.
- Reduce Transparency: contact shadow only.

### 1.8 Wrappers (new, in `App/Design/`)
- **`GlassSurface(shape:tint:scrim:)` ViewModifier.**
  - Reduce Transparency or Increase Contrast → solid.
  - macOS 26 → the scrim background, then `.glassEffect(.regular.tint(tint), in: shape)`.
  - Otherwise → material + scrim + rim.
- **`appProminentButton()` → `@ViewBuilder`.** On 26, `.buttonStyle(.glassProminent)`; on 15, `.buttonStyle(.borderedProminent)`. The two styles are different types, so branch rather than use a ternary. Add `.buttonBorderShape(.capsule)` and `.controlSize(.large)`.
- **`Card`:** solid surface1, radius 20, hairline border, Level-1 shadow. The content container for tables and the matrix.
- **`StatusChip(kind: .warning/.danger/.info/.positive, text:)`:** solid tinted fill, a 1pt border in the token colour, an SF Symbol and `textPrimary` text. Symbols: warning `exclamationmark.triangle.fill`, danger `exclamationmark.octagon.fill`, info `info.circle.fill`, positive `checkmark.circle.fill`.

Also add `RangeBar`, `AmbientBackdrop` and `ClassDisplay` (Section 3). No other new card types.

Motion: `Theme.motion` = `.smooth(duration: 0.3)`, returned as `nil` when `accessibilityReduceMotion` is on.
- Allowed: a cross-fade of the stage label; the status panel's insert and remove (opacity + 8pt offset); the RangeBar draw-in (0.4 s ease-out, width only).
- Never animate numbers.

## 2. Screens

### 2.1 Welcome (window 760x460, `.windowResizability(.contentSize)`, hidden title bar)
```
┌ ● ● ● ───────────────────────────────────────────────┐   AmbientBackdrop
│  [icon 72]  BCI Workspace            (title, rounded)│
│             Version 0.1.0                            │
│  ┌ glass card ─────────────┐   Recent Projects      │
│  │ ◇ Explore an example    │   ┌ solid card ───────┐│
│  │   A public motor-…      │   │ ▢ MyExperiment    ││
│  ├─────────────────────────┤   │   ~/Documents/…   ││
│  │ ▭ Open project…         │   │   Modified 2 d ago││
│  ├─────────────────────────┤   │ ▢ Pilot-02        ││
│  │ ⌁ Connect hardware (dim)│   └───────────────────┘│
│  │   Cyton + Daisy … 🔒    │                        │
└──────────────────────────────────────────────────────┘
```
- **Window:** `.containerBackground(.ultraThinMaterial, for: .window)` (macOS 15+) behind `AmbientBackdrop`; `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)`; `.windowBackgroundDragBehavior(.enabled)`.
- **Actions:** a `GlassEffectContainer(spacing: 12)` (26) wraps the three cards.
  - Each card: `.padding(16)`, `.contentShape(.rect(cornerRadius: 16))`.
  - On 26: `.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))`. On 15: the `GlassSurface` material fallback, plus hover brightness +6%.
  - Symbol: `.symbolRenderingMode(.hierarchical)` in accentInk, 28pt.
  - Title: `.system(.headline, design: .rounded)`.
  - Caption: `.callout` textSecondary, `lineLimit(2)`.
- **Disabled card (Connect hardware):**
  - Dim only the icon and title, to textTertiary.
  - The caption stays textSecondary at full contrast, because it is information.
  - Keep the `lock` "Not available yet" label (caption, textSecondary).
  - No `.interactive()`. Keep the existing focusable + hint accessibility.
  - Remove the 0.6 whole-card opacity.
- **Recents:**
  - A `Card` containing a `List` with `.listStyle(.plain)`, `.scrollContentBackground(.hidden)` and `.listRowSeparator(.hidden)`. Rows have radius 10, and hover/selection fill is accentFill @ 12%. No `.bordered` list.
  - Each row: a `shippingbox` icon and the name (`.body` semibold).
  - Path: `.caption` textSecondary (not mono), with `.truncationMode(.head)` to keep the useful tail, and `~` abbreviation.
  - Trailing date: "Modified 4 min ago" (`.caption`, textSecondary). It is the folder's mtime, not last-opened, so say "Modified".
  - Missing project: `exclamationmark.triangle.fill` in the warning colour + "Not found".
  - Empty state: "No recent projects.", centred, textSecondary.
- **Icon:** see Section 4. 72pt, `.accessibilityHidden(true)`.

### 2.2 Project window chrome
```
┌─ sidebar (system) ─┬─ content ──┬─ detail ─────────────────────┬ inspector ┐
│ Project            │ list       │ [status panel (floating)]    │ (system)  │
│ ▮ Recordings   1   │            │  AmbientBackdrop + cards     │           │
│   Results      2   │            │                              │           │
│ ● No hardware · Replay          │                              │           │
└────────────────────┴────────────┴──────────────────────────────┴───────────┘
 toolbar:  [▶ Evaluate]  ‹fixed›  [Parameters… ] [⇪ Export]  ‹fixed›  [▯ Inspector]
```
- Leave `NavigationSplitView`, `.inspector` and `List(.sidebar)` as they are. macOS 26 supplies a floating glass sidebar, glass toolbar groups and the scroll-edge effect; macOS 15 supplies the sidebar material. Don't add backgrounds.
- **Sidebar rows:** `Label(...).symbolRenderingMode(.hierarchical)`; keep the badges.
- **Sidebar footer status:** plain text on the sidebar, with no glass (that would be glass on glass). An `HStack` of `cable.connector.slash` and two lines, "No hardware connected" / "Replay mode", in `.caption` textSecondary, with `.padding(12)`.
- **Toolbar (`.primaryAction`):**
  - Evaluate first, as a `Label` with `.labelStyle(.titleAndIcon)` so it isn't an unlabeled glyph, using `.buttonStyle(.borderedProminent)`. The system renders it as tinted glass on 26.
  - Then `ToolbarSpacer(.fixed)` (26 only; wrap it in `if #available`), Parameters… and Export, another `ToolbarSpacer(.fixed)`, and the inspector toggle.
  - While a run is going, Evaluate swaps to Cancel (`stop.fill`) in the same slot.
  - Don't add a second prominent button in the inspector beyond what Section 2.4 describes.
- **Title:** the project name, `lineLimit(1)` (the system truncates in the middle). Subtitle: the selection. Keep the strings.
- **Window minimum:** 1100x640. It was 1000, which left the detail column about 300pt wide (sidebar 190 + content 230 + inspector 280).
- **Inspector:** shown only when `section == .recordings`. Keep the user's preference in `showInspector`, but pass `isPresented: showInspector && section == .recordings`.
- **Placeholders** (Protocols, Live Test, Pipelines detail): move the `ContentUnavailableView` into the detail column and leave the content column empty. The `ContentUnavailableView` title and description use textSecondary at full opacity, with no extra dimming.

### 2.3 Recording detail
```
┌ detail (AmbientBackdrop) ─────────────────────────────────┐
│ S001 · 3 runs                         (title, rounded)     │
│ ⚠ Public dataset, not recorded on OpenBCI Cyton+Daisy; one │  solid warning chip
│   subject; ~22 trials per class                            │
│ ┌ Card: Source ───────────────────────────────────────────┐│
│ │ Dataset  PhysioNet EEG…v1.0.0   DOI      10.13026/C28G6P││
│ │ Subject  S001                   Runs     S001R04, …R08  ││
│ │ Sample   160 Hz                 Reference per dataset … ││
│ │ License  ODC-BY                 Montage   undeclared    ││
│ │ ▸ Citations (selectable, links)                         ││
│ └─────────────────────────────────────────────────────────┘│
│        ( Channels 16 | Segments 3 | Events 90 )            │
│ ┌ Card: Table ────────────────────────────────────────────┐│
│ │ ID ^  Label  Unit  Kind                                 ││
│ │ ch00  FC3    uV    eeg                                  ││
└────────────────────────────────────────────────────────────┘
```
- **Source card:** replace the top grouped `Form` with a `Card` holding a 4-column `Grid`. Labels are textSecondary `.callout`; values are `.callout` and selectable; long values wrap. Citations go in a `DisclosureGroup`, collapsed by default. The card ends up about 180pt tall and is never clipped at a 640pt window height.
- **Table:** gets `.frame(minHeight: 240)` and the remaining space.
- **Warning:** `StatusChip(.warning, ...)`, regular-weight `.callout` text; the current bold run-on is harder to read. The wording is unchanged.
- **Picker:** `.pickerStyle(.segmented)`, labels hidden, centred. The system draws it as glass on 26.
- **Table styling:**
  - Inside a `Card`, with `.alternatingRowBackgrounds()` (fine on both 15 and 26).
  - Header on surface2. Keep the sortable columns and monospaced IDs.
  - "undeclared" in italic textSecondary.
  - Table background `.scrollContentBackground(.hidden)` so the card shows through.
- **macOS 26:** the default `.scrollEdgeEffectStyle(.soft, for: .top)`; no change needed.

### 2.4 Evaluate inspector (system inspector surface; no glass inside)
```
 Evaluate
 Recording            S001 · 3 runs
 Seed                           0
 [        ▶ Evaluate  ⌘R        ]   (borderedProminent, capsule, large)
 What this changes
  · Runs CSP + … on the 3 runs …
  · The recording is not modified.
  · The result is stored as a new record …
 What would make this misleading
  # 23 "cue_left_fist" and 22 …
  ? No session is recorded …
  👤 One subject (S001) …
  ⚠ Public recording …            (symbol orange, text primary)
  ▥ One run is held out …
 ──────────── (pinned footer) ───
 [ How the split works ]          (.bordered)
```
- **Container:** `ScrollView` + `VStack(alignment: .leading, spacing: 16)`, padding 16. No `Form(.grouped)`, so no hairline per sentence and no card per row.
- **Section headers:** `.system(.subheadline, design: .rounded).weight(.semibold)`, textSecondary (not tertiary).
- **"What this changes":** three paragraphs, `.callout`, no dividers.
- **"What would make this misleading":**
  - Rows with a 20pt icon column. The icons differ by shape (number / question / person / triangle / chart), and the warning triangle uses the warning colour. Every row has text, so no meaning rests on colour.
  - Don't collapse this block. It is the honesty block.
- **Pinned footer:** `.safeAreaInset(edge: .bottom)` holds "How the split works", so it is never below the fold. Add `.scrollEdgeEffectStyle(.soft, for: .bottom)` on 26.
- **Split popover** (system glass on 26): `VStack(spacing: 8)`, width 360, `.callout`. Bullets as small `Label("", systemImage: "circle.fill")` or real `•` text.
- **Evaluate button:** the single prominent Evaluate lives here. The toolbar Evaluate is still prominent per the system; the duplicate is acceptable because this button sits next to the explanation. The inspector is hidden when the section isn't Recordings.

### 2.5 Progress and banners
These sit at the top of the detail column via `.safeAreaInset(edge: .top)`, with 12pt/16pt padding, so content shifts and nothing is covered. One panel at a time, in priority order: error banner > progress > notice.
```
 ┌ floating glass panel, r 28, max-width 680 ──────────────────┐
 │ ✓ Loading   ● Fit   ○ Cross-validation   ○ Holdout   [Cancel]│
 │ ▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░  detail line                         │
 └──────────────────────────────────────────────────────────────┘
```
- **Progress panel:**
  - `GlassSurface(shape: .rect(cornerRadius: 28))`.
  - Stage marks: done `checkmark.circle.fill`, current `circle.inset.filled`, pending `circle`. They differ by shape and weight, not colour.
  - `ProgressView(value:total:)` tinted accentInk, a 6pt tall track via `.progressViewStyle(.linear)`. Keep the accessibility label and value.
  - Cancel uses `.buttonStyle(.bordered)` (no glass on glass) and keeps ⌘.
- **Error banner** (analysis unavailable / failed): SOLID, not glass.
  - `surface1` with a danger @ 12% fill, a 1pt danger border, and a 4pt leading danger bar.
  - `exclamationmark.octagon.fill`; title `.headline` ("Analysis unavailable"); body `.callout` textPrimary, existing copy.
  - Retry uses `appProminentButton()`.
  - The "Show details" disclosure keeps its mono caption in a surface2 well.
  - Never auto-dismisses.
- **Notice** (saved / exported / cancelled / reproduced):
  - A glass capsule (r 28) with a symbol, text and an X button.
  - Auto-dismisses after 6 s, except `.diverged` and `.exportFailed`. Those are solid warning chips that stay until dismissed.
  - Notices clear on a section change (fixes the stale banner).
  - VoiceOver announcements are unchanged.

### 2.6 Result detail
```
┌ detail ─ AmbientBackdrop ──────────────────────────────────────────────┐
│ ┌ GLASS HERO (r 28, tint, scrim) ────────────────────────────────────┐ │
│ │ Balanced accuracy                                                   │ │
│ │ 0.62                                         (64pt rounded)        │ │
│ │ BA   ┄┄┄┄┄┄┄┄┄┄┄┄●┄┄┄┄┄┄┄┄┄┄┄┄   (dashed track: no interval)      │ │
│ │ ⓘ Balanced-accuracy interval: unavailable (one held-out run)       │ │
│ │ Accuracy 0.60 · 95 % CI 0.32–0.84 (trial-level, n = 15)  (title3)  │ │
│ │ 0 ────[███████●████]──┬──────────────────────── 1                  │ │
│ │       0.32   0.60  0.84  0.53 larger-class rate                    │ │
│ │ Interval includes the larger-class rate.                           │ │
│ │ n = 15 held-out trials in 1 run · Session unknown                  │ │
│ │ CSP + shrinkage LDA · stored 22 Oct 2026 at 20:25     [Export…]    │ │
│ └─────────────────────────────────────────────────────────────────────┘ │
│ ⚠ Public dataset, not recorded on OpenBCI …            (solid chip)    │
│ ↻ Reproduction of 20:25 - evaluation.json identical    (solid chip, link)│
│ ┌ Card: Confusion ────────────┐ ┌ Card: Baseline comparison ─────────┐ │
│ ┌ Card: Class counts ─────────┐ ┌ Card: Held-out runs ───────────────┐ │
│ ┌ Card: Split policy ──────────────────────────────────────────────┐   │
│ ▸ Exclusions (0)                                                      │
└────────────────────────────────────────────────────────────────────────┘
```
Layout: `ScrollView` > `VStack(spacing: 16)`, padding 24. Below the hero, `ViewThatFits(in: .horizontal)` picks a 2-column `Grid` when the detail is at least 760 wide, otherwise a single column. Cards use `Card`.

**Hero.** Decision #8's wording is unchanged; the strings in `ResultDetailModel.headline` stay the source of truth.
- **Model:** add `headline.balancedAccuracyValue` ("0.62"). Keep the combined `balancedAccuracy` string for VoiceOver and tests.
- **Number:** "Balanced accuracy" (heroLabel, textSecondary) above the value (display, textPrimary).
- **VoiceOver:** the whole hero is `accessibilityElement(.combine)` and reads "Balanced accuracy 0.62. Accuracy 0.60, 95 percent confidence interval 0.32 to 0.84, trial-level, 15 trials.", followed by the interval status line.
- **Accuracy line:** `m.headline.accuracy` verbatim, `.system(.title3, design: .rounded).weight(.semibold).monospacedDigit()`, textPrimary.
- **Interval line:** `m.headline.balancedAccuracyInterval` verbatim, `.callout`, textPrimary (not secondary), with `info.circle` when unavailable.
- **Third line:** `trialsLine`, with the evidence token replaced by the `EvidenceText` short phrase ("Session unknown"), never the raw token.
- **Size honesty:** the CI range bar spans the full card width, 12pt tall with an 18pt marker, so the uncertainty carries as much visual weight as the number. Don't shrink it.
- **`RangeBar(value:, interval: ClosedRange<Double>?, reference: Double?, label:)`:**
  - Scale 0...1, with ticks at 0, 0.5 and 1 (caption mono, textSecondary).
  - Track: a surface2 capsule, 12pt.
  - Interval: a 12pt capsule with an accentInk → aurora gradient and a 1.5pt surface1 outline, so it reads under Increase Contrast. End labels (mono callout) under both ends.
  - Point: an 18pt accentFill circle with a 2pt surface1 ring and the value label above.
  - When `interval == nil`, draw the track dashed (`StrokeStyle(lineWidth: 2, dash: [4,4])` in textTertiary) with only the marker, so the absence is visible rather than blank.
  - Reference tick: a 2pt tall line in textSecondary with a caption label.
  - Accessibility: `.accessibilityElement`, label "Accuracy interval", value "0.32 to 0.84, point estimate 0.60".
- **BA bar:** when a run-level interval exists (≥ 2 held-out runs), add a second bar whose interval is the bootstrap CI, labelled "Run-level bootstrap, N held-out runs". Never put the trial-level interval on the BA bar.
- **Reference value** for the accuracy bar: max(classCounts.holdout) / sum, i.e. the larger class's share, labelled "larger-class rate".
  - If lower ≤ ref ≤ upper, show "Interval includes the larger-class rate." (symbol `info.circle`).
  - Otherwise show "Interval lies entirely above/below the larger-class rate."
  - It is derived from stored counts only. Add model tests. (PM questions a/b.)
- **Hero surface:** `GlassSurface(shape: .rect(cornerRadius: 28), tint: accentInk@10/14%, scrim: surface1@60/55%)`, padding 28. macOS 15: material + scrim + rim. Reduce Transparency / Increase Contrast: `Card` style.
- **Export button inside the hero:** `.buttonStyle(.bordered)` (no glass on glass). Keep the toolbar Export too: the hero button is the discoverable one and the toolbar has ⇧⌘X. The toolbar one is disabled when no result is selected.
- **Warning chip:** `StatusChip(.warning)` below the hero, full text, never collapsed.
- **Reproduction chip:**
  - Identical → `StatusChip(.info)` styled as a link button: "Reproduction of 20:25 - evaluation.json identical to the original". Clicking opens the original.
  - Differs → `StatusChip(.warning)` with the existing bug text, persistent.
  - Once the chip exists, remove the duplicate top notice for `.reproduced`. Keep only the transient toast on creation.

**Confusion matrix (`Card`).**
```
              Predicted
          Left-fist cue   Right-fist cue
          cue_left_fist   cue_right_fist
 True  Left-fist cue   ┌ ✓  7 ┐ ┌ ✗  0 ┐
       cue_left_fist   │ of 7  │ │ of 7  │
 True  Right-fist cue  ┌ ✗  6 ┐ ┌ ✓  2 ┐
       cue_right_fist  │ of 8  │ │ of 8  │
 Of 15 held-out trials, 9 were classified correctly: 7 of 7 … (summary kept)
```
- **Layout:** cells 120x84, radius 14, 12pt gaps. Column headers centred above; row headers trailing-aligned with a 12pt gap. Headers use the display name (`.callout` semibold) plus the raw label (mono caption, textSecondary).
- **Cell content:** the number in `matrixNumber`; a sub-line "of N" (row total) in `.caption` textSecondary; a corner glyph (`checkmark` correct, `xmark` wrong) in `.caption.weight(.bold)`, textPrimary at 80%.
- **Diagonal fill:** accentFill with alpha = 0.10 + 0.35 × (count / rowTotal) in dark (max 0.45), and 0.08 + 0.22 × (count / rowTotal) in light (max 0.30). Text is textPrimary (contrast ≥ 7:1 at the cap).
- **Off-diagonal fill:** surface2, plus a diagonal hatch (Canvas, textTertiary 25%, 1pt, 45°) when count > 0. Never accent. Zero cells are plain surface2 with no hatch.
- **Accessibility:** keep the per-cell labels and the full-sentence summary. Label text uses the display name with the raw label in parentheses.

**Class counts and Held-out runs:** a native `Table` inside a `Card` (solid), `.monospacedDigit()`, header on surface2. The first column shows the display name, with the raw label as a second mono line.

**Baseline comparison (`Card`):**
- Two horizontal bars on 0...1 (reference vs baseline), labelled with their values.
- Then `differenceLine` and `differenceInterval` (callout, textPrimary, `info.circle` when "unavailable").
- Then `pairedLine`, rendered as four chips (Both correct / Reference only / Baseline only / Neither) with their counts in a smaller matrix number (`.title3.monospacedDigit()`).
- Then `cvLine` as a caption.
- Never write "better/worse" prose. Show the signed difference and its interval, or "unavailable".

**Split policy:** a `Card` of `LabeledContent` rows; labels textSecondary, values mono where they are IDs. The evidence row uses the `EvidenceText` symbol and sentence (`.callout`, textPrimary).

**Exclusions:** a `DisclosureGroup` in a Card, with the count in the title.

**Parameters popover** (system glass on 26; the content sits on solid fields):
- `VStack(alignment: .leading, spacing: 16)`, width 380, padding 20.
- Four field blocks, each with:
  - A label (`.callout` semibold).
  - A `TextField` with `.textFieldStyle(.roundedBorder)` and a trailing "Default 4" (`.caption`, textSecondary, from the worker) in addition to the placeholder. Placeholders fail contrast and vanish once you type.
  - Help text in `.caption` textSecondary, with copy per decision #10.
- Reset is `.bordered`, trailing.
- Loading and unavailable states use `StatusChip(.info/.warning)`.
- Values are live, so there's no "Apply"; dismiss with Esc or by clicking away.

## 3. Class-name display
Rule scope: "labels exactly as stored" applies to channel IDs and labels and to event labels. Class labels are the worker's labels. They are shown in two forms, and the stored one is never replaced.
- **`ClassDisplay.name(_ raw: String) -> String`:**
  - `^cue_(left|right)_fist$` → "Left-fist cue" / "Right-fist cue".
  - Generic fallback for `^cue_(.+)$` → "<words> cue", sentence-cased.
  - Anything else → the raw label verbatim.
  - No per-dataset logic beyond the regex.
- **Where the display name appears:** the Result hero and trials lines (none contain labels today), confusion matrix headers, class counts, the summary sentence, and accessibility labels ("Left-fist cue, stored label cue_left_fist"). Always show the raw label as a mono secondary line or in `.help`.
- **Never mapped:** the Events table, channel tables, the inspector sentence "23 "cue_left_fist" and 22 …" (quoted raw), exported files, copy-to-clipboard.
- **Why "cue":** the stored label is the cue that was shown, not proof of an executed or imagined movement. "Left fist" alone would overclaim.

## 4. App icon
An Icon Composer `.icon` document (Xcode 26), plus a flat 1024 AppIcon fallback set for macOS 15. Generate the fallback from the same shapes with an in-repo SwiftUI `ImageRenderer` script; no external assets.
- **Base:** a continuous squircle.
  - Dark/default: vertical gradient #0A1018 → #12304F.
  - Light appearance: #F2F7FF → #CFE3FF.
  - Tinted appearance: mono.
- **Glyph layer 1 (glass layer):** a thin circle ("scalp seen from above"), diameter 54% of the canvas, 14 px stroke, #E8F3FF @ 90% (light variant #0A5FCF).
- **Glyph layer 2:** one calm waveform crossing the circle horizontally, with a single rounded peak.
  - Left half #E8F3FF @ 35%; right half a #5AA9FF → #58E0D6 gradient.
  - 16 px stroke, round caps, a soft outer glow (aurora @ 30%, blur 24 px).
- **Glyph layer 3:** one small solid dot (an electrode) at the upper right of the circle, #58E0D6, 28 px.
- No threads, no wordmark, nothing resembling a third-party mark.
- Replaces the default grid placeholder currently shown on Welcome. Test at 16, 32, 128 and 512.

## 5. Review findings (screenshots pr3-*.png)
1. **Stale notice.** "Reproduced - identical to 20:25 original" stays on Pipelines and Protocols and repeats the in-card badge. Fix: clear notices on a section change, keep one persistent chip in the result, auto-dismiss the toast after 6 s.
2. **Inspector shown everywhere and clipped.** The Evaluate inspector appears on Results, Pipelines and Protocols, where it's irrelevant. The "What would make this misleading" block is clipped at the bottom ("interval exists." is cut off), and "How the split works" sits below the fold. Fix: Section 2.4 (Recordings only, scroll + pinned footer).
3. **Source form clipped.** The Recording "Source" form is cut off mid-row at "Reference", so License, Citations and Montage can't be reached, with no scroll cue. Fix: Section 2.3's compact 4-column card.
4. **Confusion matrix.**
   - The "Predicted cue_left_fist" and "Predicted cue_right_fist" headers touch, and the row labels hug the cells.
   - The off-diagonal 6 is shaded as strongly as the correct 7, so errors look like successes.
   - The check glyph is tiny and secondary on blue (about 3:1).
   - Fix: Section 2.6.
5. **Hero hierarchy.** The raw token "unknown-session" shows in the trials line. The BA interval line is `.secondary` even though it states a limitation. Accuracy and CI are plain text, so the uncertainty is less prominent than the number. Fix: range bars, the EvidenceText phrase, textPrimary.
6. **Toolbar duplication.** Evaluate and Export are bare icons floating over the inspector column (the toolbar items land in the inspector region). Evaluate is duplicated in the inspector and Export in the result card. Fix: a titleAndIcon Evaluate, ToolbarSpacer groups, one prominent action per region (Sections 2.2 and 2.4).
7. **Result rows wrap.** "Reproduction of 20:25" wraps to two lines at 230pt. Fix: row text "Reproduction" with `arrow.triangle.2.circlepath` and the time; the full phrase goes in `.help` and the accessibility label; content column minimum 250.
8. **Welcome.**
   - The placeholder grid icon has a white border.
   - The `.bordered` list is heavy, with hard separators.
   - Recent paths are middle-truncated ("/private/tmp/c...78/scratchpad"), but the tail is what matters; use head truncation.
   - The date column is the folder's mtime but reads like last-opened ("4 minutes ago"); label it "Modified".
   - The test names (f2, e-noTable) and /private/tmp paths are test data, not a defect.
9. **Welcome disabled card contrast.** The 0.6 opacity on the whole card pushes the caption below 4.5:1 (about 3:1, grey on dark). Fix: dim only the icon and title; the caption stays textSecondary; keep the lock line.
10. **Sidebar footer.** "No hardware connected · Replay mode" wraps awkwardly at 12pt, with a tiny slashed icon and low contrast. Fix: two deliberate lines, textSecondary, `.caption`.
11. **Placeholders.** The Protocols placeholder lives in the narrow content column, with an empty detail. Pipelines' "Read-only in phase 1" is large bold mid-grey on dark (about 3.5:1). Fix: move it into the detail column and use textSecondary at full opacity.
12. **Pipelines list.** Hand-typed "•" bullets with hard wraps inside a 230pt column. The recipe IDs in mono are fine. Fix: `Label` rows or a real list, `.callout`.
13. **Inspector Form.** Every sentence of "What this changes" is its own grouped row with hairlines, so it reads like a settings table. Fix: paragraphs, no dividers.
14. **Hierarchy and spacing.** The hero stack uses four similar greys with 6pt gaps. Section titles ("Confusion matrix (held-out trials)") have the same weight as table headers. Fix: the 12/16/24 spacing scale and the sectionHeader style.
15. **Narrow detail column.** A 1000pt minimum window leaves about 300pt for the detail when the inspector is open. The screenshots are 1280pt wide, so it doesn't show there. Fix: minimum 1100, inspector hidden outside Recordings, `ViewThatFits` with 1 or 2 columns.
16. **Mixed edge treatment.** The sidebar is floating and rounded, but the inspector is flat with 1px column dividers. Expected to resolve with the Xcode 26 build. If it persists on macOS 26, don't hand-draw the sidebar or divider; file it as a follow-up.
17. **Parameters defaults.** Placeholder-only defaults disappear once typed over and have low contrast. Fix: the trailing "Default N" text.
18. **Accent contrast.** The saturated accent blue (#3478F6-like) behind white labels in dark mode gives the Evaluate button about 4:1. Fix: the accentFill #2A74D6 dark token.

## 6. Acceptance checks (PM eyeball)
- **Hero:** "Balanced accuracy 0.62" reads first. Directly under it, the accuracy-with-CI line and a full-width range bar are just as hard to miss. With one held-out run, the BA bar is dashed and "Balanced-accuracy interval: unavailable (one held-out run)" is full-contrast.
- **Warning chip:** the public-dataset warning is a solid, full-size chip with an icon, in both modes, with and without glass.
- **Glass placement:** tables, the matrix and numbers sit on opaque cards. Glass appears only on the toolbar/sidebar/inspector chrome, the Welcome action cards, the Result hero, the progress and notice panel, and popovers. No glass sits on other glass.
- **Confusion matrix:** correct cells have a check and blue shading; wrong cells have an x and hatching, so a column of errors doesn't look like success. Class names read "Left-fist cue" with `cue_left_fist` underneath, while the Events table still shows `cue_left_fist`.
- **System settings:**
  - Light and Dark both look intentional.
  - Reduce Transparency makes every glass surface solid with a border.
  - Increase Contrast thickens borders and darkens secondary text.
  - Reduce Motion removes all animation (no fade or draw-in).
- **macOS 15 vs 26:** the same layout and copy. 26 shows real Liquid Glass (floating sidebar, glass toolbar groups, glass hero); 15 shows frosted material with a rim.
- **Evaluate:** a floating progress panel whose stage marks show done/current/pending by shape. Cancel works with ⌘. A stopped worker shows a solid red banner with Retry, not a toast.
- **Navigation:** going Recordings → Results → Pipelines never leaves a stale "Reproduced" banner. Protocols and Live Test show their placeholder in the detail column.
- **Recording detail at 1100x640:** the Source card shows every row without clipping, and the table is still usable.
- **Welcome:** shows the new icon, a readable disabled-card caption, head-truncated paths and "Modified ..." dates.
- **Contrast test:** the Section 1.1 unit test passes for every token pair in both modes.

Sources (verified by the designer): Apple developer docs for `glassEffect(_:in:)`, `Glass`, `GlassEffectContainer`, `PrimitiveButtonStyle.glass` / `.glassProminent`, `backgroundExtensionEffect()`, `glassEffectID(_:in:)`, `scrollEdgeEffectStyle(_:for:)`, `ToolbarSpacer`, `sharedBackgroundVisibility(_:)`, all macOS 26.0+. The HIG pages did not render for the fetcher, so re-check "Adopting Liquid Glass" before sign-off.
