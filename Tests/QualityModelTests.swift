import XCTest
@testable import BCIWorkspace

/// Brief 002 PR 3: decoding worker-captured `inspect_recording` results and every string
/// the Quality tab builds from them. Fixtures come from worker/tools/make_quality_fixtures.py
/// (the worker's pytest fails when they go stale).
final class QualityModelTests: XCTestCase {
    static func fixture(_ name: String) throws -> InspectionReport {
        let url = try XCTUnwrap(Bundle(for: QualityModelTests.self).url(forResource: name, withExtension: "json"), "\(name).json missing from the test bundle")
        return try InspectionReport.decode(Data(contentsOf: url))
    }

    private func model(_ name: String) throws -> QualityModel { QualityModel(report: try Self.fixture(name)) }

    private func row(_ m: QualityModel, segment: Int = 0, _ label: String) throws -> QualityModel.ChannelRow {
        try XCTUnwrap(m.sections[segment].rows.first { $0.label == label }, label)
    }

    // MARK: Decoding

    func testDecodesTinyFixture() throws {
        let r = try Self.fixture("inspect_recording_tiny")
        XCTAssertEqual(r.rules.count, 6)
        XCTAssertEqual(r.rules[0], .init(id: "flatline", title: "Flatline", rule: "window standard deviation < 0.5 µV", flagWhen: "≥ 1 window"))
        XCTAssertEqual(r.segments.map(\.runId), ["S001R04", "S001R08", "S001R12"])
        let fc3 = r.segments[0].channels[0]
        XCTAssertEqual([fc3.id, fc3.label, fc3.kind, fc3.unit], ["ch00", "FC3", "eeg", "uV"])
        XCTAssertEqual(fc3.checks.map(\.rule), r.rules.map(\.id))
        XCTAssertLessThanOrEqual(fc3.psd.freqs.count, 256)
        XCTAssertEqual(fc3.psd.raw?.count, fc3.psd.freqs.count)
        XCTAssertEqual(fc3.checks[3].measured?.lines?.map(\.hz), [50, 60])
    }

    func testDecodesNullsWithReasons() throws {
        let r = try Self.fixture("inspect_recording_faults")
        let nan = try XCTUnwrap(r.segments[0].channels.first { $0.label == "NAN" })
        XCTAssertNil(nan.psd.raw)
        XCTAssertNil(nan.peakHz)
        XCTAssertTrue(nan.checks.allSatisfy { !$0.assessable && $0.measured == nil && $0.reason == "channel contains non-finite samples" })
        let mains125 = r.segments[1].channels[0].checks[3].measured?.lines?[1]
        XCTAssertEqual(mains125?.db, nil)
        XCTAssertEqual(mains125?.reason, "not assessable at 125 Hz")
    }

    // MARK: Flags, one per rule

