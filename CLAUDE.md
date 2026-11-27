# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

BCI Workspace: a native macOS (SwiftUI, Swift 6 strict concurrency, arm64-only, macOS 15+)
app for producing, inspecting, reproducing and live-testing a BCI experiment. First device
OpenBCI Cyton+Daisy; first recipe two-class motor imagery with CSP + shrinkage LDA.
Recorded-data workflows come before hardware. `docs/PRD.md` is the product source;
`README.md` tracks what is built (it can lag a merged PR; trust the code).

## Commands

Requirements: Xcode 26, `brew install uv xcodegen`.

```sh
scripts/bootstrap.sh            # uv sync worker, vendor BrainFlow dylib, xcodegen generate
xcodegen generate               # after editing project.yml or adding/removing source files
xcodebuild -project BCIWorkspace.xcodeproj -scheme BCIWorkspace test
xcodebuild -project BCIWorkspace.xcodeproj -scheme BCIWorkspace test \
  -only-testing:BCIWorkspaceTests/ContractsTests/testDatesKeepFractionalSeconds
(cd worker && uv run pytest)                                   # worker tests
(cd worker && uv run pytest tests/test_pipeline.py -k warmup)  # single worker test
(cd worker && uv run pytest -m slow)                           # full bundled-example budget test
scripts/vendor_brainflow.sh     # re-run after brainflow changes in worker/uv.lock
scripts/bundle_worker.sh [--sign "<identity>"]   # build/worker-dist (embedded on next app build)
scripts/release.sh 0.1.0        # signed + notarized DMG (docs/RELEASING.md)
```

- `project.yml` is the source of truth; `BCIWorkspace.xcodeproj` is generated and gitignored.
  Targets: `BCIWorkspace` (app), `BCIStoreCrashHelper` (tool the store crash tests kill at
  a named commit point via `CRASH_AT=<point>:<n>`), `BCIWorkspaceTests`.
- Debug signs with the personal team (`V56DG94ZL5`, "Apple Development") so macOS keeps the
  Documents-folder grant across rebuilds; never switch it to a work team.
- `native/brainflow/lib/*.dylib` is gitignored (vendored by script); `lib/VERSION` is committed
  and tests assert the dylib, the worker, and VERSION all report the same BrainFlow build.
- Colour tokens live in `App/Assets.xcassets`, written by `scripts/make_theme_assets.py`
  (Any/Dark + High Contrast); the icon by `scripts/render_app_icon.swift`. Edit the scripts,
  not the asset JSON. `ThemeContrastTests` checks contrast.

### Driving the app without clicks (Debug only)

`App/LaunchArguments.swift` is compiled out of Release. Use it for screenshots and smoke runs:
`-BCIExploreExampleAt <new.bciproj>` / `-BCIOpenProject <path>`, `-BCIAutoEvaluate N`,
`-BCISection results`, `-BCISnapshotDir <dir>` (app renders its own windows to PNG, no
Screen Recording permission), `-BCIAppearance light|dark`, `-BCIWindowSize 1100x640`,
`-BCIFailingWorker YES` (shows the "analysis unavailable" banner), `-BCIQuitWhenDone YES`.
Live acquisition (brief 004): `-BCIConnectSource demo|synthetic` connects, confirms the
Demo's declared map (synthetic: Record without positions) and starts the preview (snapshot
`live-preview` after 12 s); `-BCILiveRecordSeconds N` then records N s and stops (snapshots
`live-recording`, `live-stopped`, `live-recorded`, `live-recorded-full`, `-segments`,
`-quality`); `-BCIConnectSheet YES` walks the Connect sheet instead. Quit other running
instances first or captures come out blank.
Cued protocol (brief 005): `-BCIProtocolEditor YES` snapshots the Protocols section and the
"New version…" editor (writes a version into the project); `-BCIStartRun N` with
`-BCIConnectSource demo|synthetic` runs a short 3-run protocol (N trials per class),
snapshots the operator panel, cue window and timing summary, then evaluates.
Live feedback (brief 006): `-BCIFreezeAndReplay YES` (with `-BCIAutoEvaluate`) freezes the
first result, then shows Replay and the parity view; `-BCILiveTest N` (with
`-BCIConnectSource demo|synthetic`) runs a live run of N trials per class, first recording,
evaluating and freezing a model if none matches.
Brief 009 diagnostics:
- `-BCILayoutDump YES` (with `-BCIConnectSource`) logs window and split-view geometry to
  `~/Library/Logs/BCIWorkspace/`.
