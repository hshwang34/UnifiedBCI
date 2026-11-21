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
///     -BCIRecordingTab quality                 then show that Recording tab (channels, segments,
///                                              events, quality); quality waits for the
///                                              inspection and snapshots "quality"
///     -BCIQualityTrace YES                     with -BCIRecordingTab quality: scroll to the signal
///                                              view, snapshot "quality-trace" (raw) and
///                                              "quality-trace-bandpassed"
///     -BCITraceStart 20                        the signal view's window start (s)
///     -BCIQuitWhenDone YES                     quit after the last step
///     -BCIAppearance light|dark                force an appearance (screenshots)
///     -BCISnapshotProgress YES                 snapshot the progress panel mid-run
///     -BCIFailingWorker YES                    use a worker that dies before it is ready, to
///                                              show the "analysis unavailable" banner
///     -BCIWindowSize 1100x640                  content size of the project window for snapshots
///     -BCIResetFirstRun YES                    show the intro as on a first launch (brief 003)
///     -BCIIntroStep N                          start the intro at step N (0-based; implies the intro)
///     -BCIIntroTour YES                        with -BCISnapshotDir: snapshot every intro step
///     -BCIReduceMotion YES                     force the Reduce Motion policy (intro, montage)
///     -BCIReduceTransparency YES               force the frosted, solid head dome
///     -BCIMontageView top|left|right|front     the montage head's initial view
///     -BCIFrameLog /path/file.txt              append intro frame-interval stats there
///     -BCIOffscreenSnapshotDir /path/dir       render intro steps and montage presets with
///                                              ImageRenderer (works with the display asleep)
///     -BCIConnectSheet YES                     open the Connect sheet in the opened project
///                                              (brief 004 PR 5); snapshots "connect-picker"
///     -BCIConnectSource demo|synthetic         then connect that source; snapshots
///                                              "connect-connecting", "connect-ready", "connect-map"
///                                              Without -BCIConnectSheet: connect it, confirm the
///                                              map the Demo file declares (synthetic: Record
///                                              without positions), start the preview on the
///                                              acquisition screen (brief 004 PR 6); snapshots
///                                              "live-preview" after 12 s of streaming
///     -BCILiveRecordSeconds N                  then record N s and stop; snapshots "live-recording",
///                                              "live-stopped", then the recording in Recordings:
///                                              "live-recorded", "live-recorded-full" (tall),
///                                              "live-recorded-segments",
///                                              "live-recorded-quality"
@MainActor
enum LaunchArguments {
    private static var done = false

    // MARK: Brief 003 debug overrides (all no-ops in Release)

    /// Reduce Motion as the views apply it: the system setting, or the debug override.
    static func reduceMotion(system: Bool) -> Bool {
        #if DEBUG
        return system || UserDefaults.standard.bool(forKey: "BCIReduceMotion")
        #else
        return system
        #endif
    }

    /// Reduce Transparency as the head applies it (Debug `-BCIReduceTransparency YES`; the
    /// system key is read-only, so snapshots need this to show the frosted dome).
    static func reduceTransparency(system: Bool) -> Bool {
        #if DEBUG
        return system || UserDefaults.standard.bool(forKey: "BCIReduceTransparency")
        #else
        return system
        #endif
    }

