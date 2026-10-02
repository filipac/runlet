import Foundation

/// The messages `runlet mcp` and the running app exchange over Runlet's MCP socket (#43):
/// one JSON object per line, small requests from the tool and bounded answers from the app.
/// The socket is the security boundary for other users only (a `0700` folder, a `0600`
/// socket, and the peer's user id checked on both ends); approvals live in the app and are
/// never carried in a message.
public enum MCPBridge {
    public static let version = 1
    /// Largest message the tool may send (code is at most `MCPTools.maxCodeBytes`).
    public static let maxClientMessageBytes = 1 << 20
    /// Largest message the app may send (run output is capped well below this).
    public static let maxAppMessageBytes = 8 << 20

    /// From `runlet mcp` to the app.
    public enum ClientMessage: Sendable, Codable, Equatable {
        case hello(bridgeVersion: Int, helperPID: Int32)
        /// The client `initialize` named (shown in Settings before any call).
        case client(MCPClientInfo)
        case call(id: Int, client: MCPClientInfo, call: MCPToolCall)
        /// The MCP client cancelled the call (or went away).
        case cancel(id: Int)
    }

    /// From the app to `runlet mcp`.
    public enum AppMessage: Sendable, Codable, Equatable {
        case welcome(bridgeVersion: Int, appVersion: String)
        /// Where a call stands ("Waiting for approval in Runlet").
        case status(id: Int, message: String)
        case result(id: Int, result: MCPToolResult)
        /// The app won't serve this connection (a different bridge version); it closes next.
        case refused(String)
    }

    public static func encode<T: Encodable>(_ message: T) -> Data {
        var data = (try? JSONEncoder().encode(message)) ?? Data()
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: String) -> T? {
        try? JSONDecoder().decode(T.self, from: Data(line.utf8))
    }
}

public enum MCPSocketError: Error, Equatable, CustomStringConvertible {
    case pathTooLong(String)
    case unsafeDirectory(String)
    case notASocket(String)
    case inUse(String)
    case notRunning
    case wrongOwner
    case system(String, Int32)

