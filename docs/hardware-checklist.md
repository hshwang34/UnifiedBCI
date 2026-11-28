# Hardware checklist: OpenBCI Cyton+Daisy

This is the hand-run check on the real board that decision #26 requires before briefs 004, 005
and 006 count as shipped. Everything the app has been tested with so far uses the synthetic
board, the Demo source or recorded data. This checklist is where real hardware gets tested.

It merges the appendix checklists from briefs 004, 005 and 006 into one bench order, and adds
the checks that came with briefs 008–011 and decision #69. The IDs (H, P, L) are the
briefs' own, so each result goes back into its brief's appendix.

## How it's split up

| Sitting | What it checks | Time | Cap on? |
|---|---|---|---|
| **1. Board and recording** | Connect, stream, record, reconnect (brief 004) | about 45 min | Optional (shorted inputs are fine) |
| **1b. Long and destructive runs** | 60-minute recording, force-quit, full disk | about 75 min, mostly unattended | No |
| **2. Cued runs** | Quick check, then the full protocol (brief 005) | about 45 min | Yes |
| **3. Live feedback** | A model from sitting 2, used in a new sitting (brief 006) | about 30 min | Yes, re-applied |
| **4. Agents and hardware** | Agent rules for a real board (brief 008) | about 10 min | No |

Order matters. Sitting 2 needs sitting 1 to pass, and sitting 3 needs a model from sitting 2.
Sitting 3 must be a separate sitting, with the cap taken off and put back on: that is what
makes its result `cross-session`. Sittings 1b and 4 can run any time after sitting 1.

## Before you start (10 min)

