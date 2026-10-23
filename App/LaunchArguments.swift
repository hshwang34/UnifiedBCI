import AppKit
import CoreGraphics
import Foundation

/// Development-only launch arguments for driving the app without clicks (screenshots,
/// smoke tests). Compiled out of Release builds, so a shipped app never opens anything
/// on its own (decision #7).
///
///     -BCIExploreExampleAt /path/new.bciproj   import the bundled example there and open it
///     -BCIOpenProject /path/existing.bciproj   open a project
///     -BCIAutoEvaluate N                       then evaluate N times with the same seed
///     -BCISection results                      then select a sidebar section
///     -BCISnapshotDir /path/dir                render each step's windows to PNG there
///                                              (the app draws its own windows, so no
///                                              Screen Recording permission is needed)
///     -BCIQuitWhenDone YES                     quit after the last step
@MainActor
enum LaunchArguments {
    private static var done = false

    static func runOnce(_ workspace: Workspace) async {
        #if DEBUG
        guard !done else { return }
        done = true
        let defaults = UserDefaults.standard
        let snapshots = defaults.string(forKey: "BCISnapshotDir").map { URL(fileURLWithPath: $0, isDirectory: true) }
        func snap(_ name: String) async {
            guard let snapshots else { return }
            try? await Task.sleep(for: .seconds(1.5))
            snapshotWindows(into: snapshots, name: name)
        }
        defer {
            // From a run-loop perform, not a main-queue block: `.terminateLater` spins a nested
            // run loop, and a busy (serial) main queue would starve the shutdown Task.
            if defaults.bool(forKey: "BCIQuitWhenDone") { NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0) }
        }
        await snap("welcome")

        let target: URL
        if let path = defaults.string(forKey: "BCIExploreExampleAt") {
            target = URL(fileURLWithPath: path)
            await workspace.exploreExample(at: target)
        } else if let path = defaults.string(forKey: "BCIOpenProject") {
            target = URL(fileURLWithPath: path)
            await workspace.open(target)
        } else {
            return
        }
        guard let session = workspace.sessions[Workspace.canonical(target)] else { return }
        await snap("recordings")
        let evaluations = max(0, defaults.integer(forKey: "BCIAutoEvaluate"))
        for _ in 0..<evaluations {
            await session.evaluateAndWait()
        }
        if evaluations > 0, let root = session.resultTree.first {
            session.section = .results
            session.selectedResultID = root.id
            await snap("result")
            if let child = root.children?.first {
                session.selectedResultID = child.id
                await snap("reproduction")
            }
        }
        for name in ["pipelines", "protocols"] where snapshots != nil {
            session.section = SidebarSection(rawValue: name)!
            await snap(name)
        }
        if snapshots != nil {
            session.section = .recordings
            await snap("recordings-after")
        }
        if let raw = defaults.string(forKey: "BCISection"), let section = SidebarSection(rawValue: raw) {
            session.section = section
        }
        #endif
    }

    #if DEBUG
    /// Captures every visible titled window of this app into `<name>-<n>-<title>.png`.
    /// Uses the window server's own-window capture (`CGWindowListCreateImage`, looked up at
    /// run time: it is deprecated, and this is debug-only tooling); an app may always image
    /// its own windows, so no Screen Recording permission is involved.
    private static func snapshotWindows(into dir: URL, name: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let capture = unsafeBitCast(sym, to: Capture.self)
        let windows = NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }
        for (i, window) in windows.enumerated() {
            // .optionIncludingWindow = 1 << 3; .boundsIgnoreFraming = 1 << 0, .bestResolution = 1 << 3
            guard let image = capture(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() else { continue }
            let rep = NSBitmapImageRep(cgImage: image)
            let title = window.title.isEmpty ? "window" : window.title
            let file = dir.appendingPathComponent("\(name)-\(i)-\(title.replacingOccurrences(of: "/", with: "-")).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
        }
    }
    #endif
}
