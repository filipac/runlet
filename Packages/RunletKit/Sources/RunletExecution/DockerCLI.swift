import Foundation
import RunletCore

public struct DockerError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Thin wrapper over the Docker CLI using the machine's selected Docker context, or Docker on
/// an SSH host (an SSH profile's container step).
public struct DockerCLI: Sendable {
    /// Where `docker` runs.
    public enum Transport: Sendable {
        /// This Mac's Docker CLI (`executable`).
        case local
        /// `ssh … host /bin/sh -c '<docker command> <args>'` through the profile's shared
        /// connection (BatchMode, strict host keys), so everything built on `spec` (listing,
        /// `inspect`, the resolver, probes, `exec` runs, and Stop) works on the server unchanged.
        case ssh(SSHClient, SSHEndpoint, command: [String])
    }

    public let executable: String
    public let environment: [String: String]
    public let transport: Transport

    public init(executable: String) {
        self.executable = executable
        self.environment = ExecutableLocator.toolEnvironment(prepending: [(executable as NSString).deletingLastPathComponent])
        self.transport = .local
    }

    /// Docker on an SSH host: `dockerCommand` is how the server calls it (`docker`,
    /// `sudo -n docker`, an absolute path).
    public init(ssh: SSHClient, endpoint: SSHEndpoint, dockerCommand: String) {
        self.executable = ssh.executable
        self.environment = ssh.environment
        let words = dockerCommand.split(whereSeparator: \.isWhitespace).map(String.init)
        self.transport = .ssh(ssh, endpoint, command: words.isEmpty ? ["docker"] : words)
    }

    /// The SSH host Docker runs on (nil for this Mac's Docker).
    public var sshEndpoint: SSHEndpoint? {
        if case .ssh(_, let endpoint, _) = transport { return endpoint }
        return nil
    }

    /// PHP code for a `php -r` argument. Over SSH it travels base64-encoded
    /// (`RemoteShell.inlinePHP`), since the server's login shell parses the command line once
    /// more and some shells (fish) treat backslashes in quotes differently.
    public func phpCode(_ code: String) -> String {
        if case .ssh = transport { return RemoteShell.inlinePHP(code) }
        return code
    }

    /// A plain explanation of a failed `docker` call over SSH (`ssh` itself failing, Docker
    /// missing on the server, or no permission to use it); nil for this Mac's Docker or when
    /// the output is Docker's own message.
    public func explainFailure(_ output: String, exitCode: Int32) -> String? {
        guard case .ssh(_, let endpoint, let command) = transport else { return nil }
        let host = endpoint.displayName
        let lower = output.lowercased()
        if exitCode == 255, let explained = SSHFailure.explain(output, exitCode: exitCode, host: host) { return explained }
        let program = command.joined(separator: " ")
        if exitCode == 127, lower.contains("not found") || lower.contains("no such file") {
            return "Docker was not found on \(host) as “\(program)”. Set the profile's Docker command (for example an absolute path), or check that Docker is installed there.\n\n\(output)"
        }
        if lower.contains("permission denied") && lower.contains("docker") && (lower.contains(".sock") || lower.contains("daemon")) {
            return "The login on \(host) may not use Docker (permission denied on the Docker socket). Add the user to the docker group, or set the profile's Docker command to `sudo -n docker` if passwordless sudo is allowed.\n\n\(output)"
        }
        if lower.contains("sudo:") && (lower.contains("password is required") || lower.contains("a terminal is required")) {
            return "sudo on \(host) wants a password, and runs can't answer one. Allow passwordless sudo for Docker, or add the login to the docker group and use `docker`.\n\n\(output)"
        }
        if lower.contains("cannot connect to the docker daemon") {
            return "Docker on \(host) isn't running (or the login can't reach it).\n\n\(output)"
        }
        return nil
    }

    /// Locates the Docker CLI, honoring an explicit override.
    public static func locate(override: String? = nil) -> DockerCLI? {
        if let override, !override.isEmpty, let path = ExecutableLocator.resolve(override) {
            return DockerCLI(executable: path)
        }
        return ExecutableLocator.resolve("docker").map(DockerCLI.init(executable:))
    }

    public func spec(_ arguments: [String], stdin: Data? = nil) -> ProcessSpec {
        switch transport {
        case .local:
            return ProcessSpec(executable: executable, arguments: arguments, environment: environment, standardInput: stdin, newProcessGroup: true)
        case .ssh(let client, let endpoint, let command):
            // The control socket's folder must exist before ssh can create the master.
            try? SSHControlPaths.prepareDirectory(for: endpoint.controlPath)
            let script = (command + arguments).map(RemoteShell.quote).joined(separator: " ")
            return client.spec(endpoint, remoteCommand: RemoteShell.command(script), stdin: stdin)
        }
    }

    @discardableResult
    public func run(_ arguments: [String], timeout: Duration = .seconds(20)) async throws -> Data {
        let result = try await runCommand(spec(arguments), timeout: timeout)
        guard result.exitCode == 0 else {
            let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if let explained = explainFailure(message, exitCode: result.exitCode) { throw DockerError(explained) }
            throw DockerError(message.isEmpty ? "docker \(arguments.first ?? "") exited with code \(result.exitCode)" : message)
        }
        return result.stdout
    }

    /// Checks that the daemon for the selected context responds.
    public func serverVersion() async throws -> String {
        let data = try await run(["version", "--format", "{{.Server.Version}}"], timeout: .seconds(10))
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func imageExists(_ image: String) async -> Bool {
        (try? await run(["image", "inspect", "--format", "{{.Id}}", image], timeout: .seconds(10))) != nil
    }
}

/// A container mount from `docker inspect` (bind mounts carry the host source path).
public struct ContainerMount: Sendable, Hashable {
    public var type: String
    public var source: String
    public var destination: String

