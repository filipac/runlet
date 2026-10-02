import Foundation

/// Finds executables without relying on the terminal's PATH (apps launched from Finder
/// get a minimal environment).
public enum ExecutableLocator {
    public static var home: String { NSHomeDirectory() }

    /// Directories searched after the process PATH.
    public static var wellKnownDirectories: [String] {
        [
            "\(home)/Library/Application Support/Herd/bin",
            "\(home)/.config/herd-lite/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.docker/bin",
            "\(home)/.orbstack/bin",
            "\(home)/.rd/bin",
            "/Applications/Docker.app/Contents/Resources/bin",
            "/Applications/OrbStack.app/Contents/MacOS/xbin",
            "/usr/bin",
            "/bin",
        ]
    }

    public static var searchPath: [String] {
        let processPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (processPath + wellKnownDirectories).filter { seen.insert($0).inserted }
    }

    public static func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    /// Resolves a name (or absolute/`~` path) to an absolute executable path.
    public static func resolve(_ nameOrPath: String) -> String? {
        let expanded = (nameOrPath as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return isExecutable(expanded) ? expanded : nil
        }
        for directory in searchPath {
            let candidate = (directory as NSString).appendingPathComponent(expanded)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// Environment for child tools: the app's environment with a PATH that includes
    /// well-known tool directories (Docker credential helpers, Herd shims, etc.).
    public static func toolEnvironment(prepending extraDirectories: [String] = []) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (extraDirectories + searchPath).joined(separator: ":")
        if environment["HOME"] == nil { environment["HOME"] = home }
        return environment
    }
}

/// A validated PHP executable on the host.
public struct PHPInstallation: Sendable, Codable, Hashable, Identifiable {
    public var path: String
    public var version: String
    public var hasTokenizer: Bool
    public var source: String

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
        return PHPInstallation(path: resolved, version: version, hasTokenizer: (array.last as? Bool) ?? false, source: source)
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
