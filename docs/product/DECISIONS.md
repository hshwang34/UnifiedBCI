# Product decision log

Append-only. Newest at the bottom. When a decision is reversed, add a new entry and mark the old
one `SUPERSEDED by #n` — don't delete it. Agents read this before raising a product question.

Format: `#n · date · decision` — then *why*, and where it lives in code/docs.

---
#1 · 2026-10-20 · Project direction is the PRD's middle scope: a reproducible experiment workspace (not a viewer, not a general BCI IDE), as a native SwiftUI app with a bundled Python worker.
*Why:* PM delegated the call ("do what you think should be best"); PRD §3 and §7 recommend it. Lives in docs/PRD.md, docs/adr/0001.

#2 · 2026-10-20 · After the phase-0 spike, the first feature brief is Phase 1 "replay-to-report" (project store + bundled public recording + inspection + evaluation), not closing the signing gate first.
*Why:* delivers the first user-visible value (reproduce a result with no hardware); signing work folds in as research findings land. Brief: docs/product/briefs/001-replay-to-report.md.

#3 · 2026-10-20 · PM mode bootstrapped: docs/product/ holds the decision log and briefs.

#4 · 2026-10-20 · Bundled example = PhysioNet EEGMMIDB subject S001, imagery runs 4/8/12 (left vs right fist), cropped to 16 sensorimotor channels, ~22 trials/class, ODC-BY with citations shown.
*Why:* only cleanly redistributable MI dataset; small; wide uncertainty is shown honestly. Brief 001 Q1.

#5 · 2026-10-20 · v0.x supports Apple Silicon only; bundled Python is arm64. Intel is a later support-matrix decision.
*Why:* owner's Mac first (PRD §7); universal doubles bundle and signing work. Brief 001 Q2.

#6 · 2026-10-20 · Signal-quality inspection (PSD, clipping, flatlines, named rules) is its own brief 002, not part of 001.
*Why:* evaluation is the promise; inspection needs its own criteria. Brief 001 Q3.

#7 · 2026-10-20 · First launch shows a welcome window (Open project · Explore an example · Connect hardware); nothing auto-opens.
*Why:* keeps both entry points visible (PRD §4). Brief 001 Q4.

#8 · 2026-10-20 · Result headline shows "Balanced accuracy X" with "Accuracy Y · 95 % CI a–b (trial-level, n)" beneath it; the trial-level interval is never labelled as a balanced-accuracy interval; a run-level BA interval shows only when ≥ 2 runs are held out, else "unavailable (one held-out run)".
*Why:* the stored CI is Clopper-Pearson on accuracy; mislabelling it would overclaim. Decided by the lead as a safe default (designer flag); PM may reverse. Lives in docs/product/briefs/001-ui-spec.md.

#9 · 2026-10-22 · Visual direction: "sterile, clean, clear" — visionOS-like glass. Liquid Glass (`glassEffect`) on macOS 26; frosted-material fallback on macOS 15, which stays the minimum. Light and dark both designed; follows the system setting and honours Reduce Transparency / Increase Contrast. Neuralink's Telepathy app is a tone reference only (no branding borrowed). Supersedes the "system components only, no custom styling" line in 001-ui-spec.md.
*Why:* PM direction (brief 001 PR 3). Lives in docs/product/briefs/001-visual-spec.md.

#10 · 2026-10-22 · Seed copy reads "Chooses the held-out runs and the bootstrap draws. The same seed gives the same split." (the UI spec's "the split stays the same" was wrong: no frozen split manifest is passed yet).
*Why:* honest copy over spec wording; decided by the lead as a safe default, PM may reverse (alternative: ship a frozen split manifest per recording).

#11 · 2026-10-22 · Class names display as "Left-fist cue" / "Right-fist cue" with the stored label (`cue_left_fist`) shown beneath; channels, events and exports stay verbatim.
*Why:* the label records the cue shown, not proof of movement or imagery. Brief 001 visual spec §3.

#12 · 2026-10-22 · The accuracy range bar marks the larger-class rate with "Interval includes / lies above / lies below the larger-class rate."
*Why:* a plain "is this better than always guessing the bigger class?" cue, derived from stored counts only. Brief 001 visual spec §2.6.
