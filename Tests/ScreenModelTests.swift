import XCTest
@testable import BCIWorkspace

/// Criteria 1, 3, 4 and 10 of the 001 test plan, plus decision #8's headline wording:
/// the view models every brief-001 screen is drawn from.
@MainActor
final class ScreenModelTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-screens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// The tiny fixture's manifest and events, read through the store.
    private func tinyRecording() async throws -> (RecordingManifest, [EventRecord]) {
        let store = try ProjectStore.importBundledExample(from: try ProjectStoreTests.tinyFixtureURL(), into: scratch.appendingPathComponent("tiny.bciproj"))
        let ids = try await store.recordingIDs()
        let id = try XCTUnwrap(ids.first)
        let handle = try await store.recording(id: id)
        return (handle.manifest, try await store.events(for: id))
    }

    // MARK: Criterion 1 — welcome

    func testWelcomeActions_hardwareDisabledWithReason() {
        let actions = WelcomeModel.actions
        // UI spec §2 order: the no-hardware path first.
        XCTAssertEqual(actions.map(\.kind), [.example, .open, .hardware])
        XCTAssertTrue(actions.first { $0.kind == .example }!.isEnabled)
        XCTAssertTrue(actions.first { $0.kind == .open }!.isEnabled)
        let hardware = try! XCTUnwrap(actions.first { $0.kind == .hardware })
        XCTAssertFalse(hardware.isEnabled)
        let reason = try! XCTUnwrap(hardware.disabledReason)
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(reason.contains("phase 2"), reason)
        XCTAssertEqual(hardware.symbol, "cable.connector")
        XCTAssertTrue(actions.allSatisfy { !$0.caption.isEmpty })
    }

    // MARK: Criterion 3 — sidebar

    func testSidebarSections_orderAndPlaceholders() {
        XCTAssertEqual(SidebarSection.allCases.map(\.title), ["Recordings", "Protocols", "Pipelines", "Results", "Live Test"])
        XCTAssertEqual(SidebarSection.allCases.map(\.symbol),
                       ["waveform", "list.bullet.clipboard", "slider.horizontal.3", "chart.bar.doc.horizontal", "bolt.horizontal.circle"])
        XCTAssertEqual(SidebarSection.allCases.filter { $0.placeholder != nil }, [.protocols, .liveTest])
        XCTAssertTrue(SidebarSection.protocols.placeholder!.contains("phase 2"))
        XCTAssertTrue(SidebarSection.liveTest.placeholder!.contains("phase 3"))
        XCTAssertEqual(SidebarSection.allCases.filter(\.showsCount), [.recordings, .results])
        XCTAssertEqual(SidebarSection.statusLine, "No hardware connected · Replay mode")
    }

    // MARK: Criterion 4 — recording detail

    func testRecordingDetail_showsDeclaredMetadataOnly() async throws {
        let (m, events) = try await tinyRecording()
        let model = RecordingDetailModel(manifest: m, events: events)
        XCTAssertEqual(model.warning, m.source.warning, "the manifest's own warning is the first line")
        XCTAssertTrue(model.isPublicDataset)
        func field(_ label: String) -> String? { model.sourceFields.first { $0.label == label }?.value }
        XCTAssertEqual(field("Dataset"), m.source.dataset)
        XCTAssertEqual(field("Subject"), "S001")
        XCTAssertEqual(field("Runs"), "S001R04, S001R08, S001R12")
        XCTAssertEqual(field("Sample rate"), "160 Hz")
        XCTAssertEqual(field("License"), "ODC-BY 1.0")
        XCTAssertEqual(field("Reference"), m.reference)
        XCTAssertEqual(model.montage, m.montage)
        // Labels, units and kinds exactly as stored, in stored order.
        XCTAssertEqual(model.channels.map(\.id), m.channels.map(\.id))
        XCTAssertEqual(model.channels.map(\.label), m.channels.map(\.label))
        XCTAssertEqual(model.channels.map(\.unit), m.channels.map(\.unit))
        XCTAssertEqual(model.channels.map(\.kind), m.channels.map(\.kind))
        // One segment per run; samples summed from that segment's chunks.
        XCTAssertEqual(model.segments.map(\.runID), ["S001R04", "S001R08", "S001R12"])
        XCTAssertEqual(model.segments.map(\.session), ["—", "—", "—"], "no session is shown where the source defines none")
        XCTAssertEqual(model.segments.map(\.samples), [6720, 6720, 6720])
        XCTAssertEqual(model.segments.first?.duration, "42.0 s")
        // Events: label, onset = sampleIndex / rate, run; every stored event listed.
        XCTAssertEqual(model.events.count, events.count)
        let cue = try XCTUnwrap(events.first { $0.label == "cue_right_fist" })
        let row = try XCTUnwrap(model.events.first { $0.id == cue.eventID })
        XCTAssertEqual(row.onsetSeconds!, Double(cue.sampleAssociation!.sampleIndex) / 160, accuracy: 1e-12)
        XCTAssertEqual(row.runID, cue.runID)
        XCTAssertEqual(row.trial, cue.trialID)
        XCTAssertEqual(model.events.map(\.segment), model.events.map(\.segment).sorted(), "default order is by run, then onset")
        XCTAssertEqual(model.citations.count, m.source.attribution?.count)
    }

    func testChannelLabels_notInferredFromCount() async throws {
        var (m, _) = try await tinyRecording()
        // 16 channels with nothing declared: a 10-20 guess would be easy and wrong.
        m.channels = (0..<16).map { ChannelSpec(id: String(format: "ch%02d", $0), label: "", kind: "", unit: " ", sourceRow: 0) }
        m.montage = ""
        var model = RecordingDetailModel(manifest: m, events: [])
        XCTAssertEqual(model.channels.count, 16)
        XCTAssertTrue(model.channels.allSatisfy { $0.label == nil && $0.unit == nil && $0.kind == nil })
        XCTAssertEqual(model.montage, RecordingDetailModel.undeclared)
        XCTAssertEqual(RecordingDetailModel.undeclared, "undeclared")
        for name in ["Fp1", "C3", "Cz", "O2", "FC3"] {
            XCTAssertFalse(model.channels.contains { $0.label == name }, name)
        }

        // Arbitrary labels and a montage stored as "unspecified" pass through verbatim.
        let odd = ["left-ish", "C3", "x 1", "Fz?", "ëëg", "ch-7", "", "A1"]
        m.channels = odd.enumerated().map { ChannelSpec(id: "c\($0.offset)", label: $0.element, kind: "eeg", unit: "mV", sourceRow: 0) }
        m.montage = "unspecified"
        model = RecordingDetailModel(manifest: m, events: [])
        XCTAssertEqual(model.channels.map(\.label), odd.map { $0.isEmpty ? nil : $0 })
        XCTAssertEqual(model.channels.map(\.unit), Array(repeating: "mV", count: odd.count))
        XCTAssertEqual(model.montage, "unspecified")
    }

    // MARK: Criterion 10 — attribution

    func testExampleInfo_includesAttribution() async throws {
        let (real, _) = try await tinyRecording()
        let info = try XCTUnwrap(ExampleInfo(manifest: real))
        for needle in ["Schalk", "Goldberger", "ODC-BY", "10.13026/C28G6P", "S001"] {
            XCTAssertTrue(info.displayedText.contains(needle), needle)
            XCTAssertTrue(info.attributionText.contains(needle), needle)
        }

        // A manifest with different provenance: the panel follows it, so nothing above was hard-coded.
        var other = real
        other.source.dataset = "Example Lab Dataset v2"
        other.source.doi = "10.0000/example"
        other.source.license = "CC-BY 4.0"
        other.source.subject = "P07"
        other.source.runs = ["R1", "R2"]
        other.source.warning = "Recorded in another lab"
        other.source.attribution = [.init(text: "Doe, J. (2021). A dataset.", doi: "10.0000/doe")]
        other.source.derivations = ["nothing converted"]
        let info2 = try XCTUnwrap(ExampleInfo(manifest: other))
        for needle in ["Example Lab Dataset v2", "CC-BY 4.0", "P07", "Doe, J.", "10.0000/doe", "R1, R2"] {
            XCTAssertTrue(info2.displayedText.contains(needle) || info2.runs.joined(separator: ", ").contains(needle), needle)
        }
        for absent in ["Schalk", "Goldberger", "ODC-BY", "PhysioNet"] {
            XCTAssertFalse(info2.displayedText.contains(absent), absent)
            XCTAssertFalse(info2.attributionText.contains(absent), absent)
        }
        XCTAssertEqual(info2.attributionText, ProjectStore.attribution(for: other), "the panel and the export say the same thing")

        // A user's own recording has no example panel.
        var own = real
        own.source.kind = "brainflow"
        XCTAssertNil(ExampleInfo(manifest: own))
    }

    // MARK: Decision #8 — headline wording

    private func stored(holdoutRuns: [String], baCI: [Double]?, diffCI: [Double]?, exclusions: String = "[]") throws -> StoredResult {
        let perRun = holdoutRuns.map { #"{"run_id": "\#($0)", "n_trials": 7, "balanced_accuracy": 0.7, "accuracy": 0.7}"# }.joined(separator: ",")
        let ba = baCI.map { "[\($0[0]), \($0[1])]" } ?? "null"
        let diff = diffCI.map { "[\($0[0]), \($0[1])]" } ?? "null"
        let holdout = """
        {"balanced_accuracy": 0.6821, "accuracy": 0.7, "confusion_matrix": [[5, 2], [2, 5]], "n_test_trials": 14,
         "n_test_runs": \(holdoutRuns.count), "accuracy_ci95": [0.5123, 0.8456], "per_run": [\(perRun)],
         "balanced_accuracy_run_bootstrap_ci95": \(ba)}
        """
        let json = """
        {"split_policy": {"unit": "trial", "grouping": "run", "holdout": "GroupShuffleSplit by run, frozen before fitting",
                          "holdout_fraction": 0.25, "cv": "StratifiedGroupKFold(n_splits=2) on training runs", "evidence": "unknown-session", "seed": 3},
         "split_manifest": {"holdout_runs": \(holdoutRuns), "training_runs": ["A", "B"], "folds": [{"fold": 1, "test_runs": ["A"]}, {"fold": 2, "test_runs": ["B"]}]},
         "class_counts": {"train": [16, 14], "holdout": [7, 7]},
         "exclusions": \(exclusions),
         "models": {"reference_csp_rlda": {"cv_balanced_accuracy_per_fold": [0.6, 0.7], "cv_balanced_accuracy_mean": 0.65, "holdout": \(holdout)},
                    "baseline_logvar_rlda": {"cv_balanced_accuracy_per_fold": [0.5, 0.6], "cv_balanced_accuracy_mean": 0.55, "holdout": \(holdout)}},
         "comparison": {"reference": "reference_csp_rlda", "baseline": "baseline_logvar_rlda", "per_run_difference": [], "mean_difference": 0.11,
                        "difference_run_bootstrap_ci95": \(diff), "n_bootstrap_resamples": 0,
                        "paired_trials": {"reference_only_correct": 3, "baseline_only_correct": 1, "both_correct": 7, "neither_correct": 3}},
         "data_source": {"kind": "public_dataset", "warning": "Public dataset, not your device"}}
        """   // `\(holdoutRuns)` prints a [String] as a JSON array
        let pipeline = PipelineRecord(pipelineID: UUID(), recipe: "csp_rlda_v1", configuration: ["label_left": "cue_left_fist", "label_right": "cue_right_fist"],
                                      expectedChannelIDs: [], expectedSampleRateHz: 160, preprocessingStatePolicy: "reset_on_segment_start",
                                      trainingRecordingIDs: [], splitManifest: "{}", dependencyVersions: [:], seed: 3, fittedParametersFile: nil, configHash: "h")
        let data = Data(json.utf8)
        let meta = ResultMeta(resultID: UUID(), pipelineID: pipeline.pipelineID, recordingID: UUID(), createdAt: Date(), seed: 3, configHash: "h",
                              evaluationSHA256: AtomicFile.sha256Hex(data), durationsSeconds: [:], workerVersions: [:], workerOrigin: "development_venv",
                              reproductionOf: nil, divergedFrom: nil)
        return StoredResult(meta: meta, evaluationJSON: data, pipeline: pipeline)
    }

    func testHeadline_oneHeldOutRun_baIntervalUnavailable() throws {
        let m = try ResultDetailModel(stored: try stored(holdoutRuns: ["S001R12"], baCI: nil, diffCI: nil))
        XCTAssertEqual(m.headline.balancedAccuracy, "Balanced accuracy 0.68")
        XCTAssertEqual(m.headline.balancedAccuracyValue, "0.68")
        XCTAssertNil(m.balancedAccuracyInterval, "one held-out run: the BA bar is dashed")
        XCTAssertEqual(m.accuracyInterval, 0.5123...0.8456)
        XCTAssertTrue(m.heroAccessibilityLabel.hasPrefix("Balanced accuracy 0.68. Accuracy 0.70, 95 percent confidence interval 0.51 to 0.85, trial-level, 14 trials."), m.heroAccessibilityLabel)
        XCTAssertEqual(m.headline.accuracy, "Accuracy 0.70 · 95 % CI 0.51–0.85 (trial-level, n = 14)")
        XCTAssertEqual(m.headline.balancedAccuracyInterval, "Balanced-accuracy interval: unavailable (one held-out run)")
        XCTAssertEqual(m.differenceInterval, "Difference interval: unavailable (one held-out run)")
        XCTAssertEqual(m.trialsLine, "n = 14 held-out trials in 1 run · Session unknown", "the evidence phrase, never the raw token")
    }

    func testHeadline_trialLevelIntervalNeverLabelledAsBalancedAccuracy() throws {
        for (runs, ba) in [(["R1"], nil), (["R1", "R2"], [0.55, 0.79]), (["R1", "R2", "R3"], [0.41, 0.9])] as [([String], [Double]?)] {
            let m = try ResultDetailModel(stored: try stored(holdoutRuns: runs, baCI: ba, diffCI: ba))
            let trialCI = "0.51–0.85"
            // The trial-level interval appears only on the accuracy line, labelled trial-level.
            XCTAssertTrue(m.headline.accuracy.hasPrefix("Accuracy "))
            XCTAssertTrue(m.headline.accuracy.contains(trialCI) && m.headline.accuracy.contains("trial-level"))
            XCTAssertFalse(m.headline.accuracy.lowercased().contains("balanced"))
            XCTAssertFalse(m.headline.balancedAccuracy.contains(trialCI))
            XCTAssertFalse(m.headline.balancedAccuracyInterval.contains(trialCI))
            XCTAssertFalse(m.headline.balancedAccuracy.contains("CI"))
            if let ba {
                XCTAssertEqual(m.headline.balancedAccuracyInterval,
                               "Balanced-accuracy interval \(Fmt.fixed(ba[0]))–\(Fmt.fixed(ba[1])) (run-level bootstrap, \(runs.count) held-out runs)")
            }
        }
    }

    func testResultDetail_confusionCellsSplitAndExclusions() throws {
        let exclusions = #"[{"trial_id": "S001R04-t00", "run_id": "S001R04", "label": 1, "reason": "window_starts_before_filter_warmup", "window_start_sample": 0, "window_stop_sample": 1}]"#
        let m = try ResultDetailModel(stored: try stored(holdoutRuns: ["R1"], baCI: nil, diffCI: nil, exclusions: exclusions))
        XCTAssertEqual(m.classNames, ["cue_left_fist", "cue_right_fist"], "class names come from the pipeline configuration")
        XCTAssertEqual(m.cells.map(\.count), [5, 2, 2, 5])
        XCTAssertEqual(m.cells[1].accessibilityLabel,
                       "True Left-fist cue (cue_left_fist), predicted Right-fist cue (cue_right_fist): 2 of 7 trials, wrong")
        XCTAssertEqual(m.cells.map(\.rowTotal), [7, 7, 7, 7])
        XCTAssertEqual(Set(m.cells.map(\.accessibilityLabel)).count, 4, "every cell has its own label")
        XCTAssertEqual(m.confusionSummary, "Of 14 held-out trials, 10 were classified correctly: 5 of 7 Left-fist cue and 5 of 7 Right-fist cue.")
        XCTAssertEqual(m.classDisplayNames, ["Left-fist cue", "Right-fist cue"])
        XCTAssertEqual(m.classCounts.map(\.className), ["cue_left_fist", "cue_right_fist"], "the stored label is kept beside the display name")
        XCTAssertEqual(m.classCounts.map(\.train), [16, 14])
        XCTAssertEqual(m.evidence.symbol, "questionmark.circle")
        XCTAssertEqual(m.evidence.text, "Session unknown — this is not evidence of cross-session transfer.")
        XCTAssertEqual(m.splitFields.first { $0.label == "Seed" }?.value, "3")
        XCTAssertEqual(m.splitFields.first { $0.label == "Grouping" }?.value, "by run")
        XCTAssertEqual(m.exclusions, ["Trial S001R04-t00 (S001R04, Right-fist cue (cue_right_fist)): window starts before filter warm-up"])
        XCTAssertEqual(m.warning, "Public dataset, not your device")
    }

    func testResultTree_reproductionsAreChildrenOfTheirOriginal() {
        func meta(_ t: TimeInterval, seed: Int, of: UUID? = nil, diverged: UUID? = nil) -> ResultMeta {
            ResultMeta(resultID: UUID(), pipelineID: UUID(), recordingID: UUID(), createdAt: Date(timeIntervalSince1970: t), seed: seed,
                       configHash: "h", evaluationSHA256: "x", durationsSeconds: [:], workerVersions: [:], workerOrigin: "bundled",
                       reproductionOf: of, divergedFrom: diverged)
        }
        let a = meta(10, seed: 0)
        let a1 = meta(20, seed: 0, of: a.resultID)
        let b = meta(30, seed: 1)
        let a2 = meta(40, seed: 0, diverged: a.resultID)
        let tree = ResultNode.tree([a2, b, a1, a])
        XCTAssertEqual(tree.map(\.id), [a.resultID, b.resultID], "originals at the top level, oldest first; a new seed is a new root")
        XCTAssertEqual(tree[0].children?.map(\.id), [a1.resultID, a2.resultID])
        XCTAssertNil(tree[1].children)
        XCTAssertTrue(tree[0].children![1].diverged)
    }

    // MARK: Decision #12 — larger-class reference; decision #11 — class display

    func testLargerClassRate_fromStoredCountsOnly() {
        // 7 + 8 held out: the larger class is 8/15.
        let around = ResultDetailModel.largerClass(holdoutCounts: [7, 8], interval: 0.32...0.84)
        XCTAssertEqual(around?.rate ?? 0, 8.0 / 15, accuracy: 1e-12)
        XCTAssertEqual(around?.sentence, "Interval includes the larger-class rate.")
        XCTAssertEqual(ResultDetailModel.largerClass(holdoutCounts: [7, 8], interval: 0.60...0.90)?.sentence,
                       "Interval lies entirely above the larger-class rate.")
        XCTAssertEqual(ResultDetailModel.largerClass(holdoutCounts: [10, 2], interval: 0.40...0.80)?.sentence,
                       "Interval lies entirely below the larger-class rate.")
        // Boundaries count as included.
        XCTAssertEqual(ResultDetailModel.largerClass(holdoutCounts: [1, 1], interval: 0.5...0.9)?.sentence,
                       "Interval includes the larger-class rate.")
        XCTAssertNil(ResultDetailModel.largerClass(holdoutCounts: [0, 0], interval: 0.1...0.2), "no trials, no reference")
        XCTAssertNil(ResultDetailModel.largerClass(holdoutCounts: [3, 4], interval: nil), "no interval, nothing to compare")
    }

    func testLargerClassRate_inTheResultModel() throws {
        let m = try ResultDetailModel(stored: try stored(holdoutRuns: ["R1"], baCI: nil, diffCI: nil))
        // class_counts.holdout = [7, 7]: 0.5, inside 0.51–0.85? No: below the interval.
        XCTAssertEqual(m.largerClass?.rate, 0.5)
        XCTAssertEqual(m.largerClass?.sentence, "Interval lies entirely above the larger-class rate.")
    }

    func testClassDisplay_namesCuesAndKeepsAnythingElse() {
        XCTAssertEqual(ClassDisplay.name("cue_left_fist"), "Left-fist cue")
        XCTAssertEqual(ClassDisplay.name("cue_right_fist"), "Right-fist cue")
        XCTAssertEqual(ClassDisplay.name("cue_both_feet"), "Both feet cue")
        XCTAssertEqual(ClassDisplay.name("rest"), "rest")
        XCTAssertEqual(ClassDisplay.name("Cue_left_fist"), "Cue_left_fist", "no case folding; anything else verbatim")
        XCTAssertEqual(ClassDisplay.name("cue_left_fist_x"), "Left fist x cue")
        XCTAssertEqual(ClassDisplay.spoken("cue_left_fist"), "Left-fist cue, stored label cue_left_fist")
        XCTAssertEqual(ClassDisplay.spoken("rest"), "rest")
    }

    func testEventsAndChannels_neverUseClassDisplayNames() async throws {
        let (m, events) = try await tinyRecording()
        let model = RecordingDetailModel(manifest: m, events: events)
        XCTAssertTrue(model.events.contains { $0.label == "cue_left_fist" })
        XCTAssertFalse(model.events.contains { $0.label.contains("Left-fist") })
        let inspector = EvaluateInspectorModel(manifest: m, events: events, latest: nil, defaults: nil, modelName: { $0 })
        XCTAssertTrue(inspector.misleading[0].text.contains("“cue_left_fist”"), "the inspector quotes the raw label")
    }

    // MARK: Inspector and progress

    func testInspector_misleadingBulletsComeFromTheRecording() async throws {
        let (m, events) = try await tinyRecording()
        let model = EvaluateInspectorModel(manifest: m, events: events, latest: nil, defaults: nil, modelName: { $0 })
        let text = model.misleading.map(\.text).joined(separator: "\n")
        let left = events.filter { $0.label == "cue_left_fist" && $0.trialID != nil }.count
        let right = events.filter { $0.label == "cue_right_fist" && $0.trialID != nil }.count
        XCTAssertTrue(text.contains("\(left) “cue_left_fist”") && text.contains("\(right) “cue_right_fist”"), text)
        XCTAssertTrue(text.contains("not evidence of cross-session transfer"), text)
        XCTAssertTrue(text.contains("One subject (S001)"), text)
        XCTAssertTrue(text.contains("not recorded on your device"), text)
        XCTAssertFalse(text.contains("held out"), "held-out runs are only claimed from a stored result")

        var own = m
        own.source.kind = "brainflow"
        own.source.subject = nil
        own.segments = own.segments.map { var s = $0; s.sessionID = "day1"; return s }
        let ownText = EvaluateInspectorModel(manifest: own, events: events, latest: nil, defaults: nil, modelName: { $0 }).misleading.map(\.text).joined()
        XCTAssertFalse(ownText.contains("not recorded on your device"))
        XCTAssertFalse(ownText.contains("One subject"))
        XCTAssertTrue(ownText.contains("one session"))
    }

    func testProgressDisplay_stageLabelsAndAccessibility() {
        let fit = ProgressDisplay(.fitting(model: "reference_csp_rlda", fold: 2, of: 3, step: 1, steps: 2), modelName: { _ in "CSP" })
        XCTAssertEqual(fit.stage, "Cross-validation")
        XCTAssertEqual(fit.detail, "CSP, fold 2 of 3")
        XCTAssertEqual(fit.accessibilityValue, "Cross-validation, 2 of 3")
        XCTAssertEqual(ProgressDisplay(.loading, modelName: { $0 }).stage, "Loading")
        XCTAssertEqual(ProgressDisplay(.holdout(model: "m", step: 2, steps: 2), modelName: { $0 }).stage, "Fit and holdout")
        // Marks differ by shape: done, current, pending.
        XCTAssertEqual((0..<3).map { fit.mark(for: $0) }, [.done, .current, .pending])
        XCTAssertEqual(Set([ProgressDisplay.Mark.done, .current, .pending].map(\.symbol)).count, 3)
        let saving = ProgressDisplay(.storing, modelName: { $0 })
        XCTAssertEqual((0..<3).map { saving.mark(for: $0) }, [.done, .done, .done])
    }
}
