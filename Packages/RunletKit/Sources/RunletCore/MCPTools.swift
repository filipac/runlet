import Foundation

/// The MCP client's description of itself (`clientInfo` from `initialize`, or the
/// `io.modelcontextprotocol/clientInfo` request metadata). Self-reported and unverified: it
/// names the client on approval sheets and in Settings, and is never used to decide anything.
public struct MCPClientInfo: Sendable, Codable, Equatable, Hashable {
    public var name: String
    public var title: String?
    public var version: String?

    public init(name: String, title: String? = nil, version: String? = nil) {
        self.name = name
        self.title = title
        self.version = version
    }

    /// Reads an `Implementation` object; nil without a usable name.
    public init?(json: MCPJSON?) {
        guard let json, let name = json["name"]?.stringValue.map(Self.clean), !name.isEmpty else { return nil }
        self.name = name
        title = json["title"]?.stringValue.map(Self.clean).flatMap { $0.isEmpty ? nil : $0 }
        version = json["version"]?.stringValue.map(Self.clean).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// What Runlet shows: the title, else the name ("Claude Code", "cursor-vscode").
    public var displayName: String { title ?? name }

    public static let unknown = MCPClientInfo(name: "AI client")

    /// One line of at most 60 characters without control characters (names are shown in
    /// sheets and tab titles).
    static func clean(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }
        let line = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }
}

/// A tool call from an MCP client, with its arguments checked.
public enum MCPToolCall: Sendable, Codable, Equatable {
    case listTargets
    case listSnippets(target: String?, query: String?)
    case getSnippet(id: String)
    /// Saves a personal snippet. Never runs it.
    case addSnippet(label: String, code: String, target: String?)
    /// Runs code on a target after the user approves it in Runlet.
    case runPHP(target: String, code: String)
    case getLastOutput

    public var toolName: String {
        switch self {
        case .listTargets: "list_targets"
        case .listSnippets: "list_snippets"
        case .getSnippet: "get_snippet"
        case .addSnippet: "add_snippet"
        case .runPHP: "run_php"
        case .getLastOutput: "get_last_output"
        }
    }
}

/// What a tool call returns: text for the model, optional structured JSON, and whether the
/// call failed (a tool execution error, which the model can read and act on).
public struct MCPToolResult: Sendable, Codable, Equatable {
    public var text: String
    public var structured: MCPJSON?
    public var isError: Bool

    public init(text: String, structured: MCPJSON? = nil, isError: Bool = false) {
        self.text = text
        self.structured = structured
        self.isError = isError
    }

    public static func error(_ text: String) -> MCPToolResult {
        MCPToolResult(text: text, isError: true)
    }

    /// Structured data, with its JSON as the text (for clients that ignore structured content).
    public static func json(_ value: MCPJSON) -> MCPToolResult {
        MCPToolResult(text: value.pretty, structured: value)
    }
}

/// The tools `runlet mcp` offers (#43), their input schemas, and argument checks.
public enum MCPTools {
    /// Largest code `run_php` and `add_snippet` accept (UTF-8 bytes): enough for any snippet,
    /// small enough for the approval sheet to show all of it.
    public static let maxCodeBytes = 200_000
    public static let maxLabelLength = 200
    public static let maxTargetLength = 1_000
    public static let maxQueryLength = 200

    public enum ParseError: Error, Equatable {
        /// Not one of the tools (a protocol error).
        case unknownTool(String)
        /// Arguments that don't fit the tool's schema (a tool execution error the model can fix).
        case invalidArguments(String)
    }

    public static let names = ["list_targets", "list_snippets", "get_snippet", "add_snippet", "run_php", "get_last_output"]

