import XCTest
@testable import BCIWorkspace

final class BrainFlowBoardTests: XCTestCase {
    func testLibraryVersionMatchesVendoredWheel() throws {
        let version = try BrainFlowBoard.libraryVersion()
        XCTAssertFalse(version.isEmpty)
        // native/brainflow/lib/VERSION is written by scripts/vendor_brainflow.sh from the worker's pinned wheel.
        let url = try XCTUnwrap(Bundle.main.url(forResource: "VERSION", withExtension: nil))
        let expected = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(version, expected, "Swift links a different BrainFlow than the vendored/worker version")
    }

    func testCytonDaisyDescriptionMatchesDocumentedFacts() throws {
        // PRD section 6: Cyton+Daisy streams 16 channels at 125 Hz over the radio path.
        let d = try BrainFlowBoard.describe(boardID: KnownBoard.cytonDaisy)
        XCTAssertEqual(d.name, "CytonDaisy")
        XCTAssertEqual(d.samplingRate, 125)
        XCTAssertEqual(d.eegChannelRows.count, 16)
        XCTAssertEqual(d.eegNames.count, 16)
        XCTAssertEqual(d.packageNumRow, 0)
    }

    func testSyntheticBoardStreamsOrderedSamples() async throws {
        let board = try BrainFlowBoard(boardID: KnownBoard.synthetic)
        let desc = board.description
        try await board.startStream()
        try await Task.sleep(for: .milliseconds(600))
        let chunk = try await board.readAll()
        try await board.release()

        XCTAssertEqual(chunk.numRows, desc.numRows)
        XCTAssertGreaterThan(chunk.count, desc.samplingRate / 4, "expected at least a quarter second of samples")
        XCTAssertEqual(chunk.values.count, chunk.numRows * chunk.count)

        let ts = Array(chunk.row(desc.timestampRow))
        XCTAssertEqual(ts, ts.sorted(), "receipt timestamps must be non-decreasing")

        let seq = Array(chunk.row(desc.packageNumRow))
        for (a, b) in zip(seq, seq.dropFirst()) {
            XCTAssertTrue(b == a + 1 || (a == 255 && b == 0), "sequence skip \(a) -> \(b)")
        }
    }

    func testReleaseWithoutPrepareIsHarmless() async throws {
        let board = try BrainFlowBoard(boardID: KnownBoard.synthetic)
        try await board.release()
    }

    func testInputParamsJSONHasEveryKeyBrainFlowRequires() throws {
        let json = BrainFlowInputParams().json()
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), [
            "file", "file_anc", "file_aux", "ip_address", "ip_address_anc", "ip_address_aux",
            "ip_port", "ip_port_anc", "ip_port_aux", "ip_protocol", "mac_address", "master_board",
            "other_info", "serial_number", "serial_port", "timeout",
        ])
    }
}