- `-BCIHitTestStress YES` hit-tests every window continuously, the click path.
- `scripts/verify_flows.sh [flow…]` runs every flow and checks for a hang, a crash, error
  events and missing snapshots.
- `scripts/agent_eval/crash_repro.sh` runs the agent recording loop under stress.
- Wrap any app launch in `scripts/app_lock.sh`, so only one Debug copy runs. Two copies break
  each other's snapshots.
- The app ignores saved window state, so a launch always shows Welcome.
- `bci app diagnostics` returns recent events, errors, jobs and crash summaries.

Full list in the file's header comment.

## Architecture

Two processes (ADR 0001, 0002 in `docs/adr/`):

- **Swift app** (`App/` + `Sources/`, all compiled into the single `BCIWorkspace` target)
  owns UI, acquisition, recording, and the project store.
  - `App/Workspace.swift` — app-wide state: exactly one `ProjectSession` per canonical
    project directory (symlinks and APFS case folded). A project is never opened twice,
    because the store's orphan sweep assumes no second store evaluates in that directory.
  - `App/ProjectSession.swift` — one open project (store + `EvaluationRunner` + selection),
    `@MainActor`; all I/O happens in actors or detached tasks, never on the main thread.
  - `App/Models/ScreenModels.swift`, `ResultModels.swift` — every string a screen shows is
    built here (locale-independent `Fmt`), so views stay thin and tests check copy without
    rendering. `App/Design/` holds the glass-look tokens and wrappers (visual spec).
  - `Sources/ProjectStore/` — `ProjectStore` actor over one `.bciproj`. The directory scan
    is the truth (no index file); `open` sweeps crash orphans, `verify(recording:)` checks
    chunk hashes on demand. `ChunkWriter` + `AtomicFile` implement the commit protocol.
  - `Sources/Evaluation/EvaluationRunner.swift` — one evaluation at a time: starts/restarts
    the worker, calls `fit_evaluate_project`, forwards typed progress, stores the result
    with reproduction links. Failures split into worker-unavailable (retry with a fresh
    worker), worker-refused, and cancelled (nothing saved).
  - `Sources/BrainFlowBridge/` — `BrainFlowBoard` actor on its own `DispatchSerialQueue`;
    the only code that touches BrainFlow's C ABI (imported as Clang module `CBrainFlow` via
    `native/brainflow/include/module.modulemap`). Constants are hand-mirrored in
    `BrainFlowConstants.swift` because the upstream header is C++ — update on version bumps.
    `SequenceAccounting` detects gaps from package counters (step 1, or 2 mod 256 on Daisy),
    never from timestamps (BrainFlow's timestamp row is wall clock).
  - `Sources/Acquisition/` — `AcquisitionSession` actor: the PRD §7 state machine, one drain
    loop (the only board reader) fanning out to `RecordingWriter`, the newest-wins preview
    (`PreviewBuffer`) and `StreamHealth`; auto-reconnect into a new segment (decision #32);
    `disconnect()` waits for every finishing recording. `AcquisitionSource`: serial, synthetic,
    playback/Demo (decision #42). Screens: `App/ConnectController.swift`,
    `App/Views/AcquisitionView.swift`, copy in `App/Models/AcquisitionModels.swift` / `LiveModels.swift`.
  - `Sources/WorkerClient/` — `WorkerClient` actor spawning and talking to the Python worker;
    `WorkerLaunch.locate` picks the bundled `Contents/Resources/worker/` first, else the dev
    venv from Info.plist `BCIWorkerDevRoot` (set only in Debug). Never a system Python.
  - `Sources/Contracts/Records.swift` — on-disk record types; `docs/data-contracts.md`
    explains the rules and binary layouts; `docs/export-format.md` the export.
- **Python worker** (`worker/`, Python 3.12 pinned by `uv.lock`) — analysis only, never
  opens a board. `protocol.py` (framing), `main.py` (server, reader/work threads),
  `pipeline.py` (own CSP + rLDA, log-variance baseline, split manifest, holdout report),
  `project_io.py` (verified chunk reads from a project directory).
  MNE is a dev-only test oracle and must never enter the runtime set (bundle script fails if it does).

### Agent control (brief 008)

`Sources/Control/` (shared with the `bci` tool) holds control protocol v1, JSON lines over a
same-user Unix socket, and `ControlCatalog`, the one method list behind the CLI flags,
`bci describe` and the MCP tools. `App/Control/` is the server (`ControlServer`), the router
and its handlers, which only call `Workspace`/`ProjectSession` methods, plus jobs and operator
prompts (`AgentActivity`, `AgentBanner`). It is off unless Settings ▸ Agent Control is on;
Debug also accepts `-BCIAgentControlEnabled YES`. `Tools/bci/` builds into
`Contents/Helpers/bci`. Adding a method means: a `ControlCatalog` entry, a `dispatch` case,
a handler, and a row in `docs/agent-interface.md`. Agents never confirm human steps
(decision #48). Rules for agents using the app are in `AGENTS.md`.

### Worker IPC (protocol v1)

JSON-lines over stdio; spec in the `protocol.py` docstring, mirrored in `WorkerClient.swift`
— bump `PROTOCOL_VERSION` in both together. Every request gets exactly one response by
`id` (match by id, not order); `hello/ping/cancel/shutdown` are answered immediately even
while work runs. The worker writes protocol output to a private dup of fd 1 and redirects
fd 1 to stderr, so library prints can't corrupt framing. Large data never crosses the pipe:
requests reference immutable chunk files in the project directory.

### Project store invariants

`*.bciproj/` layout in `docs/data-contracts.md`; it is a declared package UTType, so Finder
shows it as one document. Everything under `recordings/`, `pipelines/`, `results/` is
immutable once committed (new versions = new directories). Manifests use
`ContractJSON.encoder()/decoder()` (sorted keys, ISO-8601 *with* fractional seconds — never
Foundation's `.iso8601`, NaN refused) and atomic rewrite (temp → fsync → rename → fsync
dir). Changes an older reader could misread bump `ContractVersion.format`.

### Bundled example and test fixture

`App/Resources/ExampleProject/S001-motor-imagery.bciproj` (PhysioNet EEGMMIDB S001, ODC-BY)
and `Tests/Fixtures/tiny.bciproj` are generated byte-deterministically by
`worker/tools/convert_eegmmidb.py` from raw EDFs placed by hand in `build/datasets/eegmmidb/`
(never committed); commands in `README.md`. Regenerate, don't hand-edit;
`test_convert_eegmmidb.py` (skipped without the raw files) checks they match.

## Scientific rules (from the PRD — treat as correctness requirements)

- One owner for acquisition; UI and training never block draining the device.
- Never interpolate raw data or treat bursty arrival times as an irregular ADC clock.
- Fit every step inside the training fold; split by run/session, never by window; freeze
  the holdout before fitting; report uncertainty and the simpler baseline.
- Offline evaluation replays the online causal transforms: band-pass once per continuous
  segment from zero state, cut trials afterwards; trials in filter warm-up are excluded and listed.
- Explicit channel maps/montages; never infer labels from channel count ("undeclared", not a 10-20 guess).
- Two-class classifiers don't detect "no intent"; abstention is a policy.

## Process

- Work is PM-led (`docs/product/README.md`): features start as briefs in
  `docs/product/briefs/` (status line at top; UI/visual specs and test plans alongside),
  product decisions append to `docs/product/DECISIONS.md` and are cited as "decision #N"
  in code comments.
- Feature branches live in worktrees under `.claude/worktrees/` (e.g. `feature-first-run-intro`);
  re-run `scripts/bootstrap.sh` in a new worktree. The main checkout is used by GitHub
  Desktop and can lag `origin/main`; branch worktrees from `origin/main`.
- GitHub account is the personal `hshwang34`; check `gh auth status` before pushing.
- Releases: `scripts/release.sh <version>` builds a Developer ID-signed, hardened-runtime,
  notarized + stapled DMG in `build/release/` (`docs/RELEASING.md`; no entitlement
  exceptions needed). Debug keeps hardened runtime `NO`. Open phase-0 gate: clean-machine
  launch. App Sandbox is off. Publishing (tags, GitHub Releases) needs owner approval.
