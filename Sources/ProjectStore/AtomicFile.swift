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
        try writeAndSync(data, to: tmp, fresh: true, afterWrite: { between?(.tmpWritten) })
        between?(.synced)
        try rename(tmp, to: target)
        try syncDirectory(target.deletingLastPathComponent())
        between?(.renamed)
    }

    enum Step { case tmpWritten, synced, renamed }

    /// Creates (or truncates) `url`, writes all of `data`, and fsyncs the file. Never
    /// follows a symbolic link at `url`. `fresh` is for temp files: whatever is at `url`
    /// (a crash leftover, or a link planted in a hostile project) is unlinked first and
    /// the file is created exclusively, so the bytes can only land in a new inode, and a
    /// failure (ENOSPC mid-write) unlinks it again so a full disk is not left fuller.
    static func writeAndSync(_ data: Data, to url: URL, fresh: Bool = false, afterWrite: (() throws -> Void)? = nil) throws {
        if fresh, unlink(url.path) != 0, errno != ENOENT { throw ProjectStoreError.io("unlink \(url.lastPathComponent)", errno) }
        let flags = O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | (fresh ? O_EXCL : O_TRUNC)
        let fd = open(url.path, flags, 0o644)
        guard fd >= 0 else { throw ProjectStoreError.io("open \(url.lastPathComponent)", errno) }
        defer { close(fd) }
        do {
            try writeAll(data, fd: fd, name: url.lastPathComponent)
            try afterWrite?()
            try fullSync(fd, url.lastPathComponent)
        } catch {
            if fresh { unlink(url.path) }
            throw error
        }
    }

    private static func writeAll(_ data: Data, fd: Int32, name: String) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buf.count {
                let n = Foundation.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ProjectStoreError.io("write \(name)", errno)
                }
                offset += n
            }
        }
    }

    /// F_FULLFSYNC asks the drive to flush its own cache too; plain fsync(2) on macOS
    /// only pushes to the drive. Fall back when the volume does not support it.
    static func fullSync(_ fd: Int32, _ name: String) throws {
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
            throw ProjectStoreError.io("fsync \(name)", errno)
        }
    }

    /// Fsyncs a file someone else wrote (the worker's `fitted.npz`, a copied chunk).
    static func syncFile(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ProjectStoreError.io("open \(url.lastPathComponent)", errno) }
        defer { close(fd) }
        try fullSync(fd, url.lastPathComponent)
    }

    /// Fsyncs every regular file under `dir`, then every directory bottom-up, so a
    /// following `rename` of `dir` publishes content that is already on disk. Symbolic
    /// links are neither followed nor synced.
    static func syncTree(_ dir: URL) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: dir.path) {
            let url = dir.appendingPathComponent(name)
            var st = stat()
            guard lstat(url.path, &st) == 0 else { throw ProjectStoreError.io("lstat \(name)", errno) }
            switch st.st_mode & S_IFMT {
            case S_IFREG: try syncFile(url)
            case S_IFDIR: try syncTree(url)
            default: continue
            }
        }
        try syncDirectory(dir)
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
        try fullSync(fd, "dir \(dir.lastPathComponent)")
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
    case invalidChannelMap(String)
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
        case .invalidChannelMap(let why): return "invalid channel map: \(why)"
        case .io(let what, let code): return "\(what): \(String(cString: strerror(code))) (errno \(code))"
        }
    }
}

/// A chunk whose bytes disagree with the manifest. Reported, never repaired: the
/// manifest is the claim and the file is the evidence; the app does not get to pick.
public struct IntegrityIssue: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: String, Sendable { case hashMismatch, missingChunk, sizeMismatch, unlistedChunk, notRegularFile, outsideProject }
    public var kind: Kind
    public var file: String
    public var detail: String

    public var description: String { "\(kind.rawValue) \(file): \(detail)" }
}

/// Bounded reads of small JSON files in a project that may come from anyone. One open, so
/// the checks and the read see the same file: `O_NOFOLLOW` refuses a symbolic link at the
/// last component, `O_NONBLOCK` keeps a FIFO from hanging the open, `fstat` requires a
/// regular file no larger than the cap, and the read stops at cap + 1 bytes, so a file that
/// grows after the `fstat` is refused too. Nil for anything else.
enum BoundedRead {
    static func data(at url: URL, maxBytes: Int) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= maxBytes else { return nil }
        var buffer = Data(count: maxBytes + 1)
        let total = buffer.withUnsafeMutableBytes { raw -> Int in
            var total = 0
            while total < raw.count {
                let n = read(fd, raw.baseAddress! + total, raw.count - total)
                if n < 0, errno == EINTR { continue }
                if n < 0 { return -1 }
                if n == 0 { break }
                total += n
            }
            return total
        }
        guard total >= 0, total <= maxBytes else { return nil }
        return buffer.prefix(total)
    }
}
