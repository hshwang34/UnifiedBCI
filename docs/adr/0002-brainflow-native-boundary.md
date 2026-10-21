# ADR 0002 — BrainFlow behind a C module map and a single-owner Swift actor

Status: accepted (2026-10-20) · Phase 0

## Context

Acquisition must have one owner, must not depend on the Python worker's health, and must
expose sequence numbers, receipt timestamps, and gaps rather than hiding them. BrainFlow is
the acquisition abstraction the PRD recommends. Its public ABI is C; its constants header
is C++ (`enum class`), and Swift's C++ interop has documented limits.

## Decision

- Link **only `libBoardController.dylib`** (universal x86_64/arm64, self-contained apart
  from libSystem/libc++), vendored from the worker's pinned wheel by
  `scripts/vendor_brainflow.sh` so Swift and Python always use the same build.
  `native/brainflow/lib/VERSION` is committed; the dylib is not.
- Import the C ABI through a **Clang module map** (`CBrainFlow`) over
  `board_controller.h` + `board_info_getter.h`. Constants are **hand-mirrored** in
  `BrainFlowConstants.swift` because the upstream header is C++; a comment ties the mirror
  to the vendored version.
- **`BrainFlowBoard` is an actor** holding one session. Every C call goes through it; the
  only consuming read is `read(count:)`/`readAll()`. Preview code consumes what the drain
  loop hands it — it never re-reads the device. `boardID` and `description` are
  `nonisolated let` so UI can show them without hopping.
- The full `BrainFlowInputParams` struct is mirrored because BrainFlow rejects a session
  when any key is missing from the JSON (verified against 5.23.0's `to_json()`).
- The dylib is embedded in `Contents/Frameworks` and re-signed on copy; its install name is
  already `@rpath/…`.

## Consequences

- Phase 0 proved: version query, Cyton+Daisy description (16 EEG rows @ 125 Hz, package
  row 0, timestamp row 30), and a synthetic-board stream read with non-decreasing receipt
  timestamps and contiguous sequence counters (mod 256), all from Swift 6 strict
  concurrency with no warnings.
- `ENABLE_HARDENED_RUNTIME` is `NO` for ad-hoc dev signing. Release signing with the
  personal Developer ID must re-enable it and sign the dylib with the same team, or library
  validation will refuse to load it. This is an open phase-0 gate.
- DataHandler/MLModule are deliberately not linked; filtering lives in the worker so the
  offline and online transforms are literally the same code.
- A native **acquisition helper process** (PRD: "native acquisition/recording helper") is
  not built yet; the actor lives in-app. Moving it out-of-process is a contained change
  because nothing else touches the C ABI.
