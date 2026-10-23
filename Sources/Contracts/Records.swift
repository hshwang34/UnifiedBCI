import Foundation

// Core project-store records from the PRD (section 7, "Data contracts and storage").
// These are the on-disk JSON shapes. They are versioned by `ProjectManifest.formatVersion`;
// any field change that an older reader could misinterpret bumps that number.
// See docs/data-contracts.md for byte layout of sample chunks and the rules behind each field.

public enum ContractVersion {
    public static let format = 1
}

/// JSON coding pinned for every manifest: ISO-8601 dates **with fractional seconds**
/// (`2026-10-20T04:05:06.789Z`), sorted keys, no NaN. Foundation's default `.iso8601`
/// strategy drops fractions, so a `Date` would not round-trip through it.
public enum ContractJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(makeFormatter().string(from: date))
        }
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = makeFormatter().date(from: s) { return date }
            // Accept whole-second stamps from hand-written files; we never write them.
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO-8601 date: \(s)")
        }
        return d
    }

    private static func makeFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
}

/// The app's monotonic clock: `CLOCK_MONOTONIC_RAW` nanoseconds since boot. Not affected
/// by NTP slewing or sleep adjustments; meaningless across reboots or machines, which is
/// why every recording carries a `ClockMapping` anchor.
public enum HostMonotonicClock {
    public static let epochDescription = "CLOCK_MONOTONIC_RAW nanoseconds since boot"

    public static func nowNanos() -> Int64 {
        Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW))
    }
}

/// Which clock a time value came from. Never mix values from different clocks.
public enum ClockDomain: String, Codable, Sendable {
    /// BrainFlow's timestamp row: the **host wall clock via `gettimeofday`** (seconds, µs
    /// resolution) taken when BrainFlow parsed the packet. Not monotonic (NTP can step it
    /// backwards), not an ADC clock. Never use it for gap detection.
    case brainflowReceipt = "brainflow_receipt"
    /// `HostMonotonicClock` on the app, taken when the chunk was drained or a cue presented.
    case hostMonotonic = "host_monotonic"
    /// Wall clock (`Date`), for humans and cross-machine correlation only.
    case hostWall = "host_wall"
}

/// One anchor pair relating the monotonic clock to wall time, taken at recording start.
public struct ClockMapping: Codable, Sendable, Equatable {
    public var monotonicEpoch: String = HostMonotonicClock.epochDescription
    public var anchorMonotonicNanos: Int64
    public var anchorWall: Date

    public init(anchorMonotonicNanos: Int64, anchorWall: Date) {
        self.anchorMonotonicNanos = anchorMonotonicNanos
        self.anchorWall = anchorWall
    }
}

public enum Validity: String, Codable, Sendable {
    case valid
    case insufficientWindow = "insufficient_window"
    case stale
    case disconnected
    case workerUnavailable = "worker_unavailable"
    case channelMismatch = "channel_mismatch"
}

public enum GapEvidence: String, Codable, Sendable {
    /// Sequence counter advanced by more than the board's step.
    case sequenceSkip = "sequence_skip"
    /// Counter repeated (Daisy: one half of a packet pair was lost; the sample mixes halves).
    case staleHalf = "stale_half"
    /// Counter repeated on a step-1 board: a duplicated packet, not a loss. Provenance only.
    case duplicateCounter = "duplicate_counter"
    /// Counter value was not a finite integer; the sample's position in the sequence is unknown.
    case invalidCounter = "invalid_counter"
    /// Receipt interval looked long, but no counter evidence. `estimatedMissingSamples` is nil.
    case receiptInterval = "receipt_interval"
    /// BrainFlow's ring buffer was near full at drain time; it drops oldest silently.
    case overflowSuspected = "overflow_suspected"
    /// Wall-clock timestamp stepped backwards. Not a data gap; recorded for provenance.
    case clockAnomaly = "clock_anomaly"
    /// The app was killed while BrainFlow still held buffered samples.
    case processTerminated = "process_terminated"
    case disconnect
}

public enum EndReason: String, Codable, Sendable {
    case stopped
    case disconnect
    case workerFailure = "worker_failure"
    case diskFull = "disk_full"
    case processTerminated = "process_terminated"
    case error
}

/// Which Cyton data path produced the samples. They differ in rate and are never mixed.
public enum DataPath: String, Codable, Sendable {
    /// Dongle radio link: Cyton+Daisy at 125 Hz, alternating board/Daisy packets.
    case radio125 = "radio_125"
    /// On-board SD card: 250 Hz, imported later. A different recording, not a resample.
    case sd250 = "sd_250"
}