    public init(type: String, source: String, destination: String) {
        self.type = type
        self.source = source
        self.destination = destination
    }
}

/// A running (or stopped) container as reported by `docker inspect`.
public struct ContainerInfo: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var image: String
    public var running: Bool
    public var status: String
    public var labels: [String: String]
    public var workingDir: String
    public var user: String
    public var mountDestinations: [String] { mounts.map(\.destination) }
    public var mounts: [ContainerMount]
    public var created: String

    public var composeProject: String? { labels["com.docker.compose.project"] }
    public var composeService: String? { labels["com.docker.compose.service"] }
    public var composeNumber: String? { labels["com.docker.compose.container-number"] }
    public var shortId: String { String(id.prefix(12)) }

    /// The host directory behind a container path, via the closest enclosing bind mount.
    /// Docker Desktop may report sources as `/host_mnt/Users/...`; that prefix is removed.
    /// Returns nil when the path isn't bind-mounted from the host.
    public func hostPath(forContainerPath containerPath: String) -> String? {
        let path = containerPath.hasSuffix("/") && containerPath.count > 1 ? String(containerPath.dropLast()) : containerPath
        let candidates = mounts.filter { $0.type == "bind" && (path == $0.destination || path.hasPrefix($0.destination.hasSuffix("/") ? $0.destination : $0.destination + "/")) }
        guard let mount = candidates.max(by: { $0.destination.count < $1.destination.count }) else { return nil }
        var source = mount.source
        if source.hasPrefix("/host_mnt/") { source.removeFirst("/host_mnt".count) }
        let remainder = String(path.dropFirst(mount.destination.count))
        return source + remainder
    }
    /// The container path behind a host path, via the bind mount whose source contains it
    /// (the closest one); nil when the host path isn't mounted. The inverse of
    /// `hostPath(forContainerPath:)`, used to map an SSH profile's server directory into its
    /// container.
    public func containerPath(forHostPath hostPath: String) -> String? {
        func trimmed(_ path: String) -> String { path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path }
        let path = trimmed(hostPath)
        let candidates = mounts.filter { mount in
            let source = trimmed(mount.source)
            return mount.type == "bind" && !source.isEmpty && (path == source || path.hasPrefix(source == "/" ? "/" : source + "/"))
        }
        guard let mount = candidates.max(by: { trimmed($0.source).count < trimmed($1.source).count }) else { return nil }
        let source = trimmed(mount.source)
        let remainder = source == "/" ? path : String(path.dropFirst(source.count))
        let destination = trimmed(mount.destination)
        if remainder.isEmpty { return destination }
        return destination == "/" ? remainder : destination + remainder
    }

    public var isRunletOwned: Bool { labels["dev.runlet.owned"] != nil }

    public var identity: ContainerIdentity {
        ContainerIdentity(composeProject: composeProject, composeService: composeService, containerName: name, lastContainerId: id, lastImage: image)
    }
}

extension DockerCLI {
    /// Lists running containers (Runlet's own disposable sandbox containers excluded).
    public func runningContainers() async throws -> [ContainerInfo] {
        let ids = String(decoding: try await run(["ps", "-q", "--no-trunc"]), as: UTF8.self)
            .split(whereSeparator: \.isNewline).map(String.init)
        guard !ids.isEmpty else { return [] }
        return try await inspect(ids).filter { $0.running && !$0.isRunletOwned }
    }

    /// Inspects containers. Containers that disappeared since they were listed (e.g. `--rm`
    /// containers exiting) are skipped: `docker inspect` then exits 1 but still prints the rest.
    public func inspect(_ ids: [String]) async throws -> [ContainerInfo] {
        guard !ids.isEmpty else { return [] }
        let result = try await runCommand(spec(["inspect", "--type", "container"] + ids), timeout: .seconds(20))
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        // ssh's own failure (255) is never "some containers vanished".
        let onlyMissing = result.exitCode != 255 && stderr.split(whereSeparator: \.isNewline).allSatisfy { $0.lowercased().contains("no such container") || $0.lowercased().contains("no such object") || $0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard result.exitCode == 0 || onlyMissing else {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if let explained = explainFailure(message, exitCode: result.exitCode) { throw DockerError(explained) }
            throw DockerError(message.isEmpty ? "docker inspect exited with code \(result.exitCode)" : message)
        }
        guard !result.stdout.isEmpty, let array = try? JSONSerialization.jsonObject(with: result.stdout) as? [[String: Any]] else { return [] }
        return array.compactMap(Self.parseContainer)
    }

    /// Inspects one container by ID or name; nil if it no longer exists.
    public func inspect(_ id: String) async -> ContainerInfo? {
        try? await inspect([id]).first
    }

    static func parseContainer(_ object: [String: Any]) -> ContainerInfo? {
        guard let id = object["Id"] as? String else { return nil }
        let config = object["Config"] as? [String: Any] ?? [:]
        let state = object["State"] as? [String: Any] ?? [:]
        let mounts = object["Mounts"] as? [[String: Any]] ?? []
        let name = ((object["Name"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return ContainerInfo(
            id: id,
            name: name,
            image: config["Image"] as? String ?? "",
            running: state["Running"] as? Bool ?? false,
            status: state["Status"] as? String ?? "",
            labels: config["Labels"] as? [String: String] ?? [:],
            workingDir: config["WorkingDir"] as? String ?? "",
            user: config["User"] as? String ?? "",
            mounts: mounts.compactMap { mount in
                guard let destination = mount["Destination"] as? String else { return nil }
                return ContainerMount(type: mount["Type"] as? String ?? "", source: mount["Source"] as? String ?? "", destination: destination)
            },
            created: object["Created"] as? String ?? ""
        )
    }
}
