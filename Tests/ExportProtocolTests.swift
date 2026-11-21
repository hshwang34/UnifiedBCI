import XCTest
@testable import BCIWorkspace

/// Brief 005 PR 7: the export carries the run plans of a cued recording and exactly the
/// protocol versions they name, byte for byte, so a session can be reproduced from the folder.
final class ExportProtocolTests: XCTestCase {
    private var scratch: URL!
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    /// A project (with the default protocol v1), one recording of one chunk, and a result on it.
    private func fixture(_ name: String = "x") async throws -> (store: ProjectStore, recordingID: UUID, resultID: UUID) {
        let store = try ProjectStore.create(at: scratch.appendingPathComponent("\(name).bciproj"), name: name, now: at)
        let m = RecordingManifest(
            recordingID: UUID(), sessionID: "S", runID: "run-0", createdAt: at,
            source: .init(kind: "synthetic", boardID: nil, boardName: "test", dataPath: nil, brainflowVersion: "n/a", appVersion: "test"),
            channels: [ChannelSpec(id: "ch00", label: "C3", kind: "eeg", unit: "uV", sourceRow: 0)],
            reference: "SRB2", montage: "undeclared",
            timing: .init(nominalSampleRateHz: 125, timestampClock: .hostWall, timestampGeneratedBy: "none", sequenceCounterRow: nil, sequenceStep: 1, notes: ""),
            clockMapping: .init(anchorMonotonicNanos: 0, anchorWall: at), boardConfiguration: .init(requested: [:], readback: [:]),
            chunks: [],
            segments: [.init(index: 0, sessionID: "S", runID: "run-0", startedAtWall: at, startedAtMonotonicNanos: 0, endedAtMonotonicNanos: nil, endReason: nil, detectedGaps: [])])
        let writer = try await store.createRecording(m)
        try await writer.append(ChunkPayload(samples: [1, 2, 3, 4], rowCount: 1, sampleCount: 4, segment: 0, firstSampleIndex: 0, drainedAtMonotonicNanos: 0))

        let staging = try await store.stagingDirectory()
        let npz = staging.appendingPathComponent("fitted.npz")
        try Data("PK".utf8).write(to: npz)
        let pipeline = PipelineRecord(pipelineID: UUID(), recipe: "csp_rlda_v1", configuration: [:], expectedChannelIDs: ["ch00"],
                                      expectedSampleRateHz: 125, preprocessingStatePolicy: "reset_on_segment_start", trainingRecordingIDs: [m.recordingID],
                                      splitManifest: "{}", dependencyVersions: [:], seed: 0, fittedParametersFile: nil, configHash: "h")
        let evaluation = Data("{}".utf8)
        let meta = ResultMeta(resultID: UUID(), pipelineID: pipeline.pipelineID, recordingID: m.recordingID, createdAt: at, seed: 0, configHash: "h",
                              evaluationSHA256: AtomicFile.sha256Hex(evaluation), durationsSeconds: [:], workerVersions: [:],
                              workerOrigin: "test", reproductionOf: nil, divergedFrom: nil)
        _ = try await store.storeResult(evaluationJSON: evaluation, meta: meta, pipeline: pipeline, fittedArraysFile: npz)
        return (store, m.recordingID, meta.resultID)
    }

    private func version(_ store: ProjectStore, from parent: ProtocolRecord, trialsPerClass: Int) async throws -> ProtocolRecord {
        var draft = parent.draft
        draft.trialsPerClass = trialsPerClass
        return try await store.createProtocolVersion(draft, basedOn: parent, now: at)
    }

    private func header(_ out: URL) throws -> ExportedRecording {
        try ContractJSON.decoder().decode(ExportedRecording.self, from: Data(contentsOf: out.appendingPathComponent("recording.json")))
    }

