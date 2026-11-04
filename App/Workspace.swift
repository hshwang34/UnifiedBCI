import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Declared (exported, conforming to com.apple.package) in project.yml's Info.plist
    /// properties, so Finder shows a `.bciproj` folder as one document.
    static let bciProject = UTType(exportedAs: "com.hshwang34.bciproj", conformingTo: .package)
}

/// Where recent projects are remembered. The app uses `NSDocumentController` (so the
/// system's recents and Finder agree); tests use an in-memory list.
@MainActor
protocol RecentDocuments: AnyObject {
    var urls: [URL] { get }
    func note(_ url: URL)
    func remove(_ url: URL)
    func clear()
}

@MainActor
final class SystemRecentDocuments: RecentDocuments {
    private var controller: NSDocumentController { .shared }

    var urls: [URL] { controller.recentDocumentURLs }

    func note(_ url: URL) { controller.noteNewRecentDocumentURL(url) }

    /// NSDocumentController can only clear everything; re-note the rest oldest first so
    /// their order survives.
    func remove(_ url: URL) {
        let keep = urls.filter { $0.standardizedFileURL != url.standardizedFileURL }
        controller.clearRecentDocuments(nil)
        for u in keep.reversed() { controller.noteNewRecentDocumentURL(u) }
    }

    func clear() { controller.clearRecentDocuments(nil) }
}

@MainActor
final class InMemoryRecentDocuments: RecentDocuments {
    private(set) var urls: [URL] = []
    func note(_ url: URL) { urls.removeAll { $0 == url }; urls.insert(url, at: 0) }
    func remove(_ url: URL) { urls.removeAll { $0 == url } }
    func clear() { urls = [] }
}

/// App-wide state: open project sessions (exactly one per project directory), their
/// windows, and recents. The orphan sweep in `ProjectStore.open` assumes no second store
/// is evaluating in the same directory, so a project is never opened twice: every path
/// is canonicalized, a second open of the same project returns the same session, and a
/// second window for it is closed in favour of the first.
@MainActor
@Observable
final class Workspace {
    private(set) var sessions: [URL: ProjectSession] = [:]
    private(set) var recents: [RecentProject] = []
    let launch: WorkerLaunch?
    /// The Welcome window's mode: the first-run intro or the welcome screen (brief 003).
    var welcomeFlow = WelcomeFlow()

    /// Installed by the first view that has `openWindow` in its environment.
    @ObservationIgnored var openWindow: OpenWindowAction?
    @ObservationIgnored private var opening: [URL: Task<ProjectSession, Error>] = [:]
    @ObservationIgnored private var adopting: [URL: Task<ProjectSession, Never>] = [:]
    /// Sessions being shut down, by key. The key stays reserved until the old session's
    /// worker and run have stopped, so a reopen never overlaps two stores on one directory.
    @ObservationIgnored private var closing: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private var windows: [URL: WeakWindow] = [:]
    @ObservationIgnored private var closeGuards: [URL: CloseGuard] = [:]
    @ObservationIgnored private var closeObservers: [URL: NSObjectProtocol] = [:]
    @ObservationIgnored private let recentStore: RecentDocuments

    init(recents: RecentDocuments, launch: WorkerLaunch?) {
        self.recentStore = recents
        self.launch = launch
        refreshRecents()
    }

    /// The one key for a project directory, always with a trailing slash. For an existing
    /// directory it is the path the file system reports for the open directory
    /// (`F_GETPATH`): symlinks resolved and the on-disk letter case, so `Tiny.bciproj` and
    /// `tiny.bciproj` on a case-insensitive APFS volume are one project. A path that does
    /// not exist yet falls back to a standardized, symlink-resolved spelling.
    nonisolated static func canonical(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd >= 0 {
            defer { Darwin.close(fd) }
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if fcntl(fd, F_GETPATH, &buf) != -1 {
                let resolved = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                return URL(fileURLWithPath: resolved, isDirectory: true)
            }
        }
        return URL(fileURLWithPath: url.standardizedFileURL.resolvingSymlinksInPath().path, isDirectory: true)
    }

    // MARK: Sessions

