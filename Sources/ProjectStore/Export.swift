import Foundation

/// Portable evidence for one result (docs/export-format.md). Everything a reader needs
/// without the app: the samples as documented flat binary, the event table, the channel
/// map, the pipeline configuration, the fitted arrays, and `evaluation.json` byte-for-byte.
public struct ExportedRecording: Codable, Sendable, Equatable {
    public var manifest: RecordingManifest
    public var samples: SamplesHeader
    /// The cued runs' plans and the protocol versions they name (brief 005); absent for a
    /// recording without run plans, so older exports read the same.
    public var runPlans: RunPlansHeader?

    public init(manifest: RecordingManifest, samples: SamplesHeader, runPlans: RunPlansHeader? = nil) {
        self.manifest = manifest; self.samples = samples; self.runPlans = runPlans
    }

    /// `runs/<runID>.plan.json` and `protocols/<protocolID>/protocol.json`, copied byte for byte
    /// from the project. Only plans whose protocol version is stored with the same content
    /// hash are exported, and every protocol exported is named by one of them.
    public struct RunPlansHeader: Codable, Sendable, Equatable {
        public var plans: [RunPlanFile]
        public var protocols: [ProtocolFile]
        /// Plan files in the project that could not be read or failed validation.
        public var unreadable: Int
        /// Run ids of valid plans left out because the protocol version they name is missing,
        /// unreadable, or has a different content hash.
        public var unverified: [String]
    }

    public struct RunPlanFile: Codable, Sendable, Equatable {
        public var file: String
        public var runID: String
        public var runIndex: Int
        public var sessionID: String?
        public var protocolID: UUID
        public var protocolVersion: Int
        public var protocolContentHash: String
        public var seed: UInt64
        public var sha256: String
    }

    public struct ProtocolFile: Codable, Sendable, Equatable {
        public var file: String
        public var protocolID: UUID
        public var name: String
        public var version: Int
        public var contentHash: String
        public var sha256: String
    }

