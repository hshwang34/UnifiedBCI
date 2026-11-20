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
        let scale = try XCTUnwrap(m.scales.first?.height)
        XCTAssertEqual(m.scales.map(\.unit), ["µV"])
        XCTAssertTrue([1.0, 2, 5].contains(scale / pow(10, floor(log10(scale)))))
        XCTAssertEqual(m.scaleText, "Lane height \(TraceModel.scaleNumber(scale)) µV")
        XCTAssertTrue(m.lanes.allSatisfy { $0.scale == scale })
        XCTAssertNil(m.scaleNote)
        XCTAssertEqual(m.headerText, "Signal · 0.0–10.0 s of 42 s")
        XCTAssertEqual(TraceModel.header(nil), "Signal")
        XCTAssertEqual(m.ticks.map(TraceModel.tickLabel), ["0 s", "2 s", "4 s", "6 s", "8 s", "10 s"])
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
        XCTAssertEqual([500, 2, 0.05, 0.5].map(TraceModel.scaleNumber), ["500", "2", "0.05", "0.5"])
    }

    func testClippedMeansPastHalfTheLaneHeight() throws {
        var w = try SignalWindowTests.fixture("signal_window_tiny")
        // Flatten every raw trace to ±1 around zero, then push one point of ch00 out.
        for i in w.channels.indices {
            let n = w.tS.count
            w.channels[i].raw = .init(min: Array(repeating: -1, count: n), max: Array(repeating: 1, count: n), lo: -1, hi: 1)
        }
        let flat = TraceModel(window: w, processed: false, flags: [:])
        XCTAssertEqual(flat.scales.first?.height, 2, "median span 2 → lane height 2")
        XCTAssertFalse(flat.lanes.contains(where: \.clipped), "±1 fits ± half of 2 exactly")
        w.channels[0].raw?.max[5] = 1.5
        let one = TraceModel(window: w, processed: false, flags: [:])
        XCTAssertEqual(one.lanes[0].halfScale, 1)
        XCTAssertTrue(one.lanes[0].clipped, "1.5 is past half the lane height (1), though inside a full lane (2)")
        XCTAssertTrue(one.lanes[0].accessibilityLabel.contains("exceeds the lane height"))
        XCTAssertFalse(one.lanes[1].clipped)
    }

    func testWindowInsideWarmUpScalesFromItsSamples() throws {
        var w = try SignalWindowTests.fixture("signal_window_tiny")
        w.bandpass?.warmupEndS = 20   // past the whole 0–10 s window
        let m = TraceModel(window: w, processed: true, flags: [:])
        XCTAssertEqual(m.warmup, 0...10)
        XCTAssertEqual(m.scaleNote, TraceModel.insideWarmupText)
        let spans = w.channels.compactMap { c -> Double? in
            guard let t = c.bandpassed, let lo = t.min.compactMap({ $0 }).min(), let hi = t.max.compactMap({ $0 }).max() else { return nil }
            return hi - lo
        }.sorted()
        XCTAssertEqual(m.scales.first?.height, TraceModel.nice(spans[spans.count / 2]), "not the fallback of 1")
        XCTAssertFalse(m.lanes.allSatisfy(\.clipped))
    }

    func testChannelsWithDifferentUnitsGetTheirOwnLaneHeight() throws {
        var w = try SignalWindowTests.fixture("signal_window_tiny")
        w.channels[1].unit = "g"
        let n = w.tS.count
        w.channels[1].raw = .init(min: Array(repeating: -0.01, count: n), max: Array(repeating: 0.01, count: n), lo: -0.01, hi: 0.01)
        let m = TraceModel(window: w, processed: false, flags: [:])
        XCTAssertEqual(m.scales.map(\.unit), ["µV", "g"])
        XCTAssertEqual(m.lanes[1].scale, 0.02)
        XCTAssertFalse(m.lanes[1].clipped)
        XCTAssertEqual(m.lanes[0].scale, m.scales[0].height)
        XCTAssertTrue(m.scaleText.hasSuffix(" · 0.02 g"), m.scaleText)
    }

    // MARK: Runner (fake source)

    /// A→B→A: A's cancel is sent when B is asked for; going back to A must not leave the
    /// runner waiting on the cancelled fetch. A is fetched again and ends on screen.
    func testBackToACancelledRequestReloadsIt() async throws {
        let base = try SignalWindowTests.fixture("signal_window_tiny")
        let source = FakeWindowSource(base: base)
        let runner = SignalWindowRunner(inspector: source)
        let id = UUID()
        let a = SignalWindowRunner.Request(recordingID: id, segment: 0, startS: 0)
        let b = SignalWindowRunner.Request(recordingID: id, segment: 0, startS: 10)
        runner.load(a)
        try await source.waitForPending(1)
        runner.load(b)
        runner.load(a)
        XCTAssertEqual(source.cancelled.count, 1, "A's cancel went out when B was asked for")
        // The worker honours A's cancel; the runner must start A again, never B.
        let second = try await source.waitForStarted(2)
        XCTAssertEqual(second.startS, 0)
        source.answer(second)
        while runner.isBusy { await Task.yield() }
        XCTAssertEqual(runner.state, .ready(a))
        XCTAssertEqual(runner.window?.startS, 0)
        XCTAssertEqual(source.started.map(\.startS), [0, 0], "B was never fetched")
    }

    func testFailedWindowIsRetriedOnTheNextLoad() async throws {
        let base = try SignalWindowTests.fixture("signal_window_tiny")
        let source = FakeWindowSource(base: base)
        let runner = SignalWindowRunner(inspector: source)
        let a = SignalWindowRunner.Request(recordingID: UUID(), segment: 0, startS: 0)
        runner.load(a)
        source.fail(try await source.waitForPending(1), WorkerError(code: "worker_exited", message: "gone"))
        while runner.isBusy { await Task.yield() }
        XCTAssertEqual(runner.state, .unavailable(a, reason: "gone"))
        runner.load(a)
        source.answer(try await source.waitForPending(1))
        while runner.isBusy { await Task.yield() }
        XCTAssertEqual(runner.state, .ready(a))
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

/// Holds each `signal_window` call until the test answers it; a cancel fails it as the
/// worker does (`cancelled`).
@MainActor
private final class FakeWindowSource: SignalWindowSource {
    struct Call { let requestID: String; let startS: Double; let continuation: CheckedContinuation<SignalWindow, Error> }
    let projectDirectory = URL(fileURLWithPath: "/nonexistent.bciproj")
    let base: SignalWindow
    private(set) var pending: [Call] = []
    private(set) var started: [Call] = []
    private(set) var cancelled: [String] = []

    init(base: SignalWindow) { self.base = base }

    func signalWindow(params: [String: JSONValue], requestID: String) async throws -> SignalWindow {
        guard case .double(let start) = params["start_s"] else { throw WorkerError(code: "bad_params", message: "start_s") }
        return try await withCheckedThrowingContinuation { c in
            let call = Call(requestID: requestID, startS: start, continuation: c)
            pending.append(call)
            started.append(call)
        }
    }

    func cancelSignalWindow(requestID: String) {
        cancelled.append(requestID)
        // Answered on a later turn, as the real worker's reply arrives after the cancel.
        Task { @MainActor in
            if let i = self.pending.firstIndex(where: { $0.requestID == requestID }) {
                self.pending.remove(at: i).continuation.resume(throwing: WorkerError(code: "cancelled", message: "cancelled"))
            }
        }
    }

    @discardableResult
    func waitForPending(_ n: Int) async throws -> Call {
        for _ in 0..<10_000 {
            if pending.count >= n { return pending[n - 1] }
            await Task.yield()
        }
        throw WorkerError(code: "test", message: "no pending call")
    }

    func waitForStarted(_ n: Int) async throws -> Call {
        for _ in 0..<10_000 {
            if started.count >= n { return started[n - 1] }
            await Task.yield()
        }
        throw WorkerError(code: "test", message: "call \(n) never started")
    }

    func answer(_ call: Call) {
        pending.removeAll { $0.requestID == call.requestID }
        var w = base
        w.startS = call.startS
        call.continuation.resume(returning: w)
    }

    func fail(_ call: Call, _ error: WorkerError) {
        pending.removeAll { $0.requestID == call.requestID }
        call.continuation.resume(throwing: error)
    }
}
