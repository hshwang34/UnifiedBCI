import Foundation

/// macOS crash reports (`.ips`) of this app, summarised for `app.diagnostics` and copied by
/// Help ▸ Export Diagnostics… (brief 009). Read from disk only; nothing is sent anywhere.
enum CrashReports {
    static let processName = "BCIWorkspace"

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    struct Summary: Sendable, Equatable {
        var file: String
        var time: String?
        var exceptionType: String?
        var signal: String?
        var termination: String?
        var appVersion: String?
        var faultingThread: Int?
        /// The first frames of the faulting thread, innermost first.
        var symbols: [String]

        var json: JSON {
            ["file": .string(file), "time": .from(time), "exceptionType": .from(exceptionType), "signal": .from(signal),
             "termination": .from(termination), "appVersion": .from(appVersion), "faultingThread": .from(faultingThread),
             "symbols": .array(symbols.map(JSON.string))]
        }
    }

    /// When to look back from: the previous launch's start, else 7 days ago (and never more).
    static func cutoff(previousLaunch: Date?, now: Date = Date()) -> Date {
        let week = now.addingTimeInterval(-7 * 86400)
        guard let previousLaunch else { return week }
        return max(previousLaunch, week)
    }

    /// `BCIWorkspace*.ips` in `directory` modified after `since`, newest first.
    static func files(in directory: URL = defaultDirectory, since: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url -> (URL, Date)? in
            guard url.lastPathComponent.hasPrefix(processName), url.pathExtension == "ips",
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let m = v.contentModificationDate, m > since else { return nil }
            return (url, m)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    static func summaries(in directory: URL = defaultDirectory, since: Date, symbols: Int = 8) -> [Summary] {
        files(in: directory, since: since).map { url in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return summarize(text, file: url.lastPathComponent, symbols: symbols)
        }
    }

    /// Parses an `.ips`: line 1 is a JSON header, the rest one JSON body. A report that
    /// doesn't parse still gets a row (file name only), so a crash is never hidden.
    static func summarize(_ text: String, file: String, symbols count: Int = 8) -> Summary {
        var s = Summary(file: file, symbols: [])
        let split = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = split.first else { return s }
        let header = try? JSON.parse(String(first))
        s.time = header?["timestamp"]?.stringValue
        s.appVersion = header?["app_version"]?.stringValue
        guard split.count > 1, let body = try? JSON.parse(String(split[1])) else { return s }
        s.exceptionType = body["exception"]?["type"]?.stringValue
        s.signal = body["exception"]?["signal"]?.stringValue
        s.termination = body["termination"]?["indicator"]?.stringValue
        let images = body["usedImages"]?.arrayValue ?? []
        guard let index = body["faultingThread"]?.intValue else { return s }
        s.faultingThread = index
        let threads = body["threads"]?.arrayValue ?? []
        guard threads.indices.contains(index) else { return s }
        let frames = threads[index]["frames"]?.arrayValue ?? []
        s.symbols = frames.prefix(count).map { f in
            if let sym = f["symbol"]?.stringValue { return sym }
            let image = f["imageIndex"]?.intValue.flatMap { images.indices.contains($0) ? images[$0]["name"]?.stringValue : nil } ?? "?"
            return "\(image)+\(f["imageOffset"]?.intValue ?? 0)"
        }
        return s
    }
}
