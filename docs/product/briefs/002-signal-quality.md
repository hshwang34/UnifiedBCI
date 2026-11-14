# 002 — Signal-quality inspection

**Status:** approved (lead defaults, PM delegated 2026-11-14) · **Owner:** PM · **PR:** — · **Updated:** 2026-11-14

## Problem
A developer who opens a recording today can see its channels, segments and events, and can run
an evaluation, but cannot see what the signal looks like. A flat electrode, a channel pinned at
its limit, strong mains hum or a muscle-noisy contact all change what an evaluation means, and
the app gives no hint of any of them. PRD §5 makes this a P0 requirement for the first
credible release ("Inspect raw and processed signals, PSD, clipping, flatlines, and probable
noise. Every indicator names its rule; 'good quality' is never presented as proof of neural
origin"), and phase 1's exit ("reproduce a result without hardware") lists signal inspection.

## Who it's for
The individual BCI developer, after opening a recording (the bundled example or their own)
and before or after evaluating it: "is there anything wrong with this data that I should know
before I trust a number?"

## What success looks like
- Opening a recording's **Quality** tab shows, per segment, a spectrum (PSD) for every channel,
  raw and band-passed, and a table of named checks per channel within a few seconds.
- Every flag says which rule fired, with its threshold, in plain words ("8 s of 62 s flat:
  standard deviation under 0.5 µV in a 1 s window").
- Nothing on the screen says the data is "good", "clean" or "neural". Unflagged means "none of
  these rules fired", and the screen says so.
- A short signal view shows raw and band-passed traces for a chosen window.

## Acceptance criteria
- [ ] Recording screen gets a **Quality** tab next to Channels / Segments / Events.
- [ ] Per segment and channel: flatline, pinned-at-limit, large-deflection, mains-line,
      outlier-amplitude and outlier-high-frequency checks, each with its rule text and measured
      value; a channel's row lists every rule that fired.
- [ ] PSD (Welch, 2 s Hann windows, 50 % overlap) per channel, log power, 1 Hz to Nyquist;
      raw (mean removed) and band-passed with the reference pipeline's band-pass (8–30 Hz,
      order 4, causal, from zero state, filter warm-up excluded). Toggle between the two.
- [ ] Mains check runs at 50 and 60 Hz; when the line frequency's comparison band doesn't fit
      below Nyquist, it says "not assessable at <rate> Hz" instead of a value.
- [ ] Signal view: raw and band-passed traces, all channels stacked, a 10 s window the user can
      move through the segment; channels with a flag are marked.
- [ ] Footer copy: "These checks describe the recording. They can't show that a signal comes
      from the brain." No overall pass/fail verdict.
- [ ] Inspection never changes the recording or the evaluation: flagged channels are not
      excluded anywhere (decision #24).
- [ ] Works on the bundled example and the tiny fixture; an injected flat channel, a pinned
      channel, a 60 Hz sinusoid and a high-variance channel are each flagged by exactly their
      rule in tests (known inputs, expected results — PRD §4).
- [ ] Worker failure shows the existing "analysis unavailable" state, not a blank tab.
- [ ] VoiceOver: each row reads channel, then flags; the PSD has an accessibility summary
      ("FC3: strongest peak 10.2 Hz").

## Out of scope
- Excluding channels or time spans from evaluation (later brief, needs its own provenance).
- User-editable thresholds (fixed v1 defaults, shown on screen).
- Impedance (needs live Cyton; PRD says show only when meaningful).
- Live-stream quality (phase 2), per-channel colour on the montage head (follow-up once this
  ships; decision #17 reserved it for real values).
- Artifact classification (eye/muscle/cardiac labels). The checks name rules, not causes.

## Open product questions (PM away; lead defaults, PM may reverse)
1. **Where does inspection live?** — A (tab on Recording), B (own sidebar section). **Default:** A — quality is a recording property; matches decision #16's placement of the montage view.
   → *Answer:* A (decision #21).
2. **Overall verdict?** — A (no verdict, per-rule flags only), B (traffic-light score). **Default:** A — PRD forbids presenting "good quality"; a score invites that reading.
   → *Answer:* A (decision #22).
3. **Thresholds editable?** — A (fixed, shown), B (editable per project). **Default:** A for v1; editing changes reproducibility and needs storage.
   → *Answer:* A (decision #23).
4. **Do flags exclude channels?** — A (never, display only), B (auto-exclude). **Default:** A — no silent changes to what's evaluated.
   → *Answer:* A (decision #24).

## Rules (v1 constants; shown verbatim in the UI)
Computed per segment and channel on the raw samples unless stated. "Window" = consecutive
non-overlapping 1 s windows.
| Check | Rule | Flag when |
|---|---|---|
| Flatline | window standard deviation < 0.5 µV | ≥ 1 window |
| Pinned at a limit | ≥ 5 consecutive samples equal to the channel's segment maximum or minimum | any run |
| Large deflections | window peak-to-peak > 200 µV | > 10 % of windows |
| Mains line (50 / 60 Hz) | PSD power in line ± 1 Hz vs mean of the flanking bands line ± (2–4) Hz | > 10 dB |
| Outlier amplitude | channel variance vs median across EEG channels in the segment | > 5× or < 0.2× |
| Outlier high-frequency power | channel 20–45 Hz band power (capped at Nyquist − 2 Hz) vs median across EEG channels | > 3× |
Non-EEG channel kinds are inspected but excluded from the cross-channel medians.

## Engineering decisions (lead)
- Worker computes everything (`inspect_recording` method, additive to protocol v1; `hello`
  lists it). Requests reference the recording by id, as evaluation does. Responses are bounded:
  PSD resampled to ≤ 256 frequency bins; the signal-window method returns at most 30 s ×
  channels, decimated to ≤ 2,000 points per channel (min/max envelope), so no raw data crosses
  the pipe in bulk.
- Band-passed PSD reuses the pipeline's `BandpassSpec` and `filter_segment` so inspection and
  evaluation see the same processed signal; warm-up samples (`settling_samples`) are excluded.
- Results are recomputed on demand and cached in memory per session; nothing is written to the
  project (inspection is not evidence yet).
- PR sequence (small PRs): (1) docs — this brief + decisions; (2) worker — quality rules, PSD,
  `inspect_recording` + tests with injected faults; (3) Swift — client contract + screen models
  (all copy) + tests; (4) Swift — Quality tab (table + PSD chart, Swift Charts); (5) worker +
  Swift — signal window method and trace view.

## Risks / what could go wrong for users
- A user reads "no flags" as "good data". Mitigated by the footer and the "none of these rules
  fired" wording.
- Thresholds tuned for scalp EEG in µV may misfire on other units; channels whose unit isn't µV
  get "not assessed (unit <u>)" for the amplitude rules.
- Inspection on a large recording could be slow; the tab shows progress and can be cancelled
  like evaluation.
