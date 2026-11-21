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
        // An overflow warning on the new segment's first drain sits before its sample 0.
        writer.submit(Self.block(from: 0, count: 130, segment: 1,
                                 gaps: [.init(afterSampleIndex: -1, evidence: .overflowSuspected, estimatedMissingSamples: nil, ambiguous: true)]))
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
        XCTAssertEqual(segs[0].uncommittedSampleCount, 130, "drained after segment 0 closed: counted there")
        XCTAssertNil(segs[1].uncommittedSampleCount)
        XCTAssertEqual(segs[1].detectedGaps.map(\.afterSampleIndex), [-1], "segment-relative, not offset by segment 0")
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
            // Whatever the step, the failed chunk is not on disk unlisted (its file is removed to
            // free space) and is not counted as committed: the disk manifest is the truth.
            XCTAssertEqual(handle.verify(), [], label)
            XCTAssertEqual(handle.manifest.chunks.count, 1, label)
            XCTAssertEqual(status.committedSamples, 125, label)
            XCTAssertEqual(handle.manifest.segments[0].uncommittedSampleCount, 275, label)
            XCTAssertEqual(status.committedSamples + status.uncommittedSamples, 400, "every sample accounted for: \(label)")
        }
    }

    func testCloseFailsOnAFullDisk_reasonSurvivesInTheLockFileForTheNextOpen() async throws {
        var options = RecordingWriter.Options()
        options.fault = WriteFault { p, index in (p == .afterTmpWrite && index == 1) || index == -1 ? ENOSPC : nil }
        let (store, writer) = try await start(options: options)
        writer.submit(Self.block(from: 0, count: 300))
        let status = await writer.finish()
        XCTAssertEqual(status.endReason, .diskFull)
        XCTAssertEqual(status.uncommittedSamples, 175)
        XCTAssertTrue(status.failure?.contains("segment 0 not closed") == true, status.failure ?? "")
        let reopened = try ProjectStore.open(at: store.directory)
        let handle = try await reopened.recording(id: writer.recordingID)
        let seg = handle.manifest.segments[0]
        XCTAssertEqual(seg.endReason, .diskFull, "not process_terminated: the writer was alive and said why")
        XCTAssertEqual(seg.uncommittedSampleCount, 175)
        XCTAssertEqual(seg.detectedGaps, [])
        XCTAssertEqual(handle.verify(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: handle.directory.appendingPathComponent(".writer.lock").path))
    }

    /// A failed non-final close leaves a note; the next successful save (the following
    /// segment's first chunk) clears it, so a later kill can't apply it to that segment.
    func testFailedSegmentEnd_noteIsClearedByTheNextSave() async throws {
        let failures = Counter()
        var options = RecordingWriter.Options(timestampRow: Self.timestampRow)
        options.fault = WriteFault { _, index in index == -1 && failures.next() < 2 ? EIO : nil }
        let (store, writer) = try await start(options: options)
        let lockFile = store.recordingDirectory(writer.recordingID).appendingPathComponent(".writer.lock")
        func note() -> String { (try? String(contentsOf: lockFile, encoding: .utf8))?.trimmingCharacters(in: .whitespaces) ?? "<missing>" }

        writer.submit(Self.block(from: 0, count: 125))
        writer.endSegment(.disconnect, endedAtMonotonicNanos: 2_000_000_000)
        try await waitFor("the failed close") { writer.status.failure?.contains("segment 0 not closed") == true }
        XCTAssertEqual(note(), "0 disconnect 0 2000000000", "the note names its segment")

        writer.beginSegment(startedAtWall: Date(), startedAtMonotonicNanos: 3_000_000_000)
        writer.submit(Self.block(from: 0, count: 125, segment: 1))
        try await waitFor("segment 1's first chunk") { writer.status.committedChunks == 2 }
        XCTAssertEqual(note(), "", "segment 0 is closed on disk now; its note is obsolete")
        XCTAssertNil(writer.status.endReason, "a failed non-final close lets the recording continue")

        let status = await writer.finish()
        XCTAssertEqual(status.endReason, .stopped)
        let handle = try await ProjectStore.open(at: store.directory).recording(id: writer.recordingID)
        XCTAssertEqual(handle.manifest.segments.map(\.endReason), [.disconnect, .stopped])
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockFile.path))
    }

    /// A clean stop whose close can't be written is closed `error` by the next open, never `stopped`.
    func testFailedCloseOfAStop_isClosedAsErrorByTheNextOpen() async throws {
        var options = RecordingWriter.Options(timestampRow: Self.timestampRow)
        options.fault = WriteFault { _, index in index == -1 ? EIO : nil }
        let (store, writer) = try await start(options: options)
        writer.submit(Self.block(from: 0, count: 125))
        let status = await writer.finish()
        XCTAssertTrue(status.failure?.contains("segment 0 not closed") == true, status.failure ?? "")
        let seg = try await ProjectStore.open(at: store.directory).recording(id: writer.recordingID).manifest.segments[0]
        XCTAssertEqual(seg.endReason, .error)
        XCTAssertEqual(seg.detectedGaps, [])
    }

    /// `open` applies a lock note only to the segment it names, and only if it is plausible.
    func testOpen_appliesALockNoteOnlyToItsOwnPlausibleSegment() async throws {
        let cases: [(note: String, reason: EndReason, uncommitted: Int?)] = [
            ("1 disk_full 40 3000000000", .diskFull, 40),                    // its segment: used
            ("0 disk_full 40 3000000000", .processTerminated, nil),          // stale: names segment 0
            ("1 stopped 0 3000000000", .processTerminated, nil),             // a failed close never says stopped
            ("1 disk_full 9999999 3000000000", .processTerminated, nil),    // more than 1 s × 2 × 125 Hz could bring
            ("1 disk_full 40 500000000", .processTerminated, nil),           // ended before it started
            ("disk_full 40", .processTerminated, nil),                       // old format
        ]
        for (i, c) in cases.enumerated() {
            let store = try ProjectStore.create(at: scratch.appendingPathComponent("note\(i).bciproj"), name: "n")
            var m = manifest()
            m.segments = [
                .init(index: 0, sessionID: "s", runID: "r", startedAtWall: Date(), startedAtMonotonicNanos: 1,
                      endedAtMonotonicNanos: 1_000_000_000, endReason: .disconnect, detectedGaps: []),
                .init(index: 1, sessionID: "s", runID: "r", startedAtWall: Date(), startedAtMonotonicNanos: 2_000_000_000,
                      endedAtMonotonicNanos: nil, endReason: nil, detectedGaps: []),
            ]
            let (_, lock) = try await store.createLiveRecording(m, hook: nil, fault: nil)
            lock.release(keepFile: true)   // the writer died with this note in its lock file
            let lockFile = store.recordingDirectory(m.recordingID).appendingPathComponent(".writer.lock")
            try Data(c.note.utf8).write(to: lockFile)
            let seg = try await ProjectStore.open(at: store.directory).recording(id: m.recordingID).manifest.segments[1]
            XCTAssertEqual(seg.endReason, c.reason, c.note)
            XCTAssertEqual(seg.uncommittedSampleCount, c.uncommitted, c.note)
            XCTAssertEqual(seg.detectedGaps.map(\.evidence), c.reason == .processTerminated ? [.processTerminated] : [], c.note)
        }
    }

    func testUnreadableFreeSpace_failsSafe() async throws {
        var options = RecordingWriter.Options()
        options.freeBytes = { _ in nil }
        let (_, writer) = try await start(options: options)
        writer.submit(Self.block(from: 0, count: 125))
        let status = await writer.finish()
        XCTAssertEqual(status.endReason, .error)
        XCTAssertEqual(status.uncommittedSamples, 125)
    }

    func testReleasedWithoutFinish_commitsTheBufferAndClosesAsError() async throws {
        let store = try ProjectStore.create(at: scratch.appendingPathComponent("dropped.bciproj"), name: "d")
        var id: UUID!
        do {
            let writer = try await RecordingWriter.start(in: store, manifest: manifest(), startedAtWall: Date(), startedAtMonotonicNanos: 1)
            id = writer.recordingID
            writer.submit(Self.block(from: 0, count: 50))
        }
        var seg: RecordingManifest.StreamSegment?
        try await waitFor("the released writer to close its segment") {
            seg = (try? RecordingHandle(directory: store.recordingDirectory(id)))?.manifest.segments.first
            return seg?.endReason != nil
        }
        XCTAssertEqual(seg?.endReason, .error)
        let handle = try await store.recording(id: id)
        XCTAssertEqual(handle.manifest.chunks.map(\.sampleCount), [50], "the partial chunk is committed, not dropped")
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
        XCTAssertEqual(rawHandle.verify(), [], "the failed chunk is removed, not left unlisted")
        XCTAssertEqual(raw.committedSamples, rawHandle.manifest.chunks.reduce(0) { $0 + $1.sampleCount }, "committed = listed")
        // Closed by the writer, or (no room even for that) by the next open from the lock note.
        let reopened = try await ProjectStore.open(at: store.directory).recording(id: rawHandle.id)
        XCTAssertEqual(reopened.manifest.segments[0].endReason, .diskFull)
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
        guard ProcessInfo.processInfo.environment["BCI_SOAK"] == "1" else {
            throw XCTSkip("about 2 minutes of fsyncs; run with BCI_SOAK=1 (TEST_RUNNER_BCI_SOAK=1 via xcodebuild)")
        }
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

    /// Always-on short soak: 200 chunks, and the per-commit time does not grow with the
    /// manifest (median of the last 50 vs the first 50). No wall-clock budget, so no flake.
    func testShortSoak_commitTimeDoesNotGrow() async throws {
        let (_, writer) = try await start("short-soak")
        var first: [Int64] = [], k = 0
        while writer.status.committedChunks < 200 {
            if first.isEmpty, writer.status.committedChunks >= 50 { first = Array(writer.status.recentCommitDurationsNanos.prefix(50)) }
            if k < 200 * 125, writer.status.backlogChunks < 3 {
                writer.submit(Self.block(from: k, count: 125)); k += 125
            } else {
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        let last = Array(writer.status.recentCommitDurationsNanos.suffix(50))
        await writer.finish()
        func median(_ v: [Int64]) -> Double { Double(v.sorted()[v.count / 2]) / 1e6 }
        XCTAssertEqual(first.count, 50)
        XCTAssertLessThanOrEqual(median(last), 2 * median(first) + 10, "first \(median(first)) ms, last \(median(last)) ms")
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

    func testOpenRacingAFinishingWriter_neverOverwritesItsManifest() async throws {
        let (store, writer) = try await start()
        writer.submit(Self.block(from: 0, count: 250))
        try await waitFor("two chunks") { writer.status.committedChunks == 2 }
        // Between open's unlocked first look (segment open, 2 chunks) and its lock attempt,
        // the writer commits a third chunk, finishes and drops its lock.
        let report: [String] = await withCheckedContinuation { done in
            DispatchQueue.global().async {
                let report = ProjectStore.closeUnterminatedSegments(in: store.directory, afterPrecheck: {
                    let finished = DispatchSemaphore(value: 0)
                    Task.detached {
                        writer.submit(Self.block(from: 250, count: 125))
                        await writer.finish()
                        finished.signal()
                    }
                    finished.wait()
                })
                done.resume(returning: report)
            }
        }
        XCTAssertEqual(report, [])
        let handle = try await store.recording(id: writer.recordingID)
        XCTAssertEqual(handle.manifest.chunks.count, 3, "the chunk committed after the first look is kept")
        XCTAssertEqual(handle.manifest.segments[0].endReason, .stopped)
        XCTAssertEqual(handle.manifest.segments[0].detectedGaps, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: handle.directory.appendingPathComponent(".writer.lock").path))
    }

    func testHostileManifestWithOverflowingSampleRange_isRefusedNotTrapped() async throws {
        let url = scratch.appendingPathComponent("hostile.bciproj")
        let store = try ProjectStore.create(at: url, name: "h")
        var m = manifest()
        m.segments = [.init(index: 0, sessionID: nil, runID: "r", startedAtWall: Date(), startedAtMonotonicNanos: 0,
                            endedAtMonotonicNanos: nil, endReason: nil, detectedGaps: [])]
        let writer = try await store.createRecording(m)
        try await writer.append(ChunkPayload(samples: [1, 2], rowCount: 2, sampleCount: 1, segment: 0, firstSampleIndex: 0,
                                             drainedAtMonotonicNanos: 1))
        var crafted = await writer.manifest
        crafted.channels = [ChannelSpec(id: "ch01", label: "a", kind: "eeg", unit: "uV", sourceRow: 1)]
        crafted.chunks[0].firstSampleIndex = Int.max
        let file = url.appendingPathComponent("recordings/\(m.recordingID.uuidString)/recording.json")
        try ContractJSON.encoder().encode(crafted).write(to: file)

        XCTAssertThrowsError(try RecordingHandle(directory: file.deletingLastPathComponent())) { error in
            XCTAssertTrue("\(error)".contains("overflows"), "\(error)")
        }
        let reopened = try ProjectStore.open(at: url)      // must not trap
        let closed = await reopened.closedSegments
        XCTAssertEqual(closed, [])
        XCTAssertEqual(try Data(contentsOf: file), try ContractJSON.encoder().encode(crafted), "left exactly as found")
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
