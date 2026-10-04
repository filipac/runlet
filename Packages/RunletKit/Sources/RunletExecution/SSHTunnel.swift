import Darwin
import Foundation
import RunletCore

/// Saved connections through an SSH tunnel (#143): a local forward on an SSH profile's shared
/// connection (OpenSSH ControlMaster), added with `ssh -O forward` and removed with
/// `ssh -O cancel`. Runs, probes, and Stop keep `ClearAllForwardings=yes`; only these two
/// control commands change the master's forwards.
///
/// The forward listens only on 127.0.0.1, on a port the kernel reports free just before, and
/// only while a run uses it (plus an idle time). Its `-L` argument holds a host and two ports,
/// never a user name or password, so it can show in `ps`.

/// One local forward: `127.0.0.1:<localPort>` on this Mac to `remoteHost:remotePort` as the SSH
/// server resolves them.
public struct SSHForwardSpec: Sendable, Hashable {
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int

    public init(localPort: Int, remoteHost: String, remotePort: Int) {
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    /// `ssh -L`'s argument: `127.0.0.1:50123:postgres:5432` (an IPv6 address in brackets). The
    /// bind address is explicit, so the master listens on loopback whatever `GatewayPorts` says.
    public var argument: String {
        let bare = remoteHost.hasPrefix("[") && remoteHost.hasSuffix("]") ? String(remoteHost.dropFirst().dropLast()) : remoteHost
        let host = bare.contains(":") ? "[\(bare)]" : bare
        return "\(SQLTunnelRoute.bindAddress):\(localPort):\(host):\(remotePort)"
    }
}

/// Why a forward couldn't be added.
public enum SSHTunnelError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The profile's shared connection isn't up (nobody logged in, it ended, or Disconnect).
    case notConnected(String)
    /// The master couldn't listen on the port (taken meanwhile); retried with another port.
    case portTaken(String)
    case failed(String)

    public var description: String {
        switch self {
        case .notConnected(let host): "Runlet's SSH connection to \(host) isn't open, so the tunnel couldn't be added. Nothing ran."
        case .portTaken(let detail): "The SSH tunnel couldn't listen on a free port of this Mac (\(detail)). Nothing ran."
        case .failed(let detail): "The SSH tunnel couldn't be added: \(detail) Nothing ran."
        }
    }
}

/// Free ports on 127.0.0.1 for forwards.
public enum SSHForwardPorts {
    /// A port nothing listens on at 127.0.0.1 now, chosen by the kernel (its ephemeral range).
    /// The socket is closed before `ssh` binds the port, so a process may take it meanwhile:
    /// the tunnel manager then retries with another one.
    public static func pickFree() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SSHTunnelError.portTaken("socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var address = loopback(port: 0)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw SSHTunnelError.portTaken("bind: \(String(cString: strerror(errno)))") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw SSHTunnelError.portTaken("getsockname: \(String(cString: strerror(errno)))") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// Whether something accepts connections on 127.0.0.1:`port` (tests; the app never probes).
    public static func isListening(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = loopback(port: port)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }

    static func loopback(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(clamping: port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr(SQLTunnelRoute.bindAddress))
        return address
    }
}

/// Adds and removes forwards on a shared connection (the system `ssh`; a fake in tests).
public protocol SSHForwarding: Sendable {
    func addForward(_ spec: SSHForwardSpec, on endpoint: SSHEndpoint) async throws
    /// Whether the master confirmed the cancel (false when the forward or the master is gone).
    @discardableResult
    func cancelForward(_ spec: SSHForwardSpec, on endpoint: SSHEndpoint) async -> Bool
    /// The command line of an add or cancel, for the Run Log (no secret is in it).
    func forwardCommandLine(_ spec: SSHForwardSpec, on endpoint: SSHEndpoint, cancel: Bool) -> String
}

extension SSHClient: SSHForwarding {
    /// `ssh -F /dev/null -o BatchMode=yes -o LogLevel=ERROR -S <control path> -O forward
    /// -L 127.0.0.1:<port>:<host>:<port> -- <host>`. It only talks to the local master, so
    /// no configuration is read (`-F /dev/null`): a `LocalForward` or `ClearAllForwardings` in
    /// `~/.ssh/config` can't add forwards to the request or clear Runlet's.
    public func forwardArguments(for endpoint: SSHEndpoint, spec: SSHForwardSpec, cancel: Bool) -> [String] {
        ["-F", "/dev/null"] + extraOptions + [
            "-o", "BatchMode=yes",
            "-o", "LogLevel=ERROR",
            "-S", endpoint.controlPath,
            "-O", cancel ? "cancel" : "forward",
            "-L", spec.argument,
            "--", endpoint.host,
        ]
    }