public struct ChannelSpec: Codable, Sendable, Equatable {
    public var id: String          // stable within a recording, e.g. "ch03"
    public var label: String       // user-declared, e.g. "C3"; never inferred from channel count
    public var kind: String        // "eeg", "accel", "aux", ...
    public var unit: String        // "uV" for BrainFlow-scaled Cyton EEG rows
    public var sourceRow: Int      // row in the BrainFlow sample matrix

    public init(id: String, label: String, kind: String, unit: String, sourceRow: Int) {
        self.id = id; self.label = label; self.kind = kind; self.unit = unit; self.sourceRow = sourceRow
    }
}

public struct TimingSemantics: Codable, Sendable, Equatable {
    public var nominalSampleRateHz: Double
    public var timestampClock: ClockDomain
    public var timestampGeneratedBy: String   // "host" | "device"; Cyton over dongle = "host"
    public var sequenceCounterRow: Int?       // BrainFlow package_num row, wraps at 256 on Cyton
    /// Expected counter increment per committed sample: 1 for most boards, 2 for Cyton+Daisy
    /// (BrainFlow writes the even Daisy packet's counter once per packet pair).
    public var sequenceStep: Int
    public var notes: String

    public init(nominalSampleRateHz: Double, timestampClock: ClockDomain, timestampGeneratedBy: String,
                sequenceCounterRow: Int?, sequenceStep: Int, notes: String) {
        self.nominalSampleRateHz = nominalSampleRateHz
        self.timestampClock = timestampClock
        self.timestampGeneratedBy = timestampGeneratedBy
        self.sequenceCounterRow = sequenceCounterRow
        self.sequenceStep = sequenceStep
        self.notes = notes
    }
}

/// `project.json`: the root of a `.bciproj` directory. It carries no index of its
/// children: the `recordings/`, `pipelines/`, `results/` directory scan is the truth, so a
/// crash between writing a child and updating an index can never hide or invent one.
public struct ProjectManifest: Codable, Sendable, Equatable {
    public var formatVersion: Int = ContractVersion.format
    public var name: String
    public var created: Date

    public init(name: String, created: Date) {
        self.name = name; self.created = created
    }
}

public struct RecordingManifest: Codable, Sendable, Equatable {
    public var formatVersion: Int = ContractVersion.format
    public var recordingID: UUID
    /// Grouping keys for splits: a session is one sitting (cap on, same montage); a run is
    /// one start-to-stop acquisition inside it. Derivable from stored data, never inferred:
    /// `sessionID` is nil when the source does not define one (e.g. a public dataset whose
    /// documentation does not say which runs were one sitting), and the worker then reports
    /// `unknown-session` evidence rather than claiming `same-session`.
    public var sessionID: String?
    public var runID: String
    public var createdAt: Date
    public var source: Source
    public var channels: [ChannelSpec]
    public var reference: String              // user-declared, e.g. "earclips (SRB2)"
    public var montage: String                // free text or named map id; explicit, never inferred
    public var timing: TimingSemantics
    public var clockMapping: ClockMapping
    public var boardConfiguration: BoardConfiguration
    public var chunks: [ChunkEntry]
    public var segments: [StreamSegment]

    public init(recordingID: UUID, sessionID: String?, runID: String, createdAt: Date, source: Source,
                channels: [ChannelSpec], reference: String, montage: String, timing: TimingSemantics,
                clockMapping: ClockMapping, boardConfiguration: BoardConfiguration,
                chunks: [ChunkEntry], segments: [StreamSegment]) {
        self.recordingID = recordingID; self.sessionID = sessionID; self.runID = runID
        self.createdAt = createdAt; self.source = source; self.channels = channels
        self.reference = reference; self.montage = montage; self.timing = timing
        self.clockMapping = clockMapping; self.boardConfiguration = boardConfiguration
        self.chunks = chunks; self.segments = segments
    }

