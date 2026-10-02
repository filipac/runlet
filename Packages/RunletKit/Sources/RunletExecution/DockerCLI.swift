import Foundation
import RunletCore

public struct DockerError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Thin wrapper over the Docker CLI using the machine's selected Docker context.
public struct DockerCLI: Sendable {
    public let executable: String
    public let environment: [String: String]

    public init(executable: String) {
        self.executable = executable
        self.environment = ExecutableLocator.toolEnvironment(prepending: [(executable as NSString).deletingLastPathComponent])
    }

    /// Locates the Docker CLI, honoring an explicit override.
    public static func locate(override: String? = nil) -> DockerCLI? {
        if let override, !override.isEmpty, let path = ExecutableLocator.resolve(override) {
            return DockerCLI(executable: path)
        }
        return ExecutableLocator.resolve("docker").map(DockerCLI.init(executable:))
    }

    public func spec(_ arguments: [String], stdin: Data? = nil) -> ProcessSpec {
        ProcessSpec(executable: executable, arguments: arguments, environment: environment, standardInput: stdin, newProcessGroup: true)
    }

    @discardableResult
    public func run(_ arguments: [String], timeout: Duration = .seconds(20)) async throws -> Data {
        let result = try await runCommand(spec(arguments), timeout: timeout)
        guard result.exitCode == 0 else {
            let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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
    public var mountDestinations: [String]
    public var created: String

    public var composeProject: String? { labels["com.docker.compose.project"] }
    public var composeService: String? { labels["com.docker.compose.service"] }
    public var composeNumber: String? { labels["com.docker.compose.container-number"] }
    public var shortId: String { String(id.prefix(12)) }
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

    public func inspect(_ ids: [String]) async throws -> [ContainerInfo] {
        guard !ids.isEmpty else { return [] }
        let data = try await run(["inspect", "--type", "container"] + ids)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
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
            mountDestinations: mounts.compactMap { $0["Destination"] as? String },
            created: object["Created"] as? String ?? ""
        )
    }
}
