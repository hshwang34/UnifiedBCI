# ADR 0002 — BrainFlow behind a C module map and a single-owner Swift actor

Status: accepted (2026-10-20) · Phase 0

## Context

Acquisition must have one owner, must not depend on the Python worker's health, and must
expose sequence numbers, receipt timestamps, and gaps rather than hiding them. BrainFlow is
the acquisition abstraction the PRD recommends. Its public ABI is C; its constants header
is C++ (`enum class`), and Swift's C++ interop has documented limits.

## Decision

- Link **only `libBoardController.dylib`** (the wheel ships it universal x86_64/arm64,
  self-contained apart from libSystem/libc++; the app itself builds arm64-only per brief
  001 decision #5), vendored from the worker's pinned wheel by
  `scripts/vendor_brainflow.sh` so Swift and Python always use the same build.
  `native/brainflow/lib/VERSION` is committed; the dylib is not.
- Import the C ABI through a **Clang module map** (`CBrainFlow`) over
  `board_controller.h` + `board_info_getter.h`. Constants are **hand-mirrored** in
  `BrainFlowConstants.swift` because the upstream header is C++; a comment ties the mirror
  to the vendored version.
- **`BrainFlowBoard` is an actor** holding one session, executing on its own
  `DispatchSerialQueue` so blocking C calls (`prepare_session` can take seconds on a
  Cyton) never occupy a cooperative-pool thread. Every C call goes through it; the only
  consuming read is `read(count:)`/`readAll()`, which stamps each chunk with the host
  monotonic drain time and an `overflowSuspected` flag. Preview code consumes what the
  drain loop hands it — it never re-reads the device. `boardID` and `description` are
  `nonisolated let` so UI can show them without hopping. `release()` releases even when
  `stop_stream` fails; `deinit` stops then releases. BrainFlow's spdlog is set to warn+
  once per process (it echoes the params JSON at INFO).
- **Sequence accounting lives in the bridge** (`SequenceAccounting`): the expected counter
  step is 1 for the synthetic board and Cyton, **2 for Cyton+Daisy** (BrainFlow commits one
  sample per board/Daisy packet pair with the even counter). `delta == 0` on Daisy is a
  stale half-sample, other deltas are gaps whose size is ambiguous modulo 256. BrainFlow's
  timestamp row is `gettimeofday` wall clock; a backward step is a `clock_anomaly`, and
  timestamps are never used to detect gaps.
- The full `BrainFlowInputParams` struct is mirrored because BrainFlow rejects a session
  when any key is missing from the JSON (verified against 5.23.0's `to_json()`).
- The dylib is embedded in `Contents/Frameworks` and re-signed on copy; its install name is
  already `@rpath/…`.

## Consequences

- Phase 0 proved: version query, Cyton+Daisy description (16 EEG rows @ 125 Hz, package
  row 0, timestamp row 30), and a synthetic-board stream read with no sequence findings
  at step 1, all from Swift 6 strict concurrency with no warnings. Contiguous counters
  are proven **only for the synthetic board**; Daisy steps by 2 and has not been
  exercised. Non-decreasing receipt timestamps were an observation on that run, not a
  guarantee — the row is wall clock.
- `ENABLE_HARDENED_RUNTIME` is `NO` for ad-hoc dev signing. Release signing with the
  personal Developer ID must re-enable it and sign the dylib with the same team, or library
  validation will refuse to load it. This is an open phase-0 gate.
- DataHandler/MLModule are deliberately not linked; filtering lives in the worker so the
  offline and online transforms are literally the same code.
- A native **acquisition helper process** (PRD: "native acquisition/recording helper") is
  not built yet; the actor lives in-app. Moving it out-of-process is a contained change
  because nothing else touches the C ABI.
