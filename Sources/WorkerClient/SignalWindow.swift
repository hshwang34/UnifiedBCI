import Foundation

/// The `signal_window` result (worker/main.py `handle_signal_window`, brief 002 trace view):
/// at most 30 s of one segment, every channel reduced to ≤ 2,000 points, each the min and
/// max of its samples. Decoding only, with `convertFromSnakeCase`. Raw values are as
/// recorded (no mean removed); a null point had no finite sample.
public struct SignalWindow: Decodable, Sendable, Equatable {
    public enum Which: String, Sendable { case raw, bandpassed, both }

    /// The worker's longest window.
    public static let maxDurationS = 30.0

    /// Min/max envelope; `lo`/`hi` are the window's extremes (null when nothing is finite).
    public struct Trace: Decodable, Sendable, Equatable {
        public var min: [Double?]
        public var max: [Double?]
        public var lo: Double?
        public var hi: Double?
    }

    public struct Channel: Decodable, Sendable, Equatable {
        public var id: String
        public var label: String
        public var kind: String
        public var unit: String
        public var raw: Trace?
        public var bandpassed: Trace?
        /// Why `bandpassed` is null when it was asked for (rate too low, non-finite samples).
        public var bandpassedReason: String?
    }

    /// The reference band-pass and where its warm-up ends, in seconds from segment start.
    /// Samples before `warmupEndS` are returned, not dropped; the view marks them.
    public struct Bandpass: Decodable, Sendable, Equatable {
        public var lowHz: Double
        public var highHz: Double
        public var order: Int
        public var warmupSamples: Int
        public var warmupEndS: Double
    }

    public var recordingId: String
    public var segment: Int
    public var runId: String
    public var sfreq: Double
    public var segmentDurationS: Double
    /// The window as kept: slid back inside the segment when the request ran past an end.
    public var startS: Double
    public var durationS: Double
    public var samples: Int
    public var points: Int
    /// Start time of each point, seconds from segment start.
    public var tS: [Double]
    public var bandpass: Bandpass?
    public var bandpassedReason: String?
    public var channels: [Channel]

    public static func decode(_ data: Data) throws -> SignalWindow {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(SignalWindow.self, from: data)
    }

    /// The request's params.
    public static func params(projectDirectory: URL, recordingID: UUID, segment: Int, startS: Double,
                              durationS: Double, which: Which = .both, maxPoints: Int = 2000) -> [String: JSONValue] {
        ["project_dir": .string(projectDirectory.path), "recording_id": .string(recordingID.uuidString),
         "segment": .int(segment), "start_s": .double(startS), "duration_s": .double(durationS),
         "which": .string(which.rawValue), "max_points": .int(maxPoints)]
    }
}
