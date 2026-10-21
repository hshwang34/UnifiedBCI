# ADR 0001 — Native SwiftUI app with a bundled, isolated Python analysis worker

Status: accepted (2026-10-20) · Phase 0

## Context

The PRD asks for an Xcode-built macOS app whose first scientific recipe is CSP + shrinkage
LDA with leakage-safe evaluation, and explicitly leaves open whether "in Xcode" means
all-Swift. Two unknowns dominate phase 0: whether a scientific Python stack can ship inside
a signed app without touching the user's system Python, and whether a native BrainFlow
link is practical from Swift.

## Decision

- **SwiftUI app** owns navigation, acquisition, recording, cue presentation, and the
  project store.
- **Analysis worker** is a separate Python 3.12 process (`worker/`) pinned by `uv.lock`
  (numpy 2.5.4, scipy 1.18.1, scikit-learn 1.9.1, mne 1.13.2, brainflow 5.23.0). The app
  spawns it, talks JSON-lines over stdio (protocol v1, `WorkerClient.swift` ↔
  `protocol.py`), and treats its death as a visible "analysis unavailable" state.
- **Training and inference stay in the same Python implementation** so there is no
  Swift-vs-Python numerical parity problem to manage yet. A native inference port is a
  separate, benchmarked decision gated on reference fixtures and tolerances.
- **Binary data is out-of-band.** Requests reference immutable chunk files in the project
  directory; nothing large crosses the pipe. Progress and results are JSON.
- **Interpreter resolution** (`WorkerLaunch.locate`): bundled `Contents/Resources/worker/`
  first, then the dev venv named in Info.plist. Never a system Python.

## Consequences

- Phase 0 proved: Swift ↔ worker round-trip (ready → ping → fit/evaluate on synthetic
  data → shutdown) works from the Xcode test host in ~1–4 s per call; the worker and the
  Swift bridge load byte-identical BrainFlow builds (asserted by test).
- `scripts/bundle_worker.sh` produces a relocatable python-build-standalone interpreter plus
  `--target` site-packages that the build copies into the bundle. **Unproven gates remain:**
  code-signing every `.so` inside site-packages, hardened runtime with library validation,
  notarization, and a clean-machine launch. These are the exit criteria for phase 0 that
  this ADR does not yet claim.
- App Sandbox is off for development because the dev venv lives outside the bundle. A
  release build with a bundled worker should re-evaluate sandboxing.
- Rejected: all-Swift numerics (increases parity and correctness burden without improving
  the stated workflow); PythonKit in-process (a worker crash would take acquisition down;
  violates "a worker can fail while acquisition continues").
