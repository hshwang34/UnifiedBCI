import Foundation

// Typed wrappers for the frozen-model methods of protocol v1 (brief 006; protocol.py
// docstring): `validate_model`, `replay_recording`, `live_open` / `live_push` / `live_close`.
// `live_push` is the one place samples cross the pipe: the model's channel rows only, base64
// little-endian float64, at most `maxPushSamples` per call. Everything else references files.

/// `params.model`: a pipeline's `fitted.npz`, by path and (once frozen) SHA-256.
public struct ModelArraysRef: Sendable, Equatable {
    public var arraysPath: String
    public var sha256: String?
    public var role: ModelRole

    public init(arraysPath: String, sha256: String?, role: ModelRole) {
        self.arraysPath = arraysPath; self.sha256 = sha256; self.role = role
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["arrays_path": .string(arraysPath), "which": .string(role.rawValue)]
        if let sha256 { o["sha256"] = .string(sha256) }
        return .object(o)
    }
}

/// One prediction as the worker emits it (`streaming.Prediction.to_json`). Segment-relative
/// sample indices, window half-open `[windowStart, windowStop)`.
public struct WorkerPrediction: Decodable, Sendable, Equatable {
    public struct Gap: Decodable, Sendable, Equatable { public var afterSample: Int; public var evidence: String }
    public struct Offline: Decodable, Sendable, Equatable { public var validity: String; public var score: Double? }
    public var segment: Int?
    public var kind: String
    public var windowStart: Int
    public var windowStop: Int
    public var validity: String
    public var detail: String?
    public var score: Double?
    public var confidence: Double?
    public var predictedClass: Int?
    public var trialId: String?
    public var feedbackEligible: Bool
    public var gap: Gap?
    /// Replay files only: the offline reference for the same window.
    public var offline: Offline?
}

/// `replay_recording`'s result, the parts the app keeps (streaming.replay summary).
public struct ReplayReport: Decodable, Sendable, Equatable {
    // Explicit keys, not `.convertFromSnakeCase`: that would also rewrite the quantity
    // names used as dictionary keys (`bandpassed_uv`).
    public struct Deviation: Decodable, Sendable, Equatable {
        public var observedMax: Double; public var tolerance: Double; public var within: Bool
        enum CodingKeys: String, CodingKey { case observedMax = "observed_max", tolerance, within }
    }
    public struct Pass: Decodable, Sendable, Equatable {
        public struct Report: Decodable, Sendable, Equatable {
            public var passed: Bool
            public var validityMismatches: [Where]
            public var decisionMismatches: [Where]
            public var missingWindows: [[JSONScalar]]
            public var extraWindows: [[JSONScalar]]
            enum CodingKeys: String, CodingKey {
                case passed, validityMismatches = "validity_mismatches", decisionMismatches = "decision_mismatches"
                case missingWindows = "missing_windows", extraWindows = "extra_windows"
            }
        }
        public var chunking: JSONScalar
        public var report: Report
    }
    public struct Where: Decodable, Sendable, Equatable {
        public var segment: Int?
        public var kind: String
        public var windowStop: Int
        public var trialId: String?
        enum CodingKeys: String, CodingKey { case segment, kind, windowStop = "window_stop", trialId = "trial_id" }
    }
    public var passed: Bool
    public var windowsCompared: Int
    public var tolerances: [String: Double]
    public var maxDeviation: [String: Deviation]
    public var boundaryWindows: [Where]
    public var firstValidWindowStop: [String: Int?]
    public var chunkings: [Pass]
    public var nPredictions: Int
    public var predictionsFile: String
    enum CodingKeys: String, CodingKey {
        case passed, tolerances, chunkings, windowsCompared = "windows_compared", maxDeviation = "max_deviation"
        case boundaryWindows = "boundary_windows", firstValidWindowStop = "first_valid_window_stop"
        case nPredictions = "n_predictions", predictionsFile = "predictions_file"
    }
}

