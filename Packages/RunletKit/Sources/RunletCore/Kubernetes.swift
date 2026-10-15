import Foundation

/// A Kubernetes application (#33). Credentials stay with kubectl; only its config path is saved.
public struct KubernetesProfile: Sendable, Codable, Hashable, Identifiable {
    public var id = UUID()
    public var name: String
    public var kubeconfig: String?
    public var context: String
    public var namespace: String
    public var labelSelector: String
    public var container: String
    public var workingDirectory = "/app"
    public var phpExecutable = "php"
    public var temporaryDirectory = "/tmp"
    public var localSourcePath: String?
    public var languagePHPVersion: String?
    public var strictTypes: Bool?
    public var interceptMail: Bool?
    public var environment: TargetEnvironment?
    public var color: TargetColor?
    public var autoResolve = true
    public var interchangeableReplicas = false
    /// Diagnostics only: never used to select a pod on a later run (#33).
    public var lastPod: KubernetesPodIdentity?
    /// Explicitly pinned by the user; unlike lastPod, this restricts resolution (#33).
    public var pinnedPod: KubernetesPodIdentity?
    public var revision = 1
    public var lastOpenedAt: Date?

    public init(name: String, context: String, namespace: String, labelSelector: String, container: String) {
        self.name = name
        self.context = context
        self.namespace = namespace
        self.labelSelector = labelSelector
        self.container = container
    }

    public func validate() -> [String] {
        var errors: [String] = []
        for (label, value) in [("name", name), ("context", context), ("namespace", namespace), ("label selector", labelSelector), ("container", container), ("PHP executable", phpExecutable)] {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.contains("\0") || value.hasPrefix("-") {
                errors.append("Set the \(label). It must not start with a dash.")
            }
        }
        if !workingDirectory.hasPrefix("/") { errors.append("The working directory must be an absolute path.") }
        if !temporaryDirectory.hasPrefix("/") { errors.append("The temporary directory must be an absolute path.") }
        return errors
    }
}

public struct KubernetesPodIdentity: Sendable, Codable, Hashable {
    public var name: String
    public var uid: String
    public init(name: String, uid: String) {
        self.name = name
        self.uid = uid
    }
}

/// The immutable destination of a Kubernetes run (#33), rechecked before launch and Stop.
public struct KubernetesRunTarget: Sendable, Codable, Equatable {
    public var executable: String
    public var kubeconfig: String?
    public var context: String
    public var namespace: String
    public var pod: KubernetesPodIdentity
    public var container: String

    public init(executable: String, profile: KubernetesProfile, pod: KubernetesPodIdentity) {
        self.executable = executable
        self.kubeconfig = profile.kubeconfig
        self.context = profile.context
        self.namespace = profile.namespace
        self.pod = pod
        self.container = profile.container
    }

    /// Every call carries an explicit context and namespace, even local config queries (#33).
    public var flags: [String] {
        (kubeconfig.map { ["--kubeconfig", ($0 as NSString).expandingTildeInPath] } ?? [])
            + ["--context", context, "--namespace", namespace]
    }
    public func execArguments(_ command: [String], stdin: Bool = false) -> [String] {
        flags + ["exec"] + (stdin ? ["-i"] : []) + ["-c", container, pod.name, "--"] + command
    }
}

/// Only regular, Ready containers of a Running, non-deleting pod are selectable (#33).
public struct KubernetesPod: Sendable, Equatable, Identifiable {
    public var identity: KubernetesPodIdentity
    public var id: String { identity.uid }
    public var name: String { identity.name }
    public var node: String
    public var created: String
    public var phase: String
    public var deleting: Bool
    public var containers: [String]
    public var readyContainers: [String]
    public var restarts: Int
    public func eligible(container: String) -> Bool {
        !deleting && phase == "Running" && containers.contains(container) && readyContainers.contains(container)
    }

    public static func parseList(_ data: Data) throws -> [KubernetesPod] {
        let list = try JSONDecoder().decode(PodList.self, from: data)
        return list.items.map(\.pod)
    }
    public static func parse(_ data: Data) throws -> KubernetesPod {
        try JSONDecoder().decode(PodJSON.self, from: data).pod
    }

