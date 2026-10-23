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