    public var description: String {
        switch self {
        case .pathTooLong(let path): "The socket path is too long: \(path)"
        case .unsafeDirectory(let path): "\(path) must be a folder that only you can open (mode 0700)."
        case .notASocket(let path): "\(path) exists and isn't Runlet's socket; Runlet leaves it alone."
        case .inUse(let path): "Another copy of Runlet already serves AI clients at \(path)."
        case .notRunning: "Runlet's MCP server isn't running."
        case .wrongOwner: "The socket belongs to another user."
        case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Where the app listens: `<data folder>/MCP/runlet.sock`, or, when that path is too long for
/// a Unix socket (a deep `RUNLET_DATA_DIR`), a folder in the per-user temporary directory named
/// after the data folder. Both ends compute the same path, so `RUNLET_DATA_DIR` keeps tests
/// and screenshots away from the real app.
public enum MCPSocketPaths {
    public static let fileName = "runlet.sock"
    /// `sockaddr_un.sun_path` holds 104 bytes with the terminator; keep a margin.
    public static let maximumLength = 100

    public static func socketPath(for paths: AppPaths) -> String {
        let preferred = paths.mcp.appendingPathComponent(fileName).path
        if preferred.utf8.count <= maximumLength { return preferred }
        return userTemporaryDirectory.appendingPathComponent("runlet-mcp-" + shortHash(paths.root.standardizedFileURL.path), isDirectory: true).appendingPathComponent(fileName).path
    }

    /// The per-user temporary folder (`/var/folders/…/T/`), the same for every process of this user.
    public static var userTemporaryDirectory: URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        if length > 0, length <= buffer.count {
            let path = String(decoding: buffer.prefix(length - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    /// FNV-1a, 8 hex digits: stable across processes and launches (unlike `hashValue`).
    static func shortHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(String(hash, radix: 16).suffix(8))
    }

    /// Creates the socket's folder with mode 0700, or checks an existing one: it must be a real
    /// folder (not a link) owned by this user, and is tightened to 0700.
    public static func prepareDirectory(for socketPath: String) throws {
        let directory = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid() else {
            throw MCPSocketError.unsafeDirectory(directory)
        }
        if info.st_mode & 0o077 != 0, chmod(directory, 0o700) != 0 { throw MCPSocketError.unsafeDirectory(directory) }
    }

    /// Whether a socket's folder is private to this user (checked before connecting).
    public static func isPrivateDirectory(for socketPath: String) -> Bool {
        var info = stat()
        let directory = (socketPath as NSString).deletingLastPathComponent
        return lstat(directory, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == geteuid() && info.st_mode & 0o077 == 0
    }
}

extension AppPaths {
    /// Runlet's MCP socket folder (0700; see `MCPSocketPaths`).
    public var mcp: URL { root.appendingPathComponent("MCP", isDirectory: true) }
}

/// Low-level Unix socket helpers shared by the listener and the client.
enum UnixSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw MCPSocketError.pathTooLong(path) }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPSocketError.system("socket", errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func connect(_ fd: Int32, to path: String) throws {
        var address = try address(path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw MCPSocketError.system("connect", errno) }
    }

    /// Whether something listens at `path`.
    static func isListening(_ path: String) -> Bool {
        guard let fd = try? makeSocket() else { return false }
        defer { close(fd) }
        return (try? connect(fd, to: path)) != nil
    }

    /// The peer's user id (`getpeereid`).
    static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    /// The peer's process id (`LOCAL_PEERPID`), for display.
    static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        // SOL_LOCAL (0) / LOCAL_PEERPID (0x002) from <sys/un.h>.
        return getsockopt(fd, 0, 0x002, &pid, &length) == 0 && pid > 0 ? pid : nil
    }

    static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// Writes everything, waiting up to `timeout` seconds in total for a slow reader.
    static func writeAll(_ fd: Int32, _ data: Data, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var offset = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            while offset < data.count {
                let written = write(fd, base + offset, data.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                guard written < 0, errno == EAGAIN || errno == EWOULDBLOCK else { return false }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return false }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&descriptor, 1, Int32(min(remaining, 1) * 1000))
            }
            return true
        }
    }
}

/// The app's end: listens on the MCP socket and exchanges `MCPBridge` messages with each
/// `runlet mcp` process. Connections from other users are closed at once. Events arrive on the
/// listener's own queue.
public final class MCPSocketListener: @unchecked Sendable {
    public struct Events: Sendable {
        public var connected: @Sendable (UUID, pid_t?) -> Void
        public var message: @Sendable (UUID, MCPBridge.ClientMessage) -> Void
        public var disconnected: @Sendable (UUID) -> Void

        public init(connected: @escaping @Sendable (UUID, pid_t?) -> Void, message: @escaping @Sendable (UUID, MCPBridge.ClientMessage) -> Void, disconnected: @escaping @Sendable (UUID) -> Void) {
            self.connected = connected
            self.message = message
            self.disconnected = disconnected
        }
    }

    private final class Connection {
        let id = UUID()
        let fd: Int32
        var framer = JSONLineFramer(maxLineBytes: MCPBridge.maxClientMessageBytes)
        var source: DispatchSourceRead?

        init(fd: Int32) {
            self.fd = fd
        }
    }

    public let path: String
    /// Connections at once (each is one AI client's `runlet mcp`).
    public static let maxConnections = 16
    private let events: Events
    private let queue = DispatchQueue(label: "dev.runlet.mcp.listener")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [UUID: Connection] = [:]

    public init(path: String, events: Events) {
        self.path = path
        self.events = events
    }

    /// Creates the folder and socket and starts accepting. Refuses to replace anything but a
    /// stale socket of this user's, and fails when another Runlet already listens there.
    public func start() throws {
        try queue.sync {
            guard listenFD < 0 else { return }
            try MCPSocketPaths.prepareDirectory(for: path)
            var info = stat()
            if lstat(path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == geteuid() else { throw MCPSocketError.notASocket(path) }
                if UnixSocket.isListening(path) { throw MCPSocketError.inUse(path) }
                unlink(path)
            }
            let fd = try UnixSocket.makeSocket()
            var address = try UnixSocket.address(path)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0 else {
                let code = errno
                close(fd)
                throw MCPSocketError.system("bind", code)
            }
            chmod(path, 0o600)
            guard listen(fd, 8) == 0 else {
                let code = errno
                close(fd)
                unlink(path)
                throw MCPSocketError.system("listen", code)
            }
            UnixSocket.setNonBlocking(fd)
            listenFD = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptPending() }
            source.setCancelHandler { close(fd) }
            acceptSource = source
            source.resume()
        }
    }

    /// Stops listening, closes every connection, and removes the socket file.
    public func stop() {
        queue.sync {
            guard listenFD >= 0 else { return }
            acceptSource?.cancel()
            acceptSource = nil
            listenFD = -1
            for id in Array(connections.keys) { drop(id) }
            unlink(path)
        }
    }

    public func send(_ message: MCPBridge.AppMessage, to id: UUID) {
        queue.async { [weak self] in
            guard let self, let connection = self.connections[id] else { return }
            if !UnixSocket.writeAll(connection.fd, MCPBridge.encode(message), timeout: 5) { self.drop(id) }
        }
    }

    public func disconnect(_ id: UUID) {
        queue.async { [weak self] in self?.drop(id) }
    }

    public var connectionCount: Int { queue.sync { connections.count } }

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // Only this user's processes; the folder's mode already keeps others out.
            guard UnixSocket.peerUID(fd) == geteuid(), connections.count < Self.maxConnections else {
                close(fd)
                continue
            }
            UnixSocket.setNonBlocking(fd)
            let connection = Connection(fd: fd)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let id = connection.id
            source.setEventHandler { [weak self] in self?.read(id) }
            source.setCancelHandler { close(fd) }
            connection.source = source
            connections[id] = connection
            source.resume()
            events.connected(id, UnixSocket.peerPID(fd))
        }
    }

    private func read(_ id: UUID) {
        guard let connection = connections[id] else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(connection.fd, &buffer, buffer.count)
            if count > 0 {
                for item in connection.framer.append(Data(buffer[0..<count])) {
                    switch item {
                    case .line(let line):
                        guard let message = MCPBridge.decode(MCPBridge.ClientMessage.self, from: line) else { return drop(id) }
                        events.message(id, message)
                    case .oversized:
                        return drop(id)
                    }
                }
                guard connections[id] != nil else { return }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            return drop(id)
        }
    }

    private func drop(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.source?.cancel()
        events.disconnected(id)
    }
}

