import XCTest
@testable import BCIWorkspace

final class WorkerClientTests: XCTestCase {
    private func makeClient() throws -> WorkerClient {
        let launch = try XCTUnwrap(WorkerLaunch.locate(), "no worker found; run scripts/bootstrap.sh")
        return WorkerClient(launch: launch)
    }

    func testStartAnnouncesProtocolAndPinnedDependencies() async throws {
        let client = try makeClient()
        let hello = try await client.start()
        defer { Task { await client.shutdown() } }
        XCTAssertEqual(hello.protocol, WorkerProtocol.version)
        XCTAssertNotEqual(hello.versions["brainflow"], "missing")
        XCTAssertNotEqual(hello.versions["mne"], "missing")
        XCTAssertNotEqual(hello.versions["scikit-learn"], "missing")
        XCTAssertTrue(hello.methods.contains("fit_evaluate_synthetic"))
        let brainflowSwift = try BrainFlowBoard.libraryVersion()
        XCTAssertEqual(hello.versions["brainflow"], brainflowSwift, "worker and bridge must share one BrainFlow build")
    }

    func testPingRoundTripAndUnknownMethodError() async throws {
        let client = try makeClient()
        _ = try await client.start()
        struct Pong: Decodable { let pong: Bool; let echo: String? }
        let pong = try await client.call("ping", params: ["echo": "x"], as: Pong.self)
        XCTAssertTrue(pong.pong)
        XCTAssertEqual(pong.echo, "x")

        do {
            _ = try await client.call("does_not_exist")
            XCTFail("expected an error")
        } catch let error as WorkerError {
            XCTAssertEqual(error.code, "unknown_method")
        }
        await client.shutdown()
        try await Task.sleep(for: .milliseconds(300))
        guard case .exited = await client.state else { return XCTFail("worker should have exited after shutdown") }
    }

    func testFitEvaluateSyntheticReturnsGroupedSplitRecord() async throws {
        let client = try makeClient()
        _ = try await client.start()
        defer { Task { await client.shutdown() } }

        let data = try await client.call("fit_evaluate_synthetic", params: ["seed": 1, "n_runs": 3, "trials_per_run": 6, "n_channels": 8])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let split = try XCTUnwrap(obj["split_policy"] as? [String: Any])
        XCTAssertEqual(split["grouping"] as? String, "run")
        XCTAssertEqual(split["unit"] as? String, "trial")
        let models = try XCTUnwrap(obj["models"] as? [String: Any])
        XCTAssertNotNil(models["reference_csp_rlda"])
        XCTAssertNotNil(models["baseline_logvar_rlda"])
        XCTAssertEqual((obj["data_source"] as? [String: Any])?["kind"] as? String, "synthetic")
    }
}
