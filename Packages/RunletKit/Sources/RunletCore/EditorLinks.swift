import Foundation

/// An editor that file links in the output (and "Open Project in Editor") open in.
public enum ExternalEditor: String, Sendable, Codable, CaseIterable {
    /// No editor: links reveal the file in Finder.
    case none
    case phpstorm, vscode, cursor, zed, sublime, textmate
    /// A user-provided command template (`AppSettings.externalEditorCommand`).
    case custom

    public var displayName: String {
        switch self {
        case .none: "None"
        case .phpstorm: "PhpStorm"
        case .vscode: "Visual Studio Code"
        case .cursor: "Cursor"
        case .zed: "Zed"
        case .sublime: "Sublime Text"
        case .textmate: "TextMate"
        case .custom: "Custom Command"
        }
    }

    /// Known application bundles, stable releases first.
    public var applications: [EditorApplication] {
        switch self {
        case .none, .custom:
            []
        case .phpstorm:
            [
                EditorApplication(bundleIdentifier: "com.jetbrains.PhpStorm", urlScheme: "phpstorm", cliPath: "Contents/MacOS/phpstorm"),
                EditorApplication(bundleIdentifier: "com.jetbrains.PhpStorm-EAP", urlScheme: "phpstorm", cliPath: "Contents/MacOS/phpstorm"),
            ]
        case .vscode:
            [
                EditorApplication(bundleIdentifier: "com.microsoft.VSCode", urlScheme: "vscode", cliPath: "Contents/Resources/app/bin/code"),
                EditorApplication(bundleIdentifier: "com.microsoft.VSCodeInsiders", urlScheme: "vscode-insiders", cliPath: "Contents/Resources/app/bin/code"),
                EditorApplication(bundleIdentifier: "com.vscodium", urlScheme: "vscodium", cliPath: "Contents/Resources/app/bin/codium"),
            ]
        case .cursor:
            [EditorApplication(bundleIdentifier: "com.todesktop.230313mzl4w4u92", urlScheme: "cursor", cliPath: "Contents/Resources/app/bin/cursor")]
        case .zed:
            [
                EditorApplication(bundleIdentifier: "dev.zed.Zed", urlScheme: "zed", cliPath: "Contents/MacOS/cli"),
                EditorApplication(bundleIdentifier: "dev.zed.Zed-Preview", urlScheme: "zed", cliPath: "Contents/MacOS/cli"),
            ]
        case .sublime:
            [
                EditorApplication(bundleIdentifier: "com.sublimetext.4", urlScheme: "subl", cliPath: "Contents/SharedSupport/bin/subl"),
                EditorApplication(bundleIdentifier: "com.sublimetext.3", urlScheme: "subl", cliPath: "Contents/SharedSupport/bin/subl"),
            ]
        case .textmate:
            [
                EditorApplication(bundleIdentifier: "com.macromates.TextMate", urlScheme: "txmt", cliPath: "Contents/MacOS/mate"),
                EditorApplication(bundleIdentifier: "com.macromates.TextMate.preview", urlScheme: "txmt", cliPath: "Contents/MacOS/mate"),
            ]
        }
    }
}

/// One installable variant of an editor (for example VS Code and VS Code Insiders).
public struct EditorApplication: Sendable, Hashable {
    public var bundleIdentifier: String
    /// URL scheme the app registers for "open file at line".
    public var urlScheme: String
    /// Command-line launcher inside the app bundle, used when the URL scheme isn't registered.
    public var cliPath: String

    public init(bundleIdentifier: String, urlScheme: String, cliPath: String) {
        self.bundleIdentifier = bundleIdentifier
        self.urlScheme = urlScheme
        self.cliPath = cliPath
    }
}