    func testEachInjectedFaultReadsAsItsRuleWithTheMeasuredValue() throws {
        let m = try model("inspect_recording_faults")
        let texts = { (label: String) in try self.row(m, label).flags.map(\.text) }
        XCTAssertEqual(try texts("FLAT"), ["Flatline · 8 s of 60 s flat (window standard deviation < 0.5 µV)"])
        XCTAssertEqual(try texts("PIN"), ["Pinned at a limit · 1 run, longest 20 samples (≥ 5 consecutive samples equal to the channel's segment maximum or minimum)"])
        let mains = try XCTUnwrap(texts("MAINS").first)
        XCTAssertTrue(mains.hasPrefix("Mains line (50 / 60 Hz) · 60 Hz line "), mains)
        XCTAssertTrue(mains.hasSuffix(" dB over neighbours"), mains)
        XCTAssertNotNil(mains.range(of: #"60 Hz line \d+\.\d dB"#, options: .regularExpression), mains)
        let big = try XCTUnwrap(texts("BIG").first)
        XCTAssertNotNil(big.range(of: #"^Outlier amplitude · variance \d+\.\d× the median channel$"#, options: .regularExpression), big)
        let hf = try XCTUnwrap(texts("HF").first)
        XCTAssertNotNil(hf.range(of: #"^Outlier high-frequency power · 20–45 Hz power \d+\.\d× the median channel$"#, options: .regularExpression), hf)
        for label in ["C3", "C4", "Cz"] {
            let r = try row(m, label)
            XCTAssertEqual(r.flags, [])
            XCTAssertEqual(r.status, "None of these rules fired")
            XCTAssertEqual(r.accessibilityLabel, "\(label), EEG µV. None of these rules fired.")
        }
    }

    func testLargeDeflectionsShowTheMeasuredShare_decision25() throws {
        let m = try model("inspect_recording_tiny")
        let fc3 = try row(m, "FC3")
        XCTAssertEqual(fc3.flags.map(\.text), ["Large deflections · 57 % of windows (24 of 42) with window peak-to-peak > 200 µV"])
        XCTAssertNil(fc3.status)
        XCTAssertEqual(fc3.kindUnit, "EEG · µV")
        XCTAssertEqual(fc3.accessibilityLabel, "FC3, EEG µV. Large deflections · 57 % of windows (24 of 42) with window peak-to-peak > 200 µV.")
    }

    func testNotAssessableReasonsAreShownVerbatimAndGrouped() throws {
        let m = try model("inspect_recording_faults")
        XCTAssertEqual(try row(m, "MV").notAssessed, ["Flatline, Large deflections, Outlier amplitude, Outlier high-frequency power · not assessed (unit mV)"])
        XCTAssertEqual(try row(m, "ACC").notAssessed, ["Flatline, Large deflections, Outlier amplitude, Outlier high-frequency power · not assessed (unit g)"])
        XCTAssertEqual(try row(m, "ACC").kindUnit, "accel · g")
        XCTAssertEqual(try row(m, "EMG").notAssessed, ["Outlier amplitude, Outlier high-frequency power · not compared (kind emg; medians are across EEG channels)"])
        XCTAssertEqual(try row(m, "MV").status, "None of the 2 assessed rules fired")
        XCTAssertEqual(try row(m, "EMG").status, "None of the 4 assessed rules fired")
        XCTAssertEqual(try row(m, segment: 1, "C3").status, "None of these rules fired", "one mains line assessed counts as assessed")
        XCTAssertEqual(try row(m, segment: 2, "C3").status, "None of the 5 assessed rules fired")
        let nan = try row(m, "NAN")
        XCTAssertEqual(nan.status, "No rule could be assessed")
        XCTAssertEqual(nan.notAssessed.count, 1)
        XCTAssertTrue(nan.notAssessed[0].hasSuffix(" · channel contains non-finite samples"))
        XCTAssertEqual(try row(m, segment: 1, "C3").notAssessed, ["Mains line (50 / 60 Hz) · 60 Hz not assessable at 125 Hz"])
        XCTAssertEqual(try row(m, segment: 2, "C3").notAssessed, ["Mains line (50 / 60 Hz) · not assessable at 100 Hz"])
        let undeclared = try row(m, segment: 3, "C3")
        XCTAssertEqual(undeclared.kindUnit, "EEG · unit not declared")
        XCTAssertEqual(undeclared.notAssessed, ["Flatline, Large deflections, Outlier amplitude, Outlier high-frequency power · unit not declared",
                                                "Mains line (50 / 60 Hz) · not assessable at 50 Hz"])
    }

    // MARK: Rounding never contradicts the rule (review round 1)

    func testFaithfulRoundingStaysOnTheTrueSideOfEveryBoundary() {
        XCTAssertEqual(QualityModel.faithful(10.1, digits: 0, boundaries: [10, 0, 100]), "10.1")
        XCTAssertEqual(QualityModel.faithful(99.6, digits: 0, boundaries: [10, 0, 100]), "99.6")
        XCTAssertEqual(QualityModel.faithful(57.1, digits: 0, boundaries: [10, 0, 100]), "57")
        XCTAssertEqual(QualityModel.faithful(100, digits: 0, boundaries: [10, 0, 100]), "100")
        XCTAssertEqual(QualityModel.ratio(5.04, [5, 0.2]), "5.04×")
        XCTAssertEqual(QualityModel.ratio(0.196, [5, 0.2]), "0.196×")
        XCTAssertEqual(QualityModel.ratio(6.1, [5, 0.2]), "6.1×")
        XCTAssertEqual(QualityModel.numbers(in: "> 5× or < 0.2×"), [5, 0.2])
    }

    func testFlagLinesNearThresholdsReadOnTheFlaggedSide() throws {
        var r = try Self.fixture("inspect_recording_faults")
        func set(_ label: String, _ rule: String, _ edit: (inout InspectionReport.Measured) -> Void) throws {
            let c = try XCTUnwrap(r.segments[0].channels.firstIndex { $0.label == label })
            let k = try XCTUnwrap(r.segments[0].channels[c].checks.firstIndex { $0.rule == rule })
            r.segments[0].channels[c].checks[k].flagged = true
            r.segments[0].channels[c].checks[k].measured = r.segments[0].channels[c].checks[k].measured ?? .init()
            edit(&r.segments[0].channels[c].checks[k].measured!)
        }
        try set("C3", "large_deflection") { $0.fraction = 0.101; $0.windowsOver = 101; $0.windows = 1000 }
        try set("C4", "large_deflection") { $0.fraction = 0.996; $0.windowsOver = 996; $0.windows = 1000 }
        try set("BIG", "outlier_amplitude") { $0.ratio = 5.04 }
        try set("Cz", "outlier_amplitude") { $0.ratio = 0.196 }
        try set("MAINS", "mains_line") { $0.lines = [.init(hz: 60, db: 10.04, flagged: true, assessable: true, reason: nil)] }
        let m = QualityModel(report: r)
        let texts = { (label: String) in try self.row(m, label).flags.map(\.text).joined(separator: " | ") }
        let tC3 = try texts("C3")
        XCTAssertTrue(tC3.contains("Large deflections · 10.1 % of windows (101 of 1000)"), tC3)
        let tC4 = try texts("C4")
        XCTAssertTrue(tC4.contains("Large deflections · 99.6 % of windows"), tC4)
        let tBIG = try texts("BIG")
        XCTAssertTrue(tBIG.contains("variance 5.04× the median channel"), tBIG)
        let tCz = try texts("Cz")
        XCTAssertTrue(tCz.contains("variance 0.196× the median channel"), tCz)
        let tMAINS = try texts("MAINS")
        XCTAssertTrue(tMAINS.contains("60 Hz line 10.04 dB over neighbours"), tMAINS)
    }

    func testSegmentsAreNumberedByPosition() throws {
        var r = try Self.fixture("inspect_recording_tiny")
        for i in r.segments.indices { r.segments[i].index += 10 }
        let m = QualityModel(report: r)
        XCTAssertEqual(m.sections.map(\.title).map { String($0.prefix(9)) }, ["Segment 1", "Segment 2", "Segment 3"])
        XCTAssertEqual(m.sections[2].summary, "Flags on 8 of 8 channels in segment 3")
    }

    // MARK: Summary, legend, footer

    func testSummariesAreCountsOnly() throws {
        let tiny = try model("inspect_recording_tiny")
        XCTAssertEqual(tiny.sections.map(\.summary), ["Flags on 8 of 8 channels in segment 1", "Flags on 6 of 8 channels in segment 2", "Flags on 8 of 8 channels in segment 3"])
        XCTAssertEqual(tiny.sections[0].title, "Segment 1 · S001R04 · 0:00–0:42 at 160 Hz")
        XCTAssertTrue(tiny.sections[1].title.contains(" · 0:42–"), "segments sit back to back: \(tiny.sections[1].title)")
        // A live recording's run id is a UUID: never shown, the span names the segment.
        XCTAssertEqual(QualityModel.segmentTitle(number: 1, runID: UUID().uuidString, start: 0, duration: 8.1, rateHz: 125), "Segment 1 · 0:00–0:08 at 125 Hz")
        XCTAssertEqual(QualityModel.clock(3723), "1:02:03")
        XCTAssertEqual(tiny.summary, tiny.sections.map(\.summary).joined(separator: "; "))
        XCTAssertEqual(try model("inspect_recording_faults").sections[0].summary, "Flags on 5 of 12 channels in segment 1")
    }

    func testLegendComesFromTheWorkersRules() throws {
        let r = try Self.fixture("inspect_recording_tiny")
        let m = QualityModel(report: r)
        XCTAssertEqual(m.legend.map(\.title), r.rules.map(\.title))
        XCTAssertEqual(m.legend[2].text, "window peak-to-peak > 200 µV · flag when > 10 % of windows")
        XCTAssertEqual(QualityModel.footer, "These checks describe the recording. They can't show that a signal comes from the brain.")
    }

    // MARK: Spectra

    func testSpectraAreChartReadyWithGapsAndPeakSummaries() throws {
        let tiny = try Self.fixture("inspect_recording_tiny")
        let m = QualityModel(report: tiny)
        let fc3 = m.sections[0].spectra[0]
        XCTAssertEqual(fc3.accessibilitySummary, "FC3: strongest peak 60.0 Hz")
        XCTAssertEqual(fc3.raw.count, tiny.segments[0].channels[0].psd.freqs.count)
        XCTAssertEqual(fc3.processed.count, fc3.raw.count)
        XCTAssertEqual(fc3.raw.first?.hz, tiny.segments[0].channels[0].psd.freqs.first ?? nil)
        XCTAssertEqual(Set(fc3.raw.map(\.run)), [0])
        XCTAssertGreaterThanOrEqual(fc3.raw.first?.hz ?? 0, 1)
        XCTAssertLessThanOrEqual(fc3.raw.last?.hz ?? .infinity, 80)

        let nan = try XCTUnwrap(QualityModel(report: try Self.fixture("inspect_recording_faults")).sections[0].spectra.first { $0.label == "NAN" })
        XCTAssertEqual(nan.raw, [])
        XCTAssertEqual(nan.rawNote, "channel contains non-finite samples")
        XCTAssertEqual(nan.accessibilitySummary, "NAN: no spectrum")

        let low = QualityModel(report: try Self.fixture("inspect_recording_faults")).sections[3].spectra[1]
        XCTAssertEqual(low.processed, [])
        XCTAssertFalse(low.raw.isEmpty)
        XCTAssertNil(low.rawNote)
        XCTAssertEqual(low.processedNote, "band-pass 8–30 Hz does not fit below Nyquist at 50 Hz")

        // A null bin splits the line instead of being drawn across.
        var gapped = tiny
        gapped.segments[0].channels[0].psd.raw?[5] = nil
        let s = QualityModel(report: gapped).sections[0].spectra[0]
        XCTAssertEqual(s.raw.count, fc3.raw.count - 1)
        XCTAssertEqual(s.raw.filter { $0.run == 0 }.count, 5)
        XCTAssertEqual(Set(s.raw.map(\.run)), [0, 1])
    }

    // MARK: Wording rule (PRD §5, decision #22)

    func testNoStringCallsTheSignalGoodCleanOrNeural() throws {
        // "band-pass" / "band-passed" name the filter, not a verdict, so a hyphen before
        // the word exempts it; a free-standing "pass" or "passed" still fails the scan.
        let forbidden = try NSRegularExpression(pattern: #"(?<![-\w])(good|clean|healthy|neural|brain-quality|pass|passed|passes|fail|failed|fails)\b"#, options: .caseInsensitive)
        for name in ["inspect_recording_tiny", "inspect_recording_faults"] {
            let m = try model(name)
            var strings = [QualityModel.footer, QualityModel.noFlags, QualityModel.nothingAssessed, QualityModel.rawTitle,
                           QualityModel.processedTitle, QualityModel.frequencyAxis, QualityModel.powerAxis, m.summary]
            strings += m.legend.flatMap { [$0.title, $0.rule, $0.flagWhen, $0.text] }
            for section in m.sections {
                strings += [section.title, section.summary]
                for r in section.rows {
                    strings += [r.label, r.kindUnit, r.accessibilityLabel] + r.flags.map(\.text) + r.notAssessed + [r.status].compactMap { $0 }
                }
                for s in section.spectra { strings += [s.accessibilitySummary] + [s.rawNote, s.processedNote].compactMap { $0 } }
            }
            XCTAssertGreaterThan(strings.count, 100)
            for s in strings {
                XCTAssertNil(forbidden.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), "forbidden word in \(name): \(s)")
            }
        }
    }
}