    private struct PodList: Decodable { var items: [PodJSON] }
    private struct PodJSON: Decodable {
        struct Metadata: Decodable {
            var name: String
            var uid: String
            var creationTimestamp: String?
            var deletionTimestamp: String?
        }
        struct Spec: Decodable {
            struct Container: Decodable { var name: String }
            var nodeName: String?
            var containers: [Container]
        }
        struct Status: Decodable {
            struct Container: Decodable {
                var name: String
                var ready: Bool
                var restartCount: Int
            }
            var phase: String?
            var containerStatuses: [Container]?
        }
        var metadata: Metadata
        var spec: Spec
        var status: Status?
        var pod: KubernetesPod {
            KubernetesPod(identity: .init(name: metadata.name, uid: metadata.uid), node: spec.nodeName ?? "—", created: metadata.creationTimestamp ?? "", phase: status?.phase ?? "Pending", deleting: metadata.deletionTimestamp != nil, containers: spec.containers.map(\.name), readyContainers: (status?.containerStatuses ?? []).filter(\.ready).map(\.name), restarts: (status?.containerStatuses ?? []).reduce(0) { $0 + $1.restartCount })
        }
    }
}

public enum KubernetesResolution: Sendable, Equatable {
    case resolved(KubernetesPod)
    case ambiguous([KubernetesPod])
    case unavailable(String)
}

/// Tab-local consent (#33). Losing readiness requires a fresh choice, even if only one pod remains.
/// An invalidated choice asks again when eligible pods exist; it never follows a replacement.
public struct KubernetesTabChoice: Sendable {
    public let profileId: UUID
    public let revision: Int
    public private(set) var pod: KubernetesPodIdentity?

    public init(profile: KubernetesProfile, pod: KubernetesPodIdentity) {
        profileId = profile.id
        revision = profile.revision
        self.pod = pod
    }

    public func matches(_ profile: KubernetesProfile) -> Bool {
        profileId == profile.id && revision == profile.revision
    }

    public mutating func resolve(_ profile: KubernetesProfile, pods: [KubernetesPod]) -> KubernetesResolution {
        guard matches(profile) else { return KubernetesResolver.resolve(profile, pods: pods) }
        if let pod, case .resolved(let selected) = KubernetesResolver.resolve(profile, pods: pods, choice: pod) {
            return .resolved(selected)
        }
        pod = nil
        let eligible = pods.filter { $0.eligible(container: profile.container) }.sorted { ($0.created, $0.name, $0.id) < ($1.created, $1.name, $1.id) }
        guard !eligible.isEmpty else { return .unavailable(KubernetesResolver.noReadyPodMessage(container: profile.container)) }
        return .ambiguous(eligible)
    }
}

public enum KubernetesResolver {
    /// Shared by resolution and explicit pod selection when no eligible pod exists (#33).
    public static func noReadyPodMessage(container: String) -> String {
        "No Running pod has the Ready container “\(container)”. Check the context, namespace, selector, and container, then resolve again."
    }

    /// Never uses the diagnostic lastPod as consent. Pins bind to both name and UID (#33).
    public static func resolve(_ profile: KubernetesProfile, pods: [KubernetesPod], choice: KubernetesPodIdentity? = nil) -> KubernetesResolution {
        let eligible = pods.filter { $0.eligible(container: profile.container) }.sorted { ($0.created, $0.name, $0.id) < ($1.created, $1.name, $1.id) }
        if let pin = choice ?? profile.pinnedPod {
            guard let pod = eligible.first(where: { $0.identity == pin }) else {
                return .unavailable("The chosen pod is gone or isn't ready. Choose Pod again to resolve its replacement.")
            }
            return .resolved(pod)
        }
        guard !eligible.isEmpty else { return .unavailable(noReadyPodMessage(container: profile.container)) }
        if eligible.count == 1 || profile.interchangeableReplicas { return .resolved(eligible[0]) }
        return .ambiguous(eligible)
    }

    public static func recheck(_ pod: KubernetesPod, target: KubernetesRunTarget) -> Bool {
        pod.identity == target.pod && pod.eligible(container: target.container)
    }

    public static func stopConfirmed(_ result: String) -> Bool { result == "gone" || result == "mismatch" }
}
