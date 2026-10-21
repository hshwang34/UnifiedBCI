import Foundation

// Core project-store records from the PRD (section 7, "Data contracts and storage").
// These are the on-disk JSON shapes. They are versioned by `ProjectManifest.formatVersion`;
// any field change that an older reader could misinterpret bumps that number.
// See docs/data-contracts.md for byte layout of sample chunks and the rules behind each field.

public enum ContractVersion {
    public static let format = 1
}

/// Which clock a time value came from. Never mix values from different clocks.
public enum ClockDomain: String, Codable, Sendable {
    /// Timestamp emitted by BrainFlow; for Cyton this is generated on the host at receipt.
    case brainflowReceipt = "brainflow_receipt"
    /// `ContinuousClock` on the app, taken when the chunk was drained from BrainFlow.
    case hostMonotonic = "host_monotonic"
    /// Wall clock, for humans and cross-machine correlation only.
    case hostWall = "host_wall"
}

public struct ChannelSpec: Codable, Sendable, Equatable {
    public var id: String          // stable within a recording, e.g. "ch03"
    public var label: String       // user-declared, e.g. "C3"; never inferred from channel count
    public var kind: String        // "eeg", "accel", "aux", ...
    public var unit: String        // "uV" for BrainFlow-scaled Cyton EEG rows
    public var sourceRow: Int      // row in the BrainFlow sample matrix
}

public struct TimingSemantics: Codable, Sendable, Equatable {
    public var nominalSampleRateHz: Double
    public var timestampClock: ClockDomain
    public var timestampGeneratedBy: String   // "host" | "device"; Cyton over dongle = "host"
    public var sequenceCounterRow: Int?       // BrainFlow package_num row, wraps at 256 on Cyton
    public var notes: String
}

public struct RecordingManifest: Codable, Sendable, Equatable {
    public var formatVersion: Int = ContractVersion.format
    public var recordingID: UUID
    public var createdAt: Date
    public var source: Source
    public var channels: [ChannelSpec]
    public var reference: String              // user-declared, e.g. "earclips (SRB2)"
    public var montage: String                // free text or named map id; explicit, never inferred
    public var timing: TimingSemantics
    public var boardConfiguration: [String: String]  // requested settings + readback where available
    public var chunks: [ChunkEntry]
    public var segments: [StreamSegment]

    public struct Source: Codable, Sendable, Equatable {
        public var kind: String               // "brainflow", "synthetic", "import"
        public var boardID: Int32?
        public var boardName: String
        public var brainflowVersion: String
        public var appVersion: String
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
    }

    /// A contiguous run of samples. Reconnects start a new segment; nothing is ever joined
    /// across segments, and no values are interpolated into raw data.
    public struct StreamSegment: Codable, Sendable, Equatable {
        public var index: Int
        public var startedAtWall: Date
        public var startedAtMonotonicNanos: Int64
        public var endedAtMonotonicNanos: Int64?
        public var endReason: String?         // "stopped", "disconnect", "worker_failure", "disk_full", ...
        public var detectedGaps: [Gap]
    }

    public struct Gap: Codable, Sendable, Equatable {
        public var afterSampleIndex: Int
        public var evidence: String           // "sequence_skip", "receipt_interval", ...
        public var estimatedMissingSamples: Int?
    }
}

public struct EventRecord: Codable, Sendable, Equatable {
    public var eventID: UUID
    public var trialID: String?
    public var label: String                  // "cue_left", "cue_right", "rest", "abort", ...
    public var origin: String                 // "protocol", "operator", "device_marker"
    public var intendedAtMonotonicNanos: Int64?     // when the software meant to present it
    public var presentedAtMonotonicNanos: Int64?    // presentation callback, if any
    public var wallTime: Date
    public var sampleAssociation: SampleAssociation?
    public var timingUncertaintyNanos: Int64?       // unknown → nil, never 0 by default

    public struct SampleAssociation: Codable, Sendable, Equatable {
        public var recordingID: UUID
        public var segment: Int
        public var sampleIndex: Int
        public var method: String             // "nearest_receipt_timestamp"
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
    public var splitManifest: String          // JSON blob from the worker's split_policy
    public var dependencyVersions: [String: String]
    public var seed: Int
    public var fittedParametersFile: String?  // explicit arrays, never pickled executables
    public var configHash: String
}

public struct PredictionRecord: Codable, Sendable, Equatable {
    public var pipelineID: UUID
    public var inputSegment: Int
    public var inputSampleRange: ClosedRange<Int>
    public var score: Double?
    public var validity: String               // "valid", "stale", "insufficient_window", "disconnected", ...
    public var emittedAtMonotonicNanos: Int64
    public var action: String                 // chosen class label or "abstain"
    public var feedbackPresentedAtMonotonicNanos: Int64?
}