    /// How to read the `segment-<runID>[-<index>].f64` files: one per stream segment, every chunk
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

/// What an export left out, for the notice the user sees (empty when nothing was).
public struct ExportSummary: Sendable, Equatable {
    /// Run ids of valid plans not exported because their protocol couldn't be verified.
    public var unverifiedRunPlans: [String] = []
    /// Plan files in the project that couldn't be read or failed validation.
    public var unreadableRunPlans: Int = 0
    public var leftOutRunPlans: Int { unverifiedRunPlans.count + unreadableRunPlans }
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
    /// The folder is assembled as a `.tmp-<name>` sibling, fsynced, and renamed into
    /// place, so `destination` is complete or absent; any failure removes the temp.
    /// Every segment must be tiled by its chunks contiguously from sample 0 (the rule the
    /// worker applies too); a gap or overlap fails the export rather than shifting samples.
    @discardableResult
    public func export(result id: UUID, to destination: URL) throws -> ExportSummary {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw ProjectStoreError.alreadyExists(destination) }
        // Confinement first: `O_NOFOLLOW` guards only the last component, so a hostile
        // project could make `results/<id>` (or the pipeline or recording directory) a
        // symlink and have a regular file from elsewhere exported as its own.
        try confineToProject("results/\(id.uuidString)")
        let stored = try result(id: id)
        try confineToProject("pipelines/\(stored.pipeline.pipelineID.uuidString)")
        try confineToProject("recordings/\(stored.meta.recordingID.uuidString)/chunks")
        let handle = try recording(id: stored.meta.recordingID)
        let tmp = AtomicFile.tempURL(for: destination)
        if (try? fm.attributesOfItem(atPath: tmp.path)) != nil { try fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        do {
            let summary = try writeExport(stored, handle, into: tmp)
            try AtomicFile.syncTree(tmp)
            try AtomicFile.rename(tmp, to: destination)
            try AtomicFile.syncDirectory(destination.deletingLastPathComponent())
            return summary
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    private func writeExport(_ stored: StoredResult, _ handle: RecordingHandle, into out: URL) throws -> ExportSummary {
        let manifest = handle.manifest
        let channelRows = manifest.channels.map(\.sourceRow)
        let segments = manifest.segments.sorted(by: { $0.index < $1.index })
        let names = Self.segmentFileNames(segments)
        var files: [ExportedRecording.SegmentFile] = []
        for (segment, name) in zip(segments, names) {
            var data = Data()
            var sampleCount = 0
            // Transpose chunk-major storage into one channels × samples matrix per segment.
            var rows = [[Double]](repeating: [], count: channelRows.count)
            for entry in handle.chunks(inSegment: segment.index) {
                guard entry.firstSampleIndex == sampleCount else {
                    throw ProjectStoreError.invalidManifest("segment \(segment.index): chunk \(entry.index) starts at sample \(entry.firstSampleIndex), expected \(sampleCount)")
                }
                let chunk = try handle.chunk(entry)
                for (i, row) in channelRows.enumerated() {
                    // `validate` already rejected rows outside the chunk; this is the
                    // belt to that brace, so a future manifest edit cannot crash here.
                    let start = row * entry.sampleCount
                    guard row >= 0, start + entry.sampleCount <= chunk.count else {
                        throw ProjectStoreError.invalidManifest("channel row \(row) outside chunk \(entry.index) (\(entry.rowCount) rows)")
                    }
                    rows[i].append(contentsOf: chunk[start..<(start + entry.sampleCount)])
                }
                sampleCount += entry.sampleCount
            }
            data.reserveCapacity(channelRows.count * sampleCount * MemoryLayout<Double>.size)
            for row in rows {
                for v in row {
                    var le = v.bitPattern.littleEndian
                    withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
                }
            }
            try data.write(to: out.appendingPathComponent(name))
            files.append(.init(file: name, segment: segment.index, runID: segment.runID, sessionID: segment.sessionID,
                               sampleCount: sampleCount, sha256: AtomicFile.sha256Hex(data)))
        }

        let encoder = ContractJSON.encoder()
        let runPlans = try writeRunPlans(recording: handle.id, into: out)
        let recording = ExportedRecording(manifest: manifest, samples: .init(channelCount: channelRows.count,
                                                                             sampleRateHz: manifest.timing.nominalSampleRateHz, files: files),
                                          runPlans: runPlans)
        try encoder.encode(recording).write(to: out.appendingPathComponent("recording.json"))
        try encoder.encode(ExportedChannels(sampleRateHz: manifest.timing.nominalSampleRateHz, reference: manifest.reference,
                                            montage: manifest.montage, channels: manifest.channels))
            .write(to: out.appendingPathComponent("channels.json"))
        let events = handle.directory.appendingPathComponent(Self.eventsFileName)
        var st = stat()
        if lstat(events.path, &st) == 0 {
            try Self.regularFileBytes(events, as: "recordings/\(handle.id.uuidString)/\(Self.eventsFileName)").write(to: out.appendingPathComponent("events.jsonl"))
        } else {
            try Data().write(to: out.appendingPathComponent("events.jsonl"))
        }
        try encoder.encode(stored.pipeline).write(to: out.appendingPathComponent("pipeline.json"))
        try Self.regularFileBytes(fittedArraysURL(pipelineID: stored.pipeline.pipelineID),
                                  as: "pipelines/\(stored.pipeline.pipelineID.uuidString)/\(Self.fittedFileName)")
            .write(to: out.appendingPathComponent("model.npz"))
        try stored.evaluationJSON.write(to: out.appendingPathComponent("evaluation.json"))
        try encoder.encode(stored.meta).write(to: out.appendingPathComponent("result.meta.json"))
        try Data(Self.attribution(for: manifest).utf8).write(to: out.appendingPathComponent("ATTRIBUTION.md"))
        return ExportSummary(unverifiedRunPlans: runPlans?.unverified ?? [], unreadableRunPlans: runPlans?.unreadable ?? 0)
    }

    /// Copies the recording's verified run plans and exactly the protocol versions they name,
    /// the same bytes that were read and validated (one read each, so the copy is what was
    /// checked). Nil when the recording has no plan files at all.
    private func writeRunPlans(recording id: UUID, into out: URL) throws -> ExportedRecording.RunPlansHeader? {
        let found = try runPlanFiles(recording: id)
        guard !found.valid.isEmpty || found.unreadable > 0 else { return nil }
        var protocols: [UUID: (record: ProtocolRecord, bytes: Data)] = [:]
        var missing = Set<UUID>()
        for (plan, _) in found.valid where protocols[plan.protocolID] == nil && !missing.contains(plan.protocolID) {
            if let file = protocolFile(plan.protocolID) { protocols[plan.protocolID] = file } else { missing.insert(plan.protocolID) }
        }
        let verified = found.valid.filter { Self.matches($0.plan, protocols[$0.plan.protocolID].map { [$0.record] } ?? []) }
        let unverified = found.valid.filter { !Self.matches($0.plan, protocols[$0.plan.protocolID].map { [$0.record] } ?? []) }
        // Run ids are file names; two that differ only in case (possible on a case-sensitive
        // volume) would overwrite each other on APFS, so the export refuses rather than drop one.
        var seen = Set<String>()
        for (plan, _) in verified where !seen.insert(plan.runID.lowercased()).inserted {
            throw ProjectStoreError.invalidRunPlan("two run plans differ only in case (\(plan.runID))")
        }
        var plans: [ExportedRecording.RunPlanFile] = []
        var used: [UUID: ExportedRecording.ProtocolFile] = [:]
        if !verified.isEmpty {
            let runs = out.appendingPathComponent(Self.runsDirectoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: false)
            for (plan, bytes) in verified {
                let name = plan.runID + Self.runPlanSuffix
                try bytes.write(to: runs.appendingPathComponent(name), options: .withoutOverwriting)
                plans.append(.init(file: "\(Self.runsDirectoryName)/\(name)", runID: plan.runID, runIndex: plan.runIndex,
                                   sessionID: plan.sessionID, protocolID: plan.protocolID, protocolVersion: plan.protocolVersion,
                                   protocolContentHash: plan.protocolContentHash, seed: plan.seed, sha256: AtomicFile.sha256Hex(bytes)))
                guard used[plan.protocolID] == nil, let p = protocols[plan.protocolID] else { continue }
                let dir = out.appendingPathComponent("protocols/\(plan.protocolID.uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try p.bytes.write(to: dir.appendingPathComponent(Self.protocolFileName), options: .withoutOverwriting)
                used[plan.protocolID] = .init(file: "protocols/\(plan.protocolID.uuidString)/\(Self.protocolFileName)",
                                              protocolID: plan.protocolID, name: p.record.name, version: p.record.version,
                                              contentHash: p.record.contentHash, sha256: AtomicFile.sha256Hex(p.bytes))
            }
        }
        let protocolList = used.values.sorted { ($0.name, $0.version, $0.protocolID.uuidString) < ($1.name, $1.version, $1.protocolID.uuidString) }
        return .init(plans: plans, protocols: protocolList, unreadable: found.unreadable, unverified: unverified.map(\.plan.runID).sorted())
    }

    /// Requires every component of `relativePath` below the project root to be a real
    /// directory (lstat: no symbolic link anywhere on the way), and the resolved result to
    /// stay under the resolved root. Symlinks above the root (`/var` → `/private/var`)
    /// are the user's business and are allowed.
    func confineToProject(_ relativePath: String) throws {
        let root = directory.resolvingSymlinksInPath()
        var url = directory
        for component in relativePath.split(separator: "/").map(String.init) {
            url.appendPathComponent(component)
            var st = stat()
            guard lstat(url.path, &st) == 0 else { throw ProjectStoreError.io("lstat \(relativePath)", errno) }
            guard st.st_mode & S_IFMT == S_IFDIR else {
                throw ProjectStoreError.integrity([IntegrityIssue(kind: .outsideProject, file: relativePath,
                                                                  detail: "\(component) is a symbolic link or not a directory")])
            }
        }
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw ProjectStoreError.integrity([IntegrityIssue(kind: .outsideProject, file: relativePath, detail: "resolves outside the project")])
        }
    }

    /// The bytes of a project file that must be a regular file. A symbolic link (which
    /// `copyItem` would copy as a link to whatever it names), FIFO or device planted in a
    /// hostile project is an integrity error; the export carries bytes, never links.
    static func regularFileBytes(_ url: URL, as label: String) throws -> Data {
        let fd = Foundation.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            if code == ELOOP {
                throw ProjectStoreError.integrity([IntegrityIssue(kind: .notRegularFile, file: label, detail: "is a symbolic link")])
            }
            throw ProjectStoreError.io("open \(label)", code)
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else {
            throw ProjectStoreError.integrity([IntegrityIssue(kind: .notRegularFile, file: label, detail: "is not a regular file")])
        }
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
    }

    /// `segment-<runID>.f64` per segment, with the run id made file-safe. When two
    /// segments would get the same name (a reconnect within one run, or two run ids that
    /// differ only in unsafe characters or case, which APFS folds), each colliding one
    /// gets its segment index appended: `segment-<runID>-<index>.f64`.
    static func segmentFileNames(_ segments: [RecordingManifest.StreamSegment]) -> [String] {
        let bases = segments.map { "segment-\(fileSafe($0.runID))" }
        var counts: [String: Int] = [:]
        for base in bases { counts[base.lowercased(), default: 0] += 1 }
        var used = Set<String>()
        return zip(segments, bases).map { segment, base in
            var name = counts[base.lowercased()]! > 1 ? "\(base)-\(segment.index)" : base
            while used.contains(name.lowercased()) { name += "_" }
            used.insert(name.lowercased())
            return name + ".f64"
        }
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
