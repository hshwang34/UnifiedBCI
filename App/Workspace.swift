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

    /// Installed by the first view that has `openWindow` in its environment.
    @ObservationIgnored var openWindow: OpenWindowAction?
    @ObservationIgnored private var opening: [URL: Task<ProjectSession, Error>] = [:]
    @ObservationIgnored private var windows: [URL: WeakWindow] = [:]
    @ObservationIgnored private let recentStore: RecentDocuments

    init(recents: RecentDocuments, launch: WorkerLaunch?) {
        self.recentStore = recents
        self.launch = launch
        refreshRecents()
    }

    /// The one spelling of a project path: standardized (`.`/`..` removed), symlinks
    /// resolved, always with a trailing slash. Two URLs naming the same directory compare equal.
    nonisolated static func canonical(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.resolvingSymlinksInPath().path, isDirectory: true)
    }

    // MARK: Sessions

    /// The session for the project at `url`, opening it if needed. Concurrent calls for
    /// the same project share one open.
    func session(for url: URL) async throws -> ProjectSession {
        let key = Self.canonical(url)
        if let existing = sessions[key] { return existing }
        if let pending = opening[key] { return try await pending.value }
        let launch = self.launch
        let task = Task { try await ProjectSession.open(at: key, launch: launch) }
        opening[key] = task
        defer { opening[key] = nil }
        let session = try await task.value
        sessions[key] = session
        return session
    }

    /// Registers a store that is already open (just created or imported).
    func adopt(_ store: ProjectStore) async -> ProjectSession {
        let key = Self.canonical(store.directory)
        if let existing = sessions[key] { return existing }
        let session = await ProjectSession.adopt(store, url: key, launch: launch)
        sessions[key] = session
        return session
    }

    /// Ends a project's session: stops its worker and forgets it.
    func close(_ url: URL) async {
        let key = Self.canonical(url)
        windows[key] = nil
        guard let session = sessions.removeValue(forKey: key) else { return }
        await session.shutdown()
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
        let closingID = ObjectIdentifier(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let registered = self.windows[key]?.window, ObjectIdentifier(registered) == closingID else { return }
                Task { await self.close(key) }
            }
        }
    }

    var hasProjectWindows: Bool { windows.values.contains { $0.window != nil } }

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
