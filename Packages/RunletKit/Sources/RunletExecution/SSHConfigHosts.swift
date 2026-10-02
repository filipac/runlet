import Foundation

/// Host aliases from an OpenSSH client config (`~/.ssh/config`), for the profile form's host
/// menu. Reads files only; `ssh -G` (see `SSHClient.effectiveConfiguration`) shows what an
/// alias resolves to. Patterns (`*`, `?`, `!`) are skipped, `Include` is followed (relative
/// paths are under `~/.ssh`, globs allowed), and `Match` blocks are ignored.
public enum SSHConfigHosts {
    public static var userConfig: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config")
    }

    /// Aliases in file order, without duplicates.
    public static func aliases(in config: URL = userConfig, sshDirectory: URL? = nil) -> [String] {
        let sshDirectory = sshDirectory ?? config.deletingLastPathComponent()
        var seen = Set<String>()
        var visited = Set<String>()
        var result: [String] = []
        collect(config, sshDirectory: sshDirectory, depth: 0, visited: &visited) { alias in
            if seen.insert(alias).inserted { result.append(alias) }
        }
        return result
    }

    private static func collect(_ file: URL, sshDirectory: URL, depth: Int, visited: inout Set<String>, add: (String) -> Void) {
        guard depth < 8, visited.insert(file.standardizedFileURL.path).inserted,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let words = tokens(line)
            guard let keyword = words.first?.lowercased() else { continue }
            let values = Array(words.dropFirst())
            switch keyword {
            case "host":
                for value in values where value.rangeOfCharacter(from: CharacterSet(charactersIn: "*?!")) == nil {
                    add(value)
                }
            case "include":
                for pattern in values {
                    for path in expand(pattern, sshDirectory: sshDirectory) {
                        collect(URL(fileURLWithPath: path), sshDirectory: sshDirectory, depth: depth + 1, visited: &visited, add: add)
                    }
                }
            default:
                break
            }
        }
    }

    /// Splits `Keyword value "quoted value"` and `Keyword=value`.
    static func tokens(_ line: String) -> [String] {
        var line = line
        if let equals = line.firstIndex(of: "="), !line[..<equals].contains(" ") {
            line.replaceSubrange(equals...equals, with: " ")
        }
        var words: [String] = []
        var current = ""
        var quoted = false
        for character in line {
            if character == "\"" {
                quoted.toggle()
            } else if character.isWhitespace && !quoted {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func expand(_ pattern: String, sshDirectory: URL) -> [String] {
        var path = (pattern as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = sshDirectory.appendingPathComponent(path).path }
        guard path.contains("*") || path.contains("?") || path.contains("[") else { return [path] }
        var matches = glob_t()
        defer { globfree(&matches) }
        guard glob(path, 0, nil, &matches) == 0 else { return [] }
        return (0..<Int(matches.gl_pathc)).compactMap { index in matches.gl_pathv[index].map { String(cString: $0) } }
    }
}
