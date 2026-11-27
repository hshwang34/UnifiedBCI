# 009 — Bug loop and observability

**Status:** building · **Owner:** PM · **PR:** — · **Updated:** 2026-11-26

## Problem
The first full agent eval (brief 008) found two bugs. One was the goal picker blocking
agents, now fixed. The other is an app crash on a mouse click during a recording, and its
cause is unknown. That crash took a week of features to surface, and when it happened the
app had left no trail. It logs almost nothing, `bci` quietly relaunched it, and the only
evidence was a macOS crash report. We can't fix what we can't see, and we can't say
"agents can drive this app" while a click can crash it mid-recording.

## Who it's for
- **The person running an experiment:** a crash mid-recording costs them a session, and
  maybe a participant's time.
- **The eng lead:** needs to see what the app was doing when something broke.
- **A user filing a bug:** needs one way to hand over what happened.

## What success looks like
- When something breaks, the eng lead can see what the app was doing just before: which
  call, which job, what state, which error. No guessing.
- A person can choose Help ▸ Export Diagnostics… and get a folder they can attach to a bug
  report. It never contains EEG data.
- The agent eval passes 5 of 5 scenarios twice in a row, with no app crash in either run.

## Acceptance criteria
- [ ] The app writes structured logs to macOS's own log system (subsystem
      `com.hshwang34.BCIWorkspace`, one category per area). Control calls, job state changes,
      evaluation, acquisition, runs and store errors are logged. EEG samples, labels and
      project contents are never logged.
- [ ] Each launch keeps a bounded diagnostics file in `~/Library/Logs/BCIWorkspace/`:
      recent events and errors, with the newest launches kept and older ones deleted.
- [ ] `bci app diagnostics` returns recent events, errors, active jobs, open projects, memory
      use, and a summary of any BCI Workspace crash reports since the last launch.
- [ ] Help ▸ Export Diagnostics… writes one folder containing the diagnostics file(s),
      recent crash reports and app/system versions, and says what it contains. It holds no
      EEG data and no project files.
- [ ] Nothing leaves the Mac: no network calls, no account.
- [ ] The click crash seen in eval scenario 03 (2026-11-26) is reproduced in a test or a
      Debug stress run, fixed, and stays fixed.
- [ ] The eval report includes each scenario's diagnostics and any crash reports.
- [ ] The eval passes 5/5 twice in a row with no crash. The loop gives up after 5 rounds and
      reports what's stuck.

## Out of scope
- Uploading crash reports anywhere (decision #53).
- A sweep of the whole app outside the agent paths (decision #54).
- A scheduled nightly eval (decision #55).

## Open product questions
1. **Where do diagnostics go?** → *Answer:* local only (PM, 2026-11-26, decision #53).
2. **What does "all the bugs" cover?** → *Answer:* agent paths and crashes, until the eval
   is clean (PM, 2026-11-26, decision #54).
3. **How does the loop run?** → *Answer:* in this session, until clean, at most 5 rounds
   (PM, 2026-11-26, decision #55).
4. **User-facing diagnostics?** → *Answer:* Help ▸ Export Diagnostics… (PM, 2026-11-26,
   decision #56).

## Engineering decisions (filled in by the lead while building)
- `os.Logger` through one `AppLog` type. Messages are privacy-annotated (`.public` only
  for ids, states and codes), plus an in-memory ring buffer written to the per-launch file.
- A Debug-only stress option sends hit tests to the project window while a recording or
  run is active. This reproduces the click-crash path without clicking (no Accessibility
  permission needed).
- The eval sets `BCI_NO_LAUNCH`, so a crash is never hidden by a silent relaunch (done in
  `fix-agent-eval`).

## Risks / what could go wrong for users
- Logs that say too much: anything about the participant or the signal is never logged
  (`.private` by default), and the export lists exactly what it includes.
- Log growth: the files are bounded per launch, and old launches are deleted.

## What the loop found and fixed (2026-11-27)
The live view's crash, the freezes and the blank window had one family of causes, found with
the new diagnostics: geometry and task dumps, plus real-window checks.
1. **Unbounded inspector height.** The live inspector's note used vertically-fixed text.
   Measured at a narrow width, it asked for about 1400 pt. The split view grew past the
   780 pt window, which clipped the top of every column: a blank sidebar and list, and a
   hidden header. During the inspector's collapse animation the same unbounded height became
   the 19-second layout storm behind the 2026-11-26 crash. **Fix:** the note is in a scroll
   view, and the inspector stays open in the live view.
2. **The window rebuilt five times a second.** The window root, sidebar and live header read
   the whole acquisition snapshot, which is replaced on every 200 ms poll. **Fix:** state,
   reconnects and the recording id are separate observed properties, set only when they change.
3. **A stuck polling task.** The 200 ms status poll was a sleeping main-actor Task. It was
   found recorded as the main thread's "current task" while the thread was idle. The UI froze
   at "Ready", and the next executor check (a click, app activation, an accessibility read)
   crashed. This was reproduced on `main` too. **Fix:** a run-loop timer.
4. **The live plot.** It is now an AppKit view (`LivePlotView`) that repaints on its own
   timer, so streaming never runs SwiftUI updates or window layout. Tick labels no longer
   overprint the scale caption.
5. **Launches with no window.** Saved window state from a force-quit made later launches show
   no window at all. **Fix:** the app ignores saved state (decision #7).
6. **Smaller fixes:** the live header adapts to narrow widths, the goal picker no longer
   blocks agent-opened projects, and the Debug live-record waits for the stream.

**Follow-up (not done):** the protocol-run and live-feedback status loops are also sleeping
main-actor Tasks. They pass every flow today, but should move to timers too.

**Debug tools added:**
- `-BCILayoutDump YES` logs the window and split-view geometry.
- `-BCIHitTestStress YES` hit-tests the windows continuously.
- `scripts/crash_repro.sh` (under `scripts/agent_eval/`) reproduces the crash scenario.
- `scripts/verify_flows.sh` checks every flow for hangs, crashes, error events and snapshots.
- `scripts/app_lock.sh` lets only one Debug app run at a time.

## Resume (paused 2026-11-26, branch `fix-agent-eval`, worktree `.claude/worktrees/feature-agent-control`)
- **Done:**
  - Observability: AppLog, the per-launch file, `bci app diagnostics`, Export Diagnostics.
  - The goal picker no longer blocks agents.
  - The live-view crash is found and fixed. Root cause: the inspector collapse animation's layout storm left the main actor wedged. `crash_repro.sh` with stress passes 5/5.
  - Scenario 02's checks now grade behaviour.
  - Eval round 1: 4/5 (02 failed on the old checks only; no crash).
- **Uncommitted, not yet built:** the reviewer fixes. The log file-open failure is now logged, and the export README now says crash reports contain paths. Build and run DiagnosticsTests first.
- **Next:**
  1. Build, then run the targeted tests: Diagnostics, ControlRouter, ControlProtocol, Intro, AgentIntro and LiveScreen.
  2. Eval round 2, and round 3 if needed, until 5/5 twice with no crash.
  3. Snapshot the live view with the inspector note.
  4. Push, open the PR (with the PM section), merge when CI is green, and mark the brief shipped.
- **Known open item (not fixed):** the Debug `-BCIConnectSource synthetic -BCILiveRecordSeconds` run logged no recording. It probably presses Record before the preview has started. Check it.
