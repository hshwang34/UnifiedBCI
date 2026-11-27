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

#9 · 2026-10-22 · Visual direction: "sterile, clean, clear" — visionOS-like glass. Liquid Glass (`glassEffect`) on macOS 26; frosted-material fallback on macOS 15, which stays the minimum. Light and dark both designed; follows the system setting and honours Reduce Transparency / Increase Contrast. Neuralink's Telepathy app is a tone reference only (no branding borrowed). Supersedes the "system components only, no custom styling" line in 001-ui-spec.md.
*Why:* PM direction (brief 001 PR 3). Lives in docs/product/briefs/001-visual-spec.md.

#10 · 2026-10-22 · Seed copy reads "Chooses the held-out runs and the bootstrap draws. The same seed gives the same split." (the UI spec's "the split stays the same" was wrong: no frozen split manifest is passed yet).
*Why:* honest copy over spec wording; decided by the lead as a safe default, PM may reverse (alternative: ship a frozen split manifest per recording).

#11 · 2026-10-22 · Class names display as "Left-fist cue" / "Right-fist cue" with the stored label (`cue_left_fist`) shown beneath; channels, events and exports stay verbatim.
*Why:* the label records the cue shown, not proof of movement or imagery. Brief 001 visual spec §3.

#12 · 2026-10-22 · The accuracy range bar marks the larger-class rate with "Interval includes / lies above / lies below the larger-class rate."
*Why:* a plain "is this better than always guessing the bigger class?" cue, derived from stored counts only. Brief 001 visual spec §2.6.

#13 · 2026-10-22 · Onboarding = animated first-run intro (4 steps: what it does · honest uncertainty · try the example · hardware in phase 2) in the welcome window, first launch only, skippable, replayable from Help. Decision #7 still holds (no project auto-opens).
*Why:* PM choice. Brief 003.

#14 · 2026-10-22 · Intro motion is an expressive showpiece (neural field, electrode map, self-drawing trace, glass morphs) — still 60 fps, Reduce Motion gives still frames, own imagery only.
*Why:* PM choice over the calmer recommendation. Brief 003.

#15 · 2026-10-22 · Brief 003 ships as its own PR after PR 3 merges.
*Why:* keeps PR 3 reviewable. Brief 003.

#16 · 2026-10-23 · Brief 003 grows a live 3D montage view: a stylized head reused from the intro, on the Recording screen above the channel table, cross-highlighting with it.
*Why:* PM choice ("Intro + one live view"); montage is a recording property. Brief 003.

#17 · 2026-10-23 · The montage head shows declared electrode positions, reference and labels only — no per-channel colour until brief 002 (signal quality) supplies real values.
*Why:* nothing shown that isn't stored. Brief 003.

#18 · 2026-10-23 · The head rotates by drag, with Top / Left / Right / Front / Reset buttons as the keyboard- and VoiceOver-accessible path.
*Why:* PM choice. Brief 003.

#19 · 2026-10-23 · Neuralink Telepathy stays a tone reference only (decision #9); its visuals aren't publicly verifiable, so design proceeds on the verified task structure (one focal object, short bounded steps, one headline number with its unit) plus the glass spec.
*Why:* PM choice; researcher could not verify Telepathy UI. Brief 003.

#20 · 2026-10-30 · Montage head look = "glass over a ghost head" (study A4): a thick-glass scalp dome with the faint 10-10 grid, cup electrodes and leader-line labels, over a faint glowing outline of a head for orientation. No sculpted or shaded face. The intro's scalp map uses the same look. Supersedes the placeholder primitives (sphere/cone/cylinder).
*Why:* PM choice after two rounds of live sketches (docs/product/briefs/003-head-styles.html, 003-glass-studies.html); the mannequin head was rejected and the plain dome lacked orientation. Brief 003.