/// URL and argument builders for opening a file at a line in an external editor.
public enum EditorLinks {
    /// The editor's documented "open file at line" URL, or nil for `none`/`custom`.
    ///
    /// - PhpStorm: `phpstorm://open?file=<path>&line=<n>`
    /// - VS Code, Cursor, Zed: `<scheme>://file/<path>:<n>`
    /// - Sublime Text, TextMate: `<scheme>://open?url=file://<path>&line=<n>`
    public static func url(for editor: ExternalEditor, scheme: String? = nil, path: String, line: Int?) -> URL? {
        guard let scheme = scheme ?? editor.applications.first?.urlScheme else { return nil }
        let line = line.flatMap { $0 > 0 ? $0 : nil }
        switch editor {
        case .none, .custom:
            return nil
        case .phpstorm:
            var query = "file=" + encode(path, allowed: queryValueAllowed)
            if let line { query += "&line=\(line)" }
            return URL(string: "\(scheme)://open?\(query)")
        case .vscode, .cursor, .zed:
            let suffix = line.map { ":\($0)" } ?? ""
            return URL(string: "\(scheme)://file" + encode(absolute(path), allowed: pathAllowed) + suffix)
        case .sublime, .textmate:
            var query = "url=" + encode("file://" + absolute(path), allowed: queryValueAllowed)
            if let line { query += "&line=\(line)" }
            return URL(string: "\(scheme)://open?\(query)")
        }
    }

    /// Arguments for the editor's bundled command-line launcher (`cliPath`).
    public static func cliArguments(for editor: ExternalEditor, path: String, line: Int?) -> [String] {
        let line = line.flatMap { $0 > 0 ? $0 : nil }
        guard let line else { return [path] }
        switch editor {
        case .phpstorm: return ["--line", String(line), path]
        case .vscode, .cursor: return ["--goto", "\(path):\(line)"]
        case .zed, .sublime: return ["\(path):\(line)"]
        case .textmate: return ["-l", String(line), path]
        case .none, .custom: return [path]
        }
    }

    public enum CommandError: Error, Equatable, CustomStringConvertible {
        case empty
        case unterminatedQuote

        public var description: String {
            switch self {
            case .empty: "The custom editor command is empty."
            case .unterminatedQuote: "The custom editor command has an unterminated quote."
            }
        }
    }

    /// Turns a custom command template into an argument array (the first element is the
    /// executable). Placeholders are substituted after splitting, so a path with spaces stays
    /// one argument; nothing goes through a shell.
    ///
    /// - `{file}` is the absolute path; when the template has no `{file}`, the path is appended.
    /// - `{line}` is the 1-based line. Without a line, `:{line}` is dropped (so
    ///   `{file}:{line}` becomes the path) and any other `{line}` becomes `1`.
    public static func customCommand(_ template: String, path: String, line: Int?) throws -> [String] {
        var arguments = try splitArguments(template)
        guard !arguments.isEmpty else { throw CommandError.empty }
        let line = line.flatMap { $0 > 0 ? $0 : nil }
        let hasFile = arguments.contains { $0.contains("{file}") }
        arguments = arguments.map { argument in
            var result = argument
            if line == nil { result = result.replacingOccurrences(of: ":{line}", with: "") }
            result = result.replacingOccurrences(of: "{line}", with: String(line ?? 1))
            return result.replacingOccurrences(of: "{file}", with: path)
        }
        if !hasFile { arguments.append(path) }
        return arguments
    }

    /// Splits a command line into words like a POSIX shell does for quoting only:
    /// whitespace separates words, `'…'` is literal, `"…"` allows `\"` and `\\`, and a
    /// backslash outside quotes escapes the next character. No expansion of any kind.
    public static func splitArguments(_ command: String) throws -> [String] {
        enum Quote { case none, single, double }
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote = Quote.none
        var characters = command.makeIterator()
        while let character = characters.next() {
            switch quote {
            case .single:
                if character == "'" { quote = .none } else { current.append(character) }
            case .double:
                if character == "\"" {
                    quote = .none
                } else if character == "\\" {
                    guard let next = characters.next() else { throw CommandError.unterminatedQuote }
                    if next != "\"" && next != "\\" { current.append("\\") }
                    current.append(next)
                } else {
                    current.append(character)
                }
            case .none:
                if character == " " || character == "\t" || character == "\n" {
                    if inWord {
                        words.append(current)
                        current = ""
                        inWord = false
                    }
                } else if character == "'" {
                    quote = .single
                    inWord = true
                } else if character == "\"" {
                    quote = .double
                    inWord = true
                } else if character == "\\" {
                    if let next = characters.next() { current.append(next) }
                    inWord = true
                } else {
                    current.append(character)
                    inWord = true
                }
            }
        }
        guard quote == .none else { throw CommandError.unterminatedQuote }
        if inWord { words.append(current) }
        return words
    }

