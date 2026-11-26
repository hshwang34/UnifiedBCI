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
