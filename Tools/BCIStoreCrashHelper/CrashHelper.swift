import Foundation

/// Crash-injection helper for the project-store tests (test plan, criterion 8).
///
///     BCIStoreCrashHelper <project directory> <chunk count> [recording]
///     CRASH_AT=<afterTmpWrite|afterFsync|afterRename|afterManifestWrite>:<chunk index>
///
/// Creates a project with one recording, commits `chunk count` deterministic chunks
/// (plus one event per chunk), and `_exit(9)`s — no cleanup, no flush — the moment the
/// named commit point of the named chunk is reached. Without `CRASH_AT` it exits 0 after
/// the last commit. The test reopens the directory and checks what survived.
///
/// `recording` mode drives `RecordingWriter` instead (brief 004): `chunk count` × 125
/// samples plus a 50-sample tail, submitted in 37-sample blocks so re-chunking runs, then
/// `finish(.stopped)`. Sample `k` of row `r` is `k * 10 + r` (`recordingValue`).
@main
struct CrashHelper {
    static func main() async {
        let args = CommandLine.arguments
        guard (3...4).contains(args.count), let count = Int(args[2]), args.count == 3 || args[3] == "recording" else {
            FileHandle.standardError.write(Data("usage: BCIStoreCrashHelper <project dir> <chunk count> [recording]\n".utf8))
            exit(64)
        }
        let crashAt = ProcessInfo.processInfo.environment["CRASH_AT"].flatMap(Self.parse)
        do {
            let url = URL(fileURLWithPath: args[1], isDirectory: true)
            if args.count == 4 {
                try await record(at: url, chunks: count, crashAt: crashAt)
            } else {
                try await run(at: url, chunks: count, crashAt: crashAt)
            }
        } catch {
            FileHandle.standardError.write(Data("helper failed: \(error)\n".utf8))
            exit(1)
        }
    }

    static func parse(_ spec: String) -> (CommitHook.Point, Int)? {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let point = CommitHook.Point(rawValue: parts[0]), let index = Int(parts[1]) else { return nil }
        return (point, index)
    }

    static let rows = 4
    static let samplesPerChunk = 50

    /// The exact sample values chunk `index` must contain, so the test can check the
    /// committed prefix's bytes and not just its hashes.
    static func samples(forChunk index: Int) -> [Double] {
        (0..<(rows * samplesPerChunk)).map { Double(index * 1000 + $0) * 0.5 }
    }

    static func recordingValue(sample k: Int, row r: Int) -> Double { Double(k * 10 + r) }

    static func record(at url: URL, chunks: Int, crashAt: (CommitHook.Point, Int)?) async throws {
        let store = try ProjectStore.create(at: url, name: "crash-helper")
        var options = RecordingWriter.Options()
        options.hook = hook(crashAt)
        let writer = try await RecordingWriter.start(in: store, manifest: manifest(), startedAtWall: t0, startedAtMonotonicNanos: 0, options: options)
        let total = chunks * RecordingWriter.samplesPerChunk + 50
        for start in stride(from: 0, to: total, by: 37) {
            let n = min(37, total - start)
            let values = (0..<rows).flatMap { r in (start..<(start + n)).map { recordingValue(sample: $0, row: r) } }
            writer.submit(.init(values: values, rowCount: rows, sampleCount: n, drainedAtMonotonicNanos: Int64(start + n) * 1_000_000))
        }
        let status = await writer.finish(.stopped, endedAtMonotonicNanos: Int64(total) * 1_000_000)
        if let failure = status.failure { throw ProjectStoreError.invalidChunk(failure) }
    }

    static func hook(_ crashAt: (CommitHook.Point, Int)?) -> CommitHook {
        CommitHook { point, index in
            if let crashAt, crashAt.0 == point, crashAt.1 == index { _exit(9) }
        }
    }

    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    static func manifest() -> RecordingManifest {
        RecordingManifest(
            recordingID: UUID(uuidString: "00000000-0000-4000-8000-00000000c0de")!,
            sessionID: "helper-session", runID: "helper-run", createdAt: t0,
            source: .init(kind: "synthetic", boardID: nil, boardName: "crash-helper", dataPath: nil, brainflowVersion: "n/a", appVersion: "test"),
            channels: (0..<rows).map { ChannelSpec(id: String(format: "ch%02d", $0), label: "ch\($0)", kind: "eeg", unit: "uV", sourceRow: $0) },
            reference: "none", montage: "unspecified",
            timing: .init(nominalSampleRateHz: 50, timestampClock: .hostWall, timestampGeneratedBy: "none",
                          sequenceCounterRow: nil, sequenceStep: 1, notes: "crash helper"),
            clockMapping: .init(anchorMonotonicNanos: 0, anchorWall: t0),
            boardConfiguration: .init(requested: [:], readback: [:]),
            chunks: [],
            segments: [.init(index: 0, sessionID: "helper-session", runID: "helper-run", startedAtWall: t0, startedAtMonotonicNanos: 0,
                             endedAtMonotonicNanos: nil, endReason: nil, detectedGaps: [])])
    }

    static func run(at url: URL, chunks: Int, crashAt: (CommitHook.Point, Int)?) async throws {
        let store = try ProjectStore.create(at: url, name: "crash-helper")
        let manifest = manifest()
        let writer = try await store.createRecording(manifest, hook: hook(crashAt))
        for i in 0..<chunks {
            try await writer.append(ChunkPayload(samples: samples(forChunk: i), rowCount: rows, sampleCount: samplesPerChunk,
                                                 segment: 0, firstSampleIndex: i * samplesPerChunk,
                                                 drainedAtMonotonicNanos: Int64(i + 1) * 1_000_000_000))
            try await writer.appendEvent(EventRecord(eventID: UUID(), sessionID: "helper-session", runID: "helper-run", trialID: "t\(i)",
                                                     label: "cue_left", origin: "protocol", intendedAtMonotonicNanos: nil,
                                                     presentedAtMonotonicNanos: nil, sourceTimeNanos: nil, wallTime: t0,
                                                     sampleAssociation: .init(recordingID: manifest.recordingID, segment: 0,
                                                                              sampleIndex: i * samplesPerChunk, method: "test"),
                                                     timingUncertaintyNanos: nil))
        }
    }
}
