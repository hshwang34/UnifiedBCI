# 008 — Agent control (`bci` command + MCP)

**Status:** building · **Owner:** PM · **PR:** — · **Updated:** 2026-11-25

## Problem
Everything BCI Workspace does needs a person clicking through the app. A researcher who
works with a coding agent (Claude Code, Codex) can't say "import the example, evaluate it,
freeze the model, and run a live test on the synthetic board". The agent has no way to
drive the app, and it can't see what the app found. The Debug launch arguments do the
same steps, but they're compiled out of the shipped app and were built for screenshots.

## Who it's for
A researcher or developer who already uses a coding agent and wants it to run the setup,
the workflow and the checks end to end, while they stay at the Mac for the human steps
(electrodes, participant, confirmations).

## What success looks like
- With agent control turned on, an agent can run a whole experiment from the terminal or
  through MCP: open or create a project, inspect recordings, evaluate, read results, write
  protocol versions, freeze a model, replay it, export, connect a source, record, and run
  cued protocol runs and live tests.
- Everything the agent does happens in the running app and shows in its windows. The
  person sees each step, and a project can never be opened twice.
- The agent never answers a human step for the person. It waits, tells its user what the
  app is waiting for, and goes on once the person confirms in the app.
- Every evaluation the agent reads says how many attempts were made on that recording, so
  a score picked from many tries can't pass for a single result.

## Acceptance criteria
- [ ] Agent control is off by default. When it's off the app opens no socket, and nothing
      opens on its own at launch (decision #7).
- [ ] Settings ▸ Agent control has two toggles, "Allow coding agents to control BCI
      Workspace" and "Allow agents to use hardware" (off by default).
      `bci enable` asks for the first one with an in-app confirmation.
- [ ] `bci <group> <verb>` prints one JSON object on stdout and its progress as JSON lines
      on stderr. Exit codes are fixed (`docs/agent-interface.md`). `bci describe` prints the
      machine-readable catalogue.
- [ ] `bci mcp` serves the same catalogue as MCP tools over stdio. It works with
      `claude mcp add` and with Codex's `config.toml`.
- [ ] `bci` starts the app in the background when it isn't running.
- [ ] A serial board needs "Allow agents to use hardware", plus an in-app confirmation
      the first time in each launch. Synthetic and Demo need neither.
- [ ] In a protocol run or a live test on hardware, the agent can't start a run or
      confirm any step. Each run waits for the operator in the app. The agent's job
      reports `awaiting_operator` along with the prompt.
- [ ] `operator: "agent"` (unattended runs) is accepted only on the synthetic and Demo
      sources.
- [ ] Every agent call is appended to the project's `logs/agent-actions.jsonl`. That log
      is not provenance and export leaves it out.
- [ ] `evaluate.run` and `results.show` carry the attempt counts for the recording, plus
      a `multiple_comparisons` warning past five configurations.
- [ ] The app refuses an agent action for the same reasons it disables the button, and
      returns the button's own wording.

- [ ] The first-run intro ends on a fifth step, "Works with your coding agent", which says
      it's off until allowed and that human steps stay with the person. People who saw the
      intro before get a one-time "New" card on the welcome screen. Set Up… opens Settings ▸
      Agent Control, and the card never comes back once dismissed or once control is on.
- [ ] `scripts/agent_eval/run.sh` runs Claude Code headless against the app through MCP,
      across five scenarios, and grades the transcript and the project it left.

## Out of scope
- An assistant or chat panel inside the app.
- Agents writing new pipelines or recipes (PRD §10: no automatic architecture search).
- Remote or network control: the socket is local and only for the same user.
- Marking hardware as tested (decision #26).

## Open product questions
1. **Where do the commands run?** — Options: A (inside the running app, through a local
   control server), B (a standalone tool next to the app). **Recommendation:** A. It
   keeps one owner per project and per board, reuses the cue windows, and the person can
   see what happens.
   → *Answer:* A (owner, 2026-11-25).
2. **Command line, MCP, or both?** — **Recommendation:** both, from one catalogue.
   → *Answer:* both (owner, 2026-11-25).
3. **Hardware and cued runs in the first pass?** → *Answer:* yes. Human steps stay with
   the person (owner, 2026-11-25).

## Engineering decisions (filled in by the lead while building)
- The control protocol is JSON lines over a Unix socket in
  `~/Library/Application Support/com.hshwang34.BCIWorkspace/control/` (0700). It is
  checked with `getpeereid` and a per-launch token. Protocol v1 is shared by the app and
  `bci` (`Sources/Control/`).
- A single catalogue (`ControlCatalog`) feeds `describe`, the CLI flags and MCP
  `tools/list`, so the three can't drift apart.
- Handlers call the same main-actor session methods the views use, so the windows stay
  in step with what the agent did.
- MCP is hand-rolled (initialize, tools/list, tools/call, ping), so there's no new
  dependency to sign or audit.
- `bci` ships inside the app as `Contents/Helpers/bci` and is signed with the app.
  `bci install` links it into `~/.local/bin`.

## Risks / what could go wrong for users
- An agent tries many configurations and reports the best one. Mitigation: attempt
  accounting on every result, plus the AGENTS.md rules.
- An agent acts while the person is mid-edit. Mitigation: actions are refused with
  `ui_busy` while a sheet is open.
- Another process running as the same user could turn the toggle on with `defaults write`.
  Accepted: such a process can already drive the app and the Mac directly. The socket
  still requires the same uid and the per-launch token, and Release ignores
  launch-argument overrides.
- The app is hidden when a cued run starts. Mitigation: the participant window is always
  brought forward.