    /// The `tools/list` entries, in a fixed order.
    public static var definitions: [MCPJSON] {
        [
            tool(
                "list_targets",
                title: "List Runlet targets",
                description: "Lists where Runlet can run PHP: the Laravel sandbox, local projects, Docker applications, and SSH hosts, with each target's environment (development, staging, production) and whether runs there ask for approval. Pass a target's `target` value to run_php, list_snippets, or add_snippet. Reading the list connects to nothing.",
                properties: [:],
                required: [],
                annotations: ["readOnlyHint": true, "openWorldHint": false]
            ),
            tool(
                "list_snippets",
                title: "List snippets",
                description: "Lists the user's saved snippets (id, label, optional description, target, and the first lines). With `target`, lists the snippets saved for that target or for any target, plus the project's shared snippets (.runlet/snippets). Use get_snippet for the full code.",
                properties: [
                    "target": ["type": "string", "description": "Optional. A target from list_targets, e.g. \"sandbox\" or \"local:shop\"."],
                    "query": ["type": "string", "description": "Optional. Words that must all appear in the label, description, or code."],
                ],
                required: [],
                annotations: ["readOnlyHint": true, "openWorldHint": false]
            ),
            tool(
                "get_snippet",
                title: "Get a snippet",
                description: "Returns a saved snippet's code, label, optional description, and target. Reading a snippet never runs it.",
                properties: [
                    "id": ["type": "string", "description": "The snippet's id from list_snippets (or its exact label)."],
                ],
                required: ["id"],
                annotations: ["readOnlyHint": true, "openWorldHint": false]
            ),
            tool(
                "add_snippet",
                title: "Save a snippet",
                description: "Saves PHP code as a personal snippet in Runlet's Snippets list, optionally for one target. It only saves; nothing runs.",
                properties: [
                    "label": ["type": "string", "description": "A short name for the snippet.", "maxLength": .int(maxLabelLength)],
                    "code": ["type": "string", "description": "The PHP code. The opening <?php tag is optional."],
                    "target": ["type": "string", "description": "Optional. A target from list_targets; without it the snippet fits every target."],
                ],
                required: ["label", "code"],
                annotations: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false]
            ),
            tool(
                "run_php",
                title: "Run PHP in Runlet",
                description: "Runs PHP code on a Runlet target and returns the result: the value of the last expression (as in Tinker), dumps, printed output, errors with line numbers, the duration, and the target. The user must approve every run in Runlet, which shows the code and the target; a declined or unanswered request returns an error and nothing runs. Only the Laravel sandbox can be allowed for the rest of the session. Prefer the sandbox for experiments; production targets always ask with a warning, and SSH hosts that aren't connected say approving will connect. The run appears in a Runlet tab named after this client.",
                properties: [
                    "target": ["type": "string", "description": "Where to run: \"sandbox\", or a target from list_targets (\"local:<name>\", \"docker:<name>\", \"ssh:<name>\")."],
                    "code": ["type": "string", "description": "The PHP code to run. The opening <?php tag is optional; the application (Laravel, Symfony, WordPress, …) is booted first."],
                ],
                required: ["target", "code"],
                annotations: ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": true]
            ),
            tool(
                "get_last_output",
                title: "Get the last run's output",
                description: "Returns the output of the most recent run_php run (from any AI client), or its progress while it is still running. Useful after a run_php call timed out on the client's side.",
                properties: [:],
                required: [],
                annotations: ["readOnlyHint": true, "openWorldHint": false]
            ),
        ]
    }

    private static func tool(_ name: String, title: String, description: String, properties: [String: MCPJSON], required: [String], annotations: [String: MCPJSON]) -> MCPJSON {
        var schema: [String: MCPJSON] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
        if !required.isEmpty { schema["required"] = .array(required.map(MCPJSON.string)) }
        var annotated = annotations
        annotated["title"] = .string(title)
        return ["name": .string(name), "title": .string(title), "description": .string(description), "inputSchema": .object(schema), "annotations": .object(annotated)]
    }

    /// Checks a `tools/call`'s name and arguments.
    public static func parse(name: String, arguments: MCPJSON?) -> Result<MCPToolCall, ParseError> {
        guard names.contains(name) else { return .failure(.unknownTool(name)) }
        let object: [String: MCPJSON]
        switch arguments {
        case nil, .null?: object = [:]
        case .object(let value)?: object = value
        default: return .failure(.invalidArguments("Arguments must be an object."))
        }
        let allowed: Set<String> = switch name {
        case "list_snippets": ["target", "query"]
        case "get_snippet": ["id"]
        case "add_snippet": ["label", "code", "target"]
        case "run_php": ["target", "code"]
        default: []
        }
        if let extra = object.keys.sorted().first(where: { !allowed.contains($0) }) {
            let expected = allowed.isEmpty ? "no arguments" : allowed.sorted().joined(separator: ", ")
            return .failure(.invalidArguments("Unknown argument “\(extra)” for \(name) (expected \(expected))."))
        }
        do {
            switch name {
            case "list_targets":
                return .success(.listTargets)
            case "list_snippets":
                return .success(.listSnippets(target: try string(object, "target", required: false, max: maxTargetLength), query: try string(object, "query", required: false, max: maxQueryLength)))
            case "get_snippet":
                return .success(.getSnippet(id: try string(object, "id", required: true, max: maxTargetLength)!))
            case "add_snippet":
                let label = try string(object, "label", required: true, max: maxLabelLength)!
                let code = try code(object)
                return .success(.addSnippet(label: label, code: code, target: try string(object, "target", required: false, max: maxTargetLength)))
            case "run_php":
                let target = try string(object, "target", required: true, max: maxTargetLength)!
                return .success(.runPHP(target: target, code: try code(object)))
            default:
                return .success(.getLastOutput)
            }
        } catch let error as ParseError {
            return .failure(error)
        } catch {
            return .failure(.invalidArguments("\(error)"))
        }
    }

    private static func string(_ object: [String: MCPJSON], _ key: String, required: Bool, max: Int) throws -> String? {
        guard let value = object[key], value != .null else {
            if required { throw ParseError.invalidArguments("Missing “\(key)”.") }
            return nil
        }
        guard case .string(let text) = value else { throw ParseError.invalidArguments("“\(key)” must be a string.") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if required { throw ParseError.invalidArguments("“\(key)” is empty.") }
            return nil
        }
        guard trimmed.count <= max else { throw ParseError.invalidArguments("“\(key)” is longer than \(max) characters.") }
        return trimmed
    }

    private static func code(_ object: [String: MCPJSON]) throws -> String {
        guard let value = object["code"], value != .null else { throw ParseError.invalidArguments("Missing “code”.") }
        guard case .string(let code) = value else { throw ParseError.invalidArguments("“code” must be a string.") }
        let bare = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bare.isEmpty, bare != "<?php" else { throw ParseError.invalidArguments("“code” is empty.") }
        guard code.utf8.count <= maxCodeBytes else { throw ParseError.invalidArguments("“code” is larger than \(maxCodeBytes / 1000) KB.") }
        return code
    }

    /// Guidance for the model, sent with `initialize` and `server/discover`.
    public static let instructions = """
    Runlet is a PHP scratchpad on the user's Mac. Use list_targets to see where code can run \
    (the Laravel sandbox, local projects, Docker applications, SSH hosts) and run_php to run \
    code there. Every run waits for the user to approve it in Runlet, so tell the user to \
    look at Runlet when you start one. Prefer the sandbox for experiments; production targets \
    always ask with a warning, and Runlet never logs in to an SSH host for you. Snippets can be \
    read and saved without running anything.
    """
}
