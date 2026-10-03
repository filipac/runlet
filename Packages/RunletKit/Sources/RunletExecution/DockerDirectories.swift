import Foundation
import RunletCore

/// Plain explanations of a failed `docker exec` (Docker's own message is kept below them).
public enum DockerExecFailure {
    /// nil when the output isn't one of the failures below (a PHP error, for instance).
    /// `container` names it as the user knows it; `php` and `user` are what the exec used.
    public static func explain(_ output: String, exitCode: Int32, container: String, php: String, user: String?) -> String? {
        let lower = output.lowercased()
        let lead: String
        if lower.contains("is paused") {
            lead = "The container \(container) is paused. Unpause it, then try again."
        } else if lower.contains("is not running") || lower.contains("is restarting") {
            lead = "The container \(container) isn't running. Start it, then try again."
        } else if lower.contains("no such container") {
            lead = "The container \(container) no longer exists: it was removed or recreated. Choose the running container again, then try again."
        } else if lower.contains("unable to find user") || lower.contains("unable to find group") || lower.contains("no matching entries in passwd") || lower.contains("no matching entries in group") {
            lead = "The execution user “\(user ?? "")” doesn't exist in \(container). Fix the execution user, or leave it blank for the container's default user."
        } else if lower.contains("executable file not found") || ((exitCode == 126 || exitCode == 127) && lower.contains("exec:") && (lower.contains("no such file") || lower.contains("permission denied"))) {
            lead = "PHP wasn't found in \(container) as “\(php)”. Set the PHP executable to the container's PHP (for example php or /usr/local/bin/php)."
        } else if lower.contains("cannot connect to the docker daemon") || lower.contains("is the docker daemon running") {
            lead = "Docker isn't running, or this Mac can't reach it. Start Docker, then try again."
        } else if lower.contains("permission denied"), lower.contains("docker"), lower.contains(".sock") || lower.contains("daemon") {
            lead = "This Mac's user may not use Docker (permission denied on the Docker socket)."
        } else {
            return nil
        }
        return output.isEmpty ? lead : "\(lead)\n\n\(output)"
    }
}

/// Which container Browse… lists in for a local Docker profile: only the container selected in
/// the profile form, checked again on every listing and never a guess. When that container is
/// gone or stopped, the profile's identity is resolved as a run would resolve it (`DockerProfileResolver`):
/// a Compose service whose single container was recreated is followed (with a notice), and
/// anything a run would ask about (a recreated container known only by its name, several
/// replicas) is an error that sends the user back to the container list.
public enum DockerDirectoryBrowsing {
    public enum Target: Sendable, Equatable {
        /// List in this running container; `notice` says why it isn't the selected one.
        case container(ContainerInfo, notice: String?)
        case failure(String)
    }

    /// - Parameters:
    ///   - selectedId: the container selected in the form.
    ///   - current: `docker inspect` of it now (nil: it no longer exists).
    ///   - identity: the profile's identity (Compose labels, or the container name).
    ///   - running: the running containers; only consulted when the selected one isn't running.
    public static func target(selectedId: String, current: ContainerInfo?, identity: ContainerIdentity, running: [ContainerInfo]) -> Target {
        if let current, current.running { return .container(current, notice: nil) }
        var expected = identity
        expected.lastContainerId = selectedId
        let selectedName = current?.name ?? identity.containerName ?? String(selectedId.prefix(12))
        switch DockerProfileResolver.resolve(expected, among: running) {
        case .resolved(let container, _) where container.id == selectedId:
            return .container(container, notice: nil)
        case .resolved(let container, _):
            // Only a Compose service resolves to a different container without asking.
            return .container(container, notice: "\(identity.displayName) was recreated since you selected it. Listing its new container \(container.name) (\(container.shortId)), which runs use too. Refresh the container list to select it.")
        case .ambiguous(let matches):
            return .failure("The selected container of \(identity.displayName) is gone, and \(matches.count) running containers match it. Select one in the container list, then browse again.")
        case .needsConfirmation(let container, _):
            return .failure("The container named \(container.name) was recreated (new ID \(container.shortId)). Select it in the container list to confirm it is the same application, then browse again.")
        case .notRunning:
            if let current {
                let status = current.status.isEmpty ? "" : " (\(current.status))"
                return .failure("The container \(selectedName) isn't running\(status). Start it, then try again. Runlet lists folders only in the selected container.")
            }
            return .failure("The container \(selectedName) no longer exists, and no running container matches \(identity.displayName). Start the application, refresh the container list, and select its container.")
        }
    }
}

extension DockerCLI {
    /// Browse… for a local Docker profile: checks the selected container (`docker inspect`;
    /// the running containers only when it's gone or stopped), then lists `path` in it as the
    /// profile's execution user with its PHP. Read-only, and only on an explicit Browse…;
    /// nothing in the project runs.
    public func listProfileDirectory(selectedId: String, identity: ContainerIdentity, user: String?, phpExecutable: String, path: String) async -> RemoteDirectoryListing {
        let current = await inspect(selectedId)
        let target: DockerDirectoryBrowsing.Target
        if let current, current.running {
            target = .container(current, notice: nil)
        } else {
            do {
                target = DockerDirectoryBrowsing.target(selectedId: selectedId, current: current, identity: identity, running: try await runningContainers())
            } catch {
                return RemoteDirectoryListing(path: path, error: "\(error)")
            }
        }
        switch target {
        case .failure(let message):
            return RemoteDirectoryListing(path: path, error: message)
        case .container(let container, let notice):
            var listing = await listDirectory(containerId: container.id, user: user, phpExecutable: phpExecutable, path: path, place: container.name)
            listing.notice = notice
            return listing
        }
    }
}
