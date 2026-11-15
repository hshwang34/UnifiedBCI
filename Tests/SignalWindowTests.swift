import XCTest
@testable import BCIWorkspace

/// Brief 002 trace view: the `signal_window` contract. Fixtures come from
/// worker/tools/make_quality_fixtures.py (the worker's pytest fails when they go stale).
final class SignalWindowTests: XCTestCase {
    static func fixture(_ name: String) throws -> SignalWindow {
        let url = try XCTUnwrap(Bundle(for: SignalWindowTests.self).url(forResource: name, withExtension: "json"), "\(name).json missing from the test bundle")
        return try SignalWindow.decode(Data(contentsOf: url))
    }

    func testDecodesTinyFixture() throws {
        let w = try Self.fixture("signal_window_tiny")
        XCTAssertEqual([w.runId, w.recordingId], ["S001R04", "3e2e07c7-ba7a-5111-9cee-57a4e2990416"])
        XCTAssertEqual([w.segment, w.samples, w.points], [0, 1600, 100])
        XCTAssertEqual([w.sfreq, w.segmentDurationS, w.startS, w.durationS], [160, 42, 0, 10])
        XCTAssertEqual(w.tS.count, 100)
        XCTAssertEqual(w.tS[1], 0.1, accuracy: 1e-12)
        let bp = try XCTUnwrap(w.bandpass)
        XCTAssertEqual([bp.lowHz, bp.highHz], [8, 30])
        XCTAssertEqual(bp.order, 4)
        XCTAssertEqual(bp.warmupEndS, Double(bp.warmupSamples) / 160, accuracy: 1e-12)
        XCTAssertNil(w.bandpassedReason)
        XCTAssertEqual(w.channels.count, 8)
        let fc3 = w.channels[0]
        XCTAssertEqual([fc3.id, fc3.label, fc3.kind, fc3.unit], ["ch00", "FC3", "eeg", "uV"])
        for trace in [fc3.raw, fc3.bandpassed] {
            let t = try XCTUnwrap(trace)
            XCTAssertEqual(t.min.count, 100)
            XCTAssertEqual(t.max.count, 100)
            XCTAssertEqual(t.lo, t.min.compactMap { $0 }.min())
            XCTAssertEqual(t.hi, t.max.compactMap { $0 }.max())
        }
    }

    func testDecodesNullsWithReasons() throws {
        let w = try Self.fixture("signal_window_low_rate")
        XCTAssertNil(w.bandpass)
        XCTAssertEqual(w.bandpassedReason, "band-pass 8–30 Hz does not fit below Nyquist at 50 Hz")
        XCTAssertEqual(w.startS, 5)
        let nan = try XCTUnwrap(w.channels.last)
        XCTAssertNil(nan.bandpassed)
        XCTAssertEqual(nan.bandpassedReason, w.bandpassedReason)
        XCTAssertEqual(nan.raw?.min[2...5].allSatisfy { $0 == nil }, true)
        XCTAssertNotNil(nan.raw?.min[0])
    }

    func testRealWorkerAnswersTheParamsTheAppSends() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-window-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let projectDir = scratch.appendingPathComponent("tiny.bciproj")
        let store = try ProjectStore.importBundledExample(from: try ProjectStoreTests.tinyFixtureURL(), into: projectDir)
        let ids = try await store.recordingIDs()
        let recordingID = try XCTUnwrap(ids.first)
        let client = WorkerClient(launch: try XCTUnwrap(WorkerLaunch.locate(), "no worker found; run scripts/bootstrap.sh"))
        let hello = try await client.start()
        defer { Task { await client.shutdown() } }
        XCTAssertTrue(hello.methods.contains("signal_window"))
        let params = SignalWindow.params(projectDirectory: projectDir, recordingID: recordingID, segment: 1,
                                         startS: 38, durationS: 10, which: .raw, maxPoints: 500)
        let w = try SignalWindow.decode(try await client.call("signal_window", params: params, timeout: .seconds(30)))
        XCTAssertEqual([w.startS, w.durationS], [32, 10], "slid back inside the 42 s segment")
        XCTAssertEqual([w.segment, w.points], [1, 500])
        XCTAssertNil(w.bandpass)
        XCTAssertTrue(w.channels.allSatisfy { $0.raw != nil && $0.bandpassed == nil })
        do {
            _ = try await client.call("signal_window", params: SignalWindow.params(projectDirectory: projectDir, recordingID: recordingID,
                                                                                  segment: 0, startS: 0, durationS: 31))
            XCTFail("a 31 s window must be refused")
        } catch let e as WorkerError {
            XCTAssertEqual(e.code, "bad_request")
        }
    }
}