    public func forwardCommandLine(_ spec: SSHForwardSpec, on endpoint: SSHEndpoint, cancel: Bool) -> String {
        ([executable] + forwardArguments(for: endpoint, spec: spec, cancel: cancel)).map(RemoteShell.quote).joined(separator: " ")
    }

    public func addForward(_ spec: SSHForwardSpec, on endpoint: SSHEndpoint) async throws {
        guard SSHControlSocket.status(at: endpoint.controlPath) == .connected else { throw SSHTunnelError.notConnected(endpoint.displayName) }
        let process = ProcessSpec(executable: executable, arguments: forwardArguments(for: endpoint, spec: spec, cancel: false), environment: environment, newProcessGroup: true)
        let result: (stdout: Data, stderr: Data, exitCode: Int32)
        do {
            result = try await runCommand(process, timeout: .seconds(10))
        } catch {
            throw SSHTunnelError.failed("\(error)")
        }
        guard result.exitCode != 0 else { return }
        let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = message.lowercased()
        if lower.contains("control socket connect") || lower.contains("no such file") || lower.contains("connection refused") {
            throw SSHTunnelError.notConnected(endpoint.displayName)
        }
        if lower.contains("port forwarding failed") || lower.contains("address already in use") {
            throw SSHTunnelError.portTaken("127.0.0.1:\(spec.localPort)")
        }
        throw SSHTunnelError.failed(message.isEmpty ? "ssh exit \(result.exitCode)." : message)
    }

    @discardableResult
    public func cancelForward(_ spec: SSHForwardSpec, on endpoint: SSHEndpoint) async -> Bool {
        guard SSHControlSocket.status(at: endpoint.controlPath) == .connected else { return false }
        let process = ProcessSpec(executable: executable, arguments: forwardArguments(for: endpoint, spec: spec, cancel: true), environment: environment, newProcessGroup: true)
        guard let result = try? await runCommand(process, timeout: .seconds(5)) else { return false }
        // OpenSSH exits 0 even for a forward it doesn't have, but says so.
        return result.exitCode == 0 && !String(decoding: result.stderr, as: UTF8.self).contains("not forwarded")
    }

