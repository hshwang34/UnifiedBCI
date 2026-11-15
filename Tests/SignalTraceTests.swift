import XCTest
@testable import BCIWorkspace

/// Brief 002 signal view: the trace copy and numbers (no rendering), and the window
/// runner's latest-wins queue and cache on the real worker.
@MainActor
final class SignalTraceTests: XCTestCase {
    private let flags = ["ch00": ["Large deflections"], "ch01": []]

    func testRawLanesShareOneScaleAndReadChannelFlagsThenRange() throws {
        let w = try SignalWindowTests.fixture("signal_window_tiny")
        let m = TraceModel(window: w, processed: false, flags: flags)
        XCTAssertEqual(m.lanes.map(\.label).prefix(2), ["FC3", "FC4"])
        XCTAssertEqual(m.rangeText, "0.0–10.0 s of 42 s")
        XCTAssertEqual(m.ticks, [0, 2, 4, 6, 8, 10])
        XCTAssertNil(m.warmup, "raw traces carry no warm-up mark")
        XCTAssertTrue([1.0, 2, 5].contains(m.laneScale / pow(10, floor(log10(m.laneScale)))))
        XCTAssertEqual(m.scaleText, "Lane height \(QualityModel.num(m.laneScale)) µV")
        let fc3 = m.lanes[0]
        XCTAssertTrue(fc3.isFlagged)
        XCTAssertEqual(fc3.accessibilityLabel.components(separatedBy: ". ").first, "FC3, flags: Large deflections")
        XCTAssertTrue(fc3.accessibilityLabel.contains("Raw 0.0–10.0 s of 42 s: min -176 µV, max 173 µV"), fc3.accessibilityLabel)
        XCTAssertFalse(m.lanes[1].isFlagged)
        XCTAssertTrue(m.lanes[1].accessibilityLabel.hasPrefix("FC4, no flags."))
        // Points are centred on the lane; the window's extremes are unchanged by it.
        XCTAssertEqual(fc3.points.map(\.hi).max()! + fc3.center, 173, accuracy: 1e-9)
        XCTAssertEqual(fc3.points.count, 100)
    }

    func testBandPassedMarksTheWarmUpAndNamesWhy() throws {
        let w = try SignalWindowTests.fixture("signal_window_tiny")
        let m = TraceModel(window: w, processed: true, flags: flags)
        let bp = try XCTUnwrap(w.bandpass)
        XCTAssertEqual(m.warmup, 0...bp.warmupEndS)
        XCTAssertEqual(m.warmupNote, "Shaded: band-pass warm-up, the first 0.57 s of the segment. Shown here; evaluation leaves out trials that start in it.")
        XCTAssertTrue(m.lanes[0].accessibilityLabel.contains("Band-passed 0.0–10.0 s"))
        // The warm-up is drawn, not cut: the first point is at the window start.
        XCTAssertEqual(m.lanes[0].points.first?.t, 0)
    }

    func testMissingTracesSayWhyAndGapsSplitRuns() throws {
        let w = try SignalWindowTests.fixture("signal_window_low_rate")
        let bp = TraceModel(window: w, processed: true, flags: [:])
        XCTAssertTrue(bp.lanes.allSatisfy { $0.points.isEmpty && $0.note == w.bandpassedReason })
        XCTAssertEqual(bp.lanes[0].accessibilityLabel, "C3, no flags. Not available: band-pass 8–30 Hz does not fit below Nyquist at 50 Hz.")
        let raw = TraceModel(window: w, processed: false, flags: [:])
        XCTAssertEqual(Set(raw.lanes[1].points.map(\.run)), [0, 1], "the null span is a gap")
        XCTAssertEqual(raw.lanes[1].points.count, 16)
    }

    func testWindowStepsStayInsideTheSegment() {
        XCTAssertEqual(TraceModel.step(0, by: -1, segment: 42), 0)
        XCTAssertEqual(TraceModel.step(0, by: 1, segment: 42), 10)
        XCTAssertEqual(TraceModel.step(30, by: 1, segment: 42), 32)
        XCTAssertEqual(TraceModel.clampStart(5, segment: 8), 0)
        XCTAssertEqual(TraceModel.nice(173), 200)
        XCTAssertEqual(TraceModel.nice(0.3), 0.5)
        XCTAssertEqual(TraceModel.nice(0), 1)
    }

    // MARK: Runner (real worker)

    func testRunnerLatestWinsCachesAndSharesTheInspectionWorker() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-trace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let dir = scratch.appendingPathComponent("tiny.bciproj")
        let store = try ProjectStore.importBundledExample(from: try ProjectStoreTests.tinyFixtureURL(), into: dir)
        let ids = try await store.recordingIDs()
        let id = try XCTUnwrap(ids.first)
        let inspector = InspectionRunner(projectDirectory: dir, launch: try XCTUnwrap(WorkerLaunch.locate()))
        let runner = SignalWindowRunner(inspector: inspector)
        let a = SignalWindowRunner.Request(recordingID: id, segment: 0, startS: 0)
        let b = SignalWindowRunner.Request(recordingID: id, segment: 0, startS: 10)
        let c = SignalWindowRunner.Request(recordingID: id, segment: 1, startS: 40)
        // a starts, b is superseded by c before it runs: c is what ends on screen.
        runner.load(a)
        runner.load(b)
        runner.load(c)
        var final = await runner.loadAndWait(c)
        XCTAssertEqual(final, .ready(c))
        XCTAssertEqual(runner.window?.segment, 1)
        XCTAssertEqual(runner.window?.startS, 32, "slid back inside the 42 s segment")
        XCTAssertEqual(runner.window?.points, SignalWindowRunner.maxPoints)
        // Cached: answered at once.
        final = await runner.loadAndWait(c)
        XCTAssertEqual(final, .ready(c))
        XCTAssertFalse(runner.isBusy)
        // An inspection afterwards reuses the same worker.
        let inspected = await inspector.inspectAndWait(recordingID: id)
        XCTAssertEqual(inspected, .done(recordingID: id))
        await inspector.shutdown()
        final = await runner.loadAndWait(b)
        guard case .unavailable(b, _) = final else { return XCTFail("\(final)") }
    }
}
