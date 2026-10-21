import Foundation

/// Portable evidence for one result (docs/export-format.md). Everything a reader needs
/// without the app: the samples as documented flat binary, the event table, the channel
/// map, the pipeline configuration, the fitted arrays, and `evaluation.json` byte-for-byte.
public struct ExportedRecording: Codable, Sendable, Equatable {
    public var manifest: RecordingManifest
    public var samples: SamplesHeader

    /// How to read the `segment-<runID>.f64` files: one per stream segment, every chunk
    /// of that segment concatenated, only the channel rows (in `manifest.channels` order),
    /// `channelCount × sampleCount` float64 little-endian, row-major, no header.
    public struct SamplesHeader: Codable, Sendable, Equatable {
        public var dtype: String = "float64"
        public var byteOrder: String = "little"
        public var layout: String = "row-major: channelCount rows × sampleCount columns, channel i = manifest.channels[i]"
        public var channelCount: Int
        public var sampleRateHz: Double
        public var files: [SegmentFile]
    }

    public struct SegmentFile: Codable, Sendable, Equatable {
        public var file: String
        public var segment: Int
        public var runID: String
        public var sessionID: String?
        public var sampleCount: Int
        public var sha256: String
    }
}

/// `channels.json`: the channel map alone, for readers that want nothing else.
public struct ExportedChannels: Codable, Sendable, Equatable {
    public var sampleRateHz: Double
    public var reference: String
    public var montage: String
    public var channels: [ChannelSpec]
}

extension ProjectStore {
    public static let exportFileNames = ["recording.json", "events.jsonl", "channels.json", "pipeline.json",
                                         "model.npz", "evaluation.json", "result.meta.json", "ATTRIBUTION.md"]

    /// Writes the export folder for `result` at `destination` (which must not exist).
    public func export(result id: UUID, to destination: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw ProjectStoreError.alreadyExists(destination) }
        let stored = try result(id: id)
        let handle = try recording(id: stored.meta.recordingID)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let manifest = handle.manifest
        let channelRows = manifest.channels.map(\.sourceRow)
        var files: [ExportedRecording.SegmentFile] = []
        for segment in manifest.segments.sorted(by: { $0.index < $1.index }) {
            var out = Data()
            var sampleCount = 0
            // Transpose chunk-major storage into one channels × samples matrix per segment.
            var rows = [[Double]](repeating: [], count: channelRows.count)
            for entry in handle.chunks(inSegment: segment.index) {
                let chunk = try handle.chunk(entry)
                for (i, row) in channelRows.enumerated() {
                    let start = row * entry.sampleCount
                    rows[i].append(contentsOf: chunk[start..<(start + entry.sampleCount)])
                }
                sampleCount += entry.sampleCount
            }
            out.reserveCapacity(channelRows.count * sampleCount * MemoryLayout<Double>.size)
            for row in rows {
                for v in row {
                    var le = v.bitPattern.littleEndian
                    withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
                }
            }
            let name = "segment-\(Self.fileSafe(segment.runID)).f64"
            try out.write(to: destination.appendingPathComponent(name))
            files.append(.init(file: name, segment: segment.index, runID: segment.runID, sessionID: segment.sessionID,
                               sampleCount: sampleCount, sha256: AtomicFile.sha256Hex(out)))
        }

        let encoder = ContractJSON.encoder()
        let recording = ExportedRecording(manifest: manifest, samples: .init(channelCount: channelRows.count,
                                                                             sampleRateHz: manifest.timing.nominalSampleRateHz, files: files))
        try encoder.encode(recording).write(to: destination.appendingPathComponent("recording.json"))
        try encoder.encode(ExportedChannels(sampleRateHz: manifest.timing.nominalSampleRateHz, reference: manifest.reference,
                                            montage: manifest.montage, channels: manifest.channels))
            .write(to: destination.appendingPathComponent("channels.json"))
        let events = handle.directory.appendingPathComponent(Self.eventsFileName)
        if fm.fileExists(atPath: events.path) {
            try fm.copyItem(at: events, to: destination.appendingPathComponent("events.jsonl"))
        } else {
            try Data().write(to: destination.appendingPathComponent("events.jsonl"))
        }
        try encoder.encode(stored.pipeline).write(to: destination.appendingPathComponent("pipeline.json"))
        try fm.copyItem(at: fittedArraysURL(pipelineID: stored.pipeline.pipelineID), to: destination.appendingPathComponent("model.npz"))
        try stored.evaluationJSON.write(to: destination.appendingPathComponent("evaluation.json"))
        try encoder.encode(stored.meta).write(to: destination.appendingPathComponent("result.meta.json"))
        try Data(Self.attribution(for: manifest).utf8).write(to: destination.appendingPathComponent("ATTRIBUTION.md"))
    }

    /// The attribution text shown in the example's info panel and written to every
    /// export; built from the manifest, never hard-coded, so it follows the recording.
    public static func attribution(for manifest: RecordingManifest) -> String {
        let s = manifest.source
        var lines = ["# Attribution", ""]
        if let warning = s.warning { lines += ["**\(warning).**", ""] }
        if let dataset = s.dataset {
            var line = "Source: \(dataset)"
            if let doi = s.doi { line += " (doi:\(doi))" }
            if let subject = s.subject { line += ", subject \(subject)" }
            if let runs = s.runs { line += ", runs \(runs.joined(separator: ", "))" }
            lines += [line + ".", ""]
        } else {
            lines += ["Source: \(s.kind) recording on \(s.boardName), BrainFlow \(s.brainflowVersion), written by \(s.appVersion).", ""]
        }
        if let license = s.license { lines += ["License: \(license).", ""] }
        if let citations = s.attribution, !citations.isEmpty {
            lines += ["## Please cite", ""]
            lines += citations.map { "- \($0.text) doi:\($0.doi)" }
            lines += [""]
        }
        if let derivations = s.derivations, !derivations.isEmpty {
            lines += ["## Conversions applied on import", ""]
            lines += derivations.map { "- \($0)" }
            lines += [""]
        }
        return lines.joined(separator: "\n")
    }

    private static func fileSafe(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }
}
