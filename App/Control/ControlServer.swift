import Darwin
import Foundation
import Security

/// The local control server (brief 008, decision #47). It listens only while agent control
/// is on. The socket is in a 0700 directory, peers must be this user (`getpeereid`), and
/// the first message must carry the per-launch token. Socket I/O runs on threads of its own;
/// requests go to the main actor (`ControlRouter`).
final class ControlServer: @unchecked Sendable {
    let directory: URL
    var socketPath: String { ControlProtocol.socketURL(in: directory).path }
    private(set) var token = ""
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var connections: [UUID: ControlConnection] = [:]
    private let dispatch: @Sendable (ControlRequest, ControlConnection) -> Void
    private let closed: @Sendable (ControlConnection) -> Void

    init(directory: URL = ControlProtocol.directory(),
         dispatch: @escaping @Sendable (ControlRequest, ControlConnection) -> Void,
         closed: @escaping @Sendable (ControlConnection) -> Void = { _ in }) {
        self.directory = directory
        self.dispatch = dispatch
        self.closed = closed
    }

    var isListening: Bool { lock.withLock { listener >= 0 } }

    func start(appVersion: String) throws {
        guard !isListening else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        token = Self.newToken()
        try Self.writePrivate(Data(token.utf8), to: ControlProtocol.tokenURL(in: directory))
        let fd = try UnixSocket.listen(at: socketPath)
        lock.withLock { listener = fd }
        let info = ControlServerInfo(pid: getpid(), protocol: ControlProtocol.version, appVersion: appVersion, socket: socketPath)
        try Self.writePrivate(try JSON.encoder(pretty: true).encode(info), to: ControlProtocol.serverURL(in: directory))
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "BCI control accept"
        thread.start()
    }

    func stop() {
        let (fd, open) = lock.withLock { () -> (Int32, [ControlConnection]) in
            let fd = listener
            listener = -1
            let open = Array(connections.values)
            connections = [:]
            return (fd, open)
        }
        guard fd >= 0 else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        for c in open { c.close() }
        unlink(socketPath)
        unlink(ControlProtocol.tokenURL(in: directory).path)
        unlink(ControlProtocol.serverURL(in: directory).path)
    }

    private func acceptLoop(_ fd: Int32) {
        while let client = UnixSocket.accept(fd) {
            guard UnixSocket.peerUID(client) == getuid() else { Darwin.close(client); continue }
            let c = ControlConnection(fd: client)
            lock.withLock { connections[c.id] = c }
            let thread = Thread { [weak self] in self?.readLoop(c) }
            thread.name = "BCI control connection"
            thread.start()
        }
    }

    private func readLoop(_ c: ControlConnection) {
        var lines = LineBuffer()
        defer {
            c.close()
            _ = lock.withLock { connections.removeValue(forKey: c.id) }
            closed(c)
        }
        while let chunk = UnixSocket.read(c.fd) {
            let batch: [Data]
            do { batch = try lines.append(chunk) } catch {
                c.send(.failure(nil, ControlError(.badRequest, "line longer than \(ControlProtocol.maxLineBytes) bytes")))
                return
            }
            for line in batch {
                guard let request = try? JSONDecoder().decode(ControlRequest.self, from: line) else {
                    c.send(.failure(nil, ControlError(.badRequest, "not a control request")))
                    continue
                }
                if request.method == "hello" { hello(request, c); continue }
                guard c.isAuthenticated else {
                    c.send(.failure(request.id, ControlError(.unauthorized, "send hello with the token first")))
                    continue
                }
                dispatch(request, c)
            }
        }
    }

    private func hello(_ r: ControlRequest, _ c: ControlConnection) {
        let p = r.params
        guard let given = p?["token"]?.stringValue, Self.equal(given, token) else {
            return c.send(.failure(r.id, ControlError(.unauthorized, "wrong or stale token (the app restarted?)")))
        }
        guard p?["protocol"]?.intValue == ControlProtocol.version else {
            return c.send(.failure(r.id, ControlError(.protocolMismatch, "the app speaks control protocol \(ControlProtocol.version)",
                                                       data: ["protocol": .int(Int64(ControlProtocol.version))])))
        }
        c.client = p?["client"]?.stringValue ?? "unknown"
        c.isAuthenticated = true
        c.send(.response(r.id, [
            "protocol": .int(Int64(ControlProtocol.version)),
            "appVersion": .string(Self.appVersion),
            "schemaHash": .string(ControlCatalog.schemaHash),
            "methods": .array(ControlCatalog.methods.map { .string($0.name) }),
        ]))
    }

    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count, !y.isEmpty else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".tmp-" + url.lastPathComponent)
        let fd = Darwin.open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw UnixSocket.Failure(call: "open \(tmp.path)", errno: errno) }
        let ok = UnixSocket.writeAll(fd, data)
        fchmod(fd, 0o600)
        Darwin.close(fd)
        guard ok, rename(tmp.path, url.path) == 0 else { throw UnixSocket.Failure(call: "write \(url.path)", errno: errno) }
    }
}

/// One client connection; `send` may be called from any thread.
final class ControlConnection: @unchecked Sendable, Hashable {
    let id = UUID()
    let fd: Int32
    private let lock = NSLock()
    private var isClosed = false
    private var _authenticated = false
    private var _client = ""

    init(fd: Int32) { self.fd = fd }

    var isAuthenticated: Bool {
        get { lock.withLock { _authenticated } }
        set { lock.withLock { _authenticated = newValue } }
    }

    var client: String {
        get { lock.withLock { _client } }
        set { lock.withLock { _client = newValue } }
    }

    func send(_ message: ControlMessage) {
        lock.withLock {
            guard !isClosed else { return }
            if !UnixSocket.writeAll(fd, message.line()) { isClosed = true; Darwin.shutdown(fd, SHUT_RDWR) }
        }
    }

    func close() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            Darwin.shutdown(fd, SHUT_RDWR)
        }
    }

    deinit { Darwin.close(fd) }

    static func == (a: ControlConnection, b: ControlConnection) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}
