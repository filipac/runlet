import Foundation
import RunletCore

/// Outcome of resolving a saved Docker profile against currently running containers.
public enum ProfileResolution: Sendable, Equatable {
    /// Exactly one container matches the stable identity.
    case resolved(ContainerInfo, recreated: Bool)
    /// Several replicas match; the user must choose (never pick the first).
    case ambiguous([ContainerInfo])
    /// A container with the saved name exists but is a different container than before and
    /// there is no stable Compose identity to prove it is the same application.
    case needsConfirmation(ContainerInfo, reason: String)
    /// Nothing matching is running.
    case notRunning(String)

    public var container: ContainerInfo? {
        if case .resolved(let container, _) = self { return container }
        return nil
    }
}

public enum DockerProfileResolver {
    /// Pure resolution logic over a container list (unit-tested without Docker).
    public static func resolve(_ identity: ContainerIdentity, among containers: [ContainerInfo]) -> ProfileResolution {
        let running = containers.filter(\.running)
        if let project = identity.composeProject, let service = identity.composeService {
            let matches = running.filter { $0.composeProject == project && $0.composeService == service }
            switch matches.count {
            case 0:
                return .notRunning("No running container for Compose service \(project)/\(service).")
            case 1:
                let match = matches[0]
                return .resolved(match, recreated: identity.lastContainerId != nil && identity.lastContainerId != match.id)
            default:
                // A replica the user chose earlier (ContainerChoiceSheet) stays chosen while it
                // runs; once it is gone, the choice is asked again.
                if let lastId = identity.lastContainerId, let chosen = matches.first(where: { $0.id == lastId }) {
                    return .resolved(chosen, recreated: false)
                }
                return .ambiguous(matches.sorted { ($0.composeNumber ?? $0.name) < ($1.composeNumber ?? $1.name) })
            }
        }

        if let lastId = identity.lastContainerId, let same = running.first(where: { $0.id == lastId }) {
            return .resolved(same, recreated: false)
        }
        guard let name = identity.containerName, let named = running.first(where: { $0.name == name }) else {
            return .notRunning("No running container named \(identity.containerName ?? "?").")
        }
        if identity.lastContainerId == nil {
            return .resolved(named, recreated: false)
        }
        let imageNote = identity.lastImage.map { $0 == named.image ? "same image \($0)" : "image changed from \($0) to \(named.image)" } ?? "image \(named.image)"
        return .needsConfirmation(named, reason: "The container named \(name) was recreated (new ID \(named.shortId), \(imageNote)). Confirm it is the same application before running.")
    }

    public static func resolve(_ profile: DockerProfile, docker: DockerCLI) async throws -> ProfileResolution {
        resolve(profile.identity, among: try await docker.runningContainers())
    }
}

/// Facts gathered from inside a container to help configure a profile.
public struct ContainerProbe: Sendable, Equatable, Codable {
    public var phpVersion: String?
    public var phpBinary: String?
    public var user: String?
    public var uid: Int?
    public var workingDirectoryExists: Bool
    public var workingDirectoryReadable: Bool
    public var framework: String
    public var temporaryDirectoryWritable: Bool
    public var hasTokenizer: Bool
    public var canSignal: String
    /// Candidate application directories that contain composer.json or artisan.
    public var candidates: [String]
    public var error: String?
}

extension DockerCLI {
    /// Probes PHP, the working directory, the temp directory, and signaling capability
    /// inside a container. Uses only PHP itself, so no shell utilities are required.
    public func probe(containerId: String, phpExecutable: String, user: String?, workingDirectory: String, temporaryDirectory: String, extraCandidates: [String]) async -> ContainerProbe {
        let code = #"""
        $wd = $argv[1]; $tmp = $argv[2]; $cands = array_slice($argv, 3);
        $fw = 'plain';
        $drivers = glob("$wd/.runlet/*Driver.php") ?: [];
        if ($drivers) { $fw = 'custom:' . implode(',', array_map(function ($f) { return basename($f, '.php'); }, $drivers)); }
        elseif (is_file("$wd/bootstrap/app.php") && (is_file("$wd/artisan") || is_dir("$wd/vendor/laravel-zero/framework"))) { $fw = 'laravel'; }
        elseif (is_file("$wd/wp-load.php") || is_file("$wd/web/wp/wp-load.php") || is_file("$wd/public/wp/wp-load.php") || is_file("$wd/wordpress/wp-load.php") || is_file("$wd/wp/wp-load.php")) { $fw = 'wordpress'; }
        elseif (is_file("$wd/bin/console") && (is_file("$wd/src/Kernel.php") || is_file("$wd/config/bundles.php"))) { $fw = 'symfony'; }
        elseif (is_file("$wd/composer.json") || is_file("$wd/vendor/autoload.php")) { $fw = 'composer'; }
        $found = [];
        foreach (array_unique($cands) as $c) {
            if ($c !== '' && (is_file("$c/composer.json") || is_file("$c/artisan"))) { $found[] = $c; }
        }
        $user = null; $uid = function_exists('posix_geteuid') ? posix_geteuid() : null;
        if ($uid !== null && function_exists('posix_getpwuid')) { $pw = @posix_getpwuid($uid); $user = $pw['name'] ?? null; }
        $signal = function_exists('posix_kill') ? 'posix' : ((function_exists('exec') && is_file('/bin/sh')) ? 'shell' : 'none');
        echo json_encode([
            'phpVersion' => PHP_VERSION, 'phpBinary' => PHP_BINARY, 'user' => $user, 'uid' => $uid,
            'workingDirectoryExists' => is_dir($wd), 'workingDirectoryReadable' => is_readable($wd),
            'framework' => $fw, 'temporaryDirectoryWritable' => is_dir($tmp) && is_writable($tmp),
            'hasTokenizer' => function_exists('token_get_all'), 'canSignal' => $signal, 'candidates' => $found,
        ]);
        """#
        var arguments = ["exec"]
        if let user, !user.isEmpty { arguments += ["--user", user] }
        arguments += [containerId, phpExecutable, "-r", phpCode(code), "--", workingDirectory, temporaryDirectory] + extraCandidates
        do {
            let result = try await runCommand(spec(arguments), timeout: .seconds(20))
            if result.exitCode == 0, let probe = try? JSONDecoder().decode(ContainerProbe.self, from: result.stdout) {
                return probe
            }
            let message = String(decoding: result.stderr + result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return ContainerProbe(workingDirectoryExists: false, workingDirectoryReadable: false, framework: "plain", temporaryDirectoryWritable: false, hasTokenizer: false, canSignal: "none", candidates: [], error: explainFailure(message, exitCode: result.exitCode) ?? (message.isEmpty ? "Probe failed with exit code \(result.exitCode)." : message))
        } catch {
            return ContainerProbe(workingDirectoryExists: false, workingDirectoryReadable: false, framework: "plain", temporaryDirectoryWritable: false, hasTokenizer: false, canSignal: "none", candidates: [], error: "\(error)")
        }
    }

    /// Working-directory suggestions from container metadata and mounts.
    public static func workingDirectorySuggestions(for container: ContainerInfo) -> [String] {
        var candidates: [String] = []
        if !container.workingDir.isEmpty, container.workingDir != "/" { candidates.append(container.workingDir) }
        candidates += container.mountDestinations.filter { destination in
            !destination.hasPrefix("/var/lib") && !destination.hasPrefix("/tmp") && !destination.hasPrefix("/run") && !destination.hasSuffix(".sock") && destination != "/"
        }
        candidates += ["/var/www/html", "/var/www", "/app", "/srv/app", "/code", "/application"]
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }
}
