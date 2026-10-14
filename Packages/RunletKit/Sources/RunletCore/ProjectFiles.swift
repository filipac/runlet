import Darwin
import Foundation

/// Why a project file named in a chat message (`@app/Models/Order.php`, #45) isn't sent.
public enum ProjectFileError: Error, Sendable, Equatable {
    /// The path leaves the project folder (`..`, an absolute path, or a symbolic link that points
    /// outside it).
    case outsideProject
    case notFound
    case folder
    /// A socket, a device, or another special file: reading it could block or never end.
    case notAFile
    /// Its name says it usually holds secrets (`.env`, keys, credentials).
    case secret
    case tooLarge(bytes: Int)
    case binary
    case unreadable(String)

    /// One sentence, after the path.
    public var message: String {
        switch self {
        case .outsideProject: "It's outside the project folder."
        case .notFound: "There's no such file in the project."
        case .folder: "It's a folder: name a file in it."
        case .notAFile: "It isn't a regular file."
        case .secret: "Runlet never sends files that usually hold secrets, such as .env files and keys."
        case .tooLarge(let bytes):
            "It's \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)); Runlet sends files up to \(ByteCountFormatter.string(fromByteCount: Int64(AIChatLimits.maxFileBytes), countStyle: .file))."
        case .binary: "It isn't text."
        case .unreadable(let reason): "It can't be read: \(reason)"
        }
    }
}

/// A project file the chat can send (#45), read and checked.
public struct ProjectFileText: Sendable, Equatable {
    /// The path relative to the project, as mentioned.
    public var path: String
    public var text: String
    public var bytes: Int
}

/// Project files for the chat's `@` mentions (#45): resolving a mention safely, reading it, and
/// listing the project's files for completion. Every path stays inside the project folder:
/// `..`, absolute paths, and symbolic links that lead outside are refused, and so are folders,
/// special files, files that usually hold secrets, large files, and anything that isn't text.
public enum ProjectFiles {
    /// Folders completion doesn't list (a mention of a file in one still works).
    public static let unlistedFolders: Set<String> = ["vendor", "node_modules", ".git", ".svn", ".hg", ".idea", ".vscode", ".fleet", ".DS_Store", ".phpunit.cache"]
    /// Hidden folders completion still lists.
    public static let listedHiddenFolders: Set<String> = [".runlet", ".github", ".tinkerwell"]

    private static let secretNames: Set<String> = [
        ".env", "auth.json", ".npmrc", ".netrc", ".pgpass", ".my.cnf", ".htpasswd", ".git-credentials", ".pypirc",
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "credentials.json", "service-account.json",
    ]
    private static let secretExtensions: Set<String> = ["pem", "key", "p12", "pfx", "jks", "keystore", "p8", "ppk", "kdbx", "gpg", "asc"]
    /// `.env.*` files that are templates, not secrets.
    private static let envTemplates: Set<String> = [".env.example", ".env.dist", ".env.sample", ".env.template"]
    /// Folders whose files are never sent.
    private static let secretFolders: Set<String> = [".git", ".ssh", ".gnupg", ".aws"]

    /// Whether a path's name says it usually holds secrets: `.env` and `.env.*` (but not
    /// `.env.example`), keys and certificates, credentials files, and anything in `.git` or
    /// `.ssh`.
    public static func isSecret(_ path: String) -> Bool {
        let components = path.split(separator: "/").map { String($0).lowercased() }
        guard let name = components.last else { return false }
        if components.dropLast().contains(where: secretFolders.contains) { return true }
        if name == ".env" || (name.hasPrefix(".env.") && !envTemplates.contains(name)) { return true }
        if secretNames.contains(name) || name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") { return true }
        return secretExtensions.contains((name as NSString).pathExtension)
    }

