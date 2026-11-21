import XCTest
@testable import BCIWorkspace

/// Brief 004 PR 2: the durable recording writer, crash recovery on open, disk-full stops.
final class RecordingWriterTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Fixtures

    static let rows = 32                 // every BrainFlow row of Cyton+Daisy
    static let counterRow = 0
    static let timestampRow = 30

    /// Sample `k` (index within its segment's stream) of row `r`; the counter row steps by 2
    /// mod 256 and the timestamp row is k / 125 s, so chunk metadata can be checked exactly.
    static func value(_ k: Int, _ r: Int, segment: Int = 0) -> Double {
        switch r {
        case counterRow: return Double((k * 2) % 256)
        case timestampRow: return 1_700_000_000 + Double(k) / 125
        default: return Double(segment * 1_000_000 + k * 100 + r)
        }
    }

    static func block(from start: Int, count: Int, segment: Int = 0, gaps: [RecordingManifest.Gap] = []) -> RecordingWriter.Block {
        let values = (0..<rows).flatMap { r in (start..<(start + count)).map { value($0, r, segment: segment) } }
        return .init(values: values, rowCount: rows, sampleCount: count, drainedAtMonotonicNanos: Int64(start + count) * 8_000_000, gaps: gaps)
    }

    private func manifest() -> RecordingManifest {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000.25)
        return RecordingManifest(
            recordingID: UUID(), sessionID: "s", runID: "r", createdAt: t0,
            source: .init(kind: "synthetic", boardID: -1, boardName: "test", dataPath: nil, brainflowVersion: "n/a", appVersion: "test"),
            channels: (1...16).map { ChannelSpec(id: String(format: "ch%02d", $0), label: "ch\($0)", kind: "eeg", unit: "uV", sourceRow: $0) },
            reference: "SRB2", montage: "undeclared",
            timing: .init(nominalSampleRateHz: 125, timestampClock: .brainflowReceipt, timestampGeneratedBy: "host",
                          sequenceCounterRow: Self.counterRow, sequenceStep: 2, notes: ""),
            clockMapping: .init(anchorMonotonicNanos: 0, anchorWall: t0),
            boardConfiguration: .init(requested: [:], readback: [:]), chunks: [], segments: [])
    }

    private func start(_ name: String = "w", options: RecordingWriter.Options = .init(timestampRow: timestampRow))
        async throws -> (ProjectStore, RecordingWriter) {
        let store = try ProjectStore.create(at: scratch.appendingPathComponent("\(name).bciproj"), name: name)
        let writer = try await RecordingWriter.start(in: store, manifest: manifest(), startedAtWall: Date(), startedAtMonotonicNanos: 1, options: options)
        return (store, writer)
    }

    private var timestampRow: Int { Self.timestampRow }

    /// All samples of one segment, concatenated from its listed chunks, row-major per chunk.
    private func samples(_ handle: RecordingHandle, segment: Int) throws -> [[Double]] {
        var out = Array(repeating: [Double](), count: Self.rows)
        for entry in handle.chunks(inSegment: segment) {
            XCTAssertEqual(entry.firstSampleIndex, out[0].count, "chunks tile the segment with no hole or overlap")
            let data = try handle.chunk(entry)
            for r in 0..<Self.rows { out[r] += data[(r * entry.sampleCount)..<((r + 1) * entry.sampleCount)] }
        }
        return out
    }

    private func waitFor(_ what: String, timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: Re-chunking, gaps, stop

    func testRechunksIntoFullChunks_flushesPartialOnStop_andStoresGapsAtSegmentIndices() async throws {
        let (store, writer) = try await start()
        let total = 3 * 125 + 50
        let gapInSecondBlock = RecordingManifest.Gap(afterSampleIndex: 5, evidence: .sequenceSkip, estimatedMissingSamples: 3, ambiguous: true)
        let gapInTail = RecordingManifest.Gap(afterSampleIndex: 0, evidence: .staleHalf, estimatedMissingSamples: nil, ambiguous: false)
        let starts = Array(stride(from: 0, to: total, by: 37))
        for (i, s) in starts.enumerated() {
            let n = min(37, total - s)
            let gaps = i == 1 ? [gapInSecondBlock] : (i == starts.count - 1 ? [gapInTail] : [])
            XCTAssertEqual(writer.submit(Self.block(from: s, count: n, gaps: gaps)), .accepted)
        }
        let status = await writer.finish(.stopped, endedAtMonotonicNanos: 99)

        XCTAssertEqual(status.endReason, .stopped)
        XCTAssertEqual(status.committedSamples, total)
        XCTAssertEqual(status.uncommittedSamples, 0)
        XCTAssertNil(status.failure)
        let handle = try await store.recording(id: writer.recordingID)
        XCTAssertEqual(handle.manifest.chunks.map(\.sampleCount), [125, 125, 125, 50])
        XCTAssertEqual(handle.verify(), [])
        let stored = try samples(handle, segment: 0)
        for r in [0, 1, 16, 30, 31] { XCTAssertEqual(stored[r], (0..<total).map { Self.value($0, r) }, "row \(r) exactly as received") }
        let second = handle.manifest.chunks[1]
        XCTAssertEqual(second.firstPackageNumber, (125 * 2) % 256)
        XCTAssertEqual(second.lastPackageNumber, (249 * 2) % 256)
        XCTAssertEqual(second.firstBrainflowTimestamp, Self.value(125, Self.timestampRow))
        XCTAssertEqual(second.drainedAtMonotonicNanos, Int64(222 + 37) * 8_000_000, "drain time of the block holding the chunk's last sample")
        let seg = try XCTUnwrap(handle.manifest.segments.first)
        XCTAssertEqual(seg.endReason, .stopped)
        XCTAssertEqual(seg.endedAtMonotonicNanos, 99)
        XCTAssertNil(seg.uncommittedSampleCount)
        let tailStart = (total / 37) * 37
        XCTAssertEqual(seg.detectedGaps.map(\.afterSampleIndex), [37 + 5, tailStart + 0])
        XCTAssertEqual(seg.detectedGaps.map(\.evidence), [.sequenceSkip, .staleHalf])
        XCTAssertFalse(FileManager.default.fileExists(atPath: handle.directory.appendingPathComponent(".writer.lock").path), "a finished recording keeps no lock file")
        XCTAssertEqual(writer.submit(Self.block(from: 0, count: 1)), .refused(.stopped))
    }

    func testGapIsPublishedWithTheChunkHoldingTheSampleAfterIt() async throws {
        let (store, writer) = try await start()
        // Gap after sample 124 (last of chunk 0): evidenced by sample 125, so not in chunk 0's rewrite.
        writer.submit(Self.block(from: 0, count: 125, gaps: [.init(afterSampleIndex: 124, evidence: .sequenceSkip, estimatedMissingSamples: 1, ambiguous: true)]))
        try await waitFor("chunk 0") { writer.status.committedChunks == 1 }
        var handle = try await store.recording(id: writer.recordingID)
        XCTAssertEqual(handle.manifest.segments[0].detectedGaps, [])
        writer.submit(Self.block(from: 125, count: 125))
        await writer.finish()
        handle = try await store.recording(id: writer.recordingID)
        XCTAssertEqual(handle.manifest.segments[0].detectedGaps.map(\.afterSampleIndex), [124])
    }

    func testReconnectStartsANewSegmentFromZero_nothingJoined() async throws {
        let (store, writer) = try await start()
        writer.submit(Self.block(from: 0, count: 200))
        writer.endSegment(.disconnect, endedAtMonotonicNanos: 500)
        writer.submit(Self.block(from: 0, count: 130, segment: 1))
        XCTAssertEqual(writer.status.endReason, nil)
        writer.beginSegment(startedAtWall: Date(), startedAtMonotonicNanos: 600)
        writer.submit(Self.block(from: 0, count: 130, segment: 1))
        let status = await writer.finish()

        XCTAssertEqual(status.uncommittedSamples, 130, "a block between segments is counted, never joined to either")
        let handle = try await store.recording(id: writer.recordingID)
        XCTAssertEqual(handle.verify(), [])
        XCTAssertEqual(handle.manifest.chunks.map(\.segment), [0, 0, 1, 1])
        XCTAssertEqual(handle.manifest.chunks.map(\.firstSampleIndex), [0, 125, 0, 125])
        let segs = handle.manifest.segments
        XCTAssertEqual(segs.map(\.index), [0, 1])
        XCTAssertEqual(segs.map(\.endReason), [.disconnect, .stopped])
        XCTAssertEqual(segs[0].detectedGaps, [.init(afterSampleIndex: 199, evidence: .disconnect, estimatedMissingSamples: nil, ambiguous: false)])
        XCTAssertEqual(segs[1].startedAtMonotonicNanos, 600)
        XCTAssertEqual(segs.map(\.runID), ["r", "r"])
        XCTAssertEqual(try samples(handle, segment: 1)[5], (0..<130).map { Self.value($0, 5, segment: 1) })
    }

    // MARK: Backlog and disk full

    func testBacklogOverLimit_stopsWithErrorAndCountsExactlyWhatWasNotCommitted() async throws {
        var options = RecordingWriter.Options(timestampRow: Self.timestampRow)
        options.samplesPerChunk = 10
        options.backlogLimitChunks = 3
        // A slow disk: the first commit takes 300 ms, long enough for the producer to run ahead.
        options.hook = CommitHook { point, index in if point == .afterFsync, index == 0 { usleep(300_000) } }
        let (store, writer) = try await start(options: options)
        var accepted = 0, refused = 0, results: [RecordingWriter.SubmitResult] = []
        for i in 0..<10 {
            let result = writer.submit(Self.block(from: i * 7, count: 7))
            results.append(result)
            if result == .accepted { accepted += 7 } else if refused == 0 { refused = 7 }
        }
        XCTAssertEqual(results.prefix(4), [.accepted, .accepted, .accepted, .accepted])
        XCTAssertEqual(results[4], .refused(.error), "35 samples would exceed 3 chunks of 10")
        let status = await writer.finish()
        XCTAssertEqual(status.endReason, .error)
        XCTAssertEqual(status.committedSamples, accepted, "everything accepted is committed")
        XCTAssertEqual(status.uncommittedSamples, refused)
        XCTAssertEqual(status.failure, "The disk could not keep up: 3 chunks waiting")
        let handle = try await store.recording(id: writer.recordingID)
        XCTAssertEqual(handle.verify(), [])
        XCTAssertEqual(handle.manifest.segments[0].endReason, .error)
        XCTAssertEqual(handle.manifest.segments[0].uncommittedSampleCount, 7)
    }

    func testFreeSpaceUnderMinimum_stopsDiskFull_committedPrefixVerifies() async throws {
        var options = RecordingWriter.Options(timestampRow: Self.timestampRow)
        let probes = Counter()
        options.freeBytes = { _ in probes.next() < 2 ? 500 << 20 : 99 << 20 }
        let (store, writer) = try await start(options: options)
        writer.submit(Self.block(from: 0, count: 300))
        let status = await writer.finish()
        XCTAssertEqual(status.endReason, .diskFull)
        XCTAssertEqual(status.committedSamples, 250)
        XCTAssertEqual(status.uncommittedSamples, 50)
        let handle = try await store.recording(id: writer.recordingID)
        XCTAssertEqual(handle.verify(), [])
        XCTAssertEqual(handle.manifest.segments[0].endReason, .diskFull)
        XCTAssertEqual(handle.manifest.segments[0].uncommittedSampleCount, 50)
    }

    func testENOSPCAtEachWriteStep_stopsDiskFull_andTheRecordingVerifies() async throws {
        for point in CommitHook.Point.allCases {
            var options = RecordingWriter.Options(timestampRow: Self.timestampRow)
            options.fault = WriteFault { p, index in p == point && index == 1 ? ENOSPC : nil }
            let (store, writer) = try await start("enospc-\(point.rawValue)", options: options)
            writer.submit(Self.block(from: 0, count: 400))
            let status = await writer.finish()
            let label = point.rawValue
            XCTAssertEqual(status.endReason, .diskFull, label)
            let handle = try await store.recording(id: writer.recordingID)
            XCTAssertEqual(handle.manifest.segments[0].endReason, .diskFull, label)
            let chunkFiles = try FileManager.default.contentsOfDirectory(atPath: handle.directory.appendingPathComponent("chunks").path)
            XCTAssertFalse(chunkFiles.contains { $0.hasPrefix(".tmp-") }, "no temp chunk left on a full disk: \(label)")
            switch point {
            case .afterTmpWrite, .afterFsync:
                XCTAssertEqual(handle.verify(), [], label)
                XCTAssertEqual(status.committedSamples, 125, label)
            case .afterRename:
                // Renamed, never listed: exactly what a kill at the same point leaves.
                XCTAssertEqual(handle.verify().map(\.kind), [.unlistedChunk], label)
                XCTAssertEqual(status.committedSamples, 125, label)
            case .afterManifestWrite:
                // The chunk entry was in memory; the segment-close rewrite lists it.
                XCTAssertEqual(handle.verify(), [], label)
                XCTAssertEqual(handle.manifest.chunks.count, 2, label)
                XCTAssertEqual(status.committedSamples, 250, label)
            }
            XCTAssertEqual(status.committedSamples + status.uncommittedSamples, 400, "every sample accounted for: \(label)")
        }
    }

    func testOtherWriteError_stopsWithError() async throws {
        var options = RecordingWriter.Options()
        options.fault = WriteFault { p, index in p == .afterFsync && index == 0 ? EIO : nil }
        let (_, writer) = try await start(options: options)
        writer.submit(Self.block(from: 0, count: 125))
        let status = await writer.finish()
        XCTAssertEqual(status.endReason, .error)
        XCTAssertEqual(status.uncommittedSamples, 125)
        XCTAssertTrue(status.failure?.contains("errno \(EIO)") == true, status.failure ?? "")
    }

    /// Brief 004 test plan: one disk-full stop on a real, nearly full volume. Needs only
    /// `hdiutil` (no root); skipped where disk images cannot be attached.
    func testRealSmallDiskImage_stopsDiskFullAndVerifies() async throws {
        let image = scratch.appendingPathComponent("full.dmg"), mount = scratch.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard Self.hdiutil(["create", "-size", "12m", "-fs", "HFS+", "-volname", "BCIFull", image.path]) == 0,
              Self.hdiutil(["attach", "-nobrowse", "-noverify", "-noautoopen", "-mountpoint", mount.path, image.path]) == 0 else {
            throw XCTSkip("hdiutil could not create or attach a disk image here")
        }
        defer { _ = Self.hdiutil(["detach", "-force", mount.path]) }
        let store = try ProjectStore.create(at: mount.appendingPathComponent("p.bciproj"), name: "full")

        func record(minimumFree: Int64) async throws -> (RecordingWriter.Status, RecordingHandle) {
            var options = RecordingWriter.Options(timestampRow: Self.timestampRow)
            options.minimumFreeBytes = minimumFree
            let writer = try await RecordingWriter.start(in: store, manifest: manifest(), startedAtWall: Date(), startedAtMonotonicNanos: 1, options: options)
            var k = 0
            while writer.status.endReason == nil, k < 2_000 * 125 {
                if writer.status.backlogChunks < 5 { writer.submit(Self.block(from: k, count: 125)); k += 125 }
                try await Task.sleep(for: .milliseconds(1))
            }
            let status = await writer.finish()
            return (status, try await store.recording(id: writer.recordingID))
        }

        // The 100 MB guard, scaled to this volume: stop 1 MB before it is full.
        let free = try XCTUnwrap(RecordingWriter.freeBytes(at: mount))
        let (guarded, handle) = try await record(minimumFree: free - (1 << 20))
        XCTAssertEqual(guarded.endReason, .diskFull)
        XCTAssertGreaterThan(guarded.committedChunks, 0)
        XCTAssertEqual(handle.manifest.segments[0].endReason, .diskFull)
        XCTAssertEqual(handle.verify(), [])

        // No guard: the OS's own ENOSPC. Whatever was committed still verifies.
        let (raw, rawHandle) = try await record(minimumFree: 0)
        XCTAssertEqual(raw.endReason, .diskFull, raw.failure ?? "")
        XCTAssertTrue(raw.failure?.contains("errno \(ENOSPC)") == true, raw.failure ?? "")
        XCTAssertEqual(rawHandle.verify().filter { $0.kind != .unlistedChunk }, [])
        _ = try ProjectStore.open(at: store.directory)
    }

    private static func hdiutil(_ args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return -1 }
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    // MARK: Soak

    /// 3,600 chunks (one hour at 125 Hz, all 32 rows) from a source that submits as fast as
    /// the writer drains; the manifest rewrite grows with every entry, so the budget is
    /// checked at the end: p95 of the last 100 commits ≤ 250 ms (brief 004, eng. decisions).
    func testSoak_3600Chunks_commitTimeAtTheEndStaysUnderBudget() async throws {
        let (store, writer) = try await start("soak")
        let chunks = 3_600
        var k = 0
        while k < chunks * 125 {
            if writer.status.backlogChunks < 20 {
                XCTAssertEqual(writer.submit(Self.block(from: k, count: 125)), .accepted)
                k += 125
            } else {
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        try await waitFor("the backlog to drain", timeout: .seconds(300)) { writer.status.committedChunks == chunks }
        let tail = writer.status.recentCommitDurationsNanos.sorted()
        let status = await writer.finish()
        XCTAssertEqual(status.committedChunks, chunks)
        XCTAssertEqual(status.uncommittedSamples, 0)
        let p95 = Double(tail[Int(Double(tail.count) * 0.95) - 1]) / 1e6
        print("soak: p95 of the last \(tail.count) commits at entry \(chunks) = \(String(format: "%.1f", p95)) ms, max \(Double(tail.last!) / 1e6) ms")
        XCTAssertLessThanOrEqual(p95, 250, "per-commit budget at entry 3,600")
        let handle = try await store.recording(id: writer.recordingID)
        XCTAssertEqual(handle.manifest.chunks.count, chunks)
        XCTAssertEqual(handle.manifest.segments[0].endReason, .stopped)
    }

    // MARK: Crash recovery

    func testOpenLeavesALiveWritersSegmentAlone() async throws {
        let (store, writer) = try await start()
        writer.submit(Self.block(from: 0, count: 250))
        try await waitFor("two chunks") { writer.status.committedChunks == 2 }
        let second = try ProjectStore.open(at: store.directory)
        let closed = await second.closedSegments
        XCTAssertEqual(closed, [])
        let live = try await second.recording(id: writer.recordingID)
        XCTAssertNil(live.manifest.segments[0].endReason)
        await writer.finish()
        let after = try await ProjectStore.open(at: store.directory).recording(id: writer.recordingID)
        XCTAssertEqual(after.manifest.segments[0].endReason, .stopped)
    }

    private func runRecordingHelper(chunks: Int, crashAt: (CommitHook.Point, Int)?) throws -> URL {
        let dir = scratch.appendingPathComponent("crash-\(UUID().uuidString).bciproj")
        let proc = Process()
        proc.executableURL = try ProjectStoreTests.crashHelperURL()
        proc.arguments = [dir.path, "\(chunks)", "recording"]
        var env = ProcessInfo.processInfo.environment
        if let crashAt { env["CRASH_AT"] = "\(crashAt.0.rawValue):\(crashAt.1)" } else { env.removeValue(forKey: "CRASH_AT") }
        proc.environment = env
        let stderr = Pipe()
        proc.standardError = stderr
        try proc.run()
        proc.waitUntilExit()
        let log = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(proc.terminationStatus, crashAt == nil ? 0 : 9, log)
        return dir
    }

    func testRecordingHelperWithoutCrash_stopsCleanly() async throws {
        let dir = try runRecordingHelper(chunks: 3, crashAt: nil)
        let store = try ProjectStore.open(at: dir)
        let closed = await store.closedSegments
        XCTAssertEqual(closed, [])
        let ids = try await store.recordingIDs()
        let handle = try await store.recording(id: try XCTUnwrap(ids.first))
        XCTAssertEqual(handle.manifest.chunks.map(\.sampleCount), [125, 125, 125, 50])
        XCTAssertEqual(handle.manifest.segments[0].endReason, .stopped)
        XCTAssertEqual(handle.verify(), [])
    }

    func testKillAtEachCommitPointDuringRecording_prefixSurvivesAndOpenClosesTheSegment() async throws {
        for point in CommitHook.Point.allCases {
            for index in [0, 2] {
                let label = "\(point.rawValue):\(index)"
                let dir = try runRecordingHelper(chunks: 4, crashAt: (point, index))
                let store = try ProjectStore.open(at: dir)
                let ids = try await store.recordingIDs()
                let id = try XCTUnwrap(ids.first, label)
                let handle = try await store.recording(id: id)
                let listed = point == .afterManifestWrite ? index + 1 : index
                XCTAssertEqual(handle.manifest.chunks.count, listed, label)
                for entry in handle.manifest.chunks {
                    let data = try handle.chunk(entry)
                    XCTAssertEqual(data[0..<125], ArraySlice((0..<125).map { Double((entry.firstSampleIndex + $0) * 10) }), label)
                    XCTAssertEqual(data[(3 * 125)...].last, Double((entry.firstSampleIndex + 124) * 10 + 3), label)
                }
                XCTAssertEqual(handle.verify().map(\.kind), point == .afterRename ? [.unlistedChunk] : [], label)
                let closed = await store.closedSegments
                XCTAssertEqual(closed, ["\(id.uuidString)#0"], label)
                let seg = handle.manifest.segments[0]
                XCTAssertEqual(seg.endReason, .processTerminated, label)
                XCTAssertEqual(seg.detectedGaps, [.init(afterSampleIndex: listed * 125 - 1, evidence: .processTerminated,
                                                        estimatedMissingSamples: nil, ambiguous: false)], label)
                XCTAssertEqual(seg.endedAtMonotonicNanos, handle.manifest.chunks.last?.drainedAtMonotonicNanos ?? 0, label)
                // Reopening again changes nothing: the close is a one-time repair.
                let again = try ProjectStore.open(at: dir)
                let closedAgain = await again.closedSegments
                XCTAssertEqual(closedAgain, [], label)
                let reread = try await again.recording(id: id)
                XCTAssertEqual(reread.manifest, handle.manifest, label)
            }
        }
    }

    // MARK: Bridge mapping

    func testFindingsAndOverflowBecomeStoredGaps() {
        var accounting = SequenceAccounting(expectedStep: 2)
        let counters: [Double] = [0, 2, 6, 6, .nan]
        let findings = accounting.ingest(counters: counters[...], timestamps: [1, 2, 3, 4, 5][...])
        let chunk = SampleChunk(numRows: 1, count: 5, values: counters, drainedAtMonotonicNanos: 7, availableBeforeDrain: 5, overflowSuspected: true)
        let block = RecordingWriter.Block(chunk, findings: findings)
        XCTAssertEqual(block.gaps, [
            .init(afterSampleIndex: -1, evidence: .overflowSuspected, estimatedMissingSamples: nil, ambiguous: true),
            .init(afterSampleIndex: 1, evidence: .sequenceSkip, estimatedMissingSamples: 1, ambiguous: true),
            .init(afterSampleIndex: 2, evidence: .staleHalf, estimatedMissingSamples: nil, ambiguous: false),
            .init(afterSampleIndex: 3, evidence: .invalidCounter, estimatedMissingSamples: nil, ambiguous: false),
        ])
        XCTAssertEqual(block.values.count, 5)
        XCTAssertEqual(block.drainedAtMonotonicNanos, 7)
    }
}

/// Thread-safe call counter for `@Sendable` test closures.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { defer { n += 1 }; return n } }
}
