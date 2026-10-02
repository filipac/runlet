import Foundation
import RunletCore

/// Reads a project checkout on this Mac the way `SSHProbe` reads the server's: `.git` files
/// (no `git` binary runs) and a CRC-32 of `composer.lock`.
public enum LocalCheckout {
    public static func read(_ folder: String) -> CheckoutState {
        let root = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
        var state = CheckoutState()
        if let git = gitDirectory(root) {
            let head = text(git.appendingPathComponent("HEAD"))?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let head, head.hasPrefix("ref: ") {
                let ref = String(head.dropFirst(5))
                state.branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
                state.commit = text(git.appendingPathComponent(ref))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? packedRef(ref, in: git)
            } else if let head, head.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil {
                state.commit = head
            }
            state.remote = originURL(text(git.appendingPathComponent("config")))
        }
        let lock = root.appendingPathComponent("composer.lock")
        if let data = try? Data(contentsOf: lock) {
            state.composerLockCRC = String(format: "%08x", CRC32.checksum(data))
            state.composerLockSize = data.count
        }
        return state
    }

    /// `.git` as a folder, or the folder a `gitdir:` file points to (worktrees, submodules).
    static func gitDirectory(_ root: URL) -> URL? {
        let dotGit = root.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let line = text(dotGit)?.trimmingCharacters(in: .whitespacesAndNewlines), line.hasPrefix("gitdir: ") else { return nil }
        let path = String(line.dropFirst(8))
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }

    static func packedRef(_ ref: String, in git: URL) -> String? {
        guard let packed = text(git.appendingPathComponent("packed-refs")) else { return nil }
        for line in packed.split(whereSeparator: \.isNewline) where line.hasSuffix(" " + ref) {
            return String(line.prefix(40))
        }
        return nil
    }

    /// `url` of `[remote "origin"]` in a git config.
    public static func originURL(_ config: String?) -> String? {
        guard let config else { return nil }
        var inOrigin = false
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.replacingOccurrences(of: " ", with: "") == #"[remote"origin"]"#
                continue
            }
            if inOrigin, line.hasPrefix("url") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "url" {
                    return parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    static func text(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), (attributes[.size] as? Int ?? 0) < 1_000_000 else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// Whether the local folder still matches the server's checkout (the optional drift check).
public enum CheckoutDrift {
    /// A warning when the checkouts differ, nil when they match or can't be compared.
    /// Commits are compared when both sides have `.git`; otherwise `composer.lock`.
    public static func warning(local: CheckoutState, remote: CheckoutState, host: String) -> String? {
        if let localCommit = local.commit, let remoteCommit = remote.commit {
            guard localCommit != remoteCommit else { return nil }
            return "Your local checkout \(local.summary.map { "(\($0)) " } ?? "")differs from \(host) (\(remote.summary ?? remoteCommit)). Completion and file links may not match the server's code."
        }
        if let localLock = local.composerLockCRC, let remoteLock = remote.composerLockCRC {
            guard localLock != remoteLock || local.composerLockSize != remote.composerLockSize else { return nil }
            return "composer.lock in your local folder differs from the one on \(host). Completion may not match the server's dependencies."
        }
        return nil
    }
}

/// CRC-32 (IEEE 802.3), as PHP's `hash('crc32b')` and zlib compute it.
public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1 }
        return value
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)] }
        return crc ^ 0xFFFF_FFFF
    }
}

/// Local folders that look like the server's project, for an SSH profile's local folder.
/// Signals, strongest first: the same git remote, the same `composer.json` name, the same
/// folder name. Suggestions are only ever applied with a click.
public enum LocalFolderSuggestions {
    public struct Suggestion: Sendable, Hashable, Identifiable {
        public enum Reason: Int, Sendable, Comparable {
            case gitRemote, composerName, folderName

            public static func < (lhs: Reason, rhs: Reason) -> Bool { lhs.rawValue < rhs.rawValue }

            public var description: String {
                switch self {
                case .gitRemote: "same git remote"
                case .composerName: "same composer.json name"
                case .folderName: "same folder name"
                }
            }
        }

        public var path: String
        public var reason: Reason
        public var id: String { path }
    }

    /// Folders where people keep projects (searched one and two levels deep).
    public static var defaultScanRoots: [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return ["Code", "Projects", "Sites", "Herd", "Developer", "src", "dev", "www", "Documents/Code"].map { home.appendingPathComponent($0, isDirectory: true) }
    }

