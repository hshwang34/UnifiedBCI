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

    func testUnreadableCounterFillsItsSlotAndResyncs() {
        var acc = SequenceAccounting(expectedStep: 2)
        // 10, ?, 14: the unreadable sample explains the step to 14, nothing lost.
        XCTAssertEqual(acc.ingest(counters: [10, 7.5, 14][...], timestamps: [0, 1, 2][...]),
                       [.init(afterSampleIndex: 0, kind: .invalidCounter(value: 7.5))])
        XCTAssertEqual(acc.unreadableSinceLastCounter, 0)
        // 14, ?, 20: the slot explains 16, so 18 (one sample) is an ambiguous gap.
        XCTAssertEqual(acc.ingest(counters: [6.5, 20][...], timestamps: [3, 4][...]), [
            .init(afterSampleIndex: -1, kind: .invalidCounter(value: 6.5)),
            .init(afterSampleIndex: 0, kind: .gap(estimatedMissing: 1, ambiguous: true, parityViolation: false)),
        ])
        // 20, ?, 20: shorter than the slot explains; the unknown counter could be anything,
        // so resync silently. Normal accounting resumes after (20 -> 24 loses 22).
        XCTAssertEqual(acc.ingest(counters: [6.5, 20, 24][...], timestamps: [5, 6, 7][...]), [
            .init(afterSampleIndex: -1, kind: .invalidCounter(value: 6.5)),
            .init(afterSampleIndex: 1, kind: .gap(estimatedMissing: 1, ambiguous: true, parityViolation: false)),
        ])
    }

    func testOverflowSuspectedNearBufferCapacity() {
        XCTAssertTrue(SequenceAccounting.overflowSuspected(available: 44_900, bufferSize: 45_000))
        XCTAssertTrue(SequenceAccounting.overflowSuspected(available: 45_000, bufferSize: 45_000))
        XCTAssertFalse(SequenceAccounting.overflowSuspected(available: 44_000, bufferSize: 45_000))
        XCTAssertFalse(SequenceAccounting.overflowSuspected(available: 10, bufferSize: 0), "no stream, no verdict")
    }
}

/// Bridge tests on BrainFlow's playback-file board (-3) with Cyton+Daisy as master board:
/// the only way to exercise Daisy framing (step-2 counters) without hardware (decision #26).
final class PlaybackBoardTests: XCTestCase {
    private let receivedSamples = 200

    private func fixtureURL() throws -> URL {
        try XCTUnwrap(Bundle(for: PlaybackBoardTests.self).url(forResource: "playback_cyton_daisy_faults", withExtension: "csv"),
                      "playback fixture missing from the test bundle")
    }

    /// The fixture as written: one line per sample, tab-separated rows.
    private func fixtureSamples() throws -> [[Double]] {
        try String(contentsOf: fixtureURL(), encoding: .ascii).split(separator: "\n")
            .map { $0.split(separator: "\t").map { Double($0)! } }
    }