    /// The session for the project at `url`, opening it if needed. Concurrent calls for
    /// the same project share one open; a session still shutting down is waited for.
    func session(for url: URL) async throws -> ProjectSession {
        let key = Self.canonical(url)
        while let teardown = closing[key] { await teardown.value }
        if let existing = sessions[key] { return existing }
        if let pending = opening[key] { return try await pending.value }
        if let pending = adopting[key] { return await pending.value }
        let launch = self.launch
        // The task registers the session and releases the key itself (as `close` does),
        // so a waiter that resumes first never re-checks into a finished open still
        // holding the key, nor into a gap with neither key nor session.
        let task = Task {
            defer { self.opening[key] = nil }
            let session = try await ProjectSession.open(at: key, launch: launch)
            self.sessions[key] = session
            return session
        }
        opening[key] = task
        return try await task.value
    }

    /// The session for a project window that may close before the open finishes. If the
    /// window is gone by then (`stillWanted` false) and no other window shows the project,
    /// the session is closed instead of leaking with its worker.
    func session(forWindow url: URL, stillWanted: () -> Bool) async throws -> ProjectSession? {
        let session = try await session(for: url)
        guard stillWanted() || windows[session.url]?.window != nil else {
            await close(session.url)
            return nil
        }
        return session
    }

    /// Registers a store that is already open (just created or imported). Concurrent
    /// adopts of one project share one session.
    func adopt(_ store: ProjectStore) async -> ProjectSession {
        let key = Self.canonical(store.directory)
        // Every await below can change the state, so re-check from the top after each.
        while true {
            if let teardown = closing[key] { await teardown.value; continue }
            if let existing = sessions[key] { return existing }
            if let pending = adopting[key] { return await pending.value }
            if let pending = opening[key] {
                if let session = try? await pending.value { return session }
                continue    // that open failed; this store is still good to adopt
            }
            break
        }
        let launch = self.launch
        let task = Task {
            defer { self.adopting[key] = nil }
            let session = await ProjectSession.adopt(store, url: key, launch: launch)
            self.sessions[key] = session
            return session
        }
        adopting[key] = task
        return await task.value
    }

    /// Ends a project's session: stops its run (bounded) and worker, then forgets it. The
    /// key stays reserved until that is done.
    func close(_ url: URL, window closingWindow: ObjectIdentifier? = nil) async {
        let key = Self.canonical(url)
        // A window closing late must not unregister a newer window for the same project.
        if let closingWindow, let current = windows[key]?.window, ObjectIdentifier(current) != closingWindow {
            return
        }
        windows[key] = nil
        closeGuards[key] = nil
        if let observer = closeObservers.removeValue(forKey: key) { NotificationCenter.default.removeObserver(observer) }
        if let teardown = closing[key] { return await teardown.value }
        guard let session = sessions.removeValue(forKey: key) else { return }
        // The task releases the key itself, before anyone awaiting it resumes, so a
        // waiter's re-check never sees a finished teardown still holding the key.
        let task = Task {
            await session.shutdown()
            self.closing[key] = nil
        }
        closing[key] = task
        await task.value
    }

    var isClosingAny: Bool { !closing.isEmpty }

    /// Closes every project at once (quit): sessions still open and teardowns already
    /// under way, concurrently, so N projects take one shutdown's time, not N. A window
    /// closed mid-commit is waited for here too, so quitting never cuts a store short.
    func closeAll() async {
        let keys = Array(sessions.keys)
        let teardowns = Array(closing.values)
        await withTaskGroup(of: Void.self) { group in
            for key in keys { group.addTask { await self.close(key) } }
            for teardown in teardowns { group.addTask { await teardown.value } }
        }
    }

    // MARK: Windows

    /// Brings the project's window forward, or opens one. Never a second window.
    func show(_ url: URL) {
        let key = Self.canonical(url)
        if let window = windows[key]?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        openWindow?(value: key)
    }