    public struct Source: Codable, Sendable, Equatable {
        public var kind: String               // "brainflow", "synthetic", "public_dataset"
        public var boardID: Int32?            // nil unless BrainFlow produced the samples
        /// BrainFlow board name, or for `public_dataset` the original acquisition device
        /// as the dataset documents it (e.g. "BCI2000 / g.tec (per Schalk 2004)").
        public var boardName: String
        public var dataPath: DataPath?        // nil for synthetic/imported sources
        public var brainflowVersion: String   // "n/a" when BrainFlow was not involved
        public var appVersion: String         // app, or the dev-time converter that wrote it
        // Provenance for `public_dataset` sources; all nil for live recordings. The UI shows
        // `warning` on the first line of the source panel and `attribution` in the info panel
        // and in every export, so a bundled recording is never mistaken for the user's device.
        public var dataset: String?           // "PhysioNet EEG Motor Movement/Imagery v1.0.0"
        public var doi: String?
        public var license: String?           // "ODC-BY 1.0"
        public var subject: String?           // dataset subject id, e.g. "S001"
        public var runs: [String]?            // dataset run ids in segment order
        public var warning: String?
        public var attribution: [Citation]?
        /// Explicit conversions applied on import (channel crop, unit scaling, ...). Nothing
        /// not listed here happened to the samples; resampling is never one of them.
        public var derivations: [String]?
        public var sourceFiles: [SourceFile]?

        public init(kind: String, boardID: Int32?, boardName: String, dataPath: DataPath?, brainflowVersion: String, appVersion: String,
                    dataset: String? = nil, doi: String? = nil, license: String? = nil, subject: String? = nil, runs: [String]? = nil,
                    warning: String? = nil, attribution: [Citation]? = nil, derivations: [String]? = nil, sourceFiles: [SourceFile]? = nil) {
            self.kind = kind; self.boardID = boardID; self.boardName = boardName
            self.dataPath = dataPath; self.brainflowVersion = brainflowVersion; self.appVersion = appVersion
            self.dataset = dataset; self.doi = doi; self.license = license; self.subject = subject; self.runs = runs
            self.warning = warning; self.attribution = attribution; self.derivations = derivations; self.sourceFiles = sourceFiles
        }
    }

    public struct Citation: Codable, Sendable, Equatable {
        public var text: String               // full citation as the dataset asks it to be cited
        public var doi: String

        public init(text: String, doi: String) { self.text = text; self.doi = doi }
    }

    /// An input file the import read, with its SHA-256 so the conversion is auditable.
    public struct SourceFile: Codable, Sendable, Equatable {
        public var name: String
        public var sha256: String

        public init(name: String, sha256: String) { self.name = name; self.sha256 = sha256 }
    }

    /// What we asked the board for and what it reported back. Readback is empty when the
    /// board offers none; it is never copied from `requested`.
    public struct BoardConfiguration: Codable, Sendable, Equatable {
        public var requested: [String: String]
        public var readback: [String: String]

        public init(requested: [String: String], readback: [String: String]) {
            self.requested = requested; self.readback = readback
        }
    }

    /// One immutable, append-only sample chunk file. `sha256` covers the file bytes.
    public struct ChunkEntry: Codable, Sendable, Equatable {
        public var index: Int
        public var fileName: String           // chunks/000001.f64
        public var segment: Int
        public var firstSampleIndex: Int      // global index within the segment
        public var sampleCount: Int
        public var rowCount: Int
        public var sha256: String
        public var drainedAtMonotonicNanos: Int64        // HostMonotonicClock when read from BrainFlow
        public var firstBrainflowTimestamp: Double?      // wall-clock seconds from the timestamp row
        public var lastBrainflowTimestamp: Double?
        public var firstPackageNumber: Int?
        public var lastPackageNumber: Int?

        public init(index: Int, fileName: String, segment: Int, firstSampleIndex: Int, sampleCount: Int, rowCount: Int,
                    sha256: String, drainedAtMonotonicNanos: Int64, firstBrainflowTimestamp: Double?, lastBrainflowTimestamp: Double?,
                    firstPackageNumber: Int?, lastPackageNumber: Int?) {
            self.index = index; self.fileName = fileName; self.segment = segment
            self.firstSampleIndex = firstSampleIndex; self.sampleCount = sampleCount; self.rowCount = rowCount
            self.sha256 = sha256; self.drainedAtMonotonicNanos = drainedAtMonotonicNanos
            self.firstBrainflowTimestamp = firstBrainflowTimestamp; self.lastBrainflowTimestamp = lastBrainflowTimestamp
            self.firstPackageNumber = firstPackageNumber; self.lastPackageNumber = lastPackageNumber
        }
    }

