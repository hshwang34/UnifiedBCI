# AGENTS.md

There are two kinds of agents here: agents that work **on this codebase**, and agents that
**use BCI Workspace** through `bci` or `bci mcp` (`docs/agent-interface.md`).

## Working on the code

Read `CLAUDE.md`. It covers the commands, the architecture, the project-store invariants,
and the scientific rules that count as correctness requirements. The product source is
`docs/PRD.md`, and product decisions are in `docs/product/DECISIONS.md`.

## Using the app through `bci` / MCP

The app enforces the safety rules. These are the scientific ones you must follow
yourself:

1. **The holdout is fixed before fitting.** Never pick a configuration (seed, window,
   CSP components) by its held-out score. Each seed picks a different held-out split.
   Report **every** configuration you tried, with the `accounting` block that comes with
   each result, not only the best one.
2. **Always report the baseline.** Every result has the log-variance baseline beside CSP +
   shrinkage LDA. Report both, along with their uncertainty, not a single number.
3. **Human steps belong to the person.** A job in `awaiting_operator` is waiting for
   someone at the Mac: electrodes, a participant who is ready, a resume. Pass the prompt
   on to your user and wait with `jobs.wait`. Never say a step was confirmed unless the
   job moved on.
4. **Never claim hardware was tested** unless the person tells you it was (decision #26).
   Synthetic and Demo runs are not hardware tests.
5. **Give an explicit channel map.** When connecting, the map is `declared`,
   `undeclared`, or a list of labels. Never infer 10-20 positions from the number of
   channels.
6. **Quality flags never drop data on their own.** If you leave out a flagged channel or
   run, say so and say why.
7. **Two-class classifiers don't detect "no intent".** Abstention is a policy (a
   threshold), not a third class.
