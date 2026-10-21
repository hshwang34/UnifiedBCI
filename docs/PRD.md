# BCI Experiment Workspace — Product Requirements and Architecture

Version 0.1 · October 16, 2026 · Research-informed proposal, not a validated market claim

## 1. Sponsor recommendation

Build a native macOS workspace that helps an individual BCI developer produce, inspect, reproduce, and test an experiment. Build it in Xcode. Use your Cyton + Daisy as the first supported live device, and your CSP/LDA motor-imagery work as the first complete decoding example. Make recorded-data workflows useful before hardware is connected.

The product promise is: **“Understand whether your BCI experiment works, reproduce the result, and test the same pipeline live.”**

Your stated return is a credible engineering/research portfolio and a tool you use. That supports a focused, technically honest product even if the commercial market is small. It does not justify building an entire BCI ecosystem or promising reliable thought control.

As an employer, I would value a finished native application with recoverable recordings, measured timing, defensible evaluation, clear documentation, and evidence of repeat use. A large feature checklist would be less persuasive. As a sponsor, I would fund discovery and a replay-to-report vertical slice first, with later work contingent on evidence.

## 2. What is known, and what is not

| Status | Statement |
|---|---|
| User-established | You have Cyton + Daisy, 16 channels; CSP/LDA motor imagery is relevant prior work. |
| User-established | The main goal is personal utility and an engineering/research portfolio. You want Xcode. |
| Recovered context | The linked chat proposed Connect → Prepare → Calibrate → Train → Control, with BrainFlow acquisition. |
| Unverified history | That assistant claimed an earlier August architecture discussion. The recovered conversation does not independently establish it or contain a complete architecture. |
| Research-supported | Users report friction around data interchange, metadata, tutorial execution, timing, and applying predictions. Specific evidence follows. |
| Hypothesis | A native, opinionated workspace will reduce that friction enough for developers to return regularly. |
| Hypothesis | macOS is a useful initial audience boundary. Its share of BCI users and unmet demand are unknown. |
| Assumption | An Xcode application may contain a bundled scientific helper; “Xcode” has not been interpreted as “every line must be Swift.” |
| Unknown | Current code quality, Mac architecture, electrode type/montage, available weekly time, team size, budget, and access to testers. |

## 3. Customer and market evidence

This is exploratory desk research across Reddit, OpenBCI forums, and official documentation. It is not customer interviewing, a representative survey, hands-on competitor testing, or a market-size estimate. Search results overrepresent problems; some reports concern older versions. Forum advice is evidence of user concerns, not scientific ground truth. No users were contacted.

