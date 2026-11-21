import Synchronization

/// The live preview's last 10 s (brief 004): one bounded ring per EEG channel, fed only from
/// `AcquisitionSession.preview`, i.e. chunks the drain loop already read (never a second
/// read). That stream is newest-wins, so a slow preview drops frames and never slows the
/// drain loop or the recording; this buffer only ever copies values out of a frame.
/// The screen reads a copied `Window` from any thread; nothing here touches the recording.
public final class PreviewBuffer: Sendable {
    public struct Window: Sendable, Equatable {
        public var rate: Int
        public var capacity: Int
        /// `[channel][sample]` in µV, oldest first; at most `capacity` per channel.
        public var channels: [[Float]]
        /// Indices in each channel where a stream segment starts inside the window, oldest
        /// first: the screen breaks the line at every one, nothing is joined.
        public var segmentStarts: [Int]
        public var framesIngested: Int
        public var count: Int { channels.first?.count ?? 0 }
    }

    private struct Ring {
        var data: [Float]
        var head = 0                 // next write position
        var count = 0
        var total = 0                // samples ever written
        var segment: Int?
        /// Absolute sample numbers where segments after the first began.
        var segmentStartTotals: [Int] = []
        var frames = 0
    }

    public let rows: [Int]
    public let rate: Int
    public let capacity: Int
    private let ring: Mutex<Ring>

    /// `rows`: the board's EEG rows, in channel order.
    public init(rows: [Int], rate: Int, seconds: Int = 10) {
        self.rows = rows
        self.rate = max(1, rate)
        capacity = max(1, rate * seconds)
        ring = Mutex(Ring(data: [Float](repeating: 0, count: rows.count * max(1, rate * seconds))))
    }

    /// Copies one drained chunk's EEG rows in. A frame from a new stream segment marks the
    /// break. Values are stored as received: no filling, no reordering.
    public func ingest(_ frame: AcquisitionSession.PreviewFrame) {
        let chunk = frame.chunk
        guard chunk.count > 0, let top = rows.max(), top < chunk.numRows else { return }
        let skip = max(0, chunk.count - capacity)
        ring.withLock { r in
            r.frames += 1
            if r.segment != frame.segment {
                if r.segment != nil { r.segmentStartTotals.append(r.total + skip) }
                r.segment = frame.segment
            }
            for j in skip..<chunk.count {
                for (c, row) in rows.enumerated() {
                    r.data[c * capacity + r.head] = Float(chunk.values[row * chunk.count + j])
                }
                r.head = (r.head + 1) % capacity
            }
            let added = chunk.count - skip
            r.count = min(capacity, r.count + added)
            r.total += chunk.count
            let oldest = r.total - r.count
            r.segmentStartTotals.removeAll { $0 <= oldest }
        }
    }

    public func window() -> Window {
        ring.withLock { r in
            let start = (r.head - r.count + capacity) % capacity
            let channels = rows.indices.map { c -> [Float] in
                let base = c * capacity
                if start + r.count <= capacity { return Array(r.data[(base + start)..<(base + start + r.count)]) }
                let first = capacity - start
                return Array(r.data[(base + start)..<(base + capacity)]) + Array(r.data[base..<(base + r.count - first)])
            }
            let oldest = r.total - r.count
            return Window(rate: rate, capacity: capacity, channels: channels,
                          segmentStarts: r.segmentStartTotals.map { $0 - oldest }.filter { $0 > 0 && $0 < r.count },
                          framesIngested: r.frames)
        }
    }

    /// Frames taken so far: the screen redraws only when this changes.
    public var framesIngested: Int { ring.withLock { $0.frames } }
    /// Samples per channel in the window, without copying it.
    public var filledCount: Int { ring.withLock { $0.count } }

    /// Feeds the buffer until the stream ends or the task is cancelled. Run it off the main
    /// actor: it only copies, so the newest-wins stream rarely has to drop.
    public func consume(_ stream: AsyncStream<AcquisitionSession.PreviewFrame>) async {
        for await frame in stream {
            if Task.isCancelled { return }
            ingest(frame)
        }
    }
}