/// `runlet mcp`'s end of the socket: one connection to the app, a reader thread, and
/// line-framed messages.
public final class MCPSocketClient: @unchecked Sendable {
    /// One connection's descriptor and handlers (a reconnect gets a new one).
    private final class Session: @unchecked Sendable {
        let fd: Int32
        let onMessage: @Sendable (MCPBridge.AppMessage) -> Void
        let onClose: @Sendable () -> Void

        init(fd: Int32, onMessage: @escaping @Sendable (MCPBridge.AppMessage) -> Void, onClose: @escaping @Sendable () -> Void) {
            self.fd = fd
            self.onMessage = onMessage
            self.onClose = onClose
        }
    }

    public let path: String
    private let lock = NSLock()
    private var session: Session?

    public init(path: String) {
        self.path = path
    }

    /// Connects after checking that the socket is this user's, in a private folder, and that
    /// the process listening runs as this user.
    public func connect(onMessage: @escaping @Sendable (MCPBridge.AppMessage) -> Void, onClose: @escaping @Sendable () -> Void) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw MCPSocketError.notRunning }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { throw MCPSocketError.notASocket(path) }
        guard info.st_uid == geteuid(), MCPSocketPaths.isPrivateDirectory(for: path) else { throw MCPSocketError.wrongOwner }
        let fd = try UnixSocket.makeSocket()
        do {
            try UnixSocket.connect(fd, to: path)
        } catch {
            Darwin.close(fd)
            throw MCPSocketError.notRunning
        }
        guard UnixSocket.peerUID(fd) == geteuid() else {
            Darwin.close(fd)
            throw MCPSocketError.wrongOwner
        }
        let session = Session(fd: fd, onMessage: onMessage, onClose: onClose)
        let previous = lock.withLock {
            let previous = self.session
            self.session = session
            return previous
        }
        if let previous { shutdown(previous.fd, SHUT_RDWR) }
        let thread = Thread { [weak self] in self?.readLoop(session) }
        thread.name = "runlet-mcp-socket"
        thread.start()
    }

    public var isConnected: Bool { lock.withLock { session != nil } }

    @discardableResult
    public func send(_ message: MCPBridge.ClientMessage) -> Bool {
        lock.withLock {
            guard let session else { return false }
            return UnixSocket.writeAll(session.fd, MCPBridge.encode(message), timeout: 10)
        }
    }

    public func close() {
        let current = lock.withLock {
            let current = session
            session = nil
            return current
        }
        // Shutting down wakes the reader thread, which closes the descriptor.
        if let current { shutdown(current.fd, SHUT_RDWR) }
    }

    private func readLoop(_ session: Session) {
        var framer = JSONLineFramer(maxLineBytes: MCPBridge.maxAppMessageBytes)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        reading: while true {
            let count = Darwin.read(session.fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            for item in framer.append(Data(buffer[0..<count])) {
                guard case .line(let line) = item, let message = MCPBridge.decode(MCPBridge.AppMessage.self, from: line) else { break reading }
                session.onMessage(message)
            }
        }
        lock.withLock {
            if self.session === session { self.session = nil }
        }
        Darwin.close(session.fd)
        session.onClose()
    }
}