| Observed evidence | Product implication | Limit of inference |
|---|---|---|
| An OpenBCI user in January 2025 wanted to replay external data into a left/right-hand model while waiting for a 16-channel device; a board-header detail blocked loading. [Original thread](https://openbci.com/forum/index.php?p=%2Fdiscussion%2F3966%2Fi-am-having-problem-to-put-my-data-in-the-openbci-gui) | A supported import-and-replay workflow is a concrete job. | One reported incident, not an adoption estimate. |
| An April 2022 user tried converting EDF data to simulate streaming and encountered channel/format mismatches. [Original thread](https://openbci.com/forum/index.php?p=%2Fdiscussion%2F3308%2Fgenerate-a-file-from-an-edf-file-that-can-be-read-by-the-openbci-software-playback) | Validate units, channels, sampling, and events explicitly instead of requiring header edits. | Historical evidence; current behavior needs testing. |
| A motor-imagery tutorial thread contains shape mismatches, incomplete channel labels, and difficulty locating the failing CSP component. [Original thread](https://openbci.com/forum/index.php?p=%2Fdiscussion%2F3202%2Fneuropype-motor-imagery-tutorial-questions) | Ship runnable examples, metadata checks, and errors with recovery steps. | Does not establish that all NeuroPype workflows fail. |
| A January 2026 Reddit user could classify two states in OpenViBE but struggled to trigger an external action without constantly choosing one class; they also reported documentation/forum-access difficulty. [Original thread](https://www.reddit.com/r/BCI/comments/1qjwt2z/openvibe_problem_with_outcomeprocessing/) | Prediction-to-action needs an explicit abstention/idle policy and understandable integration. | A probability threshold alone does not establish a valid idle detector. |
| A May 2025 Cyton+Daisy user reported bursty arrival timestamps and uncertainty about a regular timebase. [Original thread](https://openbci.com/forum/index.php?p=%2Fdiscussion%2F4019%2Fnon-uniform-intervals-in-the-timestamps) | Expose sample order, transport gaps, and clock semantics. | The report does not prove the ADC sampled irregularly. |
| A 2026 Reddit discussion describes difficulty obtaining reliable personal motor-imagery decoding despite a promising public-dataset result. [Original thread](https://www.reddit.com/r/BCI/comments/1ucwc7i/has_anyone_been_able_to_do_left_right_hand_motor/) | Separate algorithm validation from personal signal and protocol validation. | Self-report; no independently verified performance. |
| A March 2026 no-code BCI announcement drew responses pointing to existing tools and asking for DSP substance. [Original thread](https://www.reddit.com/r/BCI/comments/1s2xpwi/some_guys_just_made_a_nocode_software_for_bci/) | “No code” and “all in one” are weak differentiation on their own. | Small, self-selected discussion. |
| An April 2023 user praised OpenBCI setup and moving from its GUI to BrainFlow; a December 2025 hardware developer deliberately retained GUI compatibility. [User experience](https://www.reddit.com/r/Neurofeedback/comments/12ik1ub/experiences_with_openbci_hardware/), [hardware developer](https://www.reddit.com/r/BCI/comments/1polj4b/i_designed_an_open_source_8channel_eeg_board/) | Preserve interoperability and respect tools users already trust. | Positive anecdotes also cannot establish prevalence. |

**Research conclusion:** the “archaic UI” claim is not established by this evidence. Documentation friction is supported for particular tasks, but “undocumented ecosystem” is too broad. The strongest opportunity hypothesis is reducing fragile transitions between setup, recording, analysis, and live use. Better visual design should make those transitions clearer and faster.

### Initial audience

“BCI pioneers and adopters” is an aspiration, not a usable segment. Start with **Mac-using student developers, independent builders, and early researchers who can understand an experiment but do not want to repeatedly assemble acquisition, labeling, analysis, and replay infrastructure**. You are the first design partner.

Serve two entry points within that segment: a hardware owner preparing a session, and a developer testing recorded EEG without hardware. Experienced researchers are valuable reviewers, but arbitrary laboratory protocols are too broad for the initial promise. Educators are a plausible later segment because repeatable examples matter; consumer wellness users, clinical operators, and people needing dependable assistive control have materially different requirements.

### Competitive baseline and strategic alternatives

| Alternative | Established capability | Consequence for this project |
|---|---|---|
| OpenBCI GUI | Live visualization, recording, playback, and third-party streaming. [Documentation](https://docs.openbci.com/Software/OpenBCISoftware/GUIDocs/) | Rebuilding these alone is insufficient differentiation. |
| BrainFlow + MNE + scikit-learn | Acquisition abstraction and established analysis/ML building blocks. [BrainFlow](https://brainflow.readthedocs.io/en/stable/index.html), [MNE decoding](https://mne.tools/stable/auto_tutorials/machine-learning/50_decoding.html) | Reuse the scientific ecosystem; compete on workflow and traceability. |
| NeuroPype | Visual pipelines, examples, recorded/live workflows, and extension interfaces. [Documentation](https://www.neuropype.io/docs/getting_started/index.html) | Visual composition and replay are existing capabilities, not unique inventions. |
| BCI2000 | Modular acquisition, processing, application, and operator architecture. [System design](https://www.bci2000.org/mediawiki/index.php/Technical_Reference:System_Design) | A unified BCI system is an established category. |

Three viable scopes are a better OpenBCI viewer, a reproducible experiment workspace, and a general BCI IDE. Recommend the middle. A viewer is easier to finish but weaker as a research portfolio; a general IDE introduces plugin, protocol, editor, compatibility, and support obligations before establishing value.

The cheaper alternative is improving existing examples or building a narrow companion. Use it as a comparison during discovery. If the workspace offers no measurable improvement, the portfolio goal can still be served by a polished replay/evaluation companion. There is presently no evidence for pricing, willingness to pay, market size, or commercial defensibility.

## 4. Product definition and experience

The unit of work is a **project**, not a device connection. A project holds recordings, protocol versions, pipeline versions, evaluation runs, and live-test results.

The opening screen offers “Open project,” “Explore an example,” and “Connect hardware.” A project sidebar contains Recordings, Protocols, Pipelines, Results, and Live Test. The center shows the active task; a context panel explains relevant settings and warnings. Recording and connection status remain visible. A full-screen participant cue view is separate from the operator workspace.

The original five stages remain a guided path for new users. They are not a mandatory wizard: developers must be able to start with a recording, compare pipelines, inspect an unsuccessful session, or replay a model without reconnecting equipment.

Example workflow: import a recording → confirm montage/units/events → inspect signal and exclusions → run a saved evaluation → compare with a baseline → replay predictions through the live processing path → collect a new session → test the frozen pipeline with feedback → export the evidence.

Each important setting should answer “what does this change?” and “what would make this result misleading?” Examples should be executable specifications with known inputs and expected results, not screenshots that drift away from the software.

## 5. Requirements and acceptance

P0 is required for the first credible release. P1 is conditional expansion.

| Priority | Requirement | Acceptance evidence |
|---|---|---|
| P0 | Open a bundled recorded-data example without hardware or terminal setup. | A new user reaches a reproducible evaluation from a clean install. |
| P0 | Connect Cyton+Daisy via the existing dongle and display all configured channels. | Device identity, rate, units, channel mapping, configuration, and stream health are visible; reconnect creates an explicit discontinuity. |
| P0 | Inspect raw and processed signals, PSD, clipping, flatlines, and probable noise. | Every indicator names its rule; “good quality” is never presented as proof of neural origin. Impedance is shown only when meaningful for the supported setup. |
| P0 | Record received samples, metadata, and events durably. | Forced termination leaves a readable committed prefix; disk-full and dropped-data conditions are surfaced. No silent interpolation into raw data. |
| P0 | Run one configurable, cued two-class motor-imagery protocol. | Seeded trial order, rest/cue periods, aborts, and timing records survive export. Channel/montage configuration is explicit. |
| P0 | Train a reference CSP + regularized LDA pipeline and a simpler baseline. | Fitted steps occur within training folds; a frozen holdout and full configuration accompany results. |
| P0 | Evaluate and compare runs. | Show balanced accuracy, confusion matrix, class counts, uncertainty, exclusions, split policy, and baseline; identify same-session versus cross-session evidence. |
| P0 | Replay through the same streaming transforms used online. | Recorded chunks produce matching features/predictions within declared numerical tolerances, including startup and discontinuity behavior. |
| P0 | Provide cued in-app live feedback. | Abstention, invalid input, stale data, and disconnection are explicit states. Predictions and displayed feedback are logged separately. |
| P0 | Export portable evidence. | Samples, event table, channel map, protocol, pipeline configuration, model metadata, and evaluation are readable outside the app. |
| P1 | Import one external EEG format, selected from actual tester data. | Import validates sampling, units, labels, events, and missing metadata without pretending arbitrary recordings are Cyton captures. |
| P1 | Add one ecosystem integration, initially LSL if testers need it. | Explicit stream selection and documented timing semantics; no automatic selection of an arbitrary EEG stream. |
| P1 | Add a second scientific recipe. | A band-power exploration workflow exercises reusable architecture; P300/SSVEP await stimulus/timing validation. |

The bundled example and native recordings ship first. General EDF/XDF/BIDS import support is not implied by “import.” A well-tested narrow importer is more useful than several unreliable ones.

## 6. Hardware and scientific constraints

**Documented facts:** Cyton+Daisy streams 16-channel data at 125 Hz over the normal radio path. OpenBCI describes alternating board/Daisy packets and averaging. Its SD-card path can record at 250 Hz, which is a different data path. Preserve that distinction in provenance. [Sampling/data format](https://docs.openbci.com/Cyton/CytonDataFormat/), [SD recording](https://docs.openbci.com/Cyton/CytonSDCard/)

**Engineering implication:** the nominal 8 ms interval at 125 Hz is not an 8 ms end-to-end latency guarantee. The 62.5 Hz Nyquist limit is also not a promise of usable signal through that boundary. Ordinary sensorimotor-band experiments are plausible, but high-frequency applications and precise event timing require separate assessment.

BrainFlow documents that some timestamps are generated on the receiving computer. Timestamp precision is not the same as acquisition accuracy. Record sequence information, source timestamps, host monotonic receipt time, clock mapping, and gaps. Do not reinterpret bursty arrival times as a measured irregular ADC clock. [BrainFlow data format](https://brainflow.readthedocs.io/en/stable/DataFormatDesc.html)

Electrode placement, contact, reference, participant behavior, and session changes are project inputs. Owning 16 channels does not establish a useful montage or good signal. Start with an explicit channel map; never infer scalp positions from channel count. Record hardware settings, and verify readback where available instead of assuming requested settings were applied.

Software cue timestamps measure software events. Log intended presentation and presentation callbacks separately. Where onset accuracy matters, measure display/trigger timing externally before making precision claims. P300/SSVEP support is consequently a separate capability gate.

### Rules for credible CSP/LDA results

- Split by independent trials/runs, and by session when claiming session generalization. Keep overlapping windows from the same trial together.
- Fit CSP, normalization, data-driven selection, and classifier settings using training data only. Tune inside an inner split or reserve a separate validation set. Do not repeatedly select against the final holdout. These rules follow the general leakage prevention principles in [scikit-learn](https://scikit-learn.org/stable/common_pitfalls).
- Distinguish offline exploratory filtering from deployment-compatible causal processing. Final deployment evaluation replays causal transforms with the same state, warm-up, windows, and gap behavior used online.
- Version referencing, channel order, filter coefficients, feature conventions, CSP components, and classifier parameters. MNE explicitly recommends cross-validation for CSP component selection. [CSP reference](https://mne.tools/stable/generated/mne.decoding.CSP.html)
- Include artifact/confound checks and inspect spatial/spectral behavior. Good classification alone is not proof of motor imagery rather than eye, muscle, cue, or timing information.
- Report uncertainty at the trial/session level, not by pretending correlated windows are independent observations. A negative result is a legitimate outcome.

A two-class cued classifier does not automatically recognize “no intent.” For continuous control, collect appropriate idle data and measure false activations, missed actions, dwell time, and response time. Confidence thresholding is an abstention mechanism, not evidence that idle detection works.

## 7. High-level technical architecture

**Recommended implementation:** an Xcode workspace with a SwiftUI macOS app, a narrow BrainFlow native bridge, a native acquisition/recording helper, and an isolated bundled Python analysis worker using pinned scientific dependencies. This is a design recommendation, not a claim that packaging has been verified.

```text
                    SwiftUI macOS application
          Project navigation · Inspector · Cue presentation
                              |
                  Session / experiment coordinator
                    /                        \
        Acquisition helper                 Analysis worker
        BrainFlow adapter                  MNE / scikit-learn
        Device or replay                   Fit / evaluate
        Recording writer                   Replay / infer
        Stream health                      Shared causal pipeline
             |                                  |
             +------ Versioned project store ---+
                              |
                    Predictions / validity
                              |
               Feedback policy → In-app feedback
```

Acquisition has a single owner. Display rendering and training never block draining the device stream. Bounded queues make overload visible. Preview frames can be dropped; recording loss must be reported. Training is off the UI thread and isolated from acquisition; constrain its resources during a live recording.

**Native boundary:** wrap BrainFlow behind a small C-compatible or Objective-C++ interface for start/stop, configuration, metadata, and chunk reads. Catch native exceptions at that boundary and define buffer ownership. Swift supports C++ interoperation, but its documented limitations justify containing the dependency behind a small adapter. The acquisition-helper build and signing path must be proven early. [Swift interoperability](https://www.swift.org/documentation/cxx-interop/status/)

**Scientific boundary:** package a private Python environment with the app; do not depend on the user's system Python, package installation, or terminal. Use versioned local IPC, structured control messages, binary sample chunks, cancellation, and worker health signals. Model artifacts should use explicit arrays/metadata for the supported recipe; do not load arbitrary executable model files from strangers.

Keeping training and inference transforms in the same scientific implementation avoids an immediate Swift-versus-Python parity problem. If future deployment requires a native inference engine, port a frozen pipeline only after establishing reference fixtures and numerical tolerances. Do not assume a general Core ML conversion will represent every CSP/filter pipeline correctly.

**Why not pure Swift immediately?** It would increase responsibility for numerical methods and parity testing without directly improving the stated research workflow. If all-Swift implementation is itself a portfolio objective, choose that explicitly and narrow the initial scientific scope. The Xcode/native interface requirement does not require a scientific-library rewrite.

### Data contracts and storage

Use a versioned project directory containing a JSON manifest, append-only binary sample chunks, event records, and immutable derived artifacts; use a local index for navigation rather than making the index the only record of truth. Specify byte order, numeric types, dimensions, units, and checksums. Atomically commit chunks and support rebuilding the index after interruption.

Core records:

- **Recording:** source identity/version, sample rate, channel IDs/types/units, montage, reference, configuration, sample sequence, timing semantics, and gap flags.
- **Event:** event ID, trial ID, label, origin, source time, monotonic host time, sample association, and timing uncertainty where known.
- **Pipeline/model:** immutable configuration, fitted parameters, expected channels/rate, preprocessing state policy, training recording IDs, split manifest, dependency versions, seed, and hashes.
- **Prediction/action:** model ID, input sample range, score, validity reason, emission time, chosen action or abstention, and feedback presentation time.

Reject incompatible channel maps or rates; do not silently reorder or resample. Any supported conversion is explicit, recorded, and reproducible. Replay preserves original timestamps and separately tracks replay time; BrainFlow playback regenerates timestamps by default unless configured otherwise. [Playback behavior](https://brainflow.readthedocs.io/en/stable/SupportedBoards.html)

### Failure behavior and distribution

Model session state explicitly: disconnected, connecting, ready, streaming, interrupted, stopping, and failed. A device disconnect or worker failure invalidates feedback immediately. Reconnection starts a new stream segment and resets processing state; it does not silently join data across gaps. A worker can fail while acquisition continues, with a visible warning.

Keep data local by default, with explicit export and deletion. Diagnostic bundles exclude EEG and personal identifiers unless selected. No account or cloud service is needed. A signed/notarized direct-distribution build is the initial release path proposal; exact OS/CPU support and native-library packaging remain feasibility checks. Support the owner's Mac first, then publish an honestly tested support matrix.

## 8. Validation and sponsor gates

All numerical targets below are proposed acceptance targets, not measured results or published BCI norms.

| Gate | Test | Proposed pass condition |
|---|---|---|
| Problem evidence | Observe 5 target developers completing a recent workflow with their existing tools. | At least 3 independently encounter the same transition problem; record time and intervention points. |
| Basic usability | Fresh installation, bundled example, evaluation, export. | At least 4 of 5 complete without developer help within 15 minutes. |
| Workflow improvement | Compare the same task against each participant's current method; account for learning/order effects. | At least 30% lower median hands-on time with no loss of result traceability. |
| Recording integrity | One-hour live run plus forced close, unplug, disk-full, and slow-consumer tests. | No unexplained application loss; every detected gap is represented; committed data survives. Device-level loss is reported separately. |
| Processing parity | Reference fixtures, replay, and live-path chunking variations. | Features and predictions match within predefined tolerances; invalid intervals behave consistently. |
| Software responsiveness | Measure acquisition-receipt to prediction emission under declared hardware/load. | Initial target p95 under 100 ms after the required window is available; separately report window duration, transport delay, and feedback delay. |
| Scientific validity | Held-out evaluation and a fresh-session test. | Report all results, including failures, against baselines; do not require every participant to exceed an arbitrary accuracy threshold. |
| Actual utility | Four weeks of use by the owner and pilot users. | Owner uses it weekly; at least 3 of 5 testers voluntarily return for a second session. |

The primary product metric is **time to a reproducible, interpretable experiment result**. Classifier accuracy is a scientific outcome, not the sole product metric. Portfolio deliverables include a runnable app, a recording/replay example, architecture decisions, fault-recovery evidence, evaluation methodology, and a concise demonstration of what worked and what did not.

Recruitment and interviews are future work. Ask participants to show their last failed experiment, explain their current workaround, identify what they trust about the result, and demonstrate what would make them switch. Do not ask leading questions such as “Is the old UI terrible?” Commercial willingness to pay can wait until repeat use exists.

## 9. Phased roadmap

Planning assumption: one developer. These are rough effort bands, not calendar commitments; weekly availability and existing code are unknown.

| Phase | Scope | Exit decision |
|---|---|---|
| 0 — Discovery and feasibility, 1–2 focused weeks | Observe target tasks; inspect existing code; prove Xcode build, BrainFlow connection, bundled worker, and clean-machine launch. | Confirm the recurring problem and deployment approach before substantial UI work. |
| 1 — Replay to report, 2–4 weeks | Project structure, bundled dataset, signal inspection, frozen reference pipeline, honest evaluation, export. | A developer can reproduce a result without hardware. |
| 2 — Recording and protocols, 3–5 weeks | Cyton+Daisy acquisition, channel mapping, robust writer, cued protocol, events, recovery tests. | A complete new session is traceable and recoverable. |
| 3 — Closed-loop evaluation, 2–4 weeks | Same-pipeline replay/inference, validity/abstention, in-app feedback, fresh-session evidence. | Demonstrate the complete loop with measured limitations. |
| 4 — Pilot and selective breadth, 2–4 weeks | Documentation, usability fixes, one external importer or integration, second recipe if justified. | Show repeat use and publish the portfolio evidence. |

If phase 0 exposes no meaningful workflow advantage, choose a narrower companion. If motor imagery is unreliable, retain and demonstrate the experiment infrastructure with honest negative results and a simpler signal-exploration recipe. If hardware setup dominates all user time, prioritize preparation diagnostics over adding classifiers. If people prefer notebooks, make export/replay the product's center rather than forcing them into a visual editor.

## 10. Non-goals and risk register

Initial non-goals: every BrainFlow device, arbitrary graph editing, plugin marketplace, cloud accounts, automatic neural architecture search, clinical interpretation, therapeutic neurofeedback, autonomous external device control, mind reading, and guaranteed motor-imagery performance. Broad BCI developer workflows mean reusable recording/event/pipeline/evaluation foundations; they do not mean all paradigms at launch.

| Risk | Response and decision trigger |
|---|---|
| Attractive application solves a small inconvenience | Observe real work and compare against current tools before expanding. |
| Existing products already solve the chosen job | Reproduce the same task in the baseline stack; narrow or change the promise if improvement is negligible. |
| Artifact-driven or leaked performance | Fold-contained fitting, grouped splits, frozen holdout, causal replay, confound review. |
| Timing claims exceed measurement | Expose clock semantics; add physical timing validation before precision-dependent paradigms. |
| Scientific dependencies make distribution brittle | Prove signed clean-machine packaging first; pin and audit dependency licenses. |
| Reimplementing science consumes the project | Reuse validated libraries; treat a Swift port as a separate, benchmarked decision. |
| Unbounded generality prevents completion | Add a capability only when a second real workflow requires it. |
| macOS limits testers | Accept for personal/portfolio value; do not infer a commercial market from that choice. |
| No reliable personal MI result | Publish the result honestly; evaluate hardware/protocol quality separately from software correctness. |
| Documentation decays | Run example datasets and expected outputs as release checks; version examples with the app. |

## 11. Highest-value outstanding questions

1. Does “in Xcode” mean a native SwiftUI application, or a strict all-Swift implementation? Recommendation: native app with a bundled scientific worker.
2. What current code, recordings, and measured CSP/LDA results exist? Were splits by window, trial, run, or session? These determine what can be reused responsibly.
3. What exact Mac, electrode system, montage, reference, firmware, and dongle configuration will establish the first tested hardware profile?
4. How many hours per week are available, and what date matters for the portfolio? These determine whether the first release ends at replay/evaluation or includes live feedback.
5. Can five appropriate Mac-using testers be reached, and which workflow should they compare first: preparation, replay/debugging, or model evaluation?
6. Which external dataset format or application actually needs to work first? Choose from observed use rather than a speculative compatibility list.

**Decision proposal:** commit to discovery and a native replay-to-report slice. Treat live Cyton+Daisy integration as the next milestone, and motor imagery as a scientifically demanding reference workflow. Preserve the broader BCI ambition through explicit data and processing contracts, then earn breadth through demonstrated use.
