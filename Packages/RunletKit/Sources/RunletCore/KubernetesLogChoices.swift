import Foundation

/// Memory-only explicit consent shared by a target's log sources (#374). Automatic resolutions
/// never become choices. An invalidated choice drops its pod identity but keeps the requirement
/// to choose again, including after switching sources or temporarily having no eligible pods.
public struct KubernetesLogChoices: Sendable {
    private var choices: [UUID: KubernetesTabChoice] = [:]

    public init() {}

    public func choice(for profile: KubernetesProfile) -> KubernetesTabChoice? {
        guard let choice = choices[profile.id], choice.matches(profile) else { return nil }
        return choice
    }

    /// A tab's explicit choice can seed a target, but never override a viewer choice or its
    /// invalidation. Opening another source doesn't renew consent for a vanished pod (#374).
    public mutating func preselect(_ choice: KubernetesTabChoice, for profile: KubernetesProfile) {
        guard self.choice(for: profile) == nil, choice.matches(profile) else { return }
        choices[profile.id] = choice
    }

    public mutating func select(_ pod: KubernetesPodIdentity, for profile: KubernetesProfile) {
        choices[profile.id] = KubernetesTabChoice(profile: profile, pod: pod)
    }

    public mutating func resolve(_ profile: KubernetesProfile, pods: [KubernetesPod]) -> KubernetesResolution {
        guard var choice = choice(for: profile) else {
            choices[profile.id] = nil
            return KubernetesResolver.resolve(profile, pods: pods)
        }
        let resolution = choice.resolve(profile, pods: pods)
        choices[profile.id] = choice
        return resolution
    }

    /// Saving/removing a profile clears its consent; closing Logs clears all targets (#374).
    public mutating func remove(_ profileId: UUID) { choices[profileId] = nil }
    public mutating func removeAll() { choices.removeAll() }
}
