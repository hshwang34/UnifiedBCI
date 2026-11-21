import Foundation

// The bridge's view of a drained chunk, translated into what `RecordingWriter` stores.
// Kept out of `ProjectStore` so the store (and its crash helper) builds without BrainFlow.

extension SequenceAccounting.Finding {
    /// The stored gap for this finding, `afterSampleIndex` still relative to its chunk.
    /// Every counter finding is kept (provenance included); sizes are only ever the
    /// counter arithmetic's estimate, flagged ambiguous where it can alias.
    public var recordingGap: RecordingManifest.Gap {
        switch kind {
        case .gap(let missing, let ambiguous, _):
            return .init(afterSampleIndex: afterSampleIndex, evidence: .sequenceSkip, estimatedMissingSamples: missing, ambiguous: ambiguous)
        case .staleHalf:
            return .init(afterSampleIndex: afterSampleIndex, evidence: .staleHalf, estimatedMissingSamples: nil, ambiguous: false)
        case .duplicateCounter:
            return .init(afterSampleIndex: afterSampleIndex, evidence: .duplicateCounter, estimatedMissingSamples: nil, ambiguous: false)
        case .invalidCounter:
            return .init(afterSampleIndex: afterSampleIndex, evidence: .invalidCounter, estimatedMissingSamples: nil, ambiguous: false)
        case .clockAnomaly:
            return .init(afterSampleIndex: afterSampleIndex, evidence: .clockAnomaly, estimatedMissingSamples: nil, ambiguous: false)
        }
    }
}

extension RecordingWriter.Block {
    /// A drained chunk with its `SequenceAccounting` findings. An overflow warning becomes
    /// an `overflow_suspected` gap before the chunk's first sample: BrainFlow dropped the
    /// oldest buffered samples, an unknown number, before this drain.
    public init(_ chunk: SampleChunk, findings: [SequenceAccounting.Finding]) {
        var gaps = findings.map(\.recordingGap)
        if chunk.overflowSuspected {
            gaps.insert(.init(afterSampleIndex: -1, evidence: .overflowSuspected, estimatedMissingSamples: nil, ambiguous: true), at: 0)
        }
        self.init(values: chunk.values, rowCount: chunk.numRows, sampleCount: chunk.count,
                  drainedAtMonotonicNanos: chunk.drainedAtMonotonicNanos, gaps: gaps)
    }
}