    /// Called by a project window once it has an `NSWindow`. A second window for a
    /// project that already has one is closed and the first focused.
    func attach(_ window: NSWindow, to url: URL) {
        let key = Self.canonical(url)
        if let existing = windows[key]?.window, existing !== window {
            window.close()
            existing.makeKeyAndOrderFront(nil)
            return
        }
        guard windows[key]?.window !== window else { return }
        windows[key] = WeakWindow(window: window)
        let closeGuard = CloseGuard(window: window) { [weak self] in self?.sessions[key] }
        closeGuards[key] = closeGuard
        let closingID = ObjectIdentifier(window)
        if let old = closeObservers.removeValue(forKey: key) { NotificationCenter.default.removeObserver(old) }
        closeObservers[key] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let registered = self.windows[key]?.window, ObjectIdentifier(registered) == closingID else { return }
                // Synchronously, so a reopen in the same turn opens a new window.
                self.windows[key] = nil
                if let observer = self.closeObservers.removeValue(forKey: key) { NotificationCenter.default.removeObserver(observer) }
                Task { await self.close(key, window: closingID) }
            }
        }
    }

    var hasProjectWindows: Bool { windows.values.contains { $0.window != nil } }

    /// Whether closing this project's window must ask first: a run is in flight and can
    /// still be cancelled. (While storing, closing waits for the commit instead.)
    static func closeNeedsConfirmation(_ session: ProjectSession?) -> Bool {
        guard let session, session.isRunning else { return false }
        return session.runner.state != .running(.storing)
    }

    // MARK: Recents

    func noteRecent(_ url: URL) {
        recentStore.note(Self.canonical(url))
        refreshRecents()
    }

    func removeRecent(_ url: URL) {
        recentStore.remove(url)
        refreshRecents()
    }

    func clearRecents() {
        recentStore.clear()
        refreshRecents()
    }

    func refreshRecents() {
        recents = recentStore.urls.map { RecentProject(url: $0) }
    }

    // MARK: User actions (panels and alerts live here, not in the testable core)

    /// Opens a project chosen anywhere (panel, recents, Finder, launch argument).
    func open(_ url: URL) async {
        do {
            let session = try await session(for: url)
            noteRecent(session.url)
            show(session.url)
        } catch {
            Self.alert(Self.openFailureMessage(error), info: url.path)
        }
    }

    static func openFailureMessage(_ error: Error) -> String {
        switch error {
        case ProjectStoreError.notAProject: return "Not a BCI Workspace project."
        case ProjectStoreError.unsupportedFormatVersion(let found, let supported):
            return "This project was written by a newer version (format \(found); this app reads up to \(supported))."
        default: return "The project could not be opened. \(error.localizedDescription)"
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true      // a declared package shows as a file
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.bciProject]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await open(url) }
    }

    func newProjectPanel() {
        let panel = NSSavePanel()
        panel.title = "New Project"
        panel.prompt = "Create"
        panel.allowedContentTypes = [.bciProject]
        panel.nameFieldStringValue = Self.freeName("Untitled", in: Self.documents)
        panel.directoryURL = Self.documents
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let name = url.deletingPathExtension().lastPathComponent
                let store = try await Task.detached(priority: .userInitiated) { try ProjectStore.create(at: url, name: name) }.value
                let session = await adopt(store)
                noteRecent(session.url)
                show(session.url)
            } catch ProjectStoreError.alreadyExists {
                Self.alert("A file named “\(url.lastPathComponent)” already exists.", info: "Projects are never overwritten. Choose a new name.")
            } catch {
                Self.alert("The project could not be created.", info: "\(error)")
            }
        }
    }

    /// Help ▸ Show Welcome Tour (brief 003): restarts the intro at step 0 in the Welcome
    /// window, opening it if needed. Never touches the first-run flag (lead default 6) and
    /// never opens or closes a project.
    func showWelcomeTour(open: OpenWindowAction? = nil) {
        welcomeFlow.start(at: 0)
        // The menu passes its own action, so this works even when no view has installed one
        // yet (e.g. only a project window has opened this run).
        (open ?? openWindow)?(id: "welcome")
    }

    /// Whether this run has already made its first-run decision: the Welcome window can close
    /// and reopen, but the intro is considered once per launch.
    private(set) var checkedFirstRun = false

    /// The first-run gate (lead default 6), once per launch. Returns whether it presented.
    @discardableResult
    func presentIntroIfFirstRun(_ firstRun: FirstRun, reset: Bool = false, introStep: Int? = nil) -> Bool {
        guard !checkedFirstRun else { return false }
        checkedFirstRun = true
        return firstRun.presentIfNeeded(flow: &welcomeFlow, reset: reset, introStep: introStep)
    }

    func exploreExamplePanel() {
        let panel = NSSavePanel()
        panel.title = "Explore an Example"
        panel.message = "Copies the bundled public recording (PhysioNet EEGMMIDB, subject S001) into a new project. Nothing is downloaded."
        panel.prompt = "Create"
        panel.allowedContentTypes = [.bciProject]
        panel.directoryURL = Self.documents
        panel.nameFieldStringValue = Self.freeName("BCI Example", in: Self.documents)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await exploreExample(at: url) }
    }

    /// Creates a project from the app bundle's example (and nothing else) and opens it.
    func exploreExample(at destination: URL, bundle: Bundle = .main) async {
        guard let source = BundledExample.locate(in: bundle) else {
            Self.alert("The bundled example is missing from this copy of the app.", info: "Reinstall BCI Workspace.")
            return
        }
        do {
            let store = try await Task.detached(priority: .userInitiated) {
                try ProjectStore.importBundledExample(from: source, into: destination)
            }.value
            let session = await adopt(store)
            noteRecent(session.url)
            show(session.url)
        } catch ProjectStoreError.alreadyExists {
            Self.alert("A file named “\(destination.lastPathComponent)” already exists.", info: "The example is never copied over an existing file. Choose a new name.")
        } catch {
            Self.alert("The example could not be created.", info: "\(error)")
        }
    }

    func exportPanel(for session: ProjectSession) {
        guard let id = session.selectedResultID, let meta = session.results.first(where: { $0.resultID == id }) else { return }
        let panel = NSSavePanel()
        panel.title = "Export Result"
        panel.message = "Writes a folder with the samples, events, channel map, pipeline, model arrays, evaluation and attribution."
        panel.prompt = "Export"
        let stamp = meta.createdAt.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        panel.nameFieldStringValue = "\(session.name) result \(stamp)".replacingOccurrences(of: "/", with: "-")
        panel.directoryURL = Self.documents
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await session.export(resultID: id, to: url) }
    }

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// "BCI Example.bciproj", or "BCI Example 2.bciproj" … if that exists.
    static func freeName(_ base: String, in dir: URL) -> String {
        var n = 1
        while true {
            let name = n == 1 ? "\(base).bciproj" : "\(base) \(n).bciproj"
            if !FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) { return name }
            n += 1
        }
    }

    static func alert(_ message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// Sits in front of SwiftUI's window delegate: asks before a project window closes during
/// an evaluation ("Stop the evaluation and close? Nothing will be saved."); every other
/// delegate message goes to SwiftUI's delegate unchanged.
@MainActor
final class CloseGuard: NSObject, NSWindowDelegate {
    private weak var original: NSWindowDelegate?
    private weak var window: NSWindow?
    private let session: @MainActor () -> ProjectSession?

    init(window: NSWindow, session: @escaping @MainActor () -> ProjectSession?) {
        self.original = window.delegate
        self.window = window
        self.session = session
        super.init()
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let current = session()
        guard Workspace.closeNeedsConfirmation(current), let current else {
            return original?.windowShouldClose?(sender) ?? true
        }
        let alert = NSAlert()
        alert.messageText = "Stop the evaluation and close?"
        alert.informativeText = "Nothing will be saved."
        alert.addButton(withTitle: "Stop and Close")
        alert.addButton(withTitle: "Keep Running")
        alert.beginSheetModal(for: sender) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                current.cancel()
                sender.close()
            }
        }
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }
}

private struct WeakWindow {
    weak var window: NSWindow?
}

/// Hands the hosting `NSWindow` to a callback once the view is in a window.
struct WindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { ReaderView(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let onWindow: @MainActor (NSWindow) -> Void
        init(onWindow: @escaping @MainActor (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Out of the view update that moved us, so state changes are safe.
            DispatchQueue.main.async { [onWindow] in onWindow(window) }
        }
    }
}
