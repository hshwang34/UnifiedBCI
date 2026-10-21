import Foundation

/// Where to find a Python interpreter that can `import bciworkspace_worker`.
public struct WorkerLaunch: Sendable, Equatable {
    public enum Origin: Sendable, Equatable { case bundled, developmentVenv }

    public let origin: Origin
    public let python: URL
    public let pythonPath: String?
    public let workingDirectory: URL

    public init(origin: Origin, python: URL, pythonPath: String?, workingDirectory: URL) {
        self.origin = origin
        self.python = python
        self.pythonPath = pythonPath
        self.workingDirectory = workingDirectory
    }

    /// Resolution order:
    /// 1. A worker bundled by scripts/bundle_worker.sh at Contents/Resources/worker/
    /// 2. The development venv named by the `BCIWorkerDevRoot` Info.plist key
    /// Nothing else: the app must never pick up a system Python.
    public static func locate(bundle: Bundle = .main, fileManager: FileManager = .default) -> WorkerLaunch? {
        if let res = bundle.resourceURL {
            let root = res.appendingPathComponent("worker", isDirectory: true)
            let python = root.appendingPathComponent("python/bin/python3")
            let site = root.appendingPathComponent("site", isDirectory: true)
            if fileManager.isExecutableFile(atPath: python.path), fileManager.fileExists(atPath: site.path) {
                return WorkerLaunch(origin: .bundled, python: python, pythonPath: site.path, workingDirectory: root)
            }
        }
        if let dev = bundle.object(forInfoDictionaryKey: "BCIWorkerDevRoot") as? String, !dev.isEmpty {
            let root = URL(fileURLWithPath: dev, isDirectory: true)
            let python = root.appendingPathComponent(".venv/bin/python")
            if fileManager.isExecutableFile(atPath: python.path) {
                return WorkerLaunch(origin: .developmentVenv, python: python, pythonPath: nil, workingDirectory: root)
            }
        }
        return nil
    }
}