    /// Opens the profile's shared connection for an agent or key profile the way its first run
    /// would (BatchMode, `ControlMaster=auto`, its keep-alive), after the user agreed to connect
    /// (#143): a tunnel never connects by itself. Throws with OpenSSH's explanation.
    public func openSharedConnection(_ endpoint: SSHEndpoint) async throws {
        let result: (stdout: Data, stderr: Data, exitCode: Int32)
        do {
            result = try await run(endpoint, remoteCommand: RemoteShell.command("exit 0"), timeout: .seconds(20))
        } catch {
            throw SSHTunnelError.failed("\(error)")
        }
        guard result.exitCode == 0 else {
            let output = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHTunnelError.failed(SSHFailure.explain(output, exitCode: result.exitCode, host: endpoint.displayName) ?? (output.isEmpty ? "ssh exit \(result.exitCode)." : output))
        }
    }
}

/// The forwards of saved connections through SSH tunnels (#143): one per connection, reused by
/// every run while it is in use, and cancelled (`ssh -O cancel`) when it isn't:
///
/// - each run, schema read, definition, Test Connection, and Stop's cancel runner holds a
///   lease (`acquire` … `release`) while it runs; `acquire` re-sends `-O forward` every time,
///   which OpenSSH answers at once for a forward it has, and which puts it back on a master
///   that was restarted meanwhile;
/// - when the last lease ends, an idle timer starts (`idleTimeout`); a new lease stops it;
/// - `cancel` (the SQL tab closed, the connection was edited or removed) removes it once no
///   lease holds it; `cancelAll` (Disconnect, quit) removes them right away; `drop` forgets
///   them when their master is gone.
///
/// A port that turns out to be taken is retried with another one. Every add, reuse, and cancel
/// is reported to `observer` (the app logs it; no secret is in it).
public actor SSHTunnelManager {
    public struct Lease: Sendable, Hashable {
        /// The saved connection's id.
        public let key: UUID
        public let token: UUID
        public let spec: SSHForwardSpec
        public let controlPath: String
        /// The forward was there already (an earlier run's).
        public let reused: Bool
        /// The `ssh -O forward` command line, for the Run Log.
        public let commandLine: String
    }

    /// Why a forward was removed.
    public enum CancelReason: String, Sendable, Equatable {
        case idle
        case tabClosed
        case edited
        case replaced
        case disconnected
        case quit
        case unused
        /// Closed by hand (a connection manager, #180).
        case closed

        public var phrase: String {
            switch self {
            case .idle: "unused for a while"
            case .tabClosed: "its SQL tab closed"
            case .edited: "the connection changed"
            case .replaced: "the connection's host, port, or SSH profile changed"
            case .disconnected: "the SSH profile disconnected"
            case .quit: "Runlet quit"
            case .unused: "nothing uses it"
            case .closed: "it was closed by hand"
            }
        }
    }

    public enum Event: Sendable, Equatable {
        case added(key: UUID, spec: SSHForwardSpec, controlPath: String, commandLine: String)
        case reused(key: UUID, spec: SSHForwardSpec, controlPath: String)
        /// `confirmed`: the master removed it (false when it or the master was already gone).
        case cancelled(key: UUID, spec: SSHForwardSpec, controlPath: String, reason: CancelReason, confirmed: Bool, commandLine: String)
        /// Forgotten without `-O cancel`, because the master is gone.
        case dropped(key: UUID, spec: SSHForwardSpec, controlPath: String)
    }

    /// A forward as the manager knows it (the app's list of active tunnels, tests, Debug state).
    public struct Forward: Sendable, Equatable {
        public var key: UUID
        public var spec: SSHForwardSpec
        public var controlPath: String
        /// Runs holding it now (a statement, a schema read, Test Connection, a cancel runner).
        public var leases: Int
        public var idle: Bool
        public var cancelWhenUnused: Bool
        public var openedAt: Date
        /// The last time a run took or ended its hold on it.
        public var lastUsedAt: Date
    }

    private struct Entry {
        var spec: SSHForwardSpec
        var endpoint: SSHEndpoint
        var leases: Set<UUID> = []
        var cancelWhenUnused: CancelReason?
        var idleTask: Task<Void, Never>?
        var generation = 0
        var openedAt = Date()
        var lastUsedAt = Date()
    }

    public static let defaultIdleTimeout: Duration = .seconds(300)
    public static let portAttempts = 5

    private let forwarder: SSHForwarding
    private let idleTimeout: Duration
    private let pickPort: @Sendable () throws -> Int
    private var observer: (@Sendable (Event) -> Void)?
    private var entries: [UUID: Entry] = [:]
    private var locked: Set<UUID> = []
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    public init(forwarder: SSHForwarding, idleTimeout: Duration = SSHTunnelManager.defaultIdleTimeout, pickPort: @escaping @Sendable () throws -> Int = SSHForwardPorts.pickFree, observer: (@Sendable (Event) -> Void)? = nil) {
        self.forwarder = forwarder
        self.idleTimeout = idleTimeout
        self.pickPort = pickPort
        self.observer = observer
    }

    public func setObserver(_ observer: (@Sendable (Event) -> Void)?) {
        self.observer = observer
    }

    public var forwards: [Forward] {
        entries.map { key, entry in
            Forward(key: key, spec: entry.spec, controlPath: entry.endpoint.controlPath, leases: entry.leases.count, idle: entry.leases.isEmpty, cancelWhenUnused: entry.cancelWhenUnused != nil, openedAt: entry.openedAt, lastUsedAt: entry.lastUsedAt)
        }.sorted { $0.spec.localPort < $1.spec.localPort }
    }

    /// The forward of connection `key` to `remoteHost:remotePort` on `endpoint`'s master, added
    /// when it has none (or a different one), held until `release`. Throws `SSHTunnelError`.
    public func acquire(key: UUID, endpoint: SSHEndpoint, remoteHost: String, remotePort: Int) async throws -> Lease {
        await lock(key)
        defer { unlock(key) }
        let token = UUID()
        if var entry = entries[key] {
            if entry.endpoint.controlPath == endpoint.controlPath, entry.spec.remoteHost == remoteHost, entry.spec.remotePort == remotePort {
                entry.idleTask?.cancel()
                entry.idleTask = nil
                entry.generation += 1
                entry.cancelWhenUnused = nil
                entries[key] = entry
                do {
                    // Idempotent on the same master; puts the forward back on a new one.
                    try await forwarder.addForward(entry.spec, on: endpoint)
                    entry.leases.insert(token)
                    entry.endpoint = endpoint
                    entry.lastUsedAt = Date()
                    entries[key] = entry
                    observer?(.reused(key: key, spec: entry.spec, controlPath: endpoint.controlPath))
                    return Lease(key: key, token: token, spec: entry.spec, controlPath: endpoint.controlPath, reused: true, commandLine: forwarder.forwardCommandLine(entry.spec, on: endpoint, cancel: false))
                } catch SSHTunnelError.portTaken {
                    // A new master, and the port went to another process meanwhile: a new port.
                    entries[key] = nil
                    observer?(.dropped(key: key, spec: entry.spec, controlPath: entry.endpoint.controlPath))
                } catch {
                    if case SSHTunnelError.notConnected = error {
                        entries[key] = nil
                        observer?(.dropped(key: key, spec: entry.spec, controlPath: entry.endpoint.controlPath))
                    }
                    throw error
                }
            } else {
                await cancelNow(key, reason: .replaced)
            }
        }
        var lastProblem = "no port"
        for _ in 0..<Self.portAttempts {
            let spec = SSHForwardSpec(localPort: try pickPort(), remoteHost: remoteHost, remotePort: remotePort)
            do {
                try await forwarder.addForward(spec, on: endpoint)
            } catch SSHTunnelError.portTaken(let detail) {
                lastProblem = detail
                continue
            }
            var entry = Entry(spec: spec, endpoint: endpoint)
            entry.leases.insert(token)
            entries[key] = entry
            let commandLine = forwarder.forwardCommandLine(spec, on: endpoint, cancel: false)
            observer?(.added(key: key, spec: spec, controlPath: endpoint.controlPath, commandLine: commandLine))
            return Lease(key: key, token: token, spec: spec, controlPath: endpoint.controlPath, reused: false, commandLine: commandLine)
        }
        throw SSHTunnelError.portTaken("\(Self.portAttempts) ports tried, last \(lastProblem)")
    }

    /// Ends a lease. The last one starts the idle timer, or (`cancelWhenUnused`, or a `cancel`
    /// that waited for it) removes the forward now.
    public func release(_ lease: Lease, cancelWhenUnused: Bool = false) async {
        guard var entry = entries[lease.key], entry.spec == lease.spec, entry.leases.remove(lease.token) != nil else { return }
        entry.lastUsedAt = Date()
        entries[lease.key] = entry
        guard entry.leases.isEmpty else { return }
        if let reason = entry.cancelWhenUnused ?? (cancelWhenUnused ? .unused : nil) {
            await cancelNow(lease.key, reason: reason)
            return
        }
        entry.generation += 1
        let generation = entry.generation
        let timeout = idleTimeout
        entry.idleTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.expire(lease.key, generation: generation)
        }
        entries[lease.key] = entry
    }

