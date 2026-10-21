import CryptoKit
import Foundation

/// The one durable-write protocol every manifest and chunk in a project uses
/// (docs/data-contracts.md, "Atomic rewrites"): write the complete content to a sibling
/// temp file, `fsync` it, `rename(2)` over the target, `fsync` the directory. A crash at
/// any point leaves the old file or the new file, never a torn one, plus at most one
/// temp file that `ProjectStore.open` deletes.
enum AtomicFile {
    static let tempPrefix = ".tmp-"

    static func tempURL(for target: URL) -> URL {
        target.deletingLastPathComponent().appendingPathComponent(tempPrefix + target.lastPathComponent)
    }

    /// Writes `data` durably to `target`. `between` runs after each step so a test can
    /// kill the process at a named point; production passes nothing.
    static func write(_ data: Data, to target: URL, between: ((Step) -> Void)? = nil) throws {
        let tmp = tempURL(for: target)
        try writeAndSync(data, to: tmp, afterWrite: { between?(.tmpWritten) })
        between?(.synced)
        try rename(tmp, to: target)
        try syncDirectory(target.deletingLastPathComponent())
        between?(.renamed)
    }

    enum Step { case tmpWritten, synced, renamed }

    /// Creates (or truncates) `url`, writes all of `data`, and fsyncs the file.
    static func writeAndSync(_ data: Data, to url: URL, afterWrite: (() -> Void)? = nil) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ProjectStoreError.io("open \(url.lastPathComponent)", errno) }
        defer { close(fd) }
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buf.count {
                let n = Foundation.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ProjectStoreError.io("write \(url.lastPathComponent)", errno)
                }
                offset += n
            }
        }
        afterWrite?()
        // F_FULLFSYNC asks the drive to flush its own cache too; plain fsync(2) on
        // macOS only pushes to the drive. Fall back when the volume does not support it.
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
            throw ProjectStoreError.io("fsync \(url.lastPathComponent)", errno)
        }
    }

    static func rename(_ from: URL, to: URL) throws {
        guard Foundation.rename(from.path, to.path) == 0 else {
            throw ProjectStoreError.io("rename \(from.lastPathComponent) -> \(to.lastPathComponent)", errno)
        }
    }

    static func syncDirectory(_ dir: URL) throws {
        let fd = open(dir.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ProjectStoreError.io("open dir \(dir.lastPathComponent)", errno) }
        defer { close(fd) }
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
            throw ProjectStoreError.io("fsync dir \(dir.lastPathComponent)", errno)
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ProjectStoreError: Error, CustomStringConvertible, Sendable {
    case notAProject(URL)
    case unsupportedFormatVersion(found: Int, supported: Int)
    case missingRecording(UUID)
    case missingResult(UUID)
    case missingPipeline(UUID)
    case alreadyExists(URL)
    case integrity([IntegrityIssue])
    case invalidChunk(String)
    /// `recording.json` decoded but describes something impossible (a channel row no
    /// chunk has, a non-canonical chunk path, overflowing dimensions). Refused, not fixed.
    case invalidManifest(String)
    case io(String, Int32)

    public var description: String {
        switch self {
        case .notAProject(let url): return "\(url.path) is not a .bciproj directory (no readable project.json)"
        case .unsupportedFormatVersion(let found, let supported): return "project format version \(found) is newer than this app's \(supported)"
        case .missingRecording(let id): return "no recording \(id.uuidString) in this project"
        case .missingResult(let id): return "no result \(id.uuidString) in this project"
        case .missingPipeline(let id): return "no pipeline \(id.uuidString) in this project"
        case .alreadyExists(let url): return "\(url.path) already exists"
        case .integrity(let issues): return "integrity: " + issues.map(\.description).joined(separator: "; ")
        case .invalidChunk(let why): return "invalid chunk: \(why)"
        case .invalidManifest(let why): return "invalid recording manifest: \(why)"
        case .io(let what, let code): return "\(what): \(String(cString: strerror(code))) (errno \(code))"
        }
    }
}

/// A chunk whose bytes disagree with the manifest. Reported, never repaired: the
/// manifest is the claim and the file is the evidence; the app does not get to pick.
public struct IntegrityIssue: Sendable, Equatable, CustomStringConvertible {
    public enum Kind: String, Sendable { case hashMismatch, missingChunk, sizeMismatch, unlistedChunk }
    public var kind: Kind
    public var file: String
    public var detail: String

    public var description: String { "\(kind.rawValue) \(file): \(detail)" }
}