    /// A contiguous run of samples. Reconnects start a new segment; nothing is ever joined
    /// across segments, and no values are interpolated into raw data.
    public struct StreamSegment: Codable, Sendable, Equatable {
        public var index: Int
        public var sessionID: String?
        public var runID: String
        public var startedAtWall: Date
        public var startedAtMonotonicNanos: Int64
        public var endedAtMonotonicNanos: Int64?
        public var endReason: EndReason?
        public var detectedGaps: [Gap]

        public init(index: Int, sessionID: String?, runID: String, startedAtWall: Date, startedAtMonotonicNanos: Int64,
                    endedAtMonotonicNanos: Int64?, endReason: EndReason?, detectedGaps: [Gap]) {
            self.index = index; self.sessionID = sessionID; self.runID = runID
            self.startedAtWall = startedAtWall; self.startedAtMonotonicNanos = startedAtMonotonicNanos
            self.endedAtMonotonicNanos = endedAtMonotonicNanos; self.endReason = endReason; self.detectedGaps = detectedGaps
        }
    }

    public struct Gap: Codable, Sendable, Equatable {
        public var afterSampleIndex: Int
        public var evidence: GapEvidence
        /// Counter arithmetic is modulo 256, so any estimate ≥ 256/step is ambiguous; the
        /// flag says so rather than letting a reader trust the number.
        public var estimatedMissingSamples: Int?
        public var ambiguous: Bool

        public init(afterSampleIndex: Int, evidence: GapEvidence, estimatedMissingSamples: Int?, ambiguous: Bool) {
            self.afterSampleIndex = afterSampleIndex; self.evidence = evidence
            self.estimatedMissingSamples = estimatedMissingSamples; self.ambiguous = ambiguous
        }
    }
}

public struct EventRecord: Codable, Sendable, Equatable {
    public var eventID: UUID
    public var sessionID: String?
    public var runID: String
    public var trialID: String?
    public var label: String                  // "cue_left", "cue_right", "rest", "abort", ...
    public var origin: String                 // "protocol", "operator", "device_marker"
    public var intendedAtMonotonicNanos: Int64?     // when the software meant to present it
    public var presentedAtMonotonicNanos: Int64?    // presentation callback, if any
    public var sourceTimeNanos: Int64?              // device-marker time in the device's own clock, if any
    public var wallTime: Date
    public var sampleAssociation: SampleAssociation?
    public var timingUncertaintyNanos: Int64?       // unknown → nil, never 0 by default

    public init(eventID: UUID, sessionID: String?, runID: String, trialID: String?, label: String, origin: String,
                intendedAtMonotonicNanos: Int64?, presentedAtMonotonicNanos: Int64?, sourceTimeNanos: Int64?,
                wallTime: Date, sampleAssociation: SampleAssociation?, timingUncertaintyNanos: Int64?) {
        self.eventID = eventID; self.sessionID = sessionID; self.runID = runID; self.trialID = trialID
        self.label = label; self.origin = origin
        self.intendedAtMonotonicNanos = intendedAtMonotonicNanos; self.presentedAtMonotonicNanos = presentedAtMonotonicNanos
        self.sourceTimeNanos = sourceTimeNanos; self.wallTime = wallTime
        self.sampleAssociation = sampleAssociation; self.timingUncertaintyNanos = timingUncertaintyNanos
    }

    public struct SampleAssociation: Codable, Sendable, Equatable {
        public var recordingID: UUID
        public var segment: Int
        public var sampleIndex: Int
        public var method: String             // "nearest_receipt_timestamp"

        public init(recordingID: UUID, segment: Int, sampleIndex: Int, method: String) {
            self.recordingID = recordingID; self.segment = segment; self.sampleIndex = sampleIndex; self.method = method
        }
    }
}

public struct PipelineRecord: Codable, Sendable, Equatable {
    public var pipelineID: UUID
    public var recipe: String                 // "csp_rlda_v1", "logvar_rlda_v1"
    public var configuration: [String: String]
    public var expectedChannelIDs: [String]
    public var expectedSampleRateHz: Double
    public var preprocessingStatePolicy: String     // "reset_on_segment_start"
    public var trainingRecordingIDs: [UUID]
    public var splitManifest: String          // JSON blob: the worker's split_manifest, verbatim
    public var dependencyVersions: [String: String]
    public var seed: Int
    public var fittedParametersFile: String?  // explicit arrays (.npz), never pickled executables
    public var configHash: String

