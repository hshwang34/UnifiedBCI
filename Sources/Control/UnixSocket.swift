import Darwin
import Foundation

/// Minimal blocking Unix-domain stream sockets for the control protocol. The server reads
/// each connection on its own thread; the `bci` tool is single-threaded per request.
public enum UnixSocket {
    public struct Failure: Error, CustomStringConvertible {
        public let call: String
        public let errno: Int32
        public var description: String { "\(call): \(String(cString: strerror(errno)))" }
    }

    /// `sockaddr_un` for `path`, or nil when the path is too long for one (104 bytes).
    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// Binds and listens at `path` with mode 0600. A socket file left by a crashed app is
    /// replaced only when nothing answers on it.
    public static func listen(at path: String) throws -> Int32 {
        guard var addr = address(path) else { throw Failure(call: "socket path too long (\(path.utf8.count) bytes)", errno: ENAMETOOLONG) }
        if FileManager.default.fileExists(atPath: path) {
            if let probe = try? connect(to: path) {
                Darwin.close(probe)
                throw Failure(call: "another BCI Workspace is already listening at \(path)", errno: EADDRINUSE)
            }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(call: "socket", errno: errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let old = umask(0o177)
        defer { umask(old) }
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0 else { let e = errno; Darwin.close(fd); throw Failure(call: "bind", errno: e) }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else { let e = errno; Darwin.close(fd); throw Failure(call: "listen", errno: e) }
        return fd
    }

    public static func connect(to path: String) throws -> Int32 {
        guard var addr = address(path) else { throw Failure(call: "socket path too long", errno: ENAMETOOLONG) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(call: "socket", errno: errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard r == 0 else { let e = errno; Darwin.close(fd); throw Failure(call: "connect", errno: e) }
        return fd
    }

    /// Accepts one connection; nil when the listening socket was closed.
    public static func accept(_ listener: Int32) -> Int32? {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            if fd >= 0 {
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                return fd
            }
            if errno == EINTR || errno == ECONNABORTED { continue }
            return nil
        }
    }

    /// The connecting process's uid (`getpeereid`).
    public static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    /// Writes all of `data`; false when the peer went away.
    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(fd, p, left)
                if n < 0 { if errno == EINTR { continue }; return false }
                left -= n
                p = p.advanced(by: n)
            }
            return true
        }
    }

    /// Reads what is available (blocking); nil at end of stream or on error.
    public static func read(_ fd: Int32, max: Int = 64 * 1024) -> Data? {
        var buf = [UInt8](repeating: 0, count: max)
        while true {
            let n = Darwin.read(fd, &buf, max)
            if n > 0 { return Data(buf[0..<n]) }
            if n < 0, errno == EINTR { continue }
            return nil
        }
    }
}

/// A blocking client connection: one request at a time, events handed to a callback.
public final class ControlClientConnection {
    private let fd: Int32
    private var lines = LineBuffer()
    private var pending: [Data] = []
    private var next = 0

    public init(socketPath: String) throws { fd = try UnixSocket.connect(to: socketPath) }
    deinit { Darwin.close(fd) }

    /// Sends `hello` with the token; throws the server's error (e.g. `protocol_mismatch`).
    public func hello(token: String, client: String) throws -> JSON {
        try call("hello", params: ["protocol": .int(Int64(ControlProtocol.version)), "token": .string(token), "client": .string(client)])
    }

    /// Sends one request and returns its result; events for it go to `onEvent`.
    public func call(_ method: String, params: JSON? = nil, async: Bool? = nil, onEvent: ((ControlMessage) -> Void)? = nil) throws -> JSON {
        next += 1
        let id = "c\(next)"
        guard UnixSocket.writeAll(fd, ControlRequest(id: id, method: method, params: params, async: async).line()) else {
            throw ControlError(.internal, "the app closed the connection")
        }
        while true {
            let line = try nextLine()
            guard let msg = try? JSONDecoder().decode(ControlMessage.self, from: line) else { continue }
            if msg.isEvent { if msg.id == id { onEvent?(msg) }; continue }
            guard msg.id == id else { continue }
            if let error = msg.error { throw error }
            return msg.result ?? .null
        }
    }

    private func nextLine() throws -> Data {
        while pending.isEmpty {
            guard let chunk = UnixSocket.read(fd) else { throw ControlError(.internal, "the app closed the connection") }
            pending = try lines.append(chunk)
        }
        return pending.removeFirst()
    }
}