#21 · 2026-11-14 · Signal-quality inspection lives as a Quality tab on the Recording screen, next to Channels / Segments / Events.
*Why:* lead default while the PM was away (PM delegated "execute on your own"); quality is a recording property, like the montage view (#16). PM may reverse. Brief 002 Q1.

#22 · 2026-11-14 · No overall quality verdict or score: per-rule flags only, each naming its rule and measured value; an unflagged channel reads "None of these rules fired"; the tab footer says the checks can't show a signal comes from the brain.
*Why:* lead default; PRD §5 forbids presenting "good quality" as proof of neural origin. Brief 002 Q2.

#23 · 2026-11-14 · Quality thresholds are fixed v1 constants shown on screen, not user-editable.
*Why:* lead default; editable thresholds change reproducibility and need storage. Brief 002 Q3.

#24 · 2026-11-14 · Quality flags never exclude channels or time from evaluation; exclusion is a later brief with its own provenance.
*Why:* lead default; no silent change to what is evaluated. Brief 002 Q4.

#25 · 2026-11-14 · Keep the 200 µV large-deflection rule even though it fires on 15 of 16 channels of the bundled example; show the measured share of 1 s windows with each flag.
*Why:* lead default; the example really is high-amplitude (channel SD ≈ 38–56 µV), so the flag is a true measurement. Retuning would fit the rule to one recording. PM may reverse. Brief 002.

#26 · 2026-11-14 · Hardware work is built and tested in CI against BrainFlow's synthetic board and playback-file board; the PM has a Cyton+Daisy board and USB dongle on hand. Each hardware brief ends with a short hand-run checklist on the real board, and a hardware brief is not "shipped" until the PM has run it and recorded the result in the brief. The app, its docs and its PRs never claim hardware was tested when it wasn't.
*Why:* PM decision; CI has no board, and a playback file proves the code path, not the device. Briefs 004, 005, 006 (appendix checklists).

#27 · 2026-11-14 · Live feedback is a horizontal bar that grows left or right from a centre line with the classifier's confidence. On abstention, stale data, invalid input or disconnection the bar is hidden and the state is named in words.
*Why:* PM decision; one focal object (decision #19), and a hidden bar plus a named state can't be mistaken for a weak prediction. Brief 006.

#28 · 2026-11-14 · Default cued protocol is Graz-style: left hand vs right hand, 2 s fixation cross, 4 s arrow cue during imagery, random 1.5–2.5 s rest, 20 trials per class per run, seeded shuffled order. Every value is editable per protocol.
*Why:* PM decision; the standard two-class MI paradigm, and the 4 s cue fits the existing 0.5–4.0 s imagery window. Brief 005.

#29 · 2026-11-14 · No release between phases: phase-2 and phase-3 work merges to main as it is ready, and the PM decides when to publish.
*Why:* PM decision; avoids release work on half a loop. Briefs 004, 005, 006.

#30 · 2026-11-20 · Connecting to a board happens inside a project: a Connect sheet and a live acquisition screen under Recordings; the welcome screen's "Connect hardware" opens or creates a project first.
*Why:* PM decision; the project is the unit of work (PRD §4) and every sample must land in one. Brief 004 Q1.

#31 · 2026-11-20 · A recording can start without a confirmed channel map only by an explicit "Record without positions" choice, stored as "undeclared"; names are never defaulted silently.
*Why:* PM decision; explicit either way (PRD §6) without blocking a quick hardware test. Brief 004 Q2.

#32 · 2026-11-20 · On a disconnect the app retries automatically for 30 s, then shows failed with a Reconnect button; every reconnect starts a new, named segment.
*Why:* PM decision; a bumped dongle shouldn't end a session, and the new segment keeps the break explicit. Brief 004 Q3.

#33 · 2026-11-20 · Disk guard: warn before Record when free space is under about 1 hour of recording (≈ 120 MB at 16 ch / 125 Hz); stop cleanly, with a named reason, under 100 MB free.
*Why:* PM decision; a clean, named stop instead of a failed write. Brief 004 Q4.

#34 · 2026-11-20 · An aborted trial is marked aborted and excluded, not re-queued; the seeded order stays as planned and unequal class counts are listed.
*Why:* PM decision; the plan stays reproducible from the seed. Brief 005 Q1.

#35 · 2026-11-20 · A disconnect during a run aborts the current trial and pauses; Resume is offered after reconnect and continues in a new segment.
*Why:* PM decision; reconnects are already explicit segments (#32), and losing a run is costly. Brief 005 Q2.

#36 · 2026-11-20 · The participant window opens on a second display when one is connected; with one display it goes full-screen and the operator uses keyboard shortcuts. Start run… has a display picker that remembers the last choice.
*Why:* PM decision. Brief 005 Q3.

#37 · 2026-11-20 · A session defaults to 4 runs (three for training, one held out).
*Why:* PM decision; grouped CV gets at least 3 folds. Brief 005 Q4.

#38 · 2026-11-20 · "Freeze for live use" freezes the evaluation's own fit on its training runs, the model whose held-out score is on screen. A refit on all runs may follow later, labelled as having no held-out score.
*Why:* PM decision; the frozen model's evidence is the result it came from. Brief 006 Q1.

#39 · 2026-11-20 · Default abstention threshold is 0.6 confidence, editable per live run and stored with it.
*Why:* PM decision; hides near-coin-flip outputs without hiding most predictions of a modest model. Brief 006 Q2.

#40 · 2026-11-20 · The feedback bar shows only for windows lying wholly inside the imagery period; the Freeze sheet suggests evaluating with a 2 s window for live use.
*Why:* PM decision; earlier windows would be driven by pre-cue data. Brief 006 Q3.

#41 · 2026-11-20 · The live per-trial outcome is the one cue-locked window matching the training window; time on the correct side is a secondary figure.
*Why:* PM decision; comparable to the offline held-out score with an honest trial-level interval. Brief 006 Q4.

#42 · 2026-11-20 · The Connect sheet offers a "Demo" source next to the serial ports and the synthetic board: the bundled example EEG streamed through BrainFlow's playback-file board along the full live path. On screen it is labelled "Demo" only; the stored recording keeps source kind `playback` and names the played file.
*Why:* PM decision; lets anyone see live acquisition on real EEG without the kit (and makes honest screenshots possible), while stored provenance stays exact. Brief 004.

#43 · 2026-11-21 · Opening a project with no goal asks "What do you want to do?" with four goals: see how it works on the example, record EEG from a headset, train and check a decoder, run live feedback with a participant. "Not now" is always available.
*Why:* PM decision; guided setup starts from the user's objective (brief 007 Q1, PRD §5).

#44 · 2026-11-21 · The step guide is a compact card at the bottom of the project sidebar, with the step list and a "Show me" button that navigates to the step and highlights the control. No coach-mark overlays, no mandatory wizard; it can be hidden.
*Why:* PM decision; always visible without covering data (brief 007 Q2).

#45 · 2026-11-21 · Guide steps tick off automatically from the project's real state, or from what the user actually did, never by hand. Any step can be skipped and is shown as skipped, not done.
*Why:* PM decision; a checklist must not drift from reality (brief 007 Q3).

#46 · 2026-11-21 · "?" help is a short native popover (2–4 sentences, offline) at about a dozen concept-heavy spots only. There is no Help Book in this pass.
*Why:* PM decision; clean UX, help where people actually get stuck (brief 007 Q4).

#47 · 2026-11-25 · Coding agents drive the app through a local control server inside the running app. It is off by default and turned on in Settings or by `bci enable` with an in-app confirmation. It listens on a same-user Unix socket only (peer uid check plus a per-launch token). There is no network listener.
*Why:* owner decision; one owner per project and per board, the person sees what the agent does, and nothing opens on its own (#7). Brief 008.

#48 · 2026-11-25 · Agents never confirm a human step: starting a cued run, resuming after a pause, checking electrodes. Those wait for the operator in the app, and the agent's job reports `awaiting_operator`. Unattended runs (`operator: "agent"`) are allowed only on the synthetic and Demo sources. A serial board also needs "Allow agents to use hardware" and an in-app confirmation once per launch.
*Why:* owner decision; a participant's session is never driven by software alone. Brief 008.

#49 · 2026-11-25 · Every agent call is appended to the project's `logs/agent-actions.jsonl`. It is a log, not provenance: it is not a contract record, export leaves it out, and it cannot be turned off.
*Why:* lead decision; the person can always see what an agent did. Brief 008.

#50 · 2026-11-25 · Every evaluation an agent reads carries attempt accounting for its recording: the number of evaluations and distinct configurations, the held-out runs, and a `multiple_comparisons` warning past five configurations.
*Why:* lead decision; repeated evaluation against one holdout inflates the best score (PRD scientific rules). Brief 008.

#51 · 2026-11-25 · `bci` and its MCP mode use a hand-rolled JSON-lines and MCP stdio implementation with no new dependency. One catalogue feeds `describe`, the CLI flags and the MCP tools.
*Why:* lead decision; nothing new to sign, audit or pin. Brief 008.

#52 · 2026-11-25 · `bci` ships inside the app as `Contents/Helpers/bci` and is signed with it. `bci install` symlinks it into `~/.local/bin` (no sudo).
*Why:* lead decision; one notarized download, no installer. Brief 008.

#53 · 2026-11-26 · Diagnostics stay on the Mac: structured logs in macOS's log system and a bounded per-launch file. Nothing is uploaded, and no crash-reporting service or account is used.
*Why:* PM decision; keeps the PRD's local-only, no-account promise. Brief 009 Q1.

#54 · 2026-11-26 · The bug loop covers the agent paths and crashes: everything the agent eval, the smoke run and the crash watcher find. It is done when the eval is clean. A sweep of the whole app is a separate pass.
*Why:* PM decision; a bounded, measurable target. Brief 009 Q2.

#55 · 2026-11-26 · The loop runs in the working session (eval → triage → fix → rerun) until the eval passes 5/5 twice in a row with no crash, at most 5 rounds. There is no scheduled nightly run for now.
*Why:* PM decision; no ongoing usage cost. Brief 009 Q3.

#56 · 2026-11-26 · Help ▸ Export Diagnostics… writes a folder the person can attach to a bug report: logs, crash reports and versions, never EEG data or project files.
*Why:* PM decision. Brief 009 Q4.

#62 · 2026-11-27 · A result's headline is an interval with its point estimate inside it. When balanced accuracy has no run-level interval, the screen says "point estimate, no interval" beside the number and shows the trial-level accuracy interval as the larger figure; the larger-class reference is always readable beside it. The live-run card follows the same rule.
*Why:* lead decision, PM delegated design calls (2026-11-27). Honesty first: a bare number reads as more certain than it is (PRD scientific rules). Brief 011.

#63 · 2026-11-27 · Primary text uses researcher words: class display names, recipe names, "Run 1" for an unnamed run, "Live path matches offline" for replay parity. Exact stored values (labels, recipe ids, run and session ids, hashes, hop windows, chunkings) stay one click away in a Details disclosure or a tooltip. Monospace is used only for those stored identifiers.
*Why:* lead decision, PM delegated design calls (2026-11-27). The users are researchers, not ML engineers; reproducibility still needs the exact values. Brief 011.

#64 · 2026-11-27 · The sidebar's "Pipelines" section is called "Models" (frozen models, then the recipes they come from). Release-planning wording ("phase 1") never appears in the app.
*Why:* lead decision, PM delegated design calls (2026-11-27). Brief 011.

#65 · 2026-11-27 · The toolbar is contextual: Recordings offers Evaluate and Parameters…; a selected result offers Freeze for live use… and Export…; other sections and the live view offer neither. Every disabled control says why.
*Why:* lead decision, PM delegated design calls (2026-11-27). Brief 011.

#66 · 2026-11-27 · Each caveat appears once per screen: the recording's dataset or synthetic warning is the chip at the top of the page (not repeated in the inspector), and a reproduction is named by the result's own chip, not also by a toast.
*Why:* lead decision, PM delegated design calls (2026-11-27). Repetition teaches people to skip warnings. Brief 011.

#67 · 2026-11-27 · Dates on screen are localized and relative ("Today, 7:58 AM"). Stored names, exports and default model names keep the fixed `2026-11-27 07:58` form.
*Why:* lead decision, PM delegated design calls (2026-11-27). Brief 011.

#68 · 2026-11-27 · The Evaluate inspector starts hidden when the project window is narrower than 1200 pt, so the tables keep their width; the person can always show it again. It never collapses while the live view shows (brief 009 crash).
*Why:* lead decision, PM delegated design calls (2026-11-27). Brief 011.
