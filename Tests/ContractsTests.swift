import XCTest
@testable import BCIWorkspace

final class ContractsTests: XCTestCase {
    func testRecordingManifestRoundTripsThroughJSON() throws {
        let id = UUID()
        let manifest = RecordingManifest(
            recordingID: id,
            createdAt: Date(timeIntervalSince1970: 1_000),
            source: .init(kind: "brainflow", boardID: KnownBoard.cytonDaisy, boardName: "CytonDaisy", brainflowVersion: "5.23.0", appVersion: "0.1.0"),
            channels: (0..<16).map { ChannelSpec(id: String(format: "ch%02d", $0), label: "?", kind: "eeg", unit: "uV", sourceRow: $0 + 1) },
            reference: "earclips",
            montage: "unspecified",
            timing: .init(nominalSampleRateHz: 125, timestampClock: .brainflowReceipt, timestampGeneratedBy: "host", sequenceCounterRow: 0,
                          notes: "Cyton over dongle: BrainFlow stamps on receipt; not an ADC clock."),
            boardConfiguration: [:],
            chunks: [.init(index: 0, fileName: "chunks/000000.f64", segment: 0, firstSampleIndex: 0, sampleCount: 1250, rowCount: 32, sha256: "deadbeef")],
            segments: [.init(index: 0, startedAtWall: Date(timeIntervalSince1970: 1_000), startedAtMonotonicNanos: 1, endedAtMonotonicNanos: nil, endReason: nil,
                             detectedGaps: [.init(afterSampleIndex: 400, evidence: "sequence_skip", estimatedMissingSamples: 3)])]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let back = try decoder.decode(RecordingManifest.self, from: data)
        XCTAssertEqual(back, manifest)
        XCTAssertEqual(back.formatVersion, ContractVersion.format)
    }

    func testPredictionRecordKeepsAbstentionAndFeedbackTimesSeparate() throws {
        let p = PredictionRecord(pipelineID: UUID(), inputSegment: 0, inputSampleRange: 0...249, score: nil,
                                 validity: "insufficient_window", emittedAtMonotonicNanos: 10, action: "abstain",
                                 feedbackPresentedAtMonotonicNanos: nil)
        let back = try JSONDecoder().decode(PredictionRecord.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
        XCTAssertNil(back.score)
        XCTAssertNil(back.feedbackPresentedAtMonotonicNanos)
    }
}
