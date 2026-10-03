import Foundation
import RunletCore

/// A folder on a server (or in a container on it), as the directory browser and Detect show
/// it. Paths are lexical: a symlink such as Forge's `current` is kept, not resolved.
public struct RemoteDirectoryEntry: Sendable, Codable, Hashable, Identifiable {
    public var name: String
    public var path: String
    public var isSymlink: Bool
    /// Where a symlink points (`readlink`, possibly relative).
    public var target: String?
    /// Whether this login can open the folder.
    public var readable: Bool
    /// What the folder looks like: `laravel`, `symfony`, `wordpress`, `composer`, `runlet`.
    public var markers: [String]

    public var id: String { path }

    public init(name: String, path: String, isSymlink: Bool = false, target: String? = nil, readable: Bool = true, markers: [String] = []) {
        self.name = name
        self.path = path
        self.isSymlink = isSymlink
        self.target = target
        self.readable = readable
        self.markers = markers
    }

    /// Looks like a PHP application (a framework, Composer, or a `.runlet` driver).
    public var isApplication: Bool { !markers.isEmpty }
}

/// One folder's subfolders, read on the server by a short `php -r` that only lists files.
public struct RemoteDirectoryListing: Sendable, Codable, Equatable {
    /// The folder listed: absolute, with `~` expanded and `.`/`..` resolved lexically.
    public var path: String
    public var home: String?
    /// Markers of the listed folder itself (see `RemoteDirectoryEntry.markers`).
    public var markers: [String]
    public var entries: [RemoteDirectoryEntry]
    /// More than `RemoteDirectories.entryLimit` subfolders; the rest aren't listed.
    public var truncated: Bool
    public var error: String?
    /// Something to know about where this listing came from (a Docker profile's container
    /// was recreated and the listing followed it, as runs do). Not part of the list program's
    /// output.
    public var notice: String?

    public init(path: String, home: String? = nil, markers: [String] = [], entries: [RemoteDirectoryEntry] = [], truncated: Bool = false, error: String? = nil, notice: String? = nil) {
        self.path = path
        self.home = home
        self.markers = markers
        self.entries = entries
        self.truncated = truncated
        self.error = error
        self.notice = notice
    }

    /// The parent folder (nil at `/`).
    public var parent: String? {
        guard path != "/", !path.isEmpty else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}

/// What Detect found on a server: the login's home folder and folders that look like PHP
/// applications (`~/*`, `~/*/current`, `/var/www/*`, `/srv/*`, `/home/*/*`, …).
public struct RemoteDirectoryDetection: Sendable, Codable, Equatable {
    public var home: String?
    public var user: String?
    public var candidates: [RemoteDirectoryEntry]
    public var error: String?

    public init(home: String? = nil, user: String? = nil, candidates: [RemoteDirectoryEntry] = [], error: String? = nil) {
        self.home = home
        self.user = user
        self.candidates = candidates
        self.error = error
    }
}

/// The PHP programs behind the directory browser and Detect. They only read the file system
/// (`scandir`, `is_dir`, `is_file`, `readlink`): nothing in the project runs and nothing is
/// written. They travel base64-encoded (`RemoteShell.inlinePHP`), so any login shell leaves
/// them intact.
public enum RemoteDirectories {
    /// The most subfolders one listing returns.
    public static let entryLimit = 1000