    // MARK: Encoding

    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
    private static let pathAllowed = unreserved.union("/".utf8)
    private static let queryValueAllowed = unreserved.union("/:".utf8)

    /// Percent-encodes every UTF-8 byte outside `allowed`.
    static func encode(_ string: String, allowed: Set<UInt8>) -> String {
        var result = ""
        for byte in string.utf8 {
            if allowed.contains(byte) {
                result.append(Character(UnicodeScalar(byte)))
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    private static func absolute(_ path: String) -> String {
        path.hasPrefix("/") ? path : "/" + path
    }
}

/// Where a path reported by PHP can be opened on this Mac.
public enum EditorPathResolution: Sendable, Equatable {
    /// A host path that can be opened.
    case mapped(String)
    /// No host counterpart; the reason is shown as the link's tooltip.
    case unavailable(reason: String)

    public var path: String? {
        if case .mapped(let path) = self { return path }
        return nil
    }

    public var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// Maps paths as the PHP process saw them to paths on this Mac. Local and sandbox runs report
/// host paths; Docker runs report container paths, which map through the profile's working
/// directory → local source folder (or the sandbox's mounted install directory).
public struct EditorPathMapping: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Runtime paths are host paths.
        case host
        /// Runtime paths are container paths under `containerRoot`, which corresponds to
        /// `hostRoot` on this Mac (nil when no local source is configured).
        case container(containerRoot: String, hostRoot: String?)
        /// Runtime paths are paths on the SSH host `host`, under any of `remoteRoots` (the
        /// profile's directory and the real path PHP reported for it), which all correspond
        /// to `localRoot` on this Mac (nil when the profile has no local folder). A root that
        /// ends in `/current` (Forge-style zero-downtime deployments) also covers every
        /// `releases/<id>/` beside it.
        case remote(remoteRoots: [String], localRoot: String?, host: String)
    }

    public var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    public static let host = EditorPathMapping(kind: .host)

    public static func container(root: String, hostRoot: String?) -> EditorPathMapping {
        EditorPathMapping(kind: .container(containerRoot: root, hostRoot: expandedFolder(hostRoot)))
    }

    /// Server paths under `roots` (empty and duplicate roots are dropped) → `localRoot`.
    public static func remote(roots: [String?], localRoot: String?, host: String) -> EditorPathMapping {
        var seen = Set<String>()
        let unique = roots.compactMap { $0 }.filter { $0.hasPrefix("/") }.map(normalize).filter { seen.insert($0).inserted }
        return EditorPathMapping(kind: .remote(remoteRoots: unique, localRoot: expandedFolder(localRoot), host: host))
    }

    private static func expandedFolder(_ path: String?) -> String? {
        path.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
    }

    /// The mapping for a run's snapshot. `dockerLocalSource` is the Docker profile's
    /// `localSourcePath` (ignored for other kinds).
    public static func forSnapshot(_ snapshot: TargetSnapshot, dockerLocalSource: String?) -> EditorPathMapping {
        forSnapshot(snapshot, localSource: dockerLocalSource)
    }

    /// The mapping for a run's snapshot. `localSource` is the Docker or SSH profile's local
    /// folder (ignored for local and sandbox runs); `runtimeDirectory` is the working
    /// directory the run reported in `started` (for SSH, the real path of a symlinked
    /// directory such as Forge's `current`).
    public static func forSnapshot(_ snapshot: TargetSnapshot, localSource: String?, runtimeDirectory: String? = nil) -> EditorPathMapping {
        switch snapshot.kind {
        case .local, .sandboxLocal:
            return .host
        case .sandboxDocker:
            return .container(root: snapshot.workingDirectory, hostRoot: snapshot.hostMountDirectory)
        case .docker:
            return .container(root: snapshot.workingDirectory, hostRoot: localSource)
        case .ssh:
            let host = snapshot.ssh?.displayName ?? "the server"
            if let container = snapshot.containerName ?? snapshot.containerId.map({ String($0.prefix(12)) }) {
                // Container paths map to the local folder through the server directory's bind
                // mount (`localFolderRoot`), else through the container's working directory.
                if let root = snapshot.localFolderRoot {
                    return .remote(roots: [root], localRoot: localSource, host: "\(container) on \(host)")
                }
                return .remote(roots: [snapshot.workingDirectory, runtimeDirectory], localRoot: localSource, host: "\(container) on \(host)")
            }
            return .remote(roots: [snapshot.workingDirectory, runtimeDirectory], localRoot: localSource, host: host)
        }
    }

    /// The host path for `runtimePath`, or why there is none.
    public func resolve(_ runtimePath: String) -> EditorPathResolution {
        guard runtimePath.hasPrefix("/") else {
            return .unavailable(reason: "“\(runtimePath)” is not a file on disk.")
        }
        let path = Self.normalize(runtimePath)
        switch kind {
        case .host:
            return .mapped(path)
        case .container(let containerRoot, let hostRoot):
            guard let hostRoot else {
                return .unavailable(reason: "\(path) is inside the container. Set a local source folder in the Docker profile to open container files in your editor.")
            }
            let root = Self.normalize(containerRoot)
            let relative: String
            if root == "/" {
                relative = path
            } else if path == root {
                relative = ""
            } else if path.hasPrefix(root + "/") {
                relative = String(path.dropFirst(root.count))
            } else {
                return .unavailable(reason: "\(path) is outside the mapped directory \(root), so it has no counterpart on this Mac.")
            }
            let host = Self.normalize(hostRoot)
            if relative.isEmpty { return .mapped(host) }
            return .mapped(host == "/" ? relative : host + relative)
        case .remote(let remoteRoots, let localRoot, let host):
            guard let localRoot else {
                return .unavailable(reason: "\(path) is on \(host). Set a local folder in the SSH profile to open server files in your editor.")
            }
            guard let relative = Self.relativePath(path, remoteRoots: remoteRoots) else {
                let roots = remoteRoots.isEmpty ? "the profile's directory" : remoteRoots.joined(separator: " or ")
                return .unavailable(reason: "\(path) is outside \(roots) on \(host), so it has no counterpart in the local folder.")
            }
            let local = Self.normalize(localRoot)
            if relative.isEmpty { return .mapped(local) }
            return .mapped(local == "/" ? relative : local + relative)
        }
    }

    /// `path` relative to the longest matching root ("" for the root itself, else starting
    /// with "/"). A root ending in `/current` also matches `<base>/releases/<id>/…`.
    static func relativePath(_ path: String, remoteRoots: [String]) -> String? {
        var best: (length: Int, relative: String)?
        func consider(_ root: String, _ relative: String) {
            if best == nil || root.count > best!.length { best = (root.count, relative) }
        }
        for root in remoteRoots.map(normalize) {
            if root == "/" {
                consider(root, path)
            } else if path == root {
                consider(root, "")
            } else if path.hasPrefix(root + "/") {
                consider(root, String(path.dropFirst(root.count)))
            }
            if root.hasSuffix("/current") {
                let releases = String(root.dropLast("current".count)) + "releases/"
                guard path.hasPrefix(releases) else { continue }
                let rest = path.dropFirst(releases.count)
                guard let release = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first, !release.isEmpty else { continue }
                consider(releases + release, String(rest.dropFirst(release.count)))
            }
        }
        return best?.relative
    }

    /// Lexically resolves `.`, `..`, and repeated or trailing slashes (no file-system access:
    /// container paths don't exist on this Mac).
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(component)
        }
        return "/" + parts.joined(separator: "/")
    }
}
