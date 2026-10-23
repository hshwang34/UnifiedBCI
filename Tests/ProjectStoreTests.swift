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

    func testImportBundledExample_failureLeavesNothingAndRetrySucceeds() async throws {
        let damaged = scratch.appendingPathComponent("damaged.bciproj")
        try FileManager.default.copyItem(at: try Self.tinyFixtureURL(), to: damaged)
        let rec = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: damaged.appendingPathComponent("recordings").path).first)
        let chunk = damaged.appendingPathComponent("recordings/\(rec)/chunks/000005.f64")
        var bytes = try Data(contentsOf: chunk)
        bytes[1] ^= 0x10
        try bytes.write(to: chunk)
        let dest = scratch.appendingPathComponent("retry.bciproj")
        XCTAssertThrowsError(try ProjectStore.importBundledExample(from: damaged, into: dest))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path), "a failed import leaves no project at the destination")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: scratch.path).filter { $0.hasPrefix(".tmp-") }
        XCTAssertEqual(siblings, [], "nor a temp directory beside it")

        let store = try ProjectStore.importBundledExample(from: try Self.tinyFixtureURL(), into: dest)
        let ids = try await store.recordingIDs()
        XCTAssertEqual(ids.count, 1)
        let issues = try await store.verify(recording: ids[0])
        XCTAssertEqual(issues, [])
        XCTAssertEqual(store.directory, dest)
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

    func testOversizedOrSpecialChunkFile_refusedFromStatWithoutReading() async throws {
        let url = scratch.appendingPathComponent("big.bciproj")
        let store = try ProjectStore.create(at: url, name: "B")
        let manifest = sampleManifest()
        let writer = try await store.createRecording(manifest)
        try await writer.append(payload(0))
        try await writer.append(payload(1))
        let chunks = url.appendingPathComponent("recordings/\(manifest.recordingID.uuidString)/chunks")
        // 16 GiB sparse: reading it would take minutes and the memory to hold it.
        let fh = try FileHandle(forWritingTo: chunks.appendingPathComponent("000000.f64"))
        try fh.truncate(atOffset: 16 << 30)
        try fh.close()
        // A FIFO would block a plain read forever.
        try FileManager.default.removeItem(at: chunks.appendingPathComponent("000001.f64"))
        XCTAssertEqual(mkfifo(chunks.appendingPathComponent("000001.f64").path, 0o644), 0)

        let handle = try await store.recording(id: manifest.recordingID)
        let started = ContinuousClock.now
        let issues = handle.verify()
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2), "refused from fstat, not after reading")
        XCTAssertEqual(issues.map(\.kind), [.sizeMismatch, .missingChunk])
        XCTAssertTrue(issues[0].detail.contains("\(16 << 30) bytes"), issues[0].detail)
        XCTAssertTrue(issues[1].detail.contains("not a regular file"), issues[1].detail)
    }

    func testChunkWriter_neverReusesAnIndexWhoseFileExists() async throws {
        let url = scratch.appendingPathComponent("idx.bciproj")
        let store = try ProjectStore.create(at: url, name: "I")
        let manifest = sampleManifest()
        let writer = try await store.createRecording(manifest)
        try await writer.append(payload(0))
        // What an append leaves when it throws after its rename: a committed, unlisted file.
        let stray = url.appendingPathComponent("recordings/\(manifest.recordingID.uuidString)/chunks/000001.f64")
        try Data([9, 9, 9]).write(to: stray)
        let entry = try await writer.append(payload(1))
        XCTAssertEqual(entry.index, 2)
        XCTAssertEqual(try Data(contentsOf: stray), Data([9, 9, 9]), "the existing file is not replaced")
        let handle = try await store.recording(id: manifest.recordingID)
        XCTAssertEqual(try handle.chunk(entry), payload(1).samples)
        XCTAssertEqual(handle.verify().map(\.kind), [.unlistedChunk])
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
        // Temp directories from a crash an hour ago (younger ones may still be in use).
        for child in ["results", "pipelines"] {
            let dir = url.appendingPathComponent("\(child)/.tmp-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Self.age(dir)
        }

        let reopened = try ProjectStore.open(at: url)
        let removed = await reopened.removedOrphans
        XCTAssertEqual(removed.count, 4)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: recDir.appendingPathComponent("chunks").path), ["000000.f64"])
        let issues = try await reopened.verify(recording: manifest.recordingID)
        XCTAssertEqual(issues, [])
        let results = try await reopened.results()
        XCTAssertEqual(results, [])
    }

    /// Backdates `url`'s modification time past the orphan grace period.
    static func age(_ url: URL, by seconds: TimeInterval = 3600) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
    }

    func testOrphanSweep_keepsYoungUnlockedTempDirectories() async throws {
        let url = scratch.appendingPathComponent("young.bciproj")
        _ = try ProjectStore.create(at: url, name: "Y")
        let fm = FileManager.default
        // A staging directory caught before its lock file exists, a result directory
        // `storeResult` is assembling (never locked), and the same two from long ago.
        let youngStaging = url.appendingPathComponent("pipelines/.tmp-\(UUID().uuidString)")
        let youngResult = url.appendingPathComponent("results/.tmp-\(UUID().uuidString)")
        let oldStaging = url.appendingPathComponent("pipelines/.tmp-\(UUID().uuidString)")
        let oldResult = url.appendingPathComponent("results/.tmp-\(UUID().uuidString)")
        // A young staging directory whose lock exists and is free: a crashed run, sweepable.
        let freeStaging = url.appendingPathComponent("pipelines/.tmp-\(UUID().uuidString)")
        for dir in [youngStaging, youngResult, oldStaging, oldResult, freeStaging] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("evaluation.json"))
        }
        try Data().write(to: freeStaging.appendingPathComponent(ProjectStore.stagingLockFileName))
        try Self.age(oldStaging, by: 11 * 60)
        try Self.age(oldResult, by: 11 * 60)

        let store = try ProjectStore.open(at: url)
        let removed = await store.removedOrphans
        let kept = await store.keptOrphans
        XCTAssertEqual(Set(removed), Set([oldStaging, oldResult, freeStaging].map { "\($0.deletingLastPathComponent().lastPathComponent)/\($0.lastPathComponent)" }))
        XCTAssertEqual(kept.count, 2, "\(kept)")
        XCTAssertTrue(kept.allSatisfy { $0.contains("modified recently") }, "\(kept)")
        XCTAssertTrue(fm.fileExists(atPath: youngStaging.path))
        XCTAssertTrue(fm.fileExists(atPath: youngResult.path))
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

    func testResults_skipCorruptMetaAndReportIt() async throws {
        let url = scratch.appendingPathComponent("bad.bciproj")
        let store = try ProjectStore.create(at: url, name: "R")
        let good = try await storeFakeResult(in: store, seed: 1, createdAt: Date(timeIntervalSince1970: 100))
        let broken = try await storeFakeResult(in: store, seed: 2, createdAt: Date(timeIntervalSince1970: 200))
        try Data("{ not json".utf8).write(to: url.appendingPathComponent("results/\(broken.resultID.uuidString)/result.meta.json"))
        let listed = try await store.results().map(\.resultID)
        XCTAssertEqual(listed, [good.resultID], "one damaged result must not hide the others")
        let unreadable = await store.unreadableResults
        XCTAssertEqual(unreadable.map(\.resultID), [broken.resultID])
        XCTAssertFalse(unreadable[0].reason.isEmpty)
    }

    func testResult_refusesEvaluationBytesThatDisagreeWithTheMeta() async throws {
        let url = scratch.appendingPathComponent("hash.bciproj")
        let store = try ProjectStore.create(at: url, name: "R")
        let meta = try await storeFakeResult(in: store, seed: 1, createdAt: Date())
        try Data("{\"x\":2}".utf8).write(to: url.appendingPathComponent("results/\(meta.resultID.uuidString)/evaluation.json"))
        await expectThrows({ _ = try await store.result(id: meta.resultID) }) { error in
            guard case ProjectStoreError.integrity(let issues) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(issues.map(\.kind), [.hashMismatch])
        }
    }

    /// A force-quit mid-evaluation leaves the worker's staging directory and possibly a
    /// half-assembled result or pipeline directory. Reopening shows every earlier result
    /// byte-for-byte and none of the debris.
    func testKillDuringEvaluation_keepsCompletedResults() async throws {
        let url = scratch.appendingPathComponent("kill.bciproj")
        let store = try ProjectStore.create(at: url, name: "K")
        let earlier = try await storeFakeResult(in: store, seed: 1, createdAt: Date(timeIntervalSince1970: 100), evaluation: "{\"kept\": 1.0}")
        let before = try await store.result(id: earlier.resultID)
        // Debris as a kill leaves it: an unheld staging lock, a worker-written npz, a
        // result directory with only its evaluation written.
        let staging = url.appendingPathComponent("pipelines/.tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data().write(to: staging.appendingPathComponent(ProjectStore.stagingLockFileName))
        try Data("PK".utf8).write(to: staging.appendingPathComponent("fitted.npz"))
        let partialPipeline = url.appendingPathComponent("pipelines/.tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: partialPipeline, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: partialPipeline.appendingPathComponent("pipeline.json"))
        let partialResult = url.appendingPathComponent("results/.tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: partialResult, withIntermediateDirectories: true)
        try Data("{\"half\"".utf8).write(to: partialResult.appendingPathComponent("evaluation.json"))
        // The kill was a while ago; unlocked temp directories younger than the grace period are kept.
        try Self.age(partialPipeline)
        try Self.age(partialResult)

        let reopened = try ProjectStore.open(at: url)
        let removed = await reopened.removedOrphans
        XCTAssertEqual(removed.count, 3, "\(removed)")
        let listed = try await reopened.results()
        XCTAssertEqual(listed.map(\.resultID), [earlier.resultID])
        let after = try await reopened.result(id: earlier.resultID)
        XCTAssertEqual(after.evaluationJSON, before.evaluationJSON)
        XCTAssertEqual(after.meta, before.meta)
        XCTAssertEqual(after.pipeline, before.pipeline)
        let pipelines = try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("pipelines").path)
        XCTAssertEqual(pipelines, [earlier.pipelineID.uuidString])
    }

    func testOpenSweep_isBestEffortAndSkipsALiveStagingDirectory() async throws {
        let url = scratch.appendingPathComponent("sweep.bciproj")
        let live = try ProjectStore.create(at: url, name: "S")
        let staging = try await live.stagingDirectory()
        try Data("PK".utf8).write(to: staging.appendingPathComponent("fitted.npz"))
        // A temp directory whose contents cannot be deleted (read-only parent of a file).
        let stuck = url.appendingPathComponent("results/.tmp-stuck")
        try FileManager.default.createDirectory(at: stuck, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: stuck.appendingPathComponent("evaluation.json"))
        try Self.age(stuck)
        XCTAssertEqual(chmod(stuck.path, 0o500), 0)
        defer { chmod(stuck.path, 0o700) }

        let second = try ProjectStore.open(at: url)     // must not throw
        let kept = await second.keptOrphans
        XCTAssertEqual(kept.count, 2, "\(kept)")
        XCTAssertTrue(kept.contains { $0.hasPrefix("pipelines/\(staging.lastPathComponent): in use") }, "\(kept)")
        XCTAssertTrue(kept.contains { $0.hasPrefix("results/.tmp-stuck") }, "\(kept)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("fitted.npz").path),
                      "a staging directory in use by a live evaluation is not deleted")

        await live.discardStagingDirectory(staging)
        chmod(stuck.path, 0o700)
        let third = try ProjectStore.open(at: url)
        let removed = await third.removedOrphans
        XCTAssertEqual(removed, ["results/.tmp-stuck"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
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

    /// A recording with two segments whose run ids sanitize to the same file name, and a
    /// result pointing at it.
    private func twoSegmentExportFixture(_ name: String, runIDs: (String, String)) async throws -> (ProjectStore, RecordingManifest, ResultMeta) {
        let url = scratch.appendingPathComponent(name)
        let store = try ProjectStore.create(at: url, name: "E")
        var manifest = sampleManifest(rows: 3)
        let t0 = manifest.createdAt
        manifest.segments = [
            .init(index: 0, sessionID: nil, runID: runIDs.0, startedAtWall: t0, startedAtMonotonicNanos: 0, endedAtMonotonicNanos: nil, endReason: nil, detectedGaps: []),
            .init(index: 1, sessionID: nil, runID: runIDs.1, startedAtWall: t0, startedAtMonotonicNanos: 0, endedAtMonotonicNanos: nil, endReason: nil, detectedGaps: []),
        ]
        let writer = try await store.createRecording(manifest)
        try await writer.append(payload(0))
        try await writer.append(payload(1))
        var second = payload(2)
        second.segment = 1
        second.firstSampleIndex = 0
        try await writer.append(second)
        var meta = try await storeFakeResult(in: store, seed: 0, createdAt: Date())
        meta.recordingID = manifest.recordingID
        try ContractJSON.encoder().encode(meta).write(to: url.appendingPathComponent("results/\(meta.resultID.uuidString)/result.meta.json"))
        return (store, manifest, meta)
    }

    func testExport_collidingRunIDsGetDistinctFiles() async throws {
        let (store, _, meta) = try await twoSegmentExportFixture("col.bciproj", runIDs: ("run/1", "run:1"))
        let out = scratch.appendingPathComponent("export")
        try await store.export(result: meta.resultID, to: out)
        let header = try ContractJSON.decoder().decode(ExportedRecording.self, from: Data(contentsOf: out.appendingPathComponent("recording.json")))
        XCTAssertEqual(header.samples.files.map(\.file), ["segment-run_1-0.f64", "segment-run_1-1.f64"])
        XCTAssertEqual(header.samples.files.map(\.sampleCount), [8, 4])
        for file in header.samples.files {
            XCTAssertEqual(AtomicFile.sha256Hex(try Data(contentsOf: out.appendingPathComponent(file.file))), file.sha256)
        }
        // Case-only differences collide on APFS too; distinct names stay as they were.
        let s = ProjectStore.segmentFileNames
        let seg = { (i: Int, run: String) in RecordingManifest.StreamSegment(index: i, sessionID: nil, runID: run, startedAtWall: Date(),
                                                                          startedAtMonotonicNanos: 0, endedAtMonotonicNanos: nil, endReason: nil, detectedGaps: []) }
        XCTAssertEqual(s([seg(0, "A"), seg(1, "a")]), ["segment-A-0.f64", "segment-a-1.f64"])
        XCTAssertEqual(s([seg(0, "x"), seg(1, "x"), seg(2, "x-1")]), ["segment-x-0.f64", "segment-x-1.f64", "segment-x-1_.f64"])
        XCTAssertEqual(s([seg(0, "R04"), seg(1, "R08")]), ["segment-R04.f64", "segment-R08.f64"])
    }

    func testExport_refusesChunksThatDoNotTileTheSegment_andLeavesNothing() async throws {
        let (store, manifest, meta) = try await twoSegmentExportFixture("gap.bciproj", runIDs: ("a", "b"))
        try editManifest(store, manifest.recordingID) { obj in
            var chunks = obj["chunks"] as! [[String: Any]]
            chunks[1]["firstSampleIndex"] = 5      // chunk 0 covers 0..<4: a one-sample gap
            obj["chunks"] = chunks
        }
        let out = scratch.appendingPathComponent("export")
        await expectThrows({ try await store.export(result: meta.resultID, to: out) }) { error in
            guard case ProjectStoreError.invalidManifest(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("expected 4"), why)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: scratch.path).filter { $0.hasPrefix(".tmp-") }
        XCTAssertEqual(siblings, [], "a failed export leaves no temp directory")
    }

    func testExport_refusesSymlinkedEventsOrModel_andCopiesBytesNotLinks() async throws {
        let (store, manifest, meta) = try await twoSegmentExportFixture("link.bciproj", runIDs: ("a", "b"))
        let fm = FileManager.default
        let secret = scratch.appendingPathComponent("secret.txt")
        try Data("private".utf8).write(to: secret)
        let events = store.directory.appendingPathComponent("recordings/\(manifest.recordingID.uuidString)/events.jsonl")
        try? fm.removeItem(at: events)
        try fm.createSymbolicLink(at: events, withDestinationURL: secret)
        let out = scratch.appendingPathComponent("export")
        await expectThrows({ try await store.export(result: meta.resultID, to: out) }) { error in
            guard case ProjectStoreError.integrity(let issues) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(issues.map(\.kind), [.notRegularFile])
            XCTAssertTrue(issues[0].file.hasSuffix("events.jsonl"), issues[0].file)
        }
        XCTAssertFalse(fm.fileExists(atPath: out.path))

        try fm.removeItem(at: events)
        try Data("{}\n".utf8).write(to: events)
        let stored = try await store.result(id: meta.resultID)
        let model = await store.fittedArraysURL(pipelineID: stored.pipeline.pipelineID)
        try fm.removeItem(at: model)
        try fm.createSymbolicLink(at: model, withDestinationURL: secret)
        await expectThrows({ try await store.export(result: meta.resultID, to: out) }) { error in
            guard case ProjectStoreError.integrity(let issues) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(issues.first?.file.hasSuffix("fitted.npz") ?? false, "\(issues)")
        }
        XCTAssertFalse(fm.fileExists(atPath: out.path))

        try fm.removeItem(at: model)
        try Data("PK".utf8).write(to: model)
        try await store.export(result: meta.resultID, to: out)
        for name in ["events.jsonl", "model.npz"] {
            let attrs = try fm.attributesOfItem(atPath: out.appendingPathComponent(name).path)
            XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeRegular, name)
        }
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("events.jsonl")), Data("{}\n".utf8))
    }

    func testExport_refusesASymlinkedResultDirectoryPointingOutside() async throws {
        let (store, _, meta) = try await twoSegmentExportFixture("dirlink.bciproj", runIDs: ("a", "b"))
        let fm = FileManager.default
        // Move the real result outside and leave a symlink in its place: every file in it
        // is a regular file, so only the directory check can catch it.
        let resultDir = store.directory.appendingPathComponent("results/\(meta.resultID.uuidString)")
        let outside = scratch.appendingPathComponent("elsewhere", isDirectory: true)
        try fm.moveItem(at: resultDir, to: outside)
        try fm.createSymbolicLink(at: resultDir, withDestinationURL: outside)
        let out = scratch.appendingPathComponent("export")
        await expectThrows({ try await store.export(result: meta.resultID, to: out) }) { error in
            guard case ProjectStoreError.integrity(let issues) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(issues.map(\.kind), [.outsideProject])
        }
        XCTAssertFalse(fm.fileExists(atPath: out.path))
        // The same for the pipeline directory, once the result is back in place.
        try fm.removeItem(at: resultDir)
        try fm.moveItem(at: outside, to: resultDir)
        let stored = try await store.result(id: meta.resultID)
        let pipelineDir = store.directory.appendingPathComponent("pipelines/\(stored.pipeline.pipelineID.uuidString)")
        try fm.moveItem(at: pipelineDir, to: outside)
        try fm.createSymbolicLink(at: pipelineDir, withDestinationURL: outside)
        await expectThrows({ try await store.export(result: meta.resultID, to: out) }) { error in
            guard case ProjectStoreError.integrity(let issues) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(issues.map(\.kind), [.outsideProject])
        }
        XCTAssertFalse(fm.fileExists(atPath: out.path))
    }

    // MARK: Hostile manifests
    // MARK: Hostile manifests

    private func expectThrows(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line,
                              _ check: (Error) -> Void = { _ in }) async {
        do {
            try await body()
            XCTFail("expected an error", file: file, line: line)
        } catch {
            check(error)
        }
    }

    /// Rewrites one recording's manifest through a JSON-level edit so the test can
    /// produce shapes the Swift types would never encode.
    private func editManifest(_ store: ProjectStore, _ id: UUID, _ edit: (inout [String: Any]) -> Void) throws {
        let url = store.directory.appendingPathComponent("recordings/\(id.uuidString)/recording.json")
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        edit(&obj)
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
    }

    func testManifestWithChannelRowOutsideChunk_isRefusedNotCrashed() async throws {
        let url = scratch.appendingPathComponent("row.bciproj")
        let store = try ProjectStore.create(at: url, name: "H")
        let manifest = sampleManifest(rows: 3)
        let writer = try await store.createRecording(manifest)
        try await writer.append(payload(0))
        try editManifest(store, manifest.recordingID) { obj in
            var channels = obj["channels"] as! [[String: Any]]
            channels[1]["sourceRow"] = 99
            obj["channels"] = channels
        }
        let reopened = try ProjectStore.open(at: url)
        await expectThrows({ _ = try await reopened.recording(id: manifest.recordingID) }) { error in
            guard case ProjectStoreError.invalidManifest(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("row 99"), why)
        }
        // Export goes through the same validation and must fail cleanly, not index out of range.
        let meta = try await storeFakeResult(in: reopened, seed: 0, createdAt: Date())
        var fixed = meta
        fixed.recordingID = manifest.recordingID
        try ContractJSON.encoder().encode(fixed).write(to: url.appendingPathComponent("results/\(meta.resultID.uuidString)/result.meta.json"))
        let target = scratch.appendingPathComponent("x")
        await expectThrows { try await reopened.export(result: meta.resultID, to: target) }
    }

    func testManifestWithOverflowingChunkDimensions_isRefused() async throws {
        let url = scratch.appendingPathComponent("ovf.bciproj")
        let store = try ProjectStore.create(at: url, name: "H")
        let manifest = sampleManifest(rows: 3)
        let writer = try await store.createRecording(manifest)
        try await writer.append(payload(0))
        try editManifest(store, manifest.recordingID) { obj in
            var chunks = obj["chunks"] as! [[String: Any]]
            chunks[0]["rowCount"] = Int.max / 4
            chunks[0]["sampleCount"] = 8
            obj["chunks"] = chunks
        }
        await expectThrows({ _ = try await ProjectStore.open(at: url).recording(id: manifest.recordingID) }) { error in
            guard case ProjectStoreError.invalidChunk(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("overflows"), why)
        }
        try editManifest(store, manifest.recordingID) { obj in
            var chunks = obj["chunks"] as! [[String: Any]]
            chunks[0]["rowCount"] = 3
            chunks[0]["sampleCount"] = 5     // file holds 3×4
            obj["chunks"] = chunks
        }
        let handle = try await ProjectStore.open(at: url).recording(id: manifest.recordingID)
        XCTAssertEqual(handle.verify().map(\.kind), [.sizeMismatch])
        XCTAssertThrowsError(try handle.chunk(handle.manifest.chunks[0]))
    }

    func testChunkFileNameCannotEscapeTheRecordingDirectory() async throws {
        let url = scratch.appendingPathComponent("trav.bciproj")
        let store = try ProjectStore.create(at: url, name: "H")
        let manifest = sampleManifest(rows: 3)
        let writer = try await store.createRecording(manifest)
        try await writer.append(payload(0))
        // A secret outside the project with exactly the bytes the manifest expects.
        let secret = scratch.appendingPathComponent("secret.bin")
        let chunk = url.appendingPathComponent("recordings/\(manifest.recordingID.uuidString)/chunks/000000.f64")
        try FileManager.default.copyItem(at: chunk, to: secret)
        try editManifest(store, manifest.recordingID) { obj in
            var chunks = obj["chunks"] as! [[String: Any]]
            chunks[0]["fileName"] = "../../../secret.bin"
            obj["chunks"] = chunks
        }
        await expectThrows({ _ = try await ProjectStore.open(at: url).recording(id: manifest.recordingID) }) { error in
            guard case ProjectStoreError.invalidManifest = error else { return XCTFail("\(error)") }
        }
        // A symlink in place of the chunk file is not followed outside either.
        try editManifest(store, manifest.recordingID) { obj in
            var chunks = obj["chunks"] as! [[String: Any]]
            chunks[0]["fileName"] = "chunks/000000.f64"
            obj["chunks"] = chunks
        }
        try FileManager.default.removeItem(at: chunk)
        try FileManager.default.createSymbolicLink(at: chunk, withDestinationURL: secret)
        let handle = try await ProjectStore.open(at: url).recording(id: manifest.recordingID)
        XCTAssertEqual(handle.verify().map(\.kind), [.missingChunk])
        XCTAssertThrowsError(try handle.chunk(handle.manifest.chunks[0]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secret.path))
    }

    func testOrphanSweepDoesNotFollowSymlinksOutOfTheProject() async throws {
        let url = scratch.appendingPathComponent("sym.bciproj")
        _ = try ProjectStore.create(at: url, name: "H")
        let outside = scratch.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("chunks"), withIntermediateDirectories: true)
        let victim = outside.appendingPathComponent(".tmp-precious")
        let victim2 = outside.appendingPathComponent("chunks/.tmp-000000")
        try Data("keep".utf8).write(to: victim)
        try Data("keep".utf8).write(to: victim2)
        // A UUID-named symlink where a recording directory would be, a symlinked
        // results/ directory, and a symlinked temp entry inside a real recording.
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("recordings/\(UUID().uuidString)"), withDestinationURL: outside)
        try FileManager.default.removeItem(at: url.appendingPathComponent("results"))
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("results"), withDestinationURL: outside)
        let real = url.appendingPathComponent("recordings/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: real.appendingPathComponent(".tmp-link"), withDestinationURL: victim)

        let store = try ProjectStore.open(at: url)
        let removed = await store.removedOrphans
        XCTAssertEqual(removed, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim2.path))
    }
}