    /// - Parameters:
    ///   - remoteDirectory: the profile's directory on the server.
    ///   - probe: Test Connection's result, when there is one (git remote, composer name).
    ///   - knownFolders: folders Runlet already knows (local projects, profiles' folders).
    ///   - scanRoots: folders searched for checkouts (only `.git/config` and `composer.json`
    ///     of each project are read).
    public static func suggest(remoteDirectory: String, probe: SSHProbe?, knownFolders: [String], scanRoots: [URL] = defaultScanRoots, limit: Int = 5) -> [Suggestion] {
        let remote = probe?.gitRemote.flatMap(normalizedRemote)
        let composerName = probe?.composerName?.lowercased()
        let names = folderNames(for: remoteDirectory, realDirectory: probe?.realDirectory)

        var candidates: [String] = []
        var seen = Set<String>()
        func add(_ path: String) {
            let standardized = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
            if seen.insert(standardized).inserted { candidates.append(standardized) }
        }
        knownFolders.forEach(add)
        let fm = FileManager.default
        for root in scanRoots {
            guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for child in children.prefix(500) where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if isProject(child) {
                    add(child.path)
                } else if let grandchildren = try? fm.contentsOfDirectory(at: child, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                    for grandchild in grandchildren.prefix(200) where isProject(grandchild) { add(grandchild.path) }
                }
            }
        }

        var found: [Suggestion] = []
        for path in candidates where fm.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if let remote, let git = LocalCheckout.gitDirectory(url),
               let local = LocalCheckout.originURL(LocalCheckout.text(git.appendingPathComponent("config"))).flatMap(normalizedRemote), local == remote {
                found.append(Suggestion(path: path, reason: .gitRemote))
            } else if let composerName, let name = composerPackageName(url), name == composerName {
                found.append(Suggestion(path: path, reason: .composerName))
            } else if names.contains(url.lastPathComponent.lowercased()) {
                found.append(Suggestion(path: path, reason: .folderName))
            }
        }
        return Array(found.sorted { $0.reason != $1.reason ? $0.reason < $1.reason : $0.path < $1.path }.prefix(limit))
    }

    /// `git@github.com:Org/App.git`, `https://github.com/org/app`, and
    /// `ssh://git@github.com:22/org/app.git` all become `github.com/org/app`.
    public static func normalizedRemote(_ url: String) -> String? {
        var value = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        if let scheme = value.range(of: "://") { value = String(value[scheme.upperBound...]) }
        if let at = value.firstIndex(of: "@"), value[..<at].contains(where: { $0 == "/" }) == false { value = String(value[value.index(after: at)...]) }
        // scp-like "host:path" (and "host:port/path" from ssh:// URLs).
        if let colon = value.firstIndex(of: ":") {
            let host = value[..<colon]
            var rest = value[value.index(after: colon)...]
            if let slash = rest.firstIndex(of: "/"), rest[..<slash].allSatisfy(\.isNumber) { rest = rest[rest.index(after: slash)...] }
            value = host + "/" + rest
        }
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix(".git") { value.removeLast(4) }
        return value.isEmpty ? nil : value
    }

    /// Names a local checkout of `remoteDirectory` might have: the folder itself, or the
    /// site folder for Forge-style `<site>/current` and `<site>/releases/<id>`, plus the first
    /// label of a domain-like name (`shop.example.com` → `shop`).
    static func folderNames(for remoteDirectory: String, realDirectory: String?) -> Set<String> {
        var names = Set<String>()
        for path in [remoteDirectory, realDirectory].compactMap({ $0 }) {
            var components = path.split(separator: "/").map(String.init)
            if components.last == "current" { components.removeLast() }
            if components.count >= 2, components[components.count - 2] == "releases" { components.removeLast(2) }
            guard let name = components.last?.lowercased(), !name.isEmpty, !["www", "html", "app", "public", "htdocs", "srv", "var"].contains(name) else { continue }
            names.insert(name)
            if name.contains("."), let label = name.split(separator: ".").first, label.count > 2 { names.insert(String(label)) }
        }
        return names
    }

    static func isProject(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent(".git").path) || fm.fileExists(atPath: url.appendingPathComponent("composer.json").path)
    }

    static func composerPackageName(_ url: URL) -> String? {
        guard let text = LocalCheckout.text(url.appendingPathComponent("composer.json")),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return (object["name"] as? String)?.lowercased()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