    /// Removes connection `key`'s forward now, or when its last lease ends; `force` removes it
    /// now even while runs hold it (they lose their connection to the database).
    public func cancel(key: UUID, reason: CancelReason, force: Bool = false) async {
        guard var entry = entries[key] else { return }
        if entry.leases.isEmpty || force {
            await cancelNow(key, reason: reason)
        } else {
            entry.cancelWhenUnused = reason
            entries[key] = entry
        }
    }

    /// Removes every forward (on one master, or all) right away, leases or not: Disconnect
    /// (runs on the master end with it anyway) and quit.
    public func cancelAll(controlPath: String? = nil, reason: CancelReason) async {
        for (key, entry) in entries where controlPath == nil || entry.endpoint.controlPath == controlPath {
            await cancelNow(key, reason: reason)
        }
    }

    /// Forgets the forwards of a master that is gone (nothing to cancel).
    public func drop(controlPath: String) {
        for (key, entry) in entries where entry.endpoint.controlPath == controlPath {
            entry.idleTask?.cancel()
            entries[key] = nil
            observer?(.dropped(key: key, spec: entry.spec, controlPath: controlPath))
        }
    }

    private func expire(_ key: UUID, generation: Int) async {
        guard let entry = entries[key], entry.generation == generation, entry.leases.isEmpty else { return }
        await cancelNow(key, reason: .idle)
    }

    private func cancelNow(_ key: UUID, reason: CancelReason) async {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.idleTask?.cancel()
        let confirmed = await forwarder.cancelForward(entry.spec, on: entry.endpoint)
        observer?(.cancelled(key: key, spec: entry.spec, controlPath: entry.endpoint.controlPath, reason: reason, confirmed: confirmed, commandLine: forwarder.forwardCommandLine(entry.spec, on: entry.endpoint, cancel: true)))
    }

    // One acquire per connection at a time, so two runs never add two forwards for it.
    private func lock(_ key: UUID) async {
        if locked.contains(key) {
            await withCheckedContinuation { waiters[key, default: []].append($0) }
        } else {
            locked.insert(key)
        }
    }

    private func unlock(_ key: UUID) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[key] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            locked.remove(key)
        }
    }
}
