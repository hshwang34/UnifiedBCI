import Foundation

/// The `inspect_recording` result (worker/main.py `handle_inspect_recording`, brief 002).
/// Decoding only, with `convertFromSnakeCase` (`InspectionReport.decode`). Every number
/// the worker could not compute arrives as null, and every check it could not run says
/// why in `reason`; nothing here fills a gap with a guess.
public struct InspectionReport: Decodable, Sendable, Equatable {
    /// One of the six v1 checks as the worker describes it (`quality.rules()`): the only
    /// source of rule text the app shows.
    public struct Rule: Decodable, Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var rule: String
        public var flagWhen: String
    }

    public struct Segment: Decodable, Sendable, Equatable {
        public var index: Int
        public var runId: String
        public var sfreq: Double
        public var durationS: Double
        public var channels: [Channel]
    }

    public struct Channel: Decodable, Sendable, Equatable {
        public var id: String
        public var label: String
        public var kind: String
        public var unit: String
        /// Six results in `rules` order.
        public var checks: [Check]
        public var psd: Spectrum
        /// Most prominent peak of the raw spectrum; null when it has none.
        public var peakHz: Double?
    }

    public struct Check: Decodable, Sendable, Equatable {
        public var rule: String
        public var flagged: Bool
        public var assessable: Bool
        public var measured: Measured?
        public var reason: String?
    }

    /// The union of every rule's measurements; each rule fills its own fields.
    public struct Measured: Decodable, Sendable, Equatable {
        // flatline
        public var flatWindows: Int?
        public var flatS: Double?
        public var totalS: Double?
        // flatline, large_deflection
        public var windows: Int?
        // pinned
        public var runs: Int?
        public var longestRunSamples: Int?
        // large_deflection
        public var windowsOver: Int?
        public var fraction: Double?
        // mains_line
        public var lines: [MainsLine]?
        // outlier_amplitude, outlier_high_frequency
        public var value: Double?
        public var median: Double?
        public var ratio: Double?
        public var bandHz: [Double]?
    }

    public struct MainsLine: Decodable, Sendable, Equatable {
        public var hz: Double
        public var db: Double?
        public var flagged: Bool
        public var assessable: Bool
        public var reason: String?
    }

    /// Welch PSD in dB, ≤ 256 bins from 1 Hz to Nyquist. `raw` is null for a channel with
    /// non-finite samples; `processed` is null when the segment is too short after the
    /// band-pass warm-up (`processedReason`). A null bin is zero power.
    public struct Spectrum: Decodable, Sendable, Equatable {
        public var freqs: [Double?]
        public var raw: [Double?]?
        public var processed: [Double?]?
        public var processedReason: String?
    }

    public var rules: [Rule]
    public var segments: [Segment]

    public static func decode(_ data: Data) throws -> InspectionReport {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(InspectionReport.self, from: data)
    }
}