    /// The file `reference` (relative to the project, as typed after `@`) names inside `root`.
    /// Returns its real location and the path to show.
    public static func resolve(_ reference: String, in root: URL) -> Result<(url: URL, path: String), ProjectFileError> {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.notFound) }
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return .failure(.outsideProject) }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        guard !components.contains("..") else { return .failure(.outsideProject) }
        guard !components.isEmpty else { return .failure(.folder) }
        let path = components.joined(separator: "/")
        guard let realRoot = realPath(root.path) else { return .failure(.notFound) }
        let candidate = realRoot + "/" + path
        var info = stat()
        guard lstat(candidate, &info) == 0 else { return .failure(.notFound) }
        // A symbolic link anywhere on the way is followed, and must stay inside the project.
        guard let real = realPath(candidate) else { return .failure(.notFound) }
        guard real.hasPrefix(realRoot + "/") else { return real == realRoot ? .failure(.folder) : .failure(.outsideProject) }
        guard stat(real, &info) == 0 else { return .failure(.notFound) }
        if (info.st_mode & S_IFMT) == S_IFDIR { return .failure(.folder) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .failure(.notAFile) }
        // Both the name used and the name it leads to.
        if isSecret(path) || isSecret(String(real.dropFirst(realRoot.count + 1))) { return .failure(.secret) }
        return .success((URL(fileURLWithPath: real), path))
    }

    /// The file's text: refused when it's larger than `maxBytes`, or isn't UTF-8 text.
    public static func read(_ reference: String, in root: URL, maxBytes: Int = AIChatLimits.maxFileBytes) -> Result<ProjectFileText, ProjectFileError> {
        switch resolve(reference, in: root) {
        case .failure(let error):
            return .failure(error)
        case .success(let (url, path)):
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            guard size <= maxBytes else { return .failure(.tooLarge(bytes: size)) }
            let data: Data
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                data = try handle.read(upToCount: maxBytes + 1) ?? Data()
            } catch {
                return .failure(.unreadable(error.localizedDescription))
            }
            guard data.count <= maxBytes else { return .failure(.tooLarge(bytes: data.count)) }
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return .failure(.binary) }
            return .success(ProjectFileText(path: path, text: text, bytes: data.count))
        }
    }

    /// The project's files for completion, relative to `root`: at most `limit`, folders such as
    /// `vendor` and hidden ones left out, files that usually hold secrets too. Symbolic links to
    /// folders aren't followed.
    public static func list(in root: URL, limit: Int = 20_000) -> [String] {
        let base = root.standardizedFileURL
        // The enumerator may hand back the folder's real path (/private/var for /var).
        let prefixes = Set([base.path, realPath(base.path) ?? base.path].map { $0.hasSuffix("/") ? $0 : $0 + "/" })
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                                                              options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            let name = url.lastPathComponent
            if values?.isDirectory == true {
                if unlistedFolders.contains(name) || (name.hasPrefix(".") && !listedHiddenFolders.contains(name)) || secretFolders.contains(name.lowercased()) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true || values?.isSymbolicLink == true, name != ".DS_Store" else { continue }
            let full = url.standardizedFileURL.path
            guard let prefix = prefixes.first(where: full.hasPrefix) else { continue }
            let relative = String(full.dropFirst(prefix.count))
            if isSecret(relative) { continue }
            // A link is listed only when it leads to a file inside the project.
            if values?.isSymbolicLink == true, (try? resolve(relative, in: root).get()) == nil { continue }
            paths.append(relative)
            if paths.count >= limit { break }
        }
        return paths
    }

    /// The best matches for what's typed after `@`: a file name that is the query, then one that
    /// starts with it, contains it, a path that starts with or contains it, and then paths with
    /// its letters in order. Shorter paths first among equals. An empty query lists the
    /// shallowest files.
    public static func rank(_ paths: [String], query: String, limit: Int = 8) -> [String] {
        let query = query.lowercased()
        var scored: [(score: Int, path: String)] = []
        for path in paths {
            let lower = path.lowercased()
            let name = (lower as NSString).lastPathComponent
            let score: Int
            if query.isEmpty { score = lower.split(separator: "/").count }
            else if name == query || lower == query { score = 0 }
            else if name.hasPrefix(query) { score = 1 }
            else if name.contains(query) { score = 2 }
            else if lower.hasPrefix(query) { score = 3 }
            else if lower.contains(query) { score = 4 }
            else if isSubsequence(query, of: lower) { score = 5 }
            else { continue }
            scored.append((score, path))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score < b.score }
            if a.path.count != b.path.count { return a.path.count < b.path.count }
            return a.path < b.path
        }
        return scored.prefix(limit).map(\.path)
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var rest = needle[...]
        for character in haystack where character == rest.first {
            rest = rest.dropFirst()
            if rest.isEmpty { return true }
        }
        return rest.isEmpty
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