    static var resetFirstRun: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "BCIResetFirstRun")
        #else
        return false
        #endif
    }

    static var introStep: Int? {
        #if DEBUG
        return UserDefaults.standard.object(forKey: "BCIIntroStep") == nil ? nil : UserDefaults.standard.integer(forKey: "BCIIntroStep")
        #else
        return nil
        #endif
    }

    static var montagePreset: Orbit.Preset? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "BCIMontageView").flatMap(Orbit.Preset.init(rawValue:))
        #else
        return nil
        #endif
    }

    /// `-BCIRecordingTab`: the Recording tab to show (and scroll to) for snapshots.
    static var recordingTab: RecordingTab? {
        #if DEBUG
        guard let raw = UserDefaults.standard.string(forKey: "BCIRecordingTab") else { return nil }
        return RecordingTab.allCases.first { $0.rawValue.lowercased() == raw.lowercased() }
        #else
        return nil
        #endif
    }

    /// `-BCILiveRecordSeconds`: the recorded-recording snapshots bring the tabs into view.
    static var liveSnapshots: Bool {
        #if DEBUG
        return UserDefaults.standard.integer(forKey: "BCILiveRecordSeconds") > 0
        #else
        return false
        #endif
    }

    static var qualityTrace: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "BCIQualityTrace")
        #else
        return false
        #endif
    }

    static var frameLogURL: URL? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "BCIFrameLog").map { URL(fileURLWithPath: $0) }
        #else
        return nil
        #endif
    }

    /// The worker the app uses: the located one, or (Debug, `-BCIFailingWorker YES`) one
    /// that writes to stderr and exits before announcing ready.
    static func workerLaunch(default located: WorkerLaunch?) -> WorkerLaunch? {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "BCIFailingWorker"), let located else { return located }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bci-failing-worker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("failing_worker.py")
        try? "import sys\nsys.stderr.write('debug failing worker: exiting before ready (-BCIFailingWorker)\\n')\nsys.exit(3)\n"
            .write(to: script, atomically: true, encoding: .utf8)
        return WorkerLaunch(origin: located.origin, python: located.python, pythonPath: nil, workingDirectory: dir, entry: .script(script))
        #else
        return located
        #endif
    }

    static func applyAppearance() {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "BCIAppearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        #endif
    }

    static func runOnce(_ workspace: Workspace) async {
        #if DEBUG
        guard !done else { return }
        done = true
        let defaults = UserDefaults.standard
        let snapshots = defaults.string(forKey: "BCISnapshotDir").map { URL(fileURLWithPath: $0, isDirectory: true) }
        func snap(_ name: String, settle: Duration = .seconds(1.5)) async {
            guard let snapshots else { return }
            try? await Task.sleep(for: settle)
            snapshotWindows(into: snapshots, name: name)
        }
        defer {
            // From a run-loop perform, not a main-queue block: `.terminateLater` spins a nested
            // run loop, and a busy (serial) main queue would starve the shutdown Task.
            if defaults.bool(forKey: "BCIQuitWhenDone") { NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0) }
        }
        if let dir = defaults.string(forKey: "BCIOffscreenSnapshotDir") {
            OffscreenSnapshots.run(into: URL(fileURLWithPath: dir, isDirectory: true))
            return
        }
        // Brief 003: every intro step, through the same commands the keys send, then the
        // welcome screen it lands on ("Explore an example" focused).
        if defaults.bool(forKey: "BCIIntroTour"), workspace.welcomeFlow.isIntro {
            let first = workspace.welcomeFlow.step ?? 0
            // Without -BCISnapshotDir the tour still dwells on each step, so a -BCIFrameLog run
            // measures steps and transitions with no capture stalling the main thread.
            for i in first..<IntroModel.steps.count {
                try? await Task.sleep(for: .seconds(2.5))
                await snap("intro-\(i)", settle: .zero)
                if i == first {
                    try? await Task.sleep(for: .seconds(2))
                    await snap("intro-\(i)-later", settle: .zero)
                }
                workspace.welcomeFlow.apply(.next)
            }
            try? await Task.sleep(for: .seconds(1))
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
        // Size the project window's content (e.g. the 1100x640 minimum) before capturing.
        if let size = defaults.string(forKey: "BCIWindowSize")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            try? await Task.sleep(for: .milliseconds(500))
            NSApp.windows.first { $0.title == session.name }?.setContentSize(NSSize(width: size[0], height: size[1]))
        }
        if defaults.bool(forKey: "BCIConnectSheet") {
            await connectSheet(session, source: defaults.string(forKey: "BCIConnectSource"), snap: snap)
            return
        }
        if let source = defaults.string(forKey: "BCIConnectSource") {
            await liveRun(session, source: source, recordSeconds: defaults.integer(forKey: "BCILiveRecordSeconds"), snap: snap)
            return
        }
        await snap("recordings")
        if snapshots != nil {
            session.recordingTab = .events
            await snap("events")
            session.recordingTab = .segments
            await snap("segments")
            session.recordingTab = .channels
        }
        if let tab = recordingTab {
            session.recordingTab = tab
            if tab == .quality {
                await session.awaitInspection()
                await snap("quality")
                if qualityTrace, case .ready(let model) = session.qualityState, let first = model.sections.first {
                    session.traceStartS = defaults.double(forKey: "BCITraceStart")
                    _ = await session.traces.loadAndWait(.init(recordingID: session.selectedRecordingID!, segment: first.id, startS: session.traceStartS))
                    await snap("quality-trace")
                    session.traceBandpassed = true
                    await snap("quality-trace-bandpassed")
                }
            }
        }
        let evaluations = max(0, defaults.integer(forKey: "BCIAutoEvaluate"))
        for n in 0..<evaluations {
            if n == 0, defaults.bool(forKey: "BCISnapshotProgress") {
                let run = Task { await session.evaluateAndWait() }
                // Catch the panel in the cross-validation stage.
                while session.isRunning || session.runner.state == .idle {
                    if case .running(.fitting) = session.runner.state { break }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                await snap("progress", settle: .milliseconds(30))
                await run.value
            } else {
                await session.evaluateAndWait()
            }
            if session.banner != nil {
                await snap("banner")
                return
            }
        }
        if evaluations > 0, let root = session.resultTree.first {
            session.section = .results
            session.selectedResultID = root.id
            await snap("result")
            // A tall capture of the whole result page (the cards below the hero).
            if snapshots != nil, let window = NSApp.windows.first(where: { $0.title == session.name }) {
                let frame = window.frame
                window.setFrame(NSRect(x: frame.minX, y: frame.maxY - 1700, width: 1280, height: 1700), display: true)
                await snap("result-full")
                window.setFrame(frame, display: true)
            }
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
    /// Opens the Connect sheet and walks it through its states for snapshots.
    private static func connectSheet(_ session: ProjectSession, source: String?, snap: (String, Duration) async -> Void) async {
        session.showConnectSheet()
        guard let model = session.live else { return }
        await model.refresh()
        model.selectedID = source
        await snap("connect-picker", .seconds(1.5))
        guard model.selected != nil else { return }
        let connect = Task { await model.perform(.connect) }
        let deadline = ContinuousClock.now + .seconds(30)
        while model.state != .connecting, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        await snap("connect-connecting", .zero)
        await connect.value
        await snap("connect-ready", .seconds(1))
        model.tab = .channelMap
        await snap("connect-map", .seconds(1))
        if model.labels.count > 2 {
            model.labels[0] = "FC3"; model.labels[1] = "FC4"
            model.montage = "10-20 motor strip"
            model.confirmMap()
            await snap("connect-map-confirmed", .seconds(1))
        }
        // AppKit refuses to quit while a sheet is open, so -BCIQuitWhenDone closes it first.
        if UserDefaults.standard.bool(forKey: "BCIQuitWhenDone") {
            await model.close()
            session.showsConnectSheet = false
            try? await Task.sleep(for: .seconds(1))          // let the sheet finish closing
        }
    }

    /// Brief 004 PR 6: connect, start the preview on the acquisition screen, optionally record
    /// and stop, then show the recording as Recordings lists it. Quitting afterwards goes
    /// through the normal shutdown (the board is released there).
    private static func liveRun(_ session: ProjectSession, source: String, recordSeconds: Int,
                                snap: (String, Duration) async -> Void) async {
        session.showConnectSheet()
        guard let model = session.live else { return }
        await model.refresh()
        model.selectedID = source
        guard model.selected != nil else { return }
        await model.perform(.connect)
        guard model.state == .ready else { return await snap("live-failed", .seconds(1)) }
        // The Demo declares its electrodes (10-10): confirm that map. Synthetic declares
        // nothing, so it records without positions (decision #31).
        if model.declaredMap != nil { model.confirmMap() } else { model.recordWithoutPositions() }
        await model.perform(.startPreview)               // the sheet hands over to the screen
        await snap("live-preview", .seconds(12))         // the 10 s window is full
        guard recordSeconds > 0 else { return }
        await model.perform(.record)
        guard model.isRecording else { return await snap("live-record-refused", .seconds(1)) }
        let shown = min(recordSeconds, 6)
        await snap("live-recording", .seconds(shown))
        if recordSeconds > shown { try? await Task.sleep(for: .seconds(recordSeconds - shown)) }
        await model.perform(.stopRecording)
        await session.liveReload?.value
        await snap("live-stopped", .seconds(1.5))
        guard let id = model.lastRecordingID else { return }
        session.recordingTab = .channels
        session.showInspector = false                    // room for every Segments column
        session.showRecording(id)
        await snap("live-recorded", .seconds(1.5))
        // A tall capture: source, montage head and channel table together.
        if let window = NSApp.windows.first(where: { $0.title == session.name }) {
            let frame = window.frame
            window.setFrame(NSRect(x: frame.minX, y: frame.maxY - 1500, width: frame.width, height: 1500), display: true)
            await snap("live-recorded-full", .seconds(2))
            window.setFrame(frame, display: true)
        }
        session.recordingTab = .segments
        await snap("live-recorded-segments", .seconds(1))
        session.recordingTab = .quality
        await session.awaitInspection()
        await snap("live-recorded-quality", .seconds(1.5))
    }

    /// Captures every visible titled window of this app into `<name>-<n>-<title>.png`.
    /// Uses the window server's own-window capture (`CGWindowListCreateImage`, looked up at
    /// run time: it is deprecated, and this is debug-only tooling); an app may always image
    /// its own windows, so no Screen Recording permission is involved.
    private static func snapshotWindows(into dir: URL, name: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let capture = unsafeBitCast(sym, to: Capture.self)
        let windows = NSApp.windows.filter { $0.isVisible && ($0.styleMask.contains(.titled) || $0.isSheet) }
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
