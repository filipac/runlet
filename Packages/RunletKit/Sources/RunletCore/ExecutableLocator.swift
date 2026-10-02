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

