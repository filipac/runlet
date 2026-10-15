import Foundation
import RunletCore

/// kubectl owns configuration and credentials (#33). All commands use explicit scope.
public struct KubernetesCLI: Sendable {
    public let target: KubernetesRunTarget
    public init(target: KubernetesRunTarget) { self.target = target }
    public init(executable: String, profile: KubernetesProfile) {
        target = KubernetesRunTarget(executable: executable, profile: profile, pod: .init(name: "", uid: ""))
    }
    public func spec(_ arguments: [String], stdin: Data? = nil) -> ProcessSpec {
        ProcessSpec(executable: target.executable, arguments: target.flags + arguments,
                    environment: ExecutableLocator.toolEnvironment(prepending: [(target.executable as NSString).deletingLastPathComponent]), standardInput: stdin, newProcessGroup: true)
    }
    public func exec(_ command: [String], stdin: Data? = nil) -> ProcessSpec {
        var process = spec([], stdin: stdin)
        process.arguments = target.execArguments(command, stdin: stdin != nil)
        return process
    }
    public func run(_ arguments: [String]) async throws -> Data {
        let result = try await runCommand(spec(arguments), timeout: .seconds(20))
        guard result.exitCode == 0 else {
            throw ExecutionError.invalidTarget("kubectl couldn't read context “\(target.context)”, namespace “\(target.namespace)”. Check the profile and your kubectl access.\n\n\(String(decoding: result.stderr, as: UTF8.self))")
        }
        return result.stdout
    }
    public func pods(selector: String) async throws -> [KubernetesPod] {
        guard !target.context.isEmpty, !target.namespace.isEmpty, !selector.isEmpty else {
            throw ExecutionError.invalidTarget("Choose a context, namespace, and label selector first.")
        }
        return try KubernetesPod.parseList(await run(["get", "pods", "-l", selector, "-o", "json"]))
    }
    public func pod() async throws -> KubernetesPod {
        try KubernetesPod.parse(await run(["get", "pod", target.pod.name, "-o", "json"]))
    }
    public func contexts() async throws -> [String] {
        String(decoding: try await run(["config", "get-contexts", "-o", "name"]), as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }
    public func namespaces() async throws -> [String] {
        let data = try await run(["get", "namespaces", "-o", "jsonpath={.items[*].metadata.name}"])
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