- [ ] **Install the build:** use the newest build of `main` (#62 or later). Write its commit
      down: `git rev-parse --short origin/main`, or the version in the Welcome window.
- [ ] **Close other heavy work:** quit other Xcode builds, simulators and dev servers. The 16 GB
      Mac is shared, and memory pressure skews the timing numbers.
- [ ] **Prepare the hardware:** charge or replace the board's batteries, and use a USB port on
      the Mac itself, not a hub.
- [ ] **Set the dongle switch to PC.**
- [ ] **Turn on diagnostics capture:** nothing to enable; the app writes local logs by itself.
      If anything goes wrong, choose Help ▸ Export Diagnostics… right away and keep the folder.
- [ ] **Start a results sheet** with the template at the end of this file. Note:
  - Mac model and macOS version
  - displays (one or two)
  - firmware string (shown at H1)
  - dongle port name

## Sitting 1 — board and recording (brief 004)

| # | Do this | It passes when |
|---|---|---|
| H1 | Plug in the dongle, power the board, open a project, then New Recording… ▸ the serial board. | The port is listed by name. Ready in ≤ 15 s. Identity shows Cyton+Daisy, 16 ch, 125 Hz, `radio_125`, µV, and the firmware string or "not reported". |
| H2 | Look at the configuration. | Requested shows gain 24 on all 16 channels. Readback shows per-channel values or "raw only"; write down which. |
| H3 | Stream for 5 min, with electrodes connected or shorted as you normally test. | Effective rate 124–126 Hz. Counters step by 2. Any gap is listed with evidence. The preview moves smoothly. |
| N1 | During H3, use the window normally: click the sidebar, open and close the inspector, resize the window. *(new, brief 009)* | The sidebar, recordings list, header and Record/Stop stay visible. Nothing freezes or crashes, and the plot keeps drawing. |
| H5 | During a recording, pull the dongle for about 10 s, then plug it back in. | Interrupted within about 3 s. It reconnects on its own and starts a new segment; the old segment ends with `disconnect`. Nothing is joined. |
| H6 | During a recording, switch the board off for about 10 s, then on again. | As H5. If retries run out, it shows Failed with a Reconnect button that works. |
| H9 | While recording, evaluate the bundled example in another project window. | No `overflow_suspected` and no writer-backlog warning. The preview may stutter, but the recording is complete. |
| H10 | Connect with the Synthetic board. | Every surface says synthetic, and the recording's source kind is `synthetic`. |
| N2 | While streaming from the board, quit from the Dock (right-click ▸ Quit). Then reopen the app and quit with ⌘Q while the Connect sheet is open. *(new, brief 009)* | The app quits within about 5 s both times. The next launch shows the Welcome window, and the recording ends `stopped`. |
| N3 | Help ▸ Export Diagnostics…. *(new, brief 009)* | A folder with logs and versions is written. It holds no EEG data. |

## Sitting 1b — long and destructive runs (brief 004)

| # | Do this | It passes when |
|---|---|---|
| H4 | Declare a 10-20 map, then record for 60 min unattended. | No stop. Writer backlog stays < 5 chunks. The recording opens, Verify passes, and the gap list matches the health panel. App memory stays roughly flat in Activity Monitor. |
| H7 | During a recording, force-quit the app (Activity Monitor ▸ Force Quit, or `kill -9`). | After reopening, the recording lists every second up to the kill (±1 s), Verify passes, and the last segment ends `process_terminated`. The next launch shows the Welcome window. |
| H8 | Make a small disk:<br>`hdiutil create -size 256m -fs APFS -volname BCIFull ~/BCIFull.dmg && hdiutil attach ~/BCIFull.dmg`<br>Create a project on `/Volumes/BCIFull`, then add filler with `mkfile 140m /Volumes/BCIFull/filler`. Adjust the filler until Finder shows about 105 MB free, then record. | A disk-space warning appears before Record. Within a few minutes it stops with "disk full" and the seconds saved, and the recording verifies. Afterwards, run `hdiutil detach /Volumes/BCIFull` and delete the image. |

## Sitting 2 — cued runs (brief 005, decision #69)

Use two displays if you have them, with the participant window on the second display.

| # | Do this | It passes when |
|---|---|---|
| Q1 | Start Run… ▸ turn on **Quick check**, and run all 3 short runs. Then Evaluate. *(new, decision #69)* | It takes about 3 minutes. The cue window shows the instruction card, then fixation, arrow and blank, with the arrow replacing the cross. Space starts each run. The result is labelled "setup check, not a performance estimate". If it fails here, fix the cap and signal before the full runs. |
| P1 | Start Run… with the default protocol, participant window on the second display. | Instructions, then fixation, arrow and blank, in order. The operator window keeps focus, and Esc and ⌘. work. The operator panel shows run and trial progress. |
| P2 | Complete one full default run (40 trials, about 5½ min). | 40 trials, with events in `events.jsonl`. Every phase event has `presentedAt` and a `brainflow_marker` association. Timing summary p95 lateness is under 1 frame. |
| P3 | Abort one trial, pause and resume, then finish. | `trial_abort`, `pause` and `resume` events are written. The aborted trial is listed as excluded on evaluation. |
| P4 | Pull the dongle mid-trial, plug it back in, then Resume. | The trial is aborted with reason `disconnect`, and the run continues in a new segment. |
| P5 | Run 4 runs, then Evaluate. Keep this project: sitting 3 uses it. | Evaluation runs with `cue_left_hand` and `cue_right_hand`, 1 held-out run and `same-session` evidence. The result leads with its interval, whatever the accuracy is (there is no target). |
| P6 | Unplug the second display (or use a single-display Mac) and run 2 trials. | The participant window is full screen, Esc aborts, and the summary is visible afterwards. |
| P7 | Export the result. | The export folder holds `protocol.json` and the run plans, and the seeds reproduce the trial order (the worker mirror). |

## Sitting 3 — live feedback (brief 006)

Before this sitting, take the cap off and put it back on.

| # | Do this | It passes when |
|---|---|---|
| L1 | Evaluate the P5 session with a 2 s window, then Freeze for live use. | The model is listed under Models. The sheet shows the channels, the window, and "feedback can show for 1.5 s of each cue". |
| L2 | Replay that model over the same recording. | "Live path matches offline" (parity pass). Any boundary windows are listed. |
| L3 | Start a live run with the default protocol. | The bar appears only in the feedback span and is hidden with words otherwise. The operator panel shows the state and the score. |
| L4 | During the run, pull the dongle for about 5 s. | The bar hides immediately and shows "Board disconnected". After reconnecting it shows "Waiting for enough signal" until there is a full window past warm-up. |
| L5 | During a run, kill the inference worker (Activity Monitor, the `python` process under BCI Workspace). | It shows "Analysis stopped". The recording continues, and the run can finish. |
| L6 | Finish the run and open Results. | A live card shows `cross-session`, a trial-level interval, and the abstained and invalid counts. Live matches replay n of n. Latency p50, p95 and max are listed. Note p95 against the 100 ms target, pass or not. |
| L7 | Export the live run. | The folder holds `model.json`, `predictions.jsonl` and `feedback.jsonl`, readable outside the app. |

## Sitting 4 — agents and hardware (brief 008, decision #48)

These need `bci` installed (`bci install`) and Settings ▸ Agent Control ▸ "Allow agent control" on.

| # | Do this | It passes when |
|---|---|---|
| A1 | With "Allow agents to use hardware" off, run `bci sources list`, then `bci acquisition connect` for the serial board. | The board is listed, but connect is refused (exit code 5) and nothing connects. |
| A2 | Turn "Allow agents to use hardware" on and repeat the connect. | The app asks for confirmation in its window, and the connect waits until you confirm. Confirm, then run `bci acquisition disconnect`. |
| A3 | Ask an agent (Claude Code with `bci mcp`) to run a protocol on the serial board with `operator: "agent"`. | Refused: unattended runs are allowed only on synthetic and Demo. With a human operator, the job reports `awaiting_operator` until you press Space in the app. |
| A4 | Open the project's `logs/agent-actions.jsonl`. | Every agent call above is logged with its outcome. |

## Recording the result

When a sitting is done, copy its rows into the matching brief's appendix:
- H and N rows go to brief 004.
- Q and P rows go to brief 005.
- L rows go to brief 006.
- A rows go to brief 008.

A brief becomes "shipped" only after a passing run. A failure is a bug report: export
diagnostics, write down the ID, and hand both to the eng lead.

```
Date:            Mac / macOS:            Displays:
App commit:      Firmware:               Dongle port:
Sitting:         Cap: on / off / shorted

ID   Pass/Fail   Notes (numbers asked for: rate, p95 lateness, latency p95, memory)
H1
...
```
