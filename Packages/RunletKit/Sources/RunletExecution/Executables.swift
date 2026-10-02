import Foundation
import RunletCore

/// A validated PHP executable on the host.
public struct PHPInstallation: Sendable, Codable, Hashable, Identifiable {
    public var path: String
    public var version: String
    public var hasTokenizer: Bool
    public var source: String
    /// Profiler extensions this PHP loads with its own php.ini (Profile Run needs Excimer);
    /// nil when unknown.
    public var profilers: PHPProfilers?

    public var id: String { path }

    public var versionComponents: (major: Int, minor: Int) {
        let parts = version.split(separator: ".").compactMap { Int($0.prefix { $0.isNumber }) }
        return (parts.first ?? 0, parts.count > 1 ? parts[1] : 0)
    }

    public func satisfies(minimum: (Int, Int)) -> Bool {
        let (major, minor) = versionComponents
        return major > minimum.0 || (major == minimum.0 && minor >= minimum.1)
    }

    /// Runlet's runner supports PHP 7.4 and newer.
    public var isSupportedByRunner: Bool { satisfies(minimum: (7, 4)) }

    /// RC/alpha/beta/dev builds are only chosen automatically when nothing else fits.
    public var isPrerelease: Bool {
        version.range(of: #"(RC|alpha|beta|dev)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

public enum PHPDiscovery {
    /// Candidate PHP executables in preference order.
    public static func candidatePaths() -> [(path: String, source: String)] {
        var results: [(String, String)] = []
        var seen = Set<String>()
        func add(_ path: String, _ source: String) {
            let resolved = (path as NSString).resolvingSymlinksInPath
            guard ExecutableLocator.isExecutable(path), seen.insert(resolved).inserted else { return }
            results.append((path, source))
        }
        for directory in ExecutableLocator.searchPath {
            add((directory as NSString).appendingPathComponent("php"), directory.contains("Herd") ? "Herd" : "PATH")
        }
        let herd = "\(ExecutableLocator.home)/Library/Application Support/Herd/bin"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: herd) {
            for entry in entries.sorted(by: >) where entry.range(of: #"^php\d\d$"#, options: .regularExpression) != nil {
                add("\(herd)/\(entry)", "Herd")
            }
        }
        for prefix in ["/opt/homebrew/opt", "/usr/local/opt"] {
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: prefix) {
                for entry in entries.sorted(by: >) where entry.hasPrefix("php") {
                    add("\(prefix)/\(entry)/bin/php", "Homebrew")
                }
            }
        }
        return results
    }

    /// Runs `php` to read its version. Returns nil if it is not a working PHP CLI.
    public static func inspect(path: String, source: String = "Custom") async -> PHPInstallation? {
        guard let resolved = ExecutableLocator.resolve(path) else { return nil }
        let spec = ProcessSpec(
            executable: resolved,
            arguments: ["-n", "-r", "echo json_encode([PHP_VERSION, function_exists('token_get_all')]);"],
            environment: ExecutableLocator.toolEnvironment(),
            newProcessGroup: true
        )
        guard let output = try? await runCommand(spec, timeout: .seconds(10)), output.exitCode == 0,
              let array = try? JSONSerialization.jsonObject(with: output.stdout) as? [Any],
              let version = array.first as? String else {
            return nil
        }
        var installation = PHPInstallation(path: resolved, version: version, hasTokenizer: (array.last as? Bool) ?? false, source: source)
        installation.profilers = await profilers(executable: resolved)
        return installation
    }

    /// Which profiler extensions a PHP loads. Unlike the version check this reads its php.ini
    /// (extensions load there), with auto_prepend_file and auto_append_file turned off so no
    /// configured script runs. Nil when the check fails.
    public static func profilers(executable: String) async -> PHPProfilers? {
        let spec = ProcessSpec(
            executable: executable,
            arguments: ["-d", "auto_prepend_file=", "-d", "auto_append_file=", "-d", "display_errors=stderr", "-r", PHPProfilers.probeCode],
            environment: ExecutableLocator.toolEnvironment(),
            newProcessGroup: true
        )
        guard let output = try? await runCommand(spec, timeout: .seconds(10)), output.exitCode == 0 else { return nil }
        return PHPProfilers.parse(String(decoding: output.stdout, as: UTF8.self))
    }

    /// Automatic choice: the first stable installation in discovery order (the `php` on PATH,
    /// i.e. the user's default, comes first), falling back to prereleases.
    public static func preferred(_ installations: [PHPInstallation], minimum: (Int, Int) = (7, 4)) -> PHPInstallation? {
        let usable = installations.filter { $0.satisfies(minimum: minimum) && $0.hasTokenizer }
        return usable.first { !$0.isPrerelease } ?? usable.first
    }

    public static func discover() async -> [PHPInstallation] {
        var installations: [PHPInstallation] = []
        for candidate in candidatePaths() {
            if let installation = await inspect(path: candidate.path, source: candidate.source) {
                installations.append(installation)
            }
        }
        return installations
    }
}
