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
        // BrainFlow commits one sample per board/Daisy packet pair with the even counter.
        XCTAssertEqual(d.sequenceStep, 2)
        XCTAssertEqual(try BrainFlowBoard.describe(boardID: KnownBoard.synthetic).sequenceStep, 1)
        XCTAssertEqual(try BrainFlowBoard.describe(boardID: KnownBoard.cyton).sequenceStep, 1)
    }

    func testSyntheticBoardStreamsOrderedSamples() async throws {
        let board = try BrainFlowBoard(boardID: KnownBoard.synthetic)
        let desc = board.description
        let before = HostMonotonicClock.nowNanos()
        try await board.startStream()
        try await Task.sleep(for: .milliseconds(600))
        let chunk = try await board.readAll()
        try await board.release()

        XCTAssertEqual(chunk.numRows, desc.numRows)
        XCTAssertGreaterThan(chunk.count, desc.samplingRate / 4, "expected at least a quarter second of samples")
        XCTAssertEqual(chunk.values.count, chunk.numRows * chunk.count)
        XCTAssertGreaterThan(chunk.drainedAtMonotonicNanos, before)
        XCTAssertLessThanOrEqual(chunk.drainedAtMonotonicNanos, HostMonotonicClock.nowNanos())
        XCTAssertFalse(chunk.overflowSuspected)
        XCTAssertEqual(chunk.availableBeforeDrain, chunk.count)

        // Sequence accounting is the bridge's job, not the test's: the synthetic board
        // steps by 1 and its wall-clock stamps happen to be monotone, so no findings.
        var accounting = SequenceAccounting(board: desc)
        let findings = accounting.ingest(counters: chunk.row(desc.packageNumRow), timestamps: chunk.row(desc.timestampRow))
        XCTAssertEqual(findings, [])
        XCTAssertEqual(accounting.samplesSeen, chunk.count)
    }

    func testReleaseWithoutPrepareIsHarmless() async throws {
        let board = try BrainFlowBoard(boardID: KnownBoard.synthetic)
        try await board.release()
    }

    func testBoardActorRunsOnItsOwnSerialQueue() async throws {
        let board = try BrainFlowBoard(boardID: KnownBoard.synthetic)
        let onQueue = await board.isOnOwnQueue()
        XCTAssertTrue(onQueue, "BrainFlow calls must not run on the cooperative pool")
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

final class SequenceAccountingTests: XCTestCase {
    private func ingest(_ counters: [Int], step: Int, timestamps: [Double]? = nil) -> [SequenceAccounting.Finding] {
        var acc = SequenceAccounting(expectedStep: step)
        let ts = timestamps ?? counters.indices.map { Double($0) }
        return acc.ingest(counters: counters.map(Double.init)[...], timestamps: ts[...])
    }

    func testStepOneWrapIsNotAGap() {
        XCTAssertEqual(ingest([253, 254, 255, 0, 1, 2], step: 1), [])
    }

    func testStepOneSkipEstimatesMissing() {
        let f = ingest([5, 6, 9], step: 1)
        XCTAssertEqual(f, [.init(afterSampleIndex: 1, kind: .gap(estimatedMissing: 2, ambiguous: true, parityViolation: false))])
    }

    func testStepOneRepeatIsDuplicateNotStaleHalf() {
        XCTAssertEqual(ingest([7, 7], step: 1), [.init(afterSampleIndex: 0, kind: .duplicateCounter)])
    }

    func testDaisyEvenCountersWrapWithoutFindings() {
        let counters = stride(from: 0, through: 254, by: 2).map { $0 } + [0, 2, 4]
        XCTAssertEqual(ingest(counters, step: 2), [])
    }

    func testDaisyRepeatedCounterIsStaleHalf() {
        XCTAssertEqual(ingest([10, 12, 12, 14], step: 2), [.init(afterSampleIndex: 1, kind: .staleHalf)])
    }

    func testDaisyGapCountsPairsAndIsFlaggedAmbiguous() {
        // 12 -> 18 skips 14 and 16: two committed samples lost.
        XCTAssertEqual(ingest([12, 18], step: 2), [.init(afterSampleIndex: 0, kind: .gap(estimatedMissing: 2, ambiguous: true, parityViolation: false))])
        // Across the wrap: 252 -> 2 skips 254 and 0.
        XCTAssertEqual(ingest([252, 2], step: 2), [.init(afterSampleIndex: 0, kind: .gap(estimatedMissing: 2, ambiguous: true, parityViolation: false))])
    }

    func testDaisyOddDeltaIsAParityViolation() {
        let f = ingest([12, 15], step: 2)
        XCTAssertEqual(f, [.init(afterSampleIndex: 0, kind: .gap(estimatedMissing: 0, ambiguous: true, parityViolation: true))])
    }

    func testBackwardTimestampIsAClockAnomalyNotAGap() {
        let f = ingest([1, 2, 3], step: 1, timestamps: [10.0, 10.5, 10.2])
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f.first?.afterSampleIndex, 1)
        guard case .clockAnomaly(let backward)? = f.first?.kind else { return XCTFail("expected clockAnomaly, got \(f)") }
        XCTAssertEqual(backward, 0.3, accuracy: 1e-9)
    }

    func testStateCarriesAcrossChunksAndResets() {
        var acc = SequenceAccounting(expectedStep: 1)
        XCTAssertEqual(acc.ingest(counters: [254.0, 255.0][...], timestamps: [0, 1][...]), [])
        // First sample of the next chunk skips 0: the finding sits before index 0.
        XCTAssertEqual(acc.ingest(counters: [1.0, 2.0][...], timestamps: [2, 3][...]),
                       [.init(afterSampleIndex: -1, kind: .gap(estimatedMissing: 1, ambiguous: true, parityViolation: false))])
        XCTAssertEqual(acc.samplesSeen, 4)
        acc.reset()
        XCTAssertEqual(acc.ingest(counters: [9.0][...], timestamps: [0][...]), [])
        XCTAssertEqual(acc.samplesSeen, 1)
    }

    func testNonFiniteOrFractionalCountersAreReportedNotTrapped() {
        let f = ingest([5, 6, 7], step: 1, timestamps: [0, 1, 2]).count
        XCTAssertEqual(f, 0)
        var acc = SequenceAccounting(expectedStep: 1)
        let findings = acc.ingest(counters: [5.0, .nan, .infinity, 6.5, 6.0][...], timestamps: [0, 1, 2, 3, 4][...])
        XCTAssertEqual(findings.map(\.afterSampleIndex), [0, 1, 2])
        for finding in findings {
            guard case .invalidCounter = finding.kind else { return XCTFail("expected invalidCounter, got \(finding)") }
        }
        XCTAssertEqual(acc.lastCounter, 6, "valid counters still advance the state")
        XCTAssertEqual(acc.samplesSeen, 5)
    }

    func testOverflowSuspectedNearBufferCapacity() {
        XCTAssertTrue(SequenceAccounting.overflowSuspected(available: 44_900, bufferSize: 45_000))
        XCTAssertTrue(SequenceAccounting.overflowSuspected(available: 45_000, bufferSize: 45_000))
        XCTAssertFalse(SequenceAccounting.overflowSuspected(available: 44_000, bufferSize: 45_000))
        XCTAssertFalse(SequenceAccounting.overflowSuspected(available: 10, bufferSize: 0), "no stream, no verdict")
    }
}
