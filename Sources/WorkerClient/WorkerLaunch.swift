import Foundation

/// Where to find a Python interpreter that can `import bciworkspace_worker`, and how to
/// start it so nothing from the user's environment leaks into the process.
public struct WorkerLaunch: Sendable, Equatable {
    public enum Origin: Sendable, Equatable { case bundled, developmentVenv }

    /// What to run: the worker module, or (tests only) a stand-in script.
    public enum Entry: Sendable, Equatable {
        case module(String)
        case script(URL)
    }

    public let origin: Origin
    public let python: URL
    public let pythonPath: String?
    public let workingDirectory: URL
    public var entry: Entry = .module("bciworkspace_worker")

    public init(origin: Origin, python: URL, pythonPath: String?, workingDirectory: URL, entry: Entry = .module("bciworkspace_worker")) {
        self.origin = origin
        self.python = python
        self.pythonPath = pythonPath
        self.workingDirectory = workingDirectory
        self.entry = entry
    }

    /// Interpreter flags. `-I` (isolated: ignores PYTHON* variables, user site, and the
    /// script/cwd path entry) is used wherever the import path comes from the interpreter
    /// itself — the dev venv. The bundled worker installs its packages with `--target`,
    /// which only `PYTHONPATH` can add, and `-I` implies `-E` which discards it (verified
    /// on 3.12); that case uses `-s -P` and relies on `environment()` having scrubbed
    /// everything else. `-u -B -X utf8` replace the PYTHON* variables `-I` would ignore.
    public var interpreterArguments: [String] {
        let isolation = pythonPath == nil ? ["-I"] : ["-s", "-P"]
        return isolation + ["-u", "-B", "-X", "utf8"]
    }

    public var arguments: [String] {
        switch entry {
        case .module(let name): return interpreterArguments + ["-m", name]
        case .script(let url): return interpreterArguments + [url.path]
        }
    }

    /// Inherited environment minus anything that redirects the interpreter, plus the
    /// settings the worker expects. Mirrors what worker/main.py sets for itself.
    public func environment(inheriting base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        // Every PYTHON* variable (PYTHONINSPECT=1 alone would park the worker in a REPL)
        // and every DYLD_* injection goes; then the handful we rely on are set explicitly.
        var env = base.filter { !($0.key.hasPrefix("PYTHON") || $0.key.hasPrefix("DYLD_")) }
        for key in ["VIRTUAL_ENV", "CONDA_PREFIX"] {
            env.removeValue(forKey: key)
        }
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONUTF8"] = "1"
        // Single-threaded BLAS: bit-reproducible fits that never compete with acquisition.
        for key in ["OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS", "NUMEXPR_NUM_THREADS"] {
            env[key] = "1"
        }
        if let pythonPath { env["PYTHONPATH"] = pythonPath }
        return env
    }

    /// Resolution order:
    /// 1. A worker bundled by scripts/bundle_worker.sh at Contents/Resources/worker/
    /// 2. The development venv named by the `BCIWorkerDevRoot` Info.plist key (Debug builds only)
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
