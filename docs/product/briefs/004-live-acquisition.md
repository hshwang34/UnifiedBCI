# 004 — Live acquisition: connect Cyton+Daisy and record durably

**Status:** approved · **Owner:** PM · **PR:** — · **Updated:** 2026-11-20

## Problem
Everything the app does today starts from a recording someone else made. The welcome
window's "Connect hardware" button does nothing (`WelcomeView` `case .hardware: break`), the
project window says "No hardware connected · Replay mode", and the Recordings section says
"Recording from hardware arrives in phase 2." A Cyton+Daisy owner still has to use the
OpenBCI GUI or a script to capture data, then hand-convert it, losing sequence counters,
gaps, settings and timing semantics on the way. PRD §5 makes connect and durable recording
P0 ("Device identity, rate, units, channel mapping, configuration, and stream health are
visible; reconnect creates an explicit discontinuity"; "Forced termination leaves a readable
committed prefix; disk-full and dropped-data conditions are surfaced. No silent
interpolation"), and phase 2's exit is "a complete new session is traceable and recoverable".

## Who it's for
The individual BCI developer with a Cyton+Daisy and the USB dongle, inside an open project,
at the start of a sitting: plug in, check the stream is healthy, declare the channel map,
record. Also the developer without hardware, who can do the same against BrainFlow's
synthetic board to learn the flow (clearly labelled as synthetic).

## What success looks like
- From an open project, the user picks the dongle's serial port, connects, and within
  ~15 s sees the board's identity, 16 channels at 125 Hz in µV over the radio path, the
  configuration the app asked for next to what the board reported back, and a moving preview.
- Stream health is always on screen while connected: samples received, effective rate,
  gaps by cause, suspected buffer overflows, and receipt-interval spread. Bursty arrival is
  shown as bursty arrival, never as lost samples.
- Recording writes to the project as data arrives. Force-quitting the app, pulling the
  dongle or filling the disk leaves a recording that opens, verifies, and says exactly how
  and where it ended.
- A reconnect continues the same recording as a new, visibly separate stream segment;
  nothing is joined or filled in across the break.
- Nothing on screen or in a stored recording claims a real board was used when it was the
  synthetic or playback board, and nothing claims the real board was tested until the PM has
  run the appendix checklist (decision #26).

## Acceptance criteria
Connect
- [ ] "Connect hardware" on the welcome window and a **New Recording…** command in an open
      project both open the Connect sheet (Q1). Without an open project the welcome button
      asks the user to open or create one first.
- [ ] The sheet lists serial ports (`/dev/cu.*`, USB-serial devices first, with vendor/product
      names from IOKit when available), plus "Synthetic board (no hardware)" and "Demo" (decision #42). Refresh re-scans;
      a port that disappears while selected is named as gone.
- [ ] Session state is one of PRD §7's seven states — disconnected, connecting, ready,
      streaming, interrupted, stopping, failed — shown in the project window's status line in
      words, and drives which buttons are enabled (state table below).
- [ ] On Ready the sheet shows identity: board name and BrainFlow board id, BrainFlow version,
      serial port, firmware string when the board returns one (else "not reported"), EEG
      channel count, nominal rate 125 Hz, data path `radio_125`, unit µV, sequence step 2.
- [ ] Configuration: the app sends an explicit default per-channel settings command for all
      16 channels (gain 24, normal input, bias included, SRB2 connected) and stores it in
      `boardConfiguration.requested`; it then asks the board for its register settings and
      stores what came back in `boardConfiguration.readback`. The screen shows the two side by
      side. When the board offers no readback (synthetic, playback) readback is empty and the
      screen says "No readback from this board"; readback is never copied from requested.
- [ ] If readback reports a gain other than the requested one on any EEG channel, Record is
      disabled with "Channel <n> reports gain <g>; µV scaling assumes 24. Reconnect to reset."
- [ ] Failure to connect (port busy, wrong port, board off, timeout) lands in **failed** with
      the BrainFlow error named in plain words and a Retry; nothing is written to the project.

Channel map
- [ ] Before the first recording the operator declares a channel map: a label per channel,
      the reference (free text, default "SRB2"), and the montage name. A saved map from this
      project can be picked. The default labels are BrainFlow's default names with montage
      "undeclared".
- [ ] Record stays disabled until the operator either confirms a map or explicitly chooses
      "Record without positions" (montage stored as "undeclared"); positions are never
      inferred from the channel count (Q2). The montage head (brief 003) places labels only
      for a declared named standard, as today.

Preview and health
- [ ] Preview: all 16 channels stacked, last 10 s, raw µV with per-channel mean removed for
      display only, fixed or auto vertical scale. It is drawn from the chunks the drain loop
      already read (never a second read). Preview frames may be dropped under load; the
      recording never is.
- [ ] Health panel, updated at least once per second: samples received this segment;
      effective rate (counter-derived samples per monotonic second over the last 10 s);
      gaps by evidence (`sequence_skip`, `stale_half`, `invalid_counter`,
      `overflow_suspected`, `disconnect`) with estimated missing samples and the "ambiguous"
      note; drain-interval and BrainFlow-timestamp-interval p50 / p95 / max; writer backlog
      (chunks waiting); last commit time; free disk space and estimated hours left.
- [ ] Gaps are declared only from counter evidence, an overflow warning or a disconnect
      (`SequenceAccounting`, unchanged rules). A drain with no samples for ≥ 1 s but
      contiguous counters is logged as `receipt_interval` with `estimatedMissingSamples: nil`
      and shown as "arrival pause, no samples lost by counter".

Recording
- [ ] Record creates a recording in the project (`ProjectStore.createRecording`) with source
      kind `brainflow` (or `synthetic`), board id/name, `dataPath: radio_125` (nil for
      synthetic), BrainFlow and app versions, the declared channel map, reference and montage,
      timing semantics (`timestampGeneratedBy: "host"`, `sequenceStep: 2`), clock mapping
      anchor, board configuration, and a fresh `sessionID` and `runID`.
- [ ] Samples are committed in ~1 s chunks (125 samples) through `ChunkWriter`'s existing
      commit protocol, as all 32 BrainFlow rows, while streaming; detected gaps go into the
      segment's `detectedGaps` as they happen.
- [ ] Stop closes the segment with `endReason: stopped` and flushes the partial last chunk.
- [ ] Force-quit (`kill -9`) at any commit point leaves a project whose recording opens, passes
      `verify`, and holds every chunk committed before the kill. On the next open the
      unterminated segment is closed with `endReason: process_terminated` and a
      `process_terminated` gap after its last committed sample.
- [ ] Disk full: the recording stops cleanly with `endReason: disk_full` when free space falls
      under 100 MB, or on any `ENOSPC`; the screen says "Recording stopped: disk full. <n> s
      recorded and saved." The preview keeps running. Free space under 1 hour of recording
      shows a warning before Record (Q4).
- [ ] Interruption: no new samples for 3 s, or a BrainFlow read error, moves the session to
      **interrupted**, closes the segment with `endReason: disconnect` and a `disconnect` gap.
      The app retries automatically for up to 30 s (Q3); on success the stream resumes in a
      new segment (new index, sample indices from 0, `SequenceAccounting.reset()`), same
      recording, same run. The status line names every reconnect.
- [ ] No value is ever interpolated, repeated or zero-filled into raw data. A stale-half
      sample is stored as received and flagged.
- [ ] The writer never blocks the drain loop. If the writer falls 30 chunks (≈ 30 s) behind,
      recording stops with `endReason: error` and "The disk could not keep up"; nothing in
      the backlog is dropped silently (it is either committed or the stop says how much was not).
- [ ] While recording, the app holds a power assertion that prevents idle sleep, and releases it
      on stop.
- [ ] A recording made in this brief opens in the Recordings section like the bundled example:
      Channels, Segments (with end reasons and gaps), Events (empty until brief 005), Quality.

Honesty
- [ ] **Demo source (decision #42):** "Demo" streams the bundled example recording (S001)
      through BrainFlow's playback-file board with Cyton+Daisy as master board, so the whole
      live path (drain, health, preview, record) runs on real EEG without hardware. The sheet
      and status line call it "Demo" only. Its recordings store source kind `playback` with
      the played file named in the source panel, so a stored recording never says it came
      from a device.
- [ ] A synthetic-board session and recording say "Synthetic board — generated signal, not a
      device" in the sheet, the status line and the recording's source panel.
- [ ] The README's support matrix lists Cyton+Daisy as "built, not yet hand-tested" until the
      PM records a passing checklist run in this brief's appendix; then it names the date,
      firmware and Mac.
- [ ] The first-run intro's step 4 copy ("arrives in phase 2") is updated once this ships.

Tests (automated; no hardware in CI, decision #26)
- [ ] Synthetic board: connect → stream → record 60 s → stop; manifest, chunks and health
      counts match.
- [ ] Playback-file board with Cyton+Daisy as master board and a fixture CSV generated with
      step-2 counters and injected skips, a stale half, an invalid counter and a wrap: every
      injected fault is in `detectedGaps` with the right evidence; original timestamps kept.
- [ ] Crash helper killed at each of the four commit points during a recording: prefix
      survives, reopen closes the segment as `process_terminated`.
- [ ] Simulated `ENOSPC` at each write step (fault-injection hook), and one test on a real
      small disk image: stop with `disk_full`, recording verifies.
- [ ] Fake board that stops delivering, then delivers again: interrupted → new segment, no
      samples joined.
- [ ] Soak: 3,600 chunks committed through the writer from a fast fake source; per-commit time
      at the end stays under the budget (see engineering decisions).

## Session states (PRD §7)
| State | Entered when | User can | Recording |
|---|---|---|---|
| disconnected | initial; after stop/disconnect completes | pick port, Connect | — |
| connecting | Connect pressed (`prepare_session`, config, readback) | Cancel | — |
| ready | prepared, readback done, not streaming | Start preview, Disconnect | — |
| streaming | `start_stream` succeeded | Record / Stop recording, Disconnect | optional |
| interrupted | 3 s without samples or a read error | wait for auto-retry, Reconnect now, Disconnect | segment closed (`disconnect`); resumes in a new segment |
| stopping | Disconnect or window close | — | segment closed (`stopped`) |
| failed | connect failed, retries exhausted, or unrecoverable error | Retry, Disconnect | segment closed with its reason |

Closing the project window while recording asks to stop first; quitting the app stops and
closes the segment (`stopped`) before exit.

## Out of scope
- Editing per-channel settings (gain, input type, SRB/bias) beyond the fixed default; later brief.
- Impedance measurement (lead-off), SD-card recording/import (`sd_250`), WiFi shield,
  Ganglion, other BrainFlow boards, LSL output.
- Cue protocol and events (brief 005); live classification (brief 006).
- Live signal-quality flags on the stream (brief 002's checks run on the recording afterwards).
- Multiple boards at once; recording from two app instances.
- A release at the end of this brief: work merges to main and the PM decides on publishing (decision #29).

## Open product questions
1. **Where does connecting live?** — A (inside a project: Connect sheet + a live acquisition
   screen under Recordings; the welcome button opens/creates a project first), B (a standalone
   device window independent of projects, choose the project when recording starts).
   **Recommendation:** A — the project is the unit of work (PRD §4) and every sample must land
   in one; B adds a second place where state lives.
   → *Answer:* A — inside a project (PM, 2026-11-20; decision #30)
2. **Can a recording start without a declared channel map?** — A (yes, but only by an explicit
   "Record without positions" choice, stored as "undeclared"), B (no, a confirmed map is
   required), C (yes, silently with default names). **Recommendation:** A — explicit either way
   (PRD §6), without blocking a quick hardware test; C breaks "never infer".
   → *Answer:* A — yes, only by an explicit "Record without positions" choice, stored as "undeclared" (PM, 2026-11-20; decision #31)
3. **On a disconnect, does the app reconnect by itself?** — A (automatic retry for 30 s, then
   failed with a Reconnect button; every reconnect is a new segment and is named), B (always
   manual). **Recommendation:** A — a bumped dongle shouldn't end a session, and the new
   segment keeps the break explicit.
   → *Answer:* A — automatic retry for 30 s, then failed with Reconnect; every reconnect is a new, named segment (PM, 2026-11-20; decision #32)
4. **Disk-space guard?** — A (warn before Record when free space is under 1 hour of recording
   ≈ 120 MB at 16 ch / 125 Hz; stop cleanly under 100 MB free), B (only stop on the OS
   error). **Recommendation:** A — the stop is clean and named rather than a failed write.
   → *Answer:* A — warn before Record under ~1 h of space (≈ 120 MB), stop cleanly under 100 MB free (PM, 2026-11-20; decision #33)

## Engineering decisions (lead)
- **Bridge** (`Sources/BrainFlowBridge/`): `BrainFlowBoard` gains
  `configure(_ command: String) -> String` (BrainFlow `config_board`, response returned),
  `insertMarker(_ value: Double)` (for brief 005), and an init taking
  `BrainFlowInputParams.serialPort` / `.file` + `.masterBoard` for the playback board.
  All still on the actor's own serial queue. `SequenceAccounting` is reused unchanged.
  New `SerialPortScanner` (IOKit `IOSerialBSDServices`, `/dev/cu.*` callout devices only).
- **Readback**: Cyton firmware answers `?` with its ADS1299 register dump; a parser
  (`CytonRegisterReadback`) turns `CHnSET` for both boards into
  `readback["ch01.gain"] = "24"` etc. and keeps the raw text under `readback["raw"]`. The
  exact response format is unverified without the board, so the parser is tested on a
  documented sample and the checklist (H2) confirms it; if the real reply differs, readback
  stays `raw` only rather than guessing.
- **Acquisition service** (new `Sources/Acquisition/`, compiled into the app target as today):
  `AcquisitionSession` actor owns one `BrainFlowBoard` and the state machine. A drain loop
  reads every 50 ms (`readAll`), runs `SequenceAccounting`, and fans out each `SampleChunk`
  to (a) the `RecordingWriter` through a bounded `AsyncStream` (buffering 30, never
  dropping — backlog is reported), (b) the preview through a newest-wins buffer, (c) the
  health accumulator. No UI or `@MainActor` code is on that path. BrainFlow ring buffer stays
  45,000 samples (6 min at 125 Hz); overflow margin unchanged.
- **RecordingWriter** (in `Sources/ProjectStore/`): wraps `ChunkWriter`; re-chunks drained
  samples into 125-sample chunks per segment; maps `SequenceAccounting.Finding`s to
  `RecordingManifest.Gap`s; opens/closes `StreamSegment`s (`updateSegments`); translates
  `ProjectStoreError.io(_, ENOSPC)` and the 100 MB free-space probe into `disk_full`.
  `ProjectStore.open` gains "close unterminated segments as `process_terminated`" — the one
  post-hoc rewrite a committed recording gets, documented in `docs/data-contracts.md`.
- **Manifest growth risk**: `ChunkWriter` rewrites and full-fsyncs `recording.json` on every
  chunk. At one chunk per second an hour is 3,600 entries (~1.5 MB rewritten per commit).
  Budget: p95 commit ≤ 250 ms at entry 3,600 on the owner's Mac. The soak test in PR 2
  measures it; if it misses, chunks grow to 5 s (forced-quit loss ≤ 5 s, documented) before
  any format change. A chunk-list journal would be a format bump and its own PR.
- **Segment semantics**: a segment ends at stop, disconnect, disk-full, error or process
  termination; reconnects keep `sessionID` and `runID`. (The worker currently refuses two
  segments with one run id — `fit_evaluate` "a run is one segment" — so evaluation of a
  reconnected run waits for brief 005's worker PR, which groups segments by run.)
- **Channel maps** are stored per project as immutable `montages/<uuid>/montage.json`
  (labels, kinds, units, reference, montage name); a recording copies the chosen map into
  its manifest, so the recording stands alone. Older readers ignore the new directory, so no
  format bump.
- **Test boards**: synthetic (`-1`) is 250 Hz, step 1 — it exercises the flow, not Daisy
  framing. Daisy framing is tested with the playback-file board (`-3`, master board 2) from
  fixture CSVs written by a small worker tool (`worker/tools/make_playback_fixture.py`), with
  `config_board("old_timestamps")` so BrainFlow does not regenerate timestamps (PRD §7). Debug
  launch argument `-BCIAcquisitionBoard synthetic|playback:<csv>` drives screenshots and smoke
  runs; it is compiled out of Release like the rest of `LaunchArguments.swift`.
- **Not verifiable without the board** (decision #26, covered by the appendix): how BrainFlow
  reports a pulled dongle (error vs silence — hence the 3 s no-data rule), the real `?`
  reply, firmware string availability, real radio loss patterns and effective rate over an
  hour, power-off behaviour, and reconnect timing.

### PR sequence (after this docs PR; each ≤ ~400 changed lines, each leaves main working)
1. **Swift bridge** — serial/playback params, `configure`, `insertMarker`, `SerialPortScanner`,
   playback fixture tool (worker/tools, dev-only) + bridge tests on synthetic and playback.
2. **Swift service** — `RecordingWriter` (re-chunking, segments, gaps, disk-full, ENOSPC
   fault hook), `ProjectStore.open` closes unterminated segments, crash-helper recording mode,
   soak test.
3. **Swift service** — `AcquisitionSession` state machine, drain loop, bounded fan-out, health
   accumulator, interruption and auto-reconnect; tests with synthetic and a fault-injecting
   fake board.
4. **Swift service** — board configuration + `CytonRegisterReadback`, channel-map store
   (`montages/`), gain-mismatch rule; screen models (all copy) for the sheet, health and states.
5. **Swift screens** — Connect sheet (port pick, identity, requested vs readback, channel map
   editor). Reachable only behind the Debug flag until PR 6.
6. **Swift screens** — acquisition screen (preview, health panel, Record/Stop, state banner,
   disk space), status line, welcome "Connect hardware" wired; flag removed.
7. **Docs** — `docs/data-contracts.md` (segment end semantics, readback keys, `montages/`,
   post-hoc segment close), README support matrix ("built, not yet hand-tested"), intro copy
   note, brief status. Then the PM runs the appendix checklist.

## Risks / what could go wrong for users
- A user reads a healthy stream panel as "good signal". The health panel describes transport
  only; its footer says "Stream health is about delivery, not signal quality."
- The 3 s no-data rule could misfire on a long radio stall that BrainFlow would have
  survived; the cost is one extra segment, which is honest about the stall.
- Readback parsing could be wrong on firmware we haven't seen; raw text is always kept.
- Manifest rewrite cost grows with recording length (see budget); a very long recording
  could slow commits until the chunk-size fallback lands.
- Bluetooth/USB power management on some Macs may drop the dongle during sleep; the power
  assertion covers idle sleep only, not lid close.

## Appendix — hand-run checklist on the real Cyton+Daisy (PM, decision #26)
Record for each run: date, Mac model + macOS, app commit, firmware string, dongle port name,
pass/fail per item, and anything odd. The brief is "shipped" only after a passing run.

| # | Step | Pass when |
|---|---|---|
| H1 | Plug in the dongle (switch on PC), power the board, open a project, Connect hardware. | Port listed by name; Ready in ≤ 15 s; identity shows Cyton+Daisy, 16 ch, 125 Hz, `radio_125`, µV, firmware string or "not reported". |
| H2 | Look at configuration. | Requested shows gain 24 on all 16 channels; readback shows per-channel values or "raw only"; note which. |
| H3 | Stream 5 min, electrodes connected or shorted as you normally test. | Effective rate 124–126 Hz; counters step by 2; any gap is listed with evidence; preview moves smoothly. |
| H4 | Declare a 10-20 map, record 60 min unattended. | No stop; writer backlog stays < 5 chunks; recording opens, `verify` passes, gap list matches the health panel; app memory roughly flat (Activity Monitor). |
| H5 | During a recording, pull the dongle for ~10 s, plug back. | Interrupted within ~3 s; auto-reconnect; a new segment with `disconnect` end on the old one; nothing joined. |
| H6 | During a recording, switch the board off for ~10 s, on again. | As H5; if retries run out, Failed with a Reconnect button that works. |
| H7 | During a recording, force-quit the app (Activity Monitor ▸ Force Quit, or `kill -9`). | Reopen: recording lists every second up to the kill (±1 s), `verify` passes, last segment ends `process_terminated`. |
| H8 | `hdiutil create -size 256m -fs APFS -volname BCIFull ~/BCIFull.dmg && hdiutil attach ~/BCIFull.dmg`; create a project on `/Volumes/BCIFull`; add a filler file (`mkfile 140m /Volumes/BCIFull/filler`, adjust until Finder shows ≈ 105 MB free); record. | Disk-space warning before Record; within a few minutes, stop with "disk full" and the seconds saved; recording verifies. `hdiutil detach /Volumes/BCIFull` and delete the image afterwards. |
| H9 | While recording, run an evaluation of the bundled example in another project window. | No `overflow_suspected`, no writer backlog warning, preview may stutter but recording is complete. |
| H10 | Connect with the Synthetic board. | Every surface says synthetic; the recording's source kind is `synthetic`. |