    /// Every regular file under `root`, by relative path.
    private func tree(_ root: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let e = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        let prefix = root.resolvingSymlinksInPath().path + "/"
        for case let url as URL in e where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            out[String(url.resolvingSymlinksInPath().path.dropFirst(prefix.count))] = try Data(contentsOf: url)
        }
        return out
    }

    func testExportCarriesExactlyTheReferencedProtocols_andPlansByteForByte_andReproduces() async throws {
        let (store, rec, result) = try await fixture()
        let v1 = try await store.protocols().protocols[0]
        let v2 = try await version(store, from: v1, trialsPerClass: 2)
        let unused = try await version(store, from: v2, trialsPerClass: 3)
        let plans = [try ProtocolSchedule.plan(v2, recordingID: rec, sessionID: "S", runID: "run-0", runIndex: 0, sessionSeed: 41, createdAt: at),
                     try ProtocolSchedule.plan(v2, recordingID: rec, sessionID: "S", runID: "run-1", runIndex: 1, sessionSeed: 41, createdAt: at),
                     try ProtocolSchedule.plan(v1, recordingID: rec, sessionID: "S", runID: "run-2", runIndex: 2, sessionSeed: 41, createdAt: at)]
        for plan in plans { try await store.writeRunPlan(plan) }

        let out = scratch.appendingPathComponent("export")
        try await store.export(result: result, to: out)
        let files = try tree(out)
        let h = try XCTUnwrap(try header(out).runPlans)
        XCTAssertEqual(h.plans.map(\.runID), ["run-0", "run-1", "run-2"])
        XCTAssertEqual(h.unreadable, 0)
        XCTAssertEqual(h.unverified, [])
        XCTAssertEqual(Set(h.protocols.map(\.protocolID)), [v1.protocolID, v2.protocolID], "exactly the versions the plans name")
        XCTAssertFalse(files.keys.contains { $0.contains(unused.protocolID.uuidString) }, "an unused version is not exported")
        XCTAssertEqual(files.keys.filter { $0.hasPrefix("protocols/") || $0.hasPrefix("runs/") }.sorted(),
                       (h.plans.map(\.file) + h.protocols.map(\.file)).sorted())

        let project = store.directory
        for p in h.plans {
            let bytes = try XCTUnwrap(files[p.file])
            XCTAssertEqual(bytes, try Data(contentsOf: project.appendingPathComponent("recordings/\(rec.uuidString)/\(p.file)")), "plan copied byte for byte")
            XCTAssertEqual(p.sha256, AtomicFile.sha256Hex(bytes))
        }
        for p in h.protocols {
            let bytes = try XCTUnwrap(files[p.file])
            XCTAssertEqual(bytes, try Data(contentsOf: project.appendingPathComponent(p.file)), "protocol copied byte for byte")
            XCTAssertEqual(p.sha256, AtomicFile.sha256Hex(bytes))
        }

        // Reproduction from the folder alone: each plan's protocol is in the export, its
        // content hash recomputes, and the seed regenerates the same trials.
        for p in h.plans {
            let plan = try ContractJSON.decoder().decode(RunPlan.self, from: try XCTUnwrap(files[p.file]))
            let entry = try XCTUnwrap(h.protocols.first { $0.protocolID == plan.protocolID })
            let proto = try ContractJSON.decoder().decode(ProtocolRecord.self, from: try XCTUnwrap(files[entry.file]))
            XCTAssertNil(proto.problem(directoryID: plan.protocolID))
            XCTAssertEqual(ProtocolRecord.contentHash(of: proto), plan.protocolContentHash)
            XCTAssertEqual(p.protocolVersion, proto.version)
            XCTAssertEqual(p.protocolContentHash, proto.contentHash)
            XCTAssertEqual(p.seed, plan.seed)
            let again = try ProtocolSchedule.plan(proto, recordingID: rec, sessionID: plan.sessionID, runID: plan.runID,
                                                  runIndex: plan.runIndex, sessionSeed: plan.sessionSeed, createdAt: plan.createdAt)
            XCTAssertEqual(again, plan)
            XCTAssertEqual(plans.first { $0.runID == plan.runID }, plan, "round trip")
        }
    }

    func testTwoExportsOfTheSameResultAreByteIdentical() async throws {
        let (store, rec, result) = try await fixture()
        let v1 = try await store.protocols().protocols[0]
        try await store.writeRunPlan(try ProtocolSchedule.plan(v1, recordingID: rec, sessionID: "S", runID: "run-0", runIndex: 0, sessionSeed: 3, createdAt: at))
        try await store.writeRunPlan(try ProtocolSchedule.plan(v1, recordingID: rec, sessionID: "S", runID: "run-1", runIndex: 1, sessionSeed: 3, createdAt: at))
        let a = scratch.appendingPathComponent("a"), b = scratch.appendingPathComponent("b")
        try await store.export(result: result, to: a)
        try await store.export(result: result, to: b)
        let (ta, tb) = (try tree(a), try tree(b))
        XCTAssertEqual(ta.keys.sorted(), tb.keys.sorted())
        XCTAssertEqual(ta, tb)
        XCTAssertEqual(ta.keys.filter { $0.hasPrefix("protocols/") }.count, 1)
    }

    func testARecordingWithoutPlansExportsAsBefore() async throws {
        let (store, _, result) = try await fixture()
        let out = scratch.appendingPathComponent("export")
        try await store.export(result: result, to: out)
        XCTAssertNil(try header(out).runPlans)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: out.appendingPathComponent("recording.json"))) as? [String: Any])
        XCTAssertNil(json["runPlans"], "no key at all, so older readers see the same file")
        XCTAssertEqual(try tree(out).keys.sorted(), (ProjectStore.exportFileNames + ["segment-run-0.f64"]).sorted())
    }

    func testHostilePlansAndProtocolsAreLeftOutAndCounted_neverCrash() async throws {
        let (store, rec, result) = try await fixture()
        let fm = FileManager.default
        let v1 = try await store.protocols().protocols[0]
        let tampered = try await version(store, from: v1, trialsPerClass: 2)
        let padded = try await version(store, from: v1, trialsPerClass: 3)
        let linked = try await version(store, from: v1, trialsPerClass: 4)
        let mk = { (p: ProtocolRecord, run: String, i: Int) in
            try ProtocolSchedule.plan(p, recordingID: rec, sessionID: "S", runID: run, runIndex: i, sessionSeed: 9, createdAt: self.at)
        }
        try await store.writeRunPlan(try mk(v1, "good", 0))
        try await store.writeRunPlan(try mk(tampered, "tampered", 1))
        try await store.writeRunPlan(try mk(padded, "padded", 2))
        try await store.writeRunPlan(try mk(linked, "linked", 3))
        let runs = store.directory.appendingPathComponent("recordings/\(rec.uuidString)/runs")
        let protocols = store.directory.appendingPathComponent("protocols")
        let enc = ContractJSON.encoder()

        // A protocol edited in place: its content hash no longer matches.
        let tamperedFile = protocols.appendingPathComponent("\(tampered.protocolID.uuidString)/protocol.json")
        var edited = tampered
        edited.timing.cueMs += 1
        try enc.encode(edited).write(to: tamperedFile)
        // A protocol file over the read cap (valid JSON padded with whitespace).
        let paddedFile = protocols.appendingPathComponent("\(padded.protocolID.uuidString)/protocol.json")
        try (try Data(contentsOf: paddedFile) + Data(repeating: 0x20, count: ProtocolRecord.maxFileBytes)).write(to: paddedFile)
        // A protocol directory that is a symbolic link to one outside the project.
        let linkedDir = protocols.appendingPathComponent(linked.protocolID.uuidString)
        let outside = scratch.appendingPathComponent("outside-protocol")
        try fm.moveItem(at: linkedDir, to: outside)
        try fm.createSymbolicLink(at: linkedDir, withDestinationURL: outside)
        // A plan naming a protocol the project never had, one naming v1 with the wrong hash.
        var orphan = try mk(v1, "orphan", 4)
        orphan.protocolID = UUID()
        try enc.encode(orphan).write(to: runs.appendingPathComponent("orphan.plan.json"))
        var wrongHash = try mk(v1, "wronghash", 5)
        wrongHash.protocolContentHash = String(repeating: "0", count: 64)
        try enc.encode(wrongHash).write(to: runs.appendingPathComponent("wronghash.plan.json"))
        // Unreadable plans: junk, a FIFO (an open must not block), a link to an outside file,
        // one over the cap, and one whose name differs from its run id.
        try Data("{not json".utf8).write(to: runs.appendingPathComponent("junk.plan.json"))
        XCTAssertEqual(mkfifo(runs.appendingPathComponent("fifo.plan.json").path, 0o600), 0)
        let secret = scratch.appendingPathComponent("secret.plan.json")
        try enc.encode(try mk(v1, "secret", 6)).write(to: secret)
        try fm.createSymbolicLink(at: runs.appendingPathComponent("secret.plan.json"), withDestinationURL: secret)
        try (try enc.encode(try mk(v1, "big", 7)) + Data(repeating: 0x20, count: RunPlan.maxFileBytes)).write(to: runs.appendingPathComponent("big.plan.json"))
        try enc.encode(try mk(v1, "named", 8)).write(to: runs.appendingPathComponent("renamed.plan.json"))

        let out = scratch.appendingPathComponent("export")
        try await store.export(result: result, to: out)
        let h = try XCTUnwrap(try header(out).runPlans)
        XCTAssertEqual(h.plans.map(\.runID), ["good"])
        XCTAssertEqual(h.protocols.map(\.protocolID), [v1.protocolID])
        XCTAssertEqual(h.unverified, ["linked", "orphan", "padded", "tampered", "wronghash"])
        XCTAssertEqual(h.unreadable, 5)
        let files = try tree(out)
        XCTAssertEqual(files.keys.filter { $0.hasPrefix("protocols/") || $0.hasPrefix("runs/") }.sorted(),
                       ["protocols/\(v1.protocolID.uuidString)/protocol.json", "runs/good.plan.json"])
    }

    func testOnlyUnreadablePlansStillSayThereWerePlans() async throws {
        let (store, rec, result) = try await fixture()
        let runs = store.directory.appendingPathComponent("recordings/\(rec.uuidString)/runs")
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: false)
        try Data("[]".utf8).write(to: runs.appendingPathComponent("x.plan.json"))
        let out = scratch.appendingPathComponent("export")
        try await store.export(result: result, to: out)
        let h = try XCTUnwrap(try header(out).runPlans)
        XCTAssertEqual(h, .init(plans: [], protocols: [], unreadable: 1, unverified: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("runs").path))
    }
}
