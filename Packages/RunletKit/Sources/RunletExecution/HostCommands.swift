import Foundation
import RunletCore

/// The user's shell environment (PATH from `~/.zprofile`, `~/.zshrc`, …), resolved once by
/// running their login shell interactively, as a terminal would. Apps opened from Finder
/// start with launchd's minimal PATH, which misses Homebrew, Herd, `~/.bin`, and the like,
/// so host commands are listed with this environment instead.
public actor HostShellEnvironment {
    public static let shared = HostShellEnvironment()

    private var cached: [String: String]?
    private var resolving: Task<[String: String], Never>?

    public init() {}

    /// The resolved environment (cached for the app's lifetime; see `reset()`).
    public func environment() async -> [String: String] {
        if let cached { return cached }
        if let resolving { return await resolving.value }
        let task = Task { await Self.resolve() }
        resolving = task
        let value = await task.value
        cached = value
        resolving = nil
        return value
    }

    /// Forgets the cached environment, e.g. after the user changed their rc files.
    public func reset() {
        cached = nil
    }

    /// Runs `shell -i -l -c` in the home directory with stdin closed (any question an rc file
    /// asks reads end-of-file) and reads `env -0` between markers, ignoring whatever the rc
    /// files print. Falls back to `base` plus the usual Homebrew paths.
    static func resolve(
        shell: String = TerminalLaunch.userShell(),
        base: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        timeout: Duration = .seconds(10)
    ) async -> [String: String] {
        let marker = "__RUNLET_ENV_\(UUID().uuidString.prefix(8))__"
        let script = "printf '%s' '\(marker)'; /usr/bin/env -0; printf '%s' '\(marker)'"
        var environment = base
        environment["TERM"] = "dumb"
        let spec = ProcessSpec(executable: shell, arguments: ["-i", "-l", "-c", script], environment: environment, workingDirectory: home)
        if let result = try? await runCommand(spec, timeout: timeout), let parsed = parseEnvironment(result.stdout, marker: marker), parsed["PATH"] != nil {
            var merged = base
            for (key, value) in parsed where !ignoredKeys.contains(key) {
                merged[key] = value
            }
            return merged
        }
        return fallback(base)
    }

    /// Shell bookkeeping that describes the resolving shell, not the user's environment.
    static let ignoredKeys: Set<String> = ["_", "SHLVL", "PWD", "OLDPWD", "TERM", "PS1", "PS2", "PROMPT", "RPROMPT"]

    /// `KEY=VALUE\0` entries between the first two occurrences of `marker`.
    static func parseEnvironment(_ data: Data, marker: String) -> [String: String]? {
        let markerData = Data(marker.utf8)
        guard let start = data.range(of: markerData),
              let end = data.range(of: markerData, in: start.upperBound..<data.endIndex) else { return nil }
        var result: [String: String] = [:]
        for entry in data[start.upperBound..<end.lowerBound].split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { continue }
            result[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return result
    }

    static func fallback(_ base: [String: String]) -> [String: String] {
        var environment = base
        var path = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for directory in ["/opt/homebrew/bin", "/usr/local/bin"] where !path.contains(directory) {
            path.append(directory)
        }
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }
}

/// Lists the commands of a driver's host command source by running its list command on this
/// Mac, in the project's folder.
public enum HostCommandLister {
    public struct Listing: Sendable, Equatable {
        public var commands: [ProjectCommand]
        /// Why nothing was listed (the command failed or printed no list).
        public var error: String?
    }

    /// Runs `source.listCommand` with `/bin/sh -c` in `directory` (stdin closed) and parses
    /// the first JSON object it prints; anything printed around it (banners, notices) is
    /// ignored. Never throws: failures come back as `Listing.error`.
    public static func list(_ source: HostCommandSource, directory: String, environment: [String: String], timeout: Duration = .seconds(30)) async -> Listing {
        let spec = ProcessSpec(executable: "/bin/sh", arguments: ["-c", source.listCommand], environment: environment, workingDirectory: directory)
        let result: (stdout: Data, stderr: Data, exitCode: Int32)
        do {
            result = try await runCommand(spec, timeout: timeout)
        } catch {
            return Listing(commands: [], error: "Runlet could not run “\(source.listCommand)”: \(error.localizedDescription)")
        }
        if let commands = parse(result.stdout, source: source) {
            return Listing(commands: commands, error: nil)
        }
        let stderr = String(decoding: result.stderr.suffix(4000), as: UTF8.self)
            .split(whereSeparator: \.isNewline).suffix(3).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let reason = result.exitCode == 0 ? "printed no command list" : "exited with code \(result.exitCode)"
        return Listing(commands: [], error: "“\(source.listCommand)” \(reason)" + (stderr.isEmpty ? "." : ": \(stderr)"))
    }

    /// Commands from a list command's output, or nil when it holds no list in the source's format.
    public static func parse(_ data: Data, source: HostCommandSource) -> [ProjectCommand]? {
        for object in jsonObjects(in: data) {
            switch source.format {
            case .runlet:
                if let list = try? JSONDecoder().decode(RunletList.self, from: object) {
                    return commands(from: list, source: source)
                }
            case .symfony:
                if let list = try? JSONDecoder().decode(SymfonyList.self, from: object) {
                    return commands(from: list, source: source)
                }
            }
        }
        return nil
    }

    // MARK: Formats

    private struct RunletList: Decodable {
        struct Entry: Decodable {
            var name: String
            var command: String
            var description: String?
            var group: String?
            var needsInput: Bool?
        }

        var commands: [Entry]
    }

    private struct SymfonyList: Decodable {
        struct Command: Decodable {
            var name: String
            var description: String?
            var hidden: Bool?
            var definition: Definition?
        }

        struct Definition: Decodable {
            struct Argument: Decodable {
                var isRequired: Bool?

                enum CodingKeys: String, CodingKey { case isRequired = "is_required" }
            }

            var arguments: [String: Argument]

            enum CodingKeys: String, CodingKey { case arguments }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                // PHP encodes an empty argument map as `[]`.
                arguments = (try? container.decode([String: Argument].self, forKey: .arguments)) ?? [:]
            }
        }

        var application: [String: String]?
        var commands: [Command]
    }

    /// Console plumbing every Symfony application has.
    static let builtinConsoleCommands: Set<String> = ["list", "help", "completion"]

    private static func commands(from list: RunletList, source: HostCommandSource) -> [ProjectCommand] {
        var seen = Set<String>()
        return list.commands.compactMap { entry in
            let name = entry.name.trimmingCharacters(in: .whitespaces)
            let line = entry.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !line.isEmpty, seen.insert(name).inserted else { return nil }
            let group = entry.group.map(ConsoleText.plain).flatMap { $0.isEmpty ? nil : $0 }
            return ProjectCommand(name: name, description: entry.description.map(ConsoleText.plain).flatMap { $0.isEmpty ? nil : $0 }, commandLine: line,
                                  group: group, origin: .host, source: source.name, needsInput: entry.needsInput ?? false)
        }
    }

    private static func commands(from list: SymfonyList, source: HostCommandSource) -> [ProjectCommand] {
        let console = source.console ?? source.name
        var seen = Set<String>()
        return list.commands.compactMap { command in
            let name = command.name
            guard !name.isEmpty, command.hidden != true, !name.hasPrefix("_"), !builtinConsoleCommands.contains(name), seen.insert(name).inserted else { return nil }
            let description = command.description.map(ConsoleText.plain).flatMap { $0.isEmpty ? nil : $0 }
            let needsInput = command.definition?.arguments.values.contains { $0.isRequired == true } ?? false
            return ProjectCommand(name: name, description: description, commandLine: console + " " + ProjectCommandLauncher.shellQuote(name),
                                  group: nil, origin: .host, source: source.name, needsInput: needsInput)
        }
    }

    // MARK: JSON in noisy output

    /// Every balanced top-level `{…}` in `data`, in order (strings and escapes respected).
    static func jsonObjects(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var objects: [Data] = []
        var index = 0
        while index < bytes.count, objects.count < 20 {
            guard bytes[index] == UInt8(ascii: "{") else {
                index += 1
                continue
            }
            if let end = matchingBrace(bytes, from: index) {
                objects.append(Data(bytes[index...end]))
                index = end + 1
            } else {
                index += 1
            }
        }
        return objects
    }

    private static func matchingBrace(_ bytes: [UInt8], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else {
                switch byte {
                case UInt8(ascii: "\""): inString = true
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return byte == UInt8(ascii: "}") ? index : nil }
                    if depth < 0 { return nil }
                default: break
                }
            }
            index += 1
        }
        return nil
    }
}

/// Symfony Console markup in descriptions.
public enum ConsoleText {
    /// `text` without style tags (`<fg=gray>…</>`, `<info>`, …) and with repeated leading
    /// bracket labels collapsed ("[aliases: wt] [aliases: wt] Switch" → "[aliases: wt] Switch").
    public static func plain(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"</?(?:(?:fg|bg|options|href)=[^<>]*|info|comment|error|question)>|</>"#, with: "", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"^(\[[^\]]*\])(?:\s*\1)+"#, with: "$1", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }
}