    /// Shared helpers: the home folder and a folder's application markers.
    static let helpers = #"""
    $home = getenv('HOME') ?: null;
    if (($home === null || $home === '') && function_exists('posix_getpwuid') && function_exists('posix_geteuid')) { $pw = @posix_getpwuid(posix_geteuid()); $home = $pw['dir'] ?? null; }
    $markers = function ($d) {
        $m = [];
        if (@is_file("$d/artisan")) { $m[] = 'laravel'; }
        if (@is_file("$d/bin/console") && (@is_file("$d/config/bundles.php") || @is_file("$d/src/Kernel.php"))) { $m[] = 'symfony'; }
        if (@is_file("$d/wp-config.php") || @is_file("$d/wp-load.php")) { $m[] = 'wordpress'; }
        if (@is_file("$d/composer.json")) { $m[] = 'composer'; }
        if (@is_dir("$d/.runlet")) { $m[] = 'runlet'; }
        return $m;
    };
    $entry = function ($f) use ($markers) {
        $link = @is_link($f);
        return ['name' => basename($f), 'path' => $f, 'isSymlink' => $link, 'target' => $link ? (@readlink($f) ?: null) : null,
                'readable' => @is_readable($f) && @is_executable($f), 'markers' => $markers($f)];
    };
    """#

    /// Lists the subfolders of `$argv[1]` (blank: the home folder; `~` and `~/…` expand to it).
    /// Errors are codes: `relative`, `missing`, `notDirectory`, `unreadable`.
    static let listScript = helpers + #"""
    $req = $argv[1]; $limit = (int) $argv[2];
    $p = $req === '' ? ($home ?: '/') : $req;
    if ($p === '~' || strncmp($p, '~/', 2) === 0) { $p = rtrim((string) $home, '/') . substr($p, 1); }
    if ($p === '' || $p[0] !== '/') { echo json_encode(['path' => $req, 'home' => $home, 'markers' => [], 'entries' => [], 'truncated' => false, 'error' => 'relative']); exit(0); }
    $parts = [];
    foreach (explode('/', $p) as $s) { if ($s === '' || $s === '.') { continue; } if ($s === '..') { array_pop($parts); continue; } $parts[] = $s; }
    $p = '/' . implode('/', $parts);
    $out = ['path' => $p, 'home' => $home, 'markers' => [], 'entries' => [], 'truncated' => false, 'error' => null];
    if (!@file_exists($p) && !@is_link($p)) { $out['error'] = 'missing'; echo json_encode($out); exit(0); }
    if (!@is_dir($p)) { $out['error'] = 'notDirectory'; echo json_encode($out); exit(0); }
    $out['markers'] = $markers($p);
    $names = @scandir($p);
    if ($names === false) { $out['error'] = 'unreadable'; echo json_encode($out); exit(0); }
    foreach ($names as $n) {
        if ($n === '.' || $n === '..') { continue; }
        $f = $p === '/' ? "/$n" : "$p/$n";
        if (!@is_dir($f)) { continue; }
        if (count($out['entries']) >= $limit) { $out['truncated'] = true; break; }
        $out['entries'][] = $entry($f);
    }
    echo json_encode($out, JSON_INVALID_UTF8_SUBSTITUTE);
    """#

    /// The home folder and folders that look like PHP applications.
    static let detectScript = helpers + #"""
    $user = null;
    if (function_exists('posix_getpwuid') && function_exists('posix_geteuid')) { $pw = @posix_getpwuid(posix_geteuid()); $user = $pw['name'] ?? null; }
    $patterns = [];
    if ($home) { $h = rtrim($home, '/'); $patterns = [$h, "$h/*", "$h/*/current", "$h/*/*/current"]; }
    $patterns = array_merge($patterns, ['/var/www', '/var/www/*', '/var/www/*/current', '/var/www/*/*', '/srv/*', '/srv/*/current', '/home/*/*', '/home/*/*/current', '/opt/*', '/app', '/code']);
    $seen = []; $found = [];
    foreach ($patterns as $pattern) {
        foreach (glob($pattern, GLOB_ONLYDIR) ?: [] as $d) {
            if (isset($seen[$d])) { continue; }
            $seen[$d] = true;
            $e = $entry($d);
            if ($e['markers']) { $found[] = $e; }
            if (count($found) >= 60) { break 2; }
        }
    }
    echo json_encode(['home' => $home, 'user' => $user, 'candidates' => $found], JSON_INVALID_UTF8_SUBSTITUTE);
    """#

    /// Where a listing was read, for its error messages.
    public enum Place: Sendable, Equatable {
        /// A server, as the SSH login sees it ("forge@shop").
        case server(String)
        /// A container ("app-1", or "web on forge@shop"), as the execution user sees it (nil:
        /// the container's default user).
        case container(String, user: String?)
    }

    /// Turns the list program's output (the last line; a login script may print first) into
    /// a listing with plain-language errors. nil when the output isn't a listing.
    public static func decodeListing(_ stdout: Data, requested: String, host: String) -> RemoteDirectoryListing? {
        decodeListing(stdout, requested: requested, place: .server(host))
    }

    public static func decodeListing(_ stdout: Data, requested: String, place: Place) -> RemoteDirectoryListing? {
        guard var listing = decodeLastLine(RemoteDirectoryListing.self, from: stdout) else { return nil }
        if let code = listing.error {
            listing.error = listingError(code, path: listing.path.isEmpty ? requested : listing.path, place: place)
        }
        listing.entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return listing
    }

    public static func decodeDetection(_ stdout: Data) -> RemoteDirectoryDetection? {
        decodeLastLine(RemoteDirectoryDetection.self, from: stdout)
    }

    static func listingError(_ code: String, path: String, host: String) -> String {
        listingError(code, path: path, place: .server(host))
    }

    static func listingError(_ code: String, path: String, place: Place) -> String {
        switch place {
        case .server(let host):
            return switch code {
            case "relative": "“\(path)” isn't an absolute path. Start it with / (or ~ for the home folder)."
            case "missing": "\(path) doesn't exist on \(host)."
            case "notDirectory": "\(path) on \(host) is a file, not a folder."
            case "unreadable": "This login can't open \(path) on \(host) (permission denied)."
            default: code
            }
        case .container(let container, let user):
            let who = user.map { "The user “\($0)”" } ?? "The container's default user"
            return switch code {
            case "relative": "“\(path)” isn't an absolute path. Start it with / (or ~ for the user's home folder)."
            case "missing": "\(path) doesn't exist in \(container)."
            case "notDirectory": "\(path) in \(container) is a file, not a folder."
            case "unreadable": "\(who) can't open \(path) in \(container) (permission denied). Runs use the same user, so choose a folder it can read, or change the execution user."
            default: code
            }
        }
    }

    private static func decodeLastLine<T: Decodable>(_ type: T.Type, from stdout: Data) -> T? {
        let text = String(decoding: stdout, as: UTF8.self)
        guard let line = text.split(whereSeparator: \.isNewline).last else { return nil }
        return try? JSONDecoder().decode(type, from: Data(line.utf8))
    }

    /// Arguments for the list program.
    static func listArguments(path: String) -> [String] {
        [path, String(entryLimit)]
    }
}

extension DockerCLI {
    /// `docker exec [--user …] <container> <php> -r <list program> -- <path> <limit>`: no
    /// `-i`, `-t`, or `--workdir`, and the path is one argument after `--` (never parsed by a
    /// shell on this Mac; over SSH `spec` quotes every word).
    public func listDirectoryArguments(containerId: String, user: String?, phpExecutable: String, path: String) -> [String] {
        var arguments = ["exec"]
        if let user, !user.isEmpty { arguments += ["--user", user] }
        return arguments + [containerId, phpExecutable, "-r", phpCode(RemoteDirectories.listScript), "--"] + RemoteDirectories.listArguments(path: path)
    }

    /// Lists the subfolders of `path` inside a container (blank: the user's home folder there),
    /// for browsing a working directory (a local Docker profile, or an SSH profile's container
    /// step). Read-only: `scandir` and friends, nothing written.
    public func listDirectory(containerId: String, user: String?, phpExecutable: String, path: String, place: String) async -> RemoteDirectoryListing {
        let arguments = listDirectoryArguments(containerId: containerId, user: user, phpExecutable: phpExecutable, path: path)
        let user = user.flatMap { $0.isEmpty ? nil : $0 }
        do {
            let result = try await runCommand(spec(arguments), timeout: .seconds(20))
            if result.exitCode == 0, let listing = RemoteDirectories.decodeListing(result.stdout, requested: path, place: .container(place, user: user)) {
                return listing
            }
            let message = String(decoding: result.stderr + result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let explained = explainFailure(message, exitCode: result.exitCode)
                ?? DockerExecFailure.explain(message, exitCode: result.exitCode, container: place, php: phpExecutable, user: user)
            return RemoteDirectoryListing(path: path, error: explained ?? (message.isEmpty ? "docker exec failed (exit \(result.exitCode))." : message))
        } catch {
            return RemoteDirectoryListing(path: path, error: "\(error)")
        }
    }
}

extension SSHClient {
    /// Lists the subfolders of `path` on the server (blank or `~`: the home folder) with the
    /// profile's PHP, in BatchMode through the shared connection. Read-only; explicit actions
    /// only (the directory browser).
    public func listDirectory(_ endpoint: SSHEndpoint, phpExecutable: String, path: String, timeout: Duration = .seconds(20)) async -> RemoteDirectoryListing {
        let command = RemoteShell.phpCommand(php: phpExecutable, code: RemoteDirectories.listScript, arguments: RemoteDirectories.listArguments(path: path))
        do {
            let result = try await run(endpoint, remoteCommand: command, timeout: timeout)
            if result.exitCode == 0, let listing = RemoteDirectories.decodeListing(result.stdout, requested: path, host: endpoint.displayName) {
                return listing
            }
            return RemoteDirectoryListing(path: path, error: failure(result, endpoint: endpoint, php: phpExecutable))
        } catch {
            return RemoteDirectoryListing(path: path, error: "\(error)")
        }
    }

    /// Detect: the login's home folder and folders that look like PHP applications. When the
    /// profile's PHP can't be found, the home folder still comes from the shell.
    public func detectDirectories(_ endpoint: SSHEndpoint, phpExecutable: String, timeout: Duration = .seconds(20)) async -> RemoteDirectoryDetection {
        let command = RemoteShell.phpCommand(php: phpExecutable, code: RemoteDirectories.detectScript, arguments: [])
        do {
            let result = try await run(endpoint, remoteCommand: command, timeout: timeout)
            if result.exitCode == 0, let detection = RemoteDirectories.decodeDetection(result.stdout) {
                return detection
            }
            let message = failure(result, endpoint: endpoint, php: phpExecutable)
            if result.exitCode == 127 {
                // No PHP under that name: the shell still knows the home folder.
                let home = try? await run(endpoint, remoteCommand: RemoteShell.command("printf '%s\\n' \"$HOME\""), timeout: timeout)
                if let home, home.exitCode == 0,
                   let path = String(decoding: home.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init), path.hasPrefix("/") {
                    return RemoteDirectoryDetection(home: path, error: message)
                }
            }
            return RemoteDirectoryDetection(error: message)
        } catch {
            return RemoteDirectoryDetection(error: "\(error)")
        }
    }

    /// A plain explanation of a failed helper program (ssh, PHP, or its own output).
    func failure(_ result: (stdout: Data, stderr: Data, exitCode: Int32), endpoint: SSHEndpoint, php: String) -> String {
        let stderr = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = stderr.isEmpty ? stdout : stderr
        return SSHFailure.explain(raw, exitCode: result.exitCode, host: endpoint.displayName, php: php)
            ?? (raw.isEmpty ? "The command failed on \(endpoint.displayName) (exit \(result.exitCode))." : raw)
    }
}