/// A string, number, bool or null inside a list the worker sends (chunking names, window keys).
public enum JSONScalar: Decodable, Sendable, Equatable, CustomStringConvertible {
    case string(String), int(Int), double(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else { self = .string(try c.decode(String.self)) }
    }
    public var description: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        case .null: return "none"
        }
    }
}

public struct LiveSessionInfo: Decodable, Sendable, Equatable {
    public struct Window: Decodable, Sendable, Equatable { public var offsetSamples: Int; public var lengthSamples: Int; public var hopSamples: Int; public var warmupSamples: Int }
    public var session: String
    public var window: Window
}

public struct LivePushResult: Decodable, Sendable, Equatable {
    public var nSamples: Int
    public var predictions: [WorkerPrediction]
    public var workerComputeNanos: Int64
}

/// A gap or cue announced with a pushed chunk (segment-relative samples).
public struct LiveGap: Sendable, Equatable { public var afterSample: Int; public var evidence: String
    public init(afterSample: Int, evidence: String) { self.afterSample = afterSample; self.evidence = evidence } }
public struct LiveCue: Sendable, Equatable { public var sample: Int; public var trialID: String; public var endSample: Int?
    public init(sample: Int, trialID: String, endSample: Int?) { self.sample = sample; self.trialID = trialID; self.endSample = endSample } }

extension WorkerClient {
    /// Mirrors main.py `MAX_PUSH_SAMPLES`.
    public static let maxPushSamples = 512
    /// Mirrors streaming.py `DEFAULT_HOP_SAMPLES` (128 ms at 125 Hz); sent explicitly.
    public static let hopSamples = 16

    static func snakeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    public func validateModel(_ model: ModelArraysRef, nChannels: Int? = nil, timeout: Duration = .seconds(30)) async throws -> ModelValidation {
        var params: [String: JSONValue] = ["model": model.json]
        if let nChannels { params["n_channels"] = .int(nChannels) }
        return try JSONDecoder().decode(ModelValidation.self, from: try await call("validate_model", params: params, timeout: timeout))
    }

    /// Replays a recording through `model` beside the offline reference; the predictions
    /// go to `predictionsPath` (the app's staging directory), never over the pipe.
    public func replayRecording(projectDirectory: URL, recordingID: UUID, model: ModelRecord, arraysPath: String, predictionsPath: URL,
                                abstainThreshold: Double, cueLengthSeconds: Double?, requestID: String, timeout: Duration) async throws -> ReplayReport {
        var params: [String: JSONValue] = [
            "project_dir": .string(projectDirectory.path), "recording_id": .string(recordingID.uuidString),
            "model": ModelArraysRef(arraysPath: arraysPath, sha256: model.fittedSHA256, role: model.role).json,
            "expected_channel_ids": .array(model.expectedChannelIDs.map { .string($0) }),
            "expected_sample_rate_hz": .double(model.expectedSampleRateHz),
            "window": .object(["offset_s": .double(model.window.offsetSeconds), "length_s": .double(model.window.lengthSeconds)]),
            "warmup_samples": .int(model.warmupSamples),
            // Labels as the evaluation named them: lda class 0 is `left` (ProjectStore.freeze).
            "labels": .object(["left": .string(model.classLabels[0]), "right": .string(model.classLabels[1])]),
            "abstain_threshold": .double(abstainThreshold), "predictions_path": .string(predictionsPath.path),
            "hop_samples": .int(Self.hopSamples),
        ]
        if let cueLengthSeconds { params["cue_length_s"] = .double(cueLengthSeconds) }
        let data = try await call("replay_recording", params: params, timeout: timeout, requestID: requestID)
        return try JSONDecoder().decode(ReplayReport.self, from: data)
    }

