import Foundation

/// Installs the `runlet` tool as a symbolic link in a folder the user chose (Settings ▸
/// General ▸ Command-Line Tool). Only that link is ever created or removed; a file that isn't
/// such a link is never replaced.
public enum CommandLineInstall {
    /// What is at the link's path now.
    public enum Status: Equatable, Sendable {
        case notInstalled
        /// A link to this copy of the tool.
        case installed
        /// A link to another copy of Runlet's tool (another Runlet.app, possibly gone).
        case linkedElsewhere(String)
        /// A file, folder, or link that isn't Runlet's is in the way.
        case blocked
    }

    public enum InstallError: Error, Equatable, LocalizedError {
        case blocked(String)
        case linkedElsewhere(String)
        case notRunletLink(String)

        public var errorDescription: String? {
            switch self {
            case .blocked(let path): "Something that isn't Runlet's link is already at \(path). Move it away or choose another folder."
            case .linkedElsewhere(let path): "\(path) links to another copy of Runlet."
            case .notRunletLink(let path): "\(path) isn't a link to Runlet's tool, so it was left alone."
            }
        }
    }

    /// The usual folders: `/usr/local/bin` (on the default PATH) and `~/.local/bin` (no
    /// administrator password).
    public static func standardFolders(home: String = NSHomeDirectory()) -> [URL] {
        [URL(fileURLWithPath: "/usr/local/bin", isDirectory: true), URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".local/bin", isDirectory: true)]
    }

    public static func link(in folder: URL) -> URL {
        folder.appendingPathComponent(CommandLineTool.name, isDirectory: false)
    }

    /// Whether `destination` (what a link points to) is the tool inside some Runlet.app.
    public static func isRunletTool(_ destination: String) -> Bool {
        destination.hasSuffix(".app/" + CommandLineTool.bundledPath)
    }

    public static func status(of link: URL, tool: URL) -> Status {
        let fileManager = FileManager.default
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else {
            // Not a link: nothing there, or something else (a file, a folder, another tool).
            return (try? fileManager.attributesOfItem(atPath: link.path)) == nil ? .notInstalled : .blocked
        }
        let absolute = destination.hasPrefix("/") ? destination : link.deletingLastPathComponent().appendingPathComponent(destination).path
        if URL(fileURLWithPath: absolute).standardizedFileURL.path == tool.standardizedFileURL.path { return .installed }
        return isRunletTool(absolute) ? .linkedElsewhere(absolute) : .blocked
    }

    /// Creates `link` → `tool`, creating the link's folder if needed. An existing link to
    /// another copy of Runlet's tool is replaced only when `replacing` is true.
    public static func install(tool: URL, at link: URL, replacing: Bool = false) throws {
        switch status(of: link, tool: tool) {
        case .installed:
            return
        case .blocked:
            throw InstallError.blocked(link.path)
        case .linkedElsewhere:
            guard replacing else { throw InstallError.linkedElsewhere(link.path) }
            try FileManager.default.removeItem(at: link)
        case .notInstalled:
            break
        }
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: tool.path)
    }

    /// Removes `link` if it is a link to Runlet's tool (any copy).
    public static func uninstall(link: URL, tool: URL) throws {
        switch status(of: link, tool: tool) {
        case .notInstalled: return
        case .installed, .linkedElsewhere: try FileManager.default.removeItem(at: link)
        case .blocked: throw InstallError.notRunletLink(link.path)
        }
    }

    /// Whether changing `folder` needs an administrator: it (or, when missing, the nearest
    /// existing folder above it) isn't writable by this user.
    public static func needsAdministrator(for folder: URL) -> Bool {
        var current = folder.standardizedFileURL
        while !FileManager.default.fileExists(atPath: current.path), current.path != "/" {
            current = current.deletingLastPathComponent()
        }
        return !FileManager.default.isWritableFile(atPath: current.path)
    }

    /// AppleScript that creates the link with administrator privileges (macOS asks for the
    /// password). It removes only a symbolic link already at that path, never a file.
    public static func administratorInstallScript(tool: URL, link: URL) -> String {
        let folder = link.deletingLastPathComponent().path
        return """
        set folderPath to \(appleScriptString(folder))
        set linkPath to \(appleScriptString(link.path))
        set toolPath to \(appleScriptString(tool.path))
        do shell script "/bin/mkdir -p " & quoted form of folderPath & " && { [ ! -L " & quoted form of linkPath & " ] || /bin/rm " & quoted form of linkPath & "; } && /bin/ln -s " & quoted form of toolPath & " " & quoted form of linkPath with administrator privileges
        """
    }

    /// AppleScript that removes the link with administrator privileges, only if it is a link.
    public static func administratorUninstallScript(link: URL) -> String {
        """
        set linkPath to \(appleScriptString(link.path))
        do shell script "[ ! -L " & quoted form of linkPath & " ] || /bin/rm " & quoted form of linkPath with administrator privileges
        """
    }

    /// `text` as an AppleScript string literal.
    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Whether `folder` is one of the folders in a `PATH` value.
    public static func isOnPath(_ folder: URL, path: String, home: String = NSHomeDirectory()) -> Bool {
        let wanted = CommandLineTool.standardized(folder.path)
        return path.split(separator: ":").contains { entry in
            CommandLineTool.absolutePath(String(entry), currentDirectory: "/", home: home) == wanted
        }
    }

    /// The line that puts `folder` on the PATH of zsh login shells, for `~/.zprofile`.
    public static func pathExport(for folder: URL, home: String = NSHomeDirectory()) -> String {
        var path = folder.path
        if path.hasPrefix(home + "/") { path = "$HOME" + path.dropFirst(home.count) }
        return "export PATH=\"\(path):$PATH\""
    }
}