    /// Playback is paced at 125 Hz; drain until `count` samples arrived or time runs out.
    private func drain(_ board: BrainFlowBoard, until count: Int) async throws -> [SampleChunk] {
        var chunks: [SampleChunk] = []
        let deadline = ContinuousClock.now + .seconds(10)
        while chunks.reduce(0, { $0 + $1.count }) < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            chunks.append(try await board.readAll())
        }
        return chunks
    }

    func testPlaybackUsesTheMasterBoardsLayout() throws {
        let board = try BrainFlowBoard.playback(file: fixtureURL())
        XCTAssertEqual(board.boardID, KnownBoard.playbackFile)
        XCTAssertEqual(board.description, try BrainFlowBoard.describe(boardID: KnownBoard.cytonDaisy))
        XCTAssertEqual(board.description.sequenceStep, 2)
        XCTAssertThrowsError(try BrainFlowBoard(boardID: KnownBoard.playbackFile), "playback needs a file and a master board")
    }

    func testEveryInjectedFaultIsFoundAndTheFileIsReturnedUnchanged() async throws {
        let board = try BrainFlowBoard.playback(file: fixtureURL())
        let d = board.description
        try await board.startStream()
        let chunks = try await drain(board, until: receivedSamples)
        try await board.release()

        var accounting = SequenceAccounting(board: d)
        var findings: [SequenceAccounting.Finding] = []
        var columns: [[Double]] = []
        for chunk in chunks {
            let base = columns.count
            findings += accounting.ingest(counters: chunk.row(d.packageNumRow), timestamps: chunk.row(d.timestampRow))
                .map { .init(afterSampleIndex: base + $0.afterSampleIndex, kind: $0.kind) }
            columns += (0..<chunk.count).map { i in (0..<chunk.numRows).map { chunk.values[$0 * chunk.count + i] } }
        }

        // Nothing dropped, added or rewritten: every row, timestamps included (old_timestamps).
        XCTAssertEqual(columns, try fixtureSamples())
        XCTAssertEqual(findings, [
            .init(afterSampleIndex: 59, kind: .gap(estimatedMissing: 2, ambiguous: true, parityViolation: false)),
            .init(afterSampleIndex: 99, kind: .staleHalf),
            // Sample 140 arrived with an unreadable counter; it fills its slot, so 141's
            // delta of 4 is not reported as a lost sample.
            .init(afterSampleIndex: 139, kind: .invalidCounter(value: 7.5)),
            // 252 -> 2 across the wrap: 254 and 0 lost. The clean wrap at sample 27 is not listed.
            .init(afterSampleIndex: 153, kind: .gap(estimatedMissing: 2, ambiguous: true, parityViolation: false)),
        ])
    }

    func testLoopingPlaybackShowsTheRestartAsAJump() async throws {
        let board = try BrainFlowBoard.playback(file: fixtureURL(), loop: true)
        let d = board.description
        try await board.startStream()
        let chunks = try await drain(board, until: receivedSamples + 10)
        try await board.release()
        let file = try fixtureSamples()
        let restartDelta = (Int(file[0][d.packageNumRow]) - Int(file[receivedSamples - 1][d.packageNumRow]) + 256) % 256

        var accounting = SequenceAccounting(board: d)
        var total = 0
        var atRestart: [SequenceAccounting.Kind] = []
        for chunk in chunks {
            for f in accounting.ingest(counters: chunk.row(d.packageNumRow), timestamps: chunk.row(d.timestampRow))
            where total + f.afterSampleIndex == receivedSamples - 1 {
                atRestart.append(f.kind)
            }
            total += chunk.count
        }
        XCTAssertGreaterThan(total, receivedSamples)
        // The counter jumps from the file's last to its first, and the timestamps go back.
        XCTAssertEqual(atRestart.count, 2, "\(atRestart)")
        XCTAssertEqual(atRestart.first, .gap(estimatedMissing: (restartDelta - 2) / 2, ambiguous: true, parityViolation: false))
        guard case .clockAnomaly? = atRestart.last else { return XCTFail("expected a clock anomaly, got \(atRestart)") }
    }

    func testConfigureAndInsertMarker() async throws {
        // BrainFlow's playback board overlays inserted markers on the marker row of a later
        // sample (checked against 5.23.0). Looping keeps samples coming until it lands.
        let board = try BrainFlowBoard.playback(file: fixtureURL(), loop: true)
        let d = board.description
        // The playback board accepts its own commands and replies with nothing.
        let reply = try await board.configure("old_timestamps")
        XCTAssertEqual(reply, "")
        try await board.startStream()
        try await board.insertMarker(3)
        var markers: [Double] = []
        let deadline = ContinuousClock.now + .seconds(10)
        while markers.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            markers += try await board.readAll().row(d.markerRow).filter { $0 != 0 }
        }
        try await board.release()
        XCTAssertEqual(markers, [3])
    }

    func testFailedPlaybackSetupReleasesTheSession() async throws {
        let board = try BrainFlowBoard.playback(file: fixtureURL())
        let d = board.description
        await board.injectSetupFault(BrainFlowError(code: BrainFlowExitCode.generalError.rawValue, operation: "config_board"))
        do {
            try await board.startStream()
            XCTFail("setup fault must surface")
        } catch let error as BrainFlowError {
            XCTAssertEqual(error.operation, "config_board")
        }
        let preparedAfterFailure = try await board.isSessionPrepared()
        XCTAssertFalse(preparedAfterFailure, "no session may survive without old_timestamps")

        // A retry prepares from scratch and keeps the file's timestamps.
        await board.injectSetupFault(nil)
        try await board.startStream()
        let chunks = try await drain(board, until: 1)
        try await board.release()
        let first = try XCTUnwrap(chunks.first { $0.count > 0 })
        XCTAssertEqual(first.row(d.timestampRow).first, try fixtureSamples()[0][d.timestampRow])
    }

    func testMissingPlaybackFileFailsToPrepare() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID()).csv")
        let board = try BrainFlowBoard.playback(file: missing)
        do {
            try await board.startStream()
            XCTFail("a missing playback file must fail to prepare")
        } catch let error as BrainFlowError {
            XCTAssertEqual(error.operation, "prepare_session")
        }
        try await board.release()
    }
}

final class SerialPortScannerTests: XCTestCase {
    func testScanListsOnlyCalloutDevices() {
        // No hardware assumed: the list may be empty, but whatever is there is a cu device.
        for port in SerialPortScanner.scan() {
            XCTAssertTrue(port.path.hasPrefix("/dev/cu."), port.path)
        }
    }

    func testUSBSerialDevicesComeFirstThenByPath() {
        let ports = [
            SerialPort(path: "/dev/cu.debug-console"),
            SerialPort(path: "/dev/cu.usbserial-DM00Q0QN", vendorName: "FTDI", productName: "FT231X USB UART", isUSB: true),
            SerialPort(path: "/dev/cu.Bluetooth-Incoming-Port"),
            SerialPort(path: "/dev/cu.usbmodem1101", isUSB: true),
        ]
        XCTAssertEqual(SerialPortScanner.ordered(ports).map(\.path), [
            "/dev/cu.usbmodem1101", "/dev/cu.usbserial-DM00Q0QN",
            "/dev/cu.Bluetooth-Incoming-Port", "/dev/cu.debug-console",
        ])
    }

    func testInputParamFactories() {
        XCTAssertEqual(BrainFlowInputParams.serial("/dev/cu.usbserial-X").serialPort, "/dev/cu.usbserial-X")
        let p = BrainFlowInputParams.playback(file: "/tmp/a.csv", masterBoard: KnownBoard.cytonDaisy)
        XCTAssertEqual(p.file, "/tmp/a.csv")
        XCTAssertEqual(p.masterBoard, 2)
        XCTAssertEqual(p.serialPort, "")
    }
}
