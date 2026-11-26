import Foundation

/// Copy for Help ▸ Export Diagnostics… (brief 009, decision #56).
enum DiagnosticsCopy {
    static let menuExport = "Export Diagnostics…"
    static let panelTitle = "Export Diagnostics"
    static let panelMessage = "Writes a folder you can attach to a bug report: recent app logs, BCI Workspace crash reports and version info. It holds no EEG data and no project files."
    static let panelPrompt = "Export"

    static func defaultName(stamp: String) -> String { "BCI Workspace Diagnostics \(stamp)" }

    static let existsTitle = "That folder already exists"
    static func existsInfo(_ name: String) -> String { "\(name) is already there. Export never overwrites; choose a new name." }
    static let failedTitle = "Diagnostics weren't exported"

    /// The folder's README.txt: exactly what is inside, and what is not.
    static func readme(logs: [String], crashes: [String], exportedAt: String) -> String {
        var lines = [
            "BCI Workspace diagnostics",
            "Exported \(exportedAt).",
            "",
            "What's in this folder:",
            "- about.json: app version and build, macOS version, Mac model, and whether agent control is on.",
        ]
        if logs.isEmpty {
            lines.append("- No app log files were found.")
        } else {
            lines.append("- logs/: the app's event log for this launch and the one before (\(logs.joined(separator: ", "))). Each line is a time, an area, a level and an event with ids, states, error codes and durations.")
        }
        if crashes.isEmpty {
            lines.append("- No BCI Workspace crash reports from the last 7 days.")
        } else {
            lines.append("- crashes/: macOS crash reports for BCI Workspace from the last 7 days (\(crashes.joined(separator: ", "))). macOS writes these as they are: they include file paths on this Mac (so your user name) and the names of loaded libraries, but no EEG data.")
        }
        lines += [
            "",
            "What's not in it:",
            "- No EEG data, recordings, channel or event labels, participant details, results or project files.",
            "- File paths and error text are kept out of the event log (macOS's own log keeps them private).",
            "",
            "Nothing was sent anywhere. Attach this folder to a bug report yourself if you choose.",
            "",
        ]
        return lines.joined(separator: "\n")
    }
}