    public init(pipelineID: UUID, recipe: String, configuration: [String: String], expectedChannelIDs: [String],
                expectedSampleRateHz: Double, preprocessingStatePolicy: String, trainingRecordingIDs: [UUID],
                splitManifest: String, dependencyVersions: [String: String], seed: Int, fittedParametersFile: String?, configHash: String) {
        self.pipelineID = pipelineID; self.recipe = recipe; self.configuration = configuration
        self.expectedChannelIDs = expectedChannelIDs; self.expectedSampleRateHz = expectedSampleRateHz
        self.preprocessingStatePolicy = preprocessingStatePolicy; self.trainingRecordingIDs = trainingRecordingIDs
        self.splitManifest = splitManifest; self.dependencyVersions = dependencyVersions; self.seed = seed
        self.fittedParametersFile = fittedParametersFile; self.configHash = configHash
    }
}

/// `results/<uuid>/result.meta.json`: the context of one evaluation run. Everything that
/// varies between two runs of the same evaluation (wall clock, durations, worker build)
/// lives here and never in `evaluation.json`, so repeat runs can be compared byte-for-byte.
public struct ResultMeta: Codable, Sendable, Equatable {
    public var formatVersion: Int = ContractVersion.format
    public var resultID: UUID
    public var pipelineID: UUID
    public var recordingID: UUID
    public var createdAt: Date
    public var seed: Int
    public var configHash: String             // PipelineRecord.configHash, for reproduction lookup
    public var evaluationSHA256: String       // over the stored evaluation.json bytes
    public var durationsSeconds: [String: Double]   // "loading", "fit", "holdout", "total"
    public var workerVersions: [String: String]
    public var workerOrigin: String           // "bundled" | "development_venv"
    /// The earlier result this run reproduced (same recording, config hash and seed). Set
    /// only when the new `evaluation.json` is byte-identical to the original's; a rerun
    /// that differs is stored on its own and names the original in `divergedFrom`.
    public var reproductionOf: UUID?
    public var divergedFrom: UUID?

    public init(resultID: UUID, pipelineID: UUID, recordingID: UUID, createdAt: Date, seed: Int, configHash: String,
                evaluationSHA256: String, durationsSeconds: [String: Double], workerVersions: [String: String], workerOrigin: String,
                reproductionOf: UUID?, divergedFrom: UUID?) {
        self.resultID = resultID; self.pipelineID = pipelineID; self.recordingID = recordingID; self.createdAt = createdAt
        self.seed = seed; self.configHash = configHash; self.evaluationSHA256 = evaluationSHA256
        self.durationsSeconds = durationsSeconds; self.workerVersions = workerVersions; self.workerOrigin = workerOrigin
        self.reproductionOf = reproductionOf; self.divergedFrom = divergedFrom
    }
}

public struct PredictionRecord: Codable, Sendable, Equatable {
    public var pipelineID: UUID
    public var inputSegment: Int
    /// Samples the prediction was computed from; nil when none were (e.g. `worker_unavailable`).
    public var inputSampleRange: SampleRange?
    public var score: Double?
    public var validity: Validity
    public var emittedAtMonotonicNanos: Int64
    public var action: Action
    public var feedbackPresentedAtMonotonicNanos: Int64?

    public init(pipelineID: UUID, inputSegment: Int, inputSampleRange: SampleRange?, score: Double?, validity: Validity,
                emittedAtMonotonicNanos: Int64, action: Action, feedbackPresentedAtMonotonicNanos: Int64?) {
        self.pipelineID = pipelineID; self.inputSegment = inputSegment; self.inputSampleRange = inputSampleRange
        self.score = score; self.validity = validity; self.emittedAtMonotonicNanos = emittedAtMonotonicNanos
        self.action = action; self.feedbackPresentedAtMonotonicNanos = feedbackPresentedAtMonotonicNanos
    }

    /// `start` + `count` rather than a closed range: unambiguous for empty windows and in JSON.
    public struct SampleRange: Codable, Sendable, Equatable {
        public var start: Int
        public var count: Int

        public init(start: Int, count: Int) { self.start = start; self.count = count }
    }

    /// Abstention is a policy outcome, not a third class; it carries no label.
    public struct Action: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case `class`, abstain }
        public var kind: Kind
        public var label: String?

        public static func chosen(_ label: String) -> Action { Action(kind: .class, label: label) }
        public static let abstain = Action(kind: .abstain, label: nil)

        public init(kind: Kind, label: String?) { self.kind = kind; self.label = label }
    }
}