    public func liveOpen(model: ModelRecord, arraysPath: String, channelIDs: [String], sampleRateHz: Double,
                         timeout: Duration = .seconds(10)) async throws -> LiveSessionInfo {
        let params: [String: JSONValue] = [
            "model": ModelArraysRef(arraysPath: arraysPath, sha256: model.fittedSHA256, role: model.role).json,
            "channel_ids": .array(channelIDs.map { .string($0) }), "sample_rate_hz": .double(sampleRateHz),
            "expected_channel_ids": .array(model.expectedChannelIDs.map { .string($0) }),
            "expected_sample_rate_hz": .double(model.expectedSampleRateHz),
            "window": .object(["offset_s": .double(model.window.offsetSeconds), "length_s": .double(model.window.lengthSeconds)]),
            "warmup_samples": .int(model.warmupSamples), "hop_samples": .int(Self.hopSamples),
        ]
        return try Self.snakeDecoder().decode(LiveSessionInfo.self, from: try await call("live_open", params: params, timeout: timeout))
    }

    /// Pushes one drained chunk: `rows` are the model's channels in order, equal lengths.
    /// Split into calls of at most `maxPushSamples`; gaps and cues travel with the piece
    /// they fall in (a cue with the first piece). One result per call, in order.
    public func livePush(session: String, segment: Int, firstSample: Int, rows: [[Double]], gaps: [LiveGap] = [], cues: [LiveCue] = [],
                         timeout: Duration = .seconds(1)) async throws -> [LivePushResult] {
        guard let n = rows.first?.count, n > 0, rows.allSatisfy({ $0.count == n }) else {
            throw WorkerError(code: "bad_request", message: "live push needs channel rows of one non-zero length")
        }
        // Refused here, before any piece is sent: a non-finite value found by the worker in a
        // later piece would leave the session half-advanced.
        guard rows.allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
            throw WorkerError(code: "non_finite_samples", message: "live push holds non-finite samples; nothing was sent")
        }
        guard gaps.allSatisfy({ (firstSample - 1..<firstSample + n).contains($0.afterSample) }) else {
            throw WorkerError(code: "bad_request", message: "a gap lies outside the pushed chunk")
        }
        var out: [LivePushResult] = []
        var start = 0
        while start < n {
            let count = min(Self.maxPushSamples, n - start)
            let first = firstSample + start
            // Each gap goes with exactly one piece: the first whose range holds it.
            let pieceGaps = gaps.filter { ((start == 0 ? first - 1 : first)..<first + count).contains($0.afterSample) }
            var params: [String: JSONValue] = [
                "session": .string(session), "segment": .int(segment), "first_sample": .int(first), "n_samples": .int(count),
                "samples": .string(Self.base64Float64(rows, from: start, count: count)),
                "gaps": .array(pieceGaps.map { .object(["after_sample": .int($0.afterSample), "evidence": .string($0.evidence)]) }),
            ]
            if start == 0, !cues.isEmpty {
                params["cues"] = .array(cues.map { c in
                    var o: [String: JSONValue] = ["sample": .int(c.sample), "trial_id": .string(c.trialID)]
                    if let e = c.endSample { o["end_sample"] = .int(e) }
                    return .object(o)
                })
            }
            out.append(try Self.snakeDecoder().decode(LivePushResult.self, from: try await call("live_push", params: params, timeout: timeout)))
            start += count
        }
        return out
    }

    public func liveClose(session: String, timeout: Duration = .seconds(5)) async throws -> [WorkerPrediction] {
        struct Closed: Decodable { let predictions: [WorkerPrediction] }
        return try Self.snakeDecoder().decode(Closed.self, from: try await call("live_close", params: ["session": .string(session)], timeout: timeout)).predictions
    }

    /// Row-major (channels × samples) little-endian float64, base64.
    static func base64Float64(_ rows: [[Double]], from start: Int, count: Int) -> String {
        var data = Data(capacity: rows.count * count * 8)
        for row in rows {
            for v in row[start..<start + count] {
                withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            }
        }
        return data.base64EncodedString()
    }
}
