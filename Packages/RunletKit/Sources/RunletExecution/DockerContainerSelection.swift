import Foundation
import RunletCore

/// The Docker profile form's Running Containers list (#318): which container is highlighted,
/// and what a click on one changes in the profile. Pure, so the rules are tested without
/// SwiftUI; the form keeps one in its state and writes the profile it returns in one go.
///
/// - A click always makes its container the profile's container, and highlights it.
/// - A listing (opening the form, Refresh, Docker coming back) never changes the profile. It
///   highlights the running container the profile's identity resolves to, or nothing, so the
///   highlighted row and the profile's container agree.
/// - The fields a click fills in (name, execution user, working directory, local source) follow
///   the latest click until the user edits them. An edited field is kept; clearing it hands it
///   back to the clicks. An existing profile's saved values count as edited.
public struct DockerContainerSelection: Sendable, Equatable {
    /// A profile field a click can fill in.
    public enum Field: String, Sendable, Hashable, CaseIterable {
        case name, user, workingDirectory, localSource
    }

    /// The highlighted row: a running container's ID, or nil.
    public private(set) var highlighted: String?
    /// Fields the user set (typed, a suggestion, Browse…, Choose…), or that the profile already
    /// had; a click leaves them alone.
    public private(set) var userFields: Set<Field>
    /// A click was highlighted and its container isn't applied yet (the form applies it right
    /// after SwiftUI's view update).
    public private(set) var isApplying = false
    /// The working directory before any click: what a container without one falls back to.
    private let initialWorkingDirectory: String

    /// - Parameters:
    ///   - isNew: a profile that isn't saved yet. Its working directory follows clicks unless it
    ///     differs from `defaultWorkingDirectory` (a duplicate's); a saved profile's never does.
    public init(profile: DockerProfile, isNew: Bool, defaultWorkingDirectory: String = "/var/www/html") {
        var fields: Set<Field> = []
        if !Self.isBlank(profile.name) { fields.insert(.name) }
        if !Self.isBlank(profile.user) { fields.insert(.user) }
        if !Self.isBlank(profile.localSourcePath) { fields.insert(.localSource) }
        if !Self.isBlank(profile.workingDirectory), !isNew || profile.workingDirectory != defaultWorkingDirectory {
            fields.insert(.workingDirectory)
        }
        userFields = fields
        initialWorkingDirectory = profile.workingDirectory
    }

    /// The user changed `field` to `value`: kept from now on, or handed back to the clicks when
    /// it's blank.
    public mutating func edit(_ field: Field, value: String?) {
        if Self.isBlank(value) {
            userFields.remove(field)
        } else {
            userFields.insert(field)
        }
    }

    /// Whether a click on the row `id` must apply it: false only when it's already the
    /// highlighted row and the profile's container (SwiftUI repeating a highlight back).
    public func needsApplying(_ id: String, profile: DockerProfile, among containers: [ContainerInfo]) -> Bool {
        id != highlighted || Self.resolvedId(profile.identity, among: containers) != id
    }

    /// Highlights a clicked row before its container is applied (see `isApplying`).
    public mutating func highlight(_ id: String) {
        highlighted = id
        isApplying = true
    }

    /// A click on `container`: highlights it and returns `profile` with it as the container,
    /// and the fields the user didn't set filled in from it. `folderExists` checks the host
    /// folder behind the working directory's bind mount before it becomes the local source.
    public mutating func click(_ container: ContainerInfo, in profile: DockerProfile, folderExists: (String) -> Bool) -> DockerProfile {
        highlighted = container.id
        isApplying = false
        var result = profile
        result.identity = container.identity
        if !userFields.contains(.name) {
            result.name = container.composeService ?? container.name
        }
        if !userFields.contains(.user) {
            result.user = container.user.isEmpty ? nil : container.user
        }
        if !userFields.contains(.workingDirectory) {
            let own = container.workingDir
            result.workingDirectory = own.isEmpty || own == "/" ? initialWorkingDirectory : own
        }
        if !userFields.contains(.localSource) {
            result.localSourcePath = container.hostPath(forContainerPath: result.workingDirectory).flatMap { folderExists($0) ? $0 : nil }
        }
        return result
    }

    /// After a listing: highlights the running container the profile's identity resolves to
    /// (the clicked one while it runs), or nothing when none or several match. Never changes
    /// the profile.
    public mutating func listed(_ containers: [ContainerInfo], profile: DockerProfile) {
        highlighted = Self.resolvedId(profile.identity, among: containers)
        isApplying = false
    }

    /// The highlighted row and the profile's container disagree (shown in the form; the rules
    /// above keep it from happening).
    public func disagrees(with profile: DockerProfile, among containers: [ContainerInfo]) -> Bool {
        guard let highlighted, !isApplying else { return false }
        return Self.resolvedId(profile.identity, among: containers) != highlighted
    }

    /// Other saved profiles that use the same container as `identity` (by Compose project and
    /// service, else by container name). Two profiles may share one, with different users or
    /// folders.
    public static func profiles(sharing identity: ContainerIdentity, in profiles: [DockerProfile], except id: UUID) -> [DockerProfile] {
        profiles.filter { other in
            guard other.id != id else { return false }
            if let project = identity.composeProject, let service = identity.composeService {
                return other.identity.composeProject == project && other.identity.composeService == service
            }
            guard identity.composeService == nil, other.identity.composeService == nil, let name = identity.containerName else { return false }
            return other.identity.containerName == name
        }
    }

    private static func resolvedId(_ identity: ContainerIdentity, among containers: [ContainerInfo]) -> String? {
        guard identity.composeService != nil || identity.containerName != nil else { return nil }
        return DockerProfileResolver.resolve(identity, among: containers).container?.id
    }

    private static func isBlank(_ value: String?) -> Bool {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension SSHProfile {
    /// The profile with `container` chosen in its container step (List Containers…): the
    /// container's identity, and its working directory and user unless they were set. An empty
    /// server directory is filled from the bind mount behind the working directory (the
    /// project's folder on the server), and an empty name from the service. Returned whole, so
    /// the form writes the profile once (#318). Unchanged without a container step.
    public func choosingContainer(_ container: ContainerInfo) -> SSHProfile {
        guard var step = self.container else { return self }
        var result = self
        step.identity = container.identity
        let defaults = RemoteContainerStep()
        if step.workingDirectory == defaults.workingDirectory || step.workingDirectory.isEmpty, !container.workingDir.isEmpty, container.workingDir != "/" {
            step.workingDirectory = container.workingDir
        }
        if (step.user ?? "").isEmpty, !container.user.isEmpty { step.user = container.user }
        result.container = step
        if SSHProfile.normalizedDirectory(result.remoteDirectory).isEmpty, let source = container.hostPath(forContainerPath: step.workingDirectory) {
            result.remoteDirectory = source
        }
        if result.name.trimmingCharacters(in: .whitespaces).isEmpty {
            result.name = "\(container.composeService ?? container.name) on \(result.host)"
        }
        return result
    }
}
