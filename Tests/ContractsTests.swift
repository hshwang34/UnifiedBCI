import XCTest
@testable import BCIWorkspace

final class ContractsTests: XCTestCase {
    private func sampleManifest() -> RecordingManifest {
        let id = UUID()
        let t0 = Date(timeIntervalSince1970: 1_000.25)
        return RecordingManifest(
            recordingID: id,
            sessionID: "S001",
            runID: "S001-run04",
            createdAt: t0,
            source: .init(kind: "brainflow", boardID: KnownBoard.cytonDaisy, boardName: "CytonDaisy", dataPath: .radio125,
                          brainflowVersion: "5.23.0", appVersion: "0.1.0"),
            channels: (0..<16).map { ChannelSpec(id: String(format: "ch%02d", $0), label: "?", kind: "eeg", unit: "uV", sourceRow: $0 + 1) },
            reference: "earclips",
            montage: "unspecified",
            timing: .init(nominalSampleRateHz: 125, timestampClock: .brainflowReceipt, timestampGeneratedBy: "host",
                          sequenceCounterRow: 0, sequenceStep: 2,
                          notes: "Cyton over dongle: BrainFlow stamps on receipt with gettimeofday; not an ADC clock."),
            clockMapping: .init(anchorMonotonicNanos: 123_456_789, anchorWall: t0),
            boardConfiguration: .init(requested: ["gain": "24"], readback: [:]),
            chunks: [.init(index: 0, fileName: "chunks/000000.f64", segment: 0, firstSampleIndex: 0, sampleCount: 1250, rowCount: 32,
                           sha256: "deadbeef", drainedAtMonotonicNanos: 200_000_000, firstBrainflowTimestamp: 1_000.251, lastBrainflowTimestamp: 1_010.25,
                           firstPackageNumber: 0, lastPackageNumber: 194)],
            segments: [.init(index: 0, sessionID: "S001", runID: "S001-run04", startedAtWall: t0, startedAtMonotonicNanos: 1,
                             endedAtMonotonicNanos: nil, endReason: nil,
                             detectedGaps: [.init(afterSampleIndex: 400, evidence: .sequenceSkip, estimatedMissingSamples: 3, ambiguous: true),
                                            .init(afterSampleIndex: 900, evidence: .staleHalf, estimatedMissingSamples: nil, ambiguous: false)])]
        )
    }

    func testRecordingManifestRoundTripsThroughContractJSON() throws {
        let manifest = sampleManifest()
        let data = try ContractJSON.encoder().encode(manifest)
        let back = try ContractJSON.decoder().decode(RecordingManifest.self, from: data)
        XCTAssertEqual(back, manifest)
        XCTAssertEqual(back.formatVersion, ContractVersion.format)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"sequence_skip\""), "GapEvidence must serialize as its snake_case raw value")
        XCTAssertTrue(text.contains("\"stale_half\""))
        XCTAssertTrue(text.contains("\"radio_125\""))
        XCTAssertTrue(text.contains("CLOCK_MONOTONIC_RAW"))
    }

    func testDatesKeepFractionalSeconds() throws {
        // Foundation's .iso8601 strategy would write 1970-01-01T00:16:40Z and lose the 250 ms.
        struct Stamp: Codable, Equatable { var at: Date }
        let stamp = Stamp(at: Date(timeIntervalSince1970: 1_000.25))
        let data = try ContractJSON.encoder().encode(stamp)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("1970-01-01T00:16:40.250Z"), String(decoding: data, as: UTF8.self))
        let back = try ContractJSON.decoder().decode(Stamp.self, from: data)
        XCTAssertEqual(back.at.timeIntervalSince1970, 1_000.25, accuracy: 0.0005)

        // Whole-second stamps from hand-written files still decode.
        let plain = try ContractJSON.decoder().decode(Stamp.self, from: Data("{\"at\":\"2026-10-20T04:05:06Z\"}".utf8))
        XCTAssertEqual(plain.at.timeIntervalSince1970, 1_792_469_106, accuracy: 0.0005)
    }

    func testProjectManifestRoundTrips() throws {
        let p = ProjectManifest(name: "Example", created: Date(timeIntervalSince1970: 5.5), recordingIDs: [UUID()], pipelineIDs: [], resultIDs: [UUID(), UUID()])
        let back = try ContractJSON.decoder().decode(ProjectManifest.self, from: ContractJSON.encoder().encode(p))
        XCTAssertEqual(back, p)
        XCTAssertEqual(back.formatVersion, 1)
    }

    func testEventRecordCarriesRunSessionAndSourceTime() throws {
        let e = EventRecord(eventID: UUID(), sessionID: "S001", runID: "S001-run04", trialID: "t007", label: "cue_left", origin: "device_marker",
                            intendedAtMonotonicNanos: nil, presentedAtMonotonicNanos: nil, sourceTimeNanos: 42_000,
                            wallTime: Date(timeIntervalSince1970: 7.125), sampleAssociation: nil, timingUncertaintyNanos: nil)
        let back = try ContractJSON.decoder().decode(EventRecord.self, from: ContractJSON.encoder().encode(e))
        XCTAssertEqual(back, e)
        XCTAssertNil(back.timingUncertaintyNanos, "unknown uncertainty stays nil, never 0")
    }

    func testPredictionRecordKeepsAbstentionAndFeedbackTimesSeparate() throws {
        let p = PredictionRecord(pipelineID: UUID(), inputSegment: 0, inputSampleRange: nil, score: nil,
                                 validity: .insufficientWindow, emittedAtMonotonicNanos: 10, action: .abstain,
                                 feedbackPresentedAtMonotonicNanos: nil)
        let data = try ContractJSON.encoder().encode(p)
        let back = try ContractJSON.decoder().decode(PredictionRecord.self, from: data)
        XCTAssertEqual(back, p)
        XCTAssertNil(back.score)
        XCTAssertNil(back.inputSampleRange)
        XCTAssertNil(back.feedbackPresentedAtMonotonicNanos)
        XCTAssertEqual(back.action.kind, .abstain)
        XCTAssertNil(back.action.label, "abstention is not a class and carries no label")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"insufficient_window\""))

        let chosen = PredictionRecord(pipelineID: UUID(), inputSegment: 1, inputSampleRange: .init(start: 1_000, count: 250), score: 0.8,
                                      validity: .valid, emittedAtMonotonicNanos: 20, action: .chosen("cue_left"), feedbackPresentedAtMonotonicNanos: 25)
        let back2 = try ContractJSON.decoder().decode(PredictionRecord.self, from: ContractJSON.encoder().encode(chosen))
        XCTAssertEqual(back2, chosen)
        XCTAssertEqual(back2.action.label, "cue_left")
    }

    func testEncoderRefusesNaN() {
        struct S: Encodable { var x: Double }
        XCTAssertThrowsError(try ContractJSON.encoder().encode(S(x: .nan)))
    }
}
