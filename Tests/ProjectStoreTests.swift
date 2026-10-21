import XCTest
@testable import BCIWorkspace

final class ProjectStoreTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Fixtures

    /// F1: tiny.bciproj, bundled into the test bundle as a folder reference.
    static func tinyFixtureURL() throws -> URL {
        try XCTUnwrap(Bundle(for: ProjectStoreTests.self).url(forResource: "tiny", withExtension: "bciproj"), "tiny.bciproj missing from the test bundle")
    }

    /// The crash helper is built beside the app by the test target's dependency; the
    /// test bundle lives inside the app, so walk up to the products directory.
    static func crashHelperURL() throws -> URL {
        var dir = Bundle(for: ProjectStoreTests.self).bundleURL
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("BCIStoreCrashHelper")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("BCIStoreCrashHelper not found next to the products")
    }

    private func sampleManifest(id: UUID = UUID(), rows: Int = 3) -> RecordingManifest {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000.5)
        return RecordingManifest(
            recordingID: id, sessionID: nil, runID: "r", createdAt: t0,
            source: .init(kind: "synthetic", boardID: nil, boardName: "test", dataPath: nil, brainflowVersion: "n/a", appVersion: "test"),
            channels: (0..<rows).map { ChannelSpec(id: "ch0\($0)", label: "L\($0)", kind: "eeg", unit: "uV", sourceRow: $0) },
            reference: "none", montage: "unspecified",
            timing: .init(nominalSampleRateHz: 10, timestampClock: .hostWall, timestampGeneratedBy: "none", sequenceCounterRow: nil, sequenceStep: 1, notes: ""),
            clockMapping: .init(anchorMonotonicNanos: 0, anchorWall: t0),
            boardConfiguration: .init(requested: [:], readback: [:]),
            chunks: [],
            segments: [.init(index: 0, sessionID: nil, runID: "r", startedAtWall: t0, startedAtMonotonicNanos: 0, endedAtMonotonicNanos: nil, endReason: nil, detectedGaps: [])])
    }

    private func payload(_ index: Int, rows: Int = 3, count: Int = 4) -> ChunkPayload {
        ChunkPayload(samples: (0..<(rows * count)).map { Double(index * 100 + $0) }, rowCount: rows, sampleCount: count,
                     segment: 0, firstSampleIndex: index * count, drainedAtMonotonicNanos: Int64(index))
    }

    // MARK: Create / open

    func testCreateOpenAndDirectoryScanIsTheTruth() async throws {
        let url = scratch.appendingPathComponent("p.bciproj")
        let store = try ProjectStore.create(at: url, name: "P")
        let name = await store.manifest.name
        XCTAssertEqual(name, "P")
        let none = try await store.recordingIDs()
        XCTAssertEqual(none, [])

        let manifest = sampleManifest()
        let writer = try await store.createRecording(manifest)
        try await writer.append(payload(0))
        try await writer.append(payload(1))

        // A stray directory without a manifest, and a non-UUID name, are not recordings.
        try FileManager.default.createDirectory(at: url.appendingPathComponent("recordings/\(UUID().uuidString)"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("recordings/notes"), withIntermediateDirectories: true)

        let reopened = try ProjectStore.open(at: url)
        let ids = try await reopened.recordingIDs()
        XCTAssertEqual(ids, [manifest.recordingID])
        let handle = try await reopened.recording(id: manifest.recordingID)
        XCTAssertEqual(handle.manifest.chunks.count, 2)
        XCTAssertEqual(try handle.chunk(handle.manifest.chunks[1]), payload(1).samples)
        let issues = try await reopened.verify(recording: manifest.recordingID)
        XCTAssertEqual(issues, [])
        XCTAssertThrowsError(try ProjectStore.create(at: url, name: "again"))
    }

    func testOpenRejectsFutureFormatVersion() throws {
        let url = scratch.appendingPathComponent("future.bciproj")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("{\"formatVersion\": \(ContractVersion.format + 1), \"name\": \"x\", \"created\": \"2026-01-01T00:00:00.000Z\", \"newField\": 1}".utf8)
            .write(to: url.appendingPathComponent("project.json"))
        XCTAssertThrowsError(try ProjectStore.open(at: url)) { error in
            guard case ProjectStoreError.unsupportedFormatVersion(let found, let supported) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(found, ContractVersion.format + 1)
            XCTAssertEqual(supported, ContractVersion.format)
        }
        XCTAssertThrowsError(try ProjectStore.open(at: scratch.appendingPathComponent("nothing-here")))
    }

    // MARK: Bundled example

    func testImportBundledExample_copiesAndVerifiesEveryChunk() async throws {
        let dest = scratch.appendingPathComponent("example.bciproj")
        let store = try ProjectStore.importBundledExample(from: try Self.tinyFixtureURL(), into: dest)
        let ids = try await store.recordingIDs()
        XCTAssertEqual(ids.count, 1)
        let handle = try await store.recording(id: ids[0])
        XCTAssertEqual(handle.manifest.source.kind, "public_dataset")
        XCTAssertEqual(handle.manifest.source.license, "ODC-BY 1.0")
        XCTAssertNil(handle.manifest.sessionID)
        XCTAssertEqual(handle.manifest.segments.map(\.runID), ["S001R04", "S001R08", "S001R12"])
        XCTAssertEqual(handle.manifest.channels.map(\.label), ["FC3", "FC4", "C3", "C1", "Cz", "C2", "C4", "CPz"])
        let issues = try await store.verify(recording: ids[0])
        XCTAssertEqual(issues, [])
        let events = try await store.events(for: ids[0])
        XCTAssertEqual(events.filter { $0.label.hasPrefix("cue_") }.count, 15)
        XCTAssertTrue(events.allSatisfy { $0.timingUncertaintyNanos == nil })
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("README.md").path))
        // The app's own bundled example is reachable through the one injection point.
        let appExample = try XCTUnwrap(BundledExample.locate(in: .main), "S001 example missing from the app bundle")
        let full = try ProjectStore.importBundledExample(from: appExample, into: scratch.appendingPathComponent("full.bciproj"))
        let fullIDs = try await full.recordingIDs()
        let fullHandle = try await full.recording(id: try XCTUnwrap(fullIDs.first))
        XCTAssertEqual(fullHandle.manifest.channels.count, 16)
        XCTAssertEqual(fullHandle.manifest.chunks.count, 375)
        XCTAssertEqual(fullHandle.manifest.source.attribution?.count, 3)
        XCTAssertTrue(fullHandle.manifest.source.warning?.contains("not recorded on OpenBCI") ?? false)
    }

    func testImportBundledExample_refusesADamagedBundle() throws {
        let damaged = scratch.appendingPathComponent("damaged.bciproj")
        try FileManager.default.copyItem(at: try Self.tinyFixtureURL(), to: damaged)
        let rec = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: damaged.appendingPathComponent("recordings").path).first)
        let chunk = damaged.appendingPathComponent("recordings/\(rec)/chunks/000000.f64")
        var bytes = try Data(contentsOf: chunk)
        bytes[0] ^= 0xFF
        try bytes.write(to: chunk)
        let dest = scratch.appendingPathComponent("copy.bciproj")
        XCTAssertThrowsError(try ProjectStore.importBundledExample(from: damaged, into: dest)) { error in
            guard case ProjectStoreError.integrity(let issues) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(issues.first?.kind, .hashMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("recordings/\(rec)/recording.json").path),
                       "a refused import must not leave a recording behind")
    }

    // MARK: Integrity

    func testCorruptChunk_reportedNotRepaired() async throws {
        let url = scratch.appendingPathComponent("c.bciproj")
        let store = try ProjectStore.create(at: url, name: "C")
        let manifest = sampleManifest()
        let writer = try await store.createRecording(manifest)
        try await writer.append(payload(0))
        try await writer.append(payload(1))
        let chunk = url.appendingPathComponent("recordings/\(manifest.recordingID.uuidString)/chunks/000001.f64")
        var bytes = try Data(contentsOf: chunk)
        bytes[3] ^= 0x01
        try bytes.write(to: chunk)

        let reopened = try ProjectStore.open(at: url)
        let issues = try await reopened.verify(recording: manifest.recordingID)
        XCTAssertEqual(issues.map(\.kind), [.hashMismatch])
        XCTAssertEqual(issues.first?.file, "chunks/000001.f64")
        XCTAssertEqual(try Data(contentsOf: chunk), bytes, "verify must not touch the file")
        let handle = try await reopened.recording(id: manifest.recordingID)
        XCTAssertEqual(try handle.chunk(handle.manifest.chunks[0]), payload(0).samples, "the good chunk still reads")
        XCTAssertThrowsError(try handle.chunk(handle.manifest.chunks[1]))
        XCTAssertEqual(try Data(contentsOf: chunk), bytes)
    }

    func testOrphanTempFilesRemovedOnOpen_committedFilesUntouched() async throws {
        let url = scratch.appendingPathComponent("o.bciproj")
        let store = try ProjectStore.create(at: url, name: "O")
        let manifest = sampleManifest()
        let writer = try await store.createRecording(manifest)
        try await writer.append(payload(0))
        let recDir = url.appendingPathComponent("recordings/\(manifest.recordingID.uuidString)")
        try Data([1, 2, 3]).write(to: recDir.appendingPathComponent("chunks/.tmp-000001"))
        try Data("{".utf8).write(to: recDir.appendingPathComponent(".tmp-recording.json"))
        try FileManager.default.createDirectory(at: url.appendingPathComponent("results/.tmp-\(UUID().uuidString)"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("pipelines/.tmp-\(UUID().uuidString)"), withIntermediateDirectories: true)

        let reopened = try ProjectStore.open(at: url)
        let removed = await reopened.removedOrphans
        XCTAssertEqual(removed.count, 4)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: recDir.appendingPathComponent("chunks").path), ["000000.f64"])
        let issues = try await reopened.verify(recording: manifest.recordingID)
        XCTAssertEqual(issues, [])
        let results = try await reopened.results()
        XCTAssertEqual(results, [])
    }

    // MARK: Crash injection

    private struct CrashOutcome {
        var status: Int32
        var chunksListed: Int
        var issues: [IntegrityIssue]
        var orphansRemoved: [String]
        var eventLines: Int
    }

    private func runHelper(chunks: Int, crashAt: (CommitHook.Point, Int)?) async throws -> CrashOutcome {
        let dir = scratch.appendingPathComponent("crash-\(UUID().uuidString).bciproj")
        let proc = Process()
        proc.executableURL = try Self.crashHelperURL()
        proc.arguments = [dir.path, "\(chunks)"]
        var env = ProcessInfo.processInfo.environment
        if let crashAt { env["CRASH_AT"] = "\(crashAt.0.rawValue):\(crashAt.1)" } else { env.removeValue(forKey: "CRASH_AT") }
        proc.environment = env
        let stderr = Pipe()
        proc.standardError = stderr
        try proc.run()
        proc.waitUntilExit()
        let log = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if crashAt == nil { XCTAssertEqual(proc.terminationStatus, 0, log) }

        let store = try ProjectStore.open(at: dir)
        let ids = try await store.recordingIDs()
        let handle = try await store.recording(id: try XCTUnwrap(ids.first, "recording manifest must survive: \(log)"))
        // Every listed chunk reads back with exactly the bytes the helper wrote.
        for (i, entry) in handle.manifest.chunks.enumerated() {
            XCTAssertEqual(entry.index, i)
            XCTAssertEqual(try handle.chunk(entry), (0..<(4 * 50)).map { Double(i * 1000 + $0) * 0.5 }, "chunk \(i) after \(String(describing: crashAt))")
        }
        let events = try handle.events()      // throws on a torn line
        return CrashOutcome(status: proc.terminationStatus, chunksListed: handle.manifest.chunks.count, issues: handle.verify(),
                            orphansRemoved: await store.removedOrphans, eventLines: events.count)
    }

    func testHelperWithoutCrashCommitsEverything() async throws {
        let outcome = try await runHelper(chunks: 3, crashAt: nil)
        XCTAssertEqual(outcome.chunksListed, 3)
        XCTAssertEqual(outcome.issues, [])
        XCTAssertEqual(outcome.orphansRemoved, [])
        XCTAssertEqual(outcome.eventLines, 3)
    }

    func testCrashAtEachCommitPoint_reopenIsConsistent() async throws {
        for point in CommitHook.Point.allCases {
            for index in [0, 2] {
                let outcome = try await runHelper(chunks: 4, crashAt: (point, index))
                let label = "\(point.rawValue):\(index)"
                XCTAssertEqual(outcome.status, 9, label)
                let committedPrefix = point == .afterManifestWrite ? index + 1 : index
                XCTAssertEqual(outcome.chunksListed, committedPrefix, "listed prefix after \(label)")
                switch point {
                case .afterTmpWrite, .afterFsync:
                    XCTAssertEqual(outcome.orphansRemoved, ["chunks/.tmp-\(String(format: "%06d", index))"], label)
                    XCTAssertEqual(outcome.issues, [], label)
                case .afterRename:
                    // Renamed but not yet listed: reported as unlisted, never adopted or deleted.
                    XCTAssertEqual(outcome.orphansRemoved, [], label)
                    XCTAssertEqual(outcome.issues.map(\.kind), [.unlistedChunk], label)
                    XCTAssertEqual(outcome.issues.first?.file, "chunks/\(String(format: "%06d", index)).f64", label)
                case .afterManifestWrite:
                    XCTAssertEqual(outcome.orphansRemoved, [], label)
                    XCTAssertEqual(outcome.issues, [], label)
                }
                XCTAssertLessThanOrEqual(outcome.eventLines, index + 1, label)
                XCTAssertGreaterThanOrEqual(outcome.eventLines, index, label)
            }
        }
    }

    // MARK: Results

    private func storeFakeResult(in store: ProjectStore, seed: Int, createdAt: Date, evaluation: String = "{\"x\":1}") async throws -> ResultMeta {
        let staging = try await store.stagingDirectory()
        let npz = staging.appendingPathComponent("fitted.npz")
        try Data("PK\u{03}\u{04}not-really-npz".utf8).write(to: npz)
        let pipeline = PipelineRecord(pipelineID: UUID(), recipe: "csp_rlda_v1", configuration: ["a": "1"], expectedChannelIDs: ["ch00"],
                                      expectedSampleRateHz: 10, preprocessingStatePolicy: "reset_on_segment_start", trainingRecordingIDs: [],
                                      splitManifest: "{}", dependencyVersions: ["numpy": "x"], seed: seed, fittedParametersFile: nil, configHash: "h")
        let evaluationJSON = Data(evaluation.utf8)
        let meta = ResultMeta(resultID: UUID(), pipelineID: pipeline.pipelineID, recordingID: UUID(), createdAt: createdAt, seed: seed, configHash: "h",
                              evaluationSHA256: AtomicFile.sha256Hex(evaluationJSON), durationsSeconds: ["total": 1], workerVersions: [:],
                              workerOrigin: "test", reproductionOf: nil, divergedFrom: nil)
        _ = try await store.storeResult(evaluationJSON: evaluationJSON, meta: meta, pipeline: pipeline, fittedArraysFile: npz)
        return meta
    }

    func testStoreResult_isAtomicListedByCreationAndByteExact() async throws {
        let url = scratch.appendingPathComponent("r.bciproj")
        let store = try ProjectStore.create(at: url, name: "R")
        let later = try await storeFakeResult(in: store, seed: 2, createdAt: Date(timeIntervalSince1970: 200), evaluation: "{\"b\": 2.50 }")
        let earlier = try await storeFakeResult(in: store, seed: 1, createdAt: Date(timeIntervalSince1970: 100))
        let listed = try await store.results().map(\.resultID)
        XCTAssertEqual(listed, [earlier.resultID, later.resultID])
        let stored = try await store.result(id: later.resultID)
        XCTAssertEqual(String(decoding: stored.evaluationJSON, as: UTF8.self), "{\"b\": 2.50 }", "evaluation.json is stored byte-for-byte")
        XCTAssertEqual(stored.pipeline.fittedParametersFile, "fitted.npz")
        XCTAssertEqual(stored.pipeline.seed, 2)
        let npzURL = await store.fittedArraysURL(pipelineID: stored.pipeline.pipelineID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: npzURL.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("pipelines").path).filter { $0.hasPrefix(".tmp-") }
        XCTAssertEqual(leftovers, [], "staging directories are consumed by storeResult")
        let pipelineCount = try await store.pipelineIDs().count
        XCTAssertEqual(pipelineCount, 2)
    }

    // MARK: Export

    func testExport_samplesConcatenateChunksInChannelOrder() async throws {
        let url = scratch.appendingPathComponent("e.bciproj")
        let store = try ProjectStore.create(at: url, name: "E")
        var manifest = sampleManifest(rows: 3)
        // Channel order differs from row order: channels[0] reads row 2.
        manifest.channels = [ChannelSpec(id: "a", label: "A", kind: "eeg", unit: "uV", sourceRow: 2),
                             ChannelSpec(id: "b", label: "B", kind: "eeg", unit: "uV", sourceRow: 0)]
        let writer = try await store.createRecording(manifest)
        try await writer.append(payload(0))
        try await writer.append(payload(1))
        var meta = try await storeFakeResult(in: store, seed: 0, createdAt: Date())
        meta.recordingID = manifest.recordingID
        // Point the stored meta at the recording (the fake helper used a random id).
        try ContractJSON.encoder().encode(meta).write(to: url.appendingPathComponent("results/\(meta.resultID.uuidString)/result.meta.json"))

        let out = scratch.appendingPathComponent("export")
        try await store.export(result: meta.resultID, to: out)
        let names = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        XCTAssertEqual(names, (ProjectStore.exportFileNames + ["segment-r.f64"]).sorted())
        let header = try ContractJSON.decoder().decode(ExportedRecording.self, from: Data(contentsOf: out.appendingPathComponent("recording.json")))
        XCTAssertEqual(header.samples.channelCount, 2)
        XCTAssertEqual(header.samples.files.map(\.sampleCount), [8])
        let f64 = try Data(contentsOf: out.appendingPathComponent("segment-r.f64"))
        XCTAssertEqual(header.samples.files[0].sha256, AtomicFile.sha256Hex(f64))
        let values = f64.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
        // Row 0 of the export = source row 2 of chunk 0 then chunk 1; row 1 = source row 0.
        var expected: [Double] = []
        for range in [8..<12, 108..<112, 0..<4, 100..<104] { expected += range.map { Double($0) } }
        XCTAssertEqual(values, expected)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("evaluation.json")), Data("{\"x\":1}".utf8))
        let attribution = try String(contentsOf: out.appendingPathComponent("ATTRIBUTION.md"), encoding: .utf8)
        XCTAssertTrue(attribution.contains("synthetic recording on test"))
    }
}
