import Foundation

/// What `run_php` and `get_last_output` return for one run (#43), built from the run's events
/// in order: printed output, dumps, the result, errors with the line in the code the client
/// sent, notices, and how the run ended. Text is capped so a chatty snippet can't flood the
/// client; the Runlet tab keeps everything.
public struct MCPRunReport: Sendable, Equatable {
    public static let maxTextCharacters = 60_000

    public enum Entry: Sendable, Equatable {
        case output(String, stderr: Bool)
        case dump(String, line: Int?, dd: Bool)
        case result(String, type: String)
        case noResult
        case error(String)
        case notice(String)
        /// `\Runlet\notice()`, `warning()`, or `error()` (#196): "Warning (line 3): …".
        case message(String)
    }

    public var clientName: String
    public var tabTitle: String
    public var startedAt: Date
    /// The resolved target ("Sandbox · Laravel 12.31"); set once the run starts.
    public var targetLabel: String
    public private(set) var entries: [Entry] = []
    public private(set) var errors: [RunErrorInfo] = []
    /// The snippet's notice, warning, and error cards (#196); none of them fails the run.
    public private(set) var messages: [SnippetMessage] = []
    public private(set) var finished: FinishedInfo?
    public private(set) var phpVersion: String?
    public private(set) var framework: String?
    public private(set) var truncated = false
    private var characters = 0

    public init(clientName: String, tabTitle: String, targetLabel: String, startedAt: Date = Date()) {
        self.clientName = clientName
        self.tabTitle = tabTitle
        self.targetLabel = targetLabel
        self.startedAt = startedAt
    }

    public var isFinished: Bool { finished != nil }

    public mutating func apply(_ kind: RunEvent.Kind) {
        switch kind {
        case .started(let info):
            phpVersion = info.phpVersion ?? phpVersion
            framework = info.framework.map(Self.displayName) ?? framework
        case .bootstrapped(let info):
            if let name = info.driverName ?? info.framework.map(Self.displayName) {
                framework = name + (info.frameworkVersion.map { " " + $0 } ?? "")
            }
        case .stdout(let data):
            append(.output(String(decoding: data, as: UTF8.self), stderr: false))
        case .stderr(let data):
            append(.output(String(decoding: data, as: UTF8.self), stderr: true))
        case .dump(let dump):
            append(.dump(dump.value.plainText(), line: dump.inSnippet == true ? dump.snippetLine : nil, dd: dump.isDD))
        case .result(let result):
            if result.hasValue, let value = result.value {
                append(.result(value.plainText(), type: value.typeLabel))
            } else {
                append(.noResult)
            }
        case .error(let error):
            errors.append(error)
            append(.error(Self.describe(error)))
        case .notice(let message):
            append(.notice(message))
        case .snippetMessage(let message):
            messages.append(message)
            append(.message(message.summary(line: message.callerSnippetLine)))
        case .finished(let info):
            finished = info
        default:
            break
        }
    }

    /// The run couldn't start (the target couldn't be resolved, PHP is missing, …).
    public mutating func failBeforeLaunch(_ message: String) {
        let error = RunErrorInfo(stage: .launch, message: message)
        errors.append(error)
        append(.error(Self.describe(error)))
        finished = FinishedInfo(status: .failed, reason: "launch-failed", elapsedMs: 0)
    }

    private mutating func append(_ entry: Entry) {
        let size = Self.text(of: entry).count
        guard characters + size <= Self.maxTextCharacters else {
            truncated = true
            return
        }
        characters += size
        // Consecutive output on the same stream reads as one block.
        if case .output(let text, let stderr) = entry, case .output(let previous, let previousStderr)? = entries.last, stderr == previousStderr {
            entries[entries.count - 1] = .output(previous + text, stderr: stderr)
        } else {
            entries.append(entry)
        }
    }

    /// "laravel" → "Laravel", as tab cards show it.
    static func displayName(_ framework: String) -> String {
        framework.prefix(1).uppercased() + framework.dropFirst()
    }

    static func describe(_ error: RunErrorInfo) -> String {
        var text = (error.className ?? "Error") + ": " + error.message
        if error.inSnippet == true || error.snippetLine != nil, let line = error.snippetLine {
            text += " (line \(line))"
        } else if let file = error.file {
            text += " (\(file)" + (error.line.map { ":\($0)" } ?? "") + ")"
        }
        if error.stage != .execute { text += " [\(error.stage.rawValue)]" }
        return text
    }

    static func text(of entry: Entry) -> String {
        switch entry {
        case .output(let text, let stderr): (stderr ? "stderr:\n" : "Output:\n") + text
        case .dump(let value, let line, let dd): (dd ? "dd" : "dump") + (line.map { " (line \($0))" } ?? "") + ":\n" + value
        case .result(let value, let type): "Result (\(type)):\n" + value
        case .noResult: "No return value."
        case .error(let text): "Error: " + text
        case .notice(let text): "Note: " + text
        case .message(let text): text
        }
    }

    public var status: String {
        guard let finished else { return "running" }
        return finished.status.rawValue
    }

    /// The answer for the client. A run that failed (or was stopped) is a tool error, so the
    /// model sees that its code didn't work.
    public func toolResult(now: Date = Date()) -> MCPToolResult {
        var lines = ["Ran on \(targetLabel) in the Runlet tab “\(tabTitle)” (requested by \(clientName))."]
        let facts = [phpVersion.map { "PHP " + $0 }, framework].compactMap { $0 }
        if !facts.isEmpty { lines.append(facts.joined(separator: " · ")) }
        lines.append("")
        lines += entries.map(Self.text(of:)).flatMap { [$0, ""] }
        if truncated { lines.append("(More output was cut off here; the Runlet tab shows all of it.)\n") }
        if let finished {
            var end = "Finished: \(finished.status.rawValue) (\(finished.reason)) in \(finished.elapsedMs) ms"
            if let code = finished.exitCode { end += ", exit code \(code)" }
            lines.append(end + ".")
        } else {
            lines.append("Still running (started \(Int(now.timeIntervalSince(startedAt))) s ago). Call get_last_output again later.")
        }

        var structured: [String: MCPJSON] = [
            "target": .string(targetLabel),
            "tab": .string(tabTitle),
            "client": .string(clientName),
            "status": .string(status),
            "truncated": .bool(truncated),
        ]
        if let finished {
            structured["reason"] = .string(finished.reason)
            structured["durationMs"] = .int(finished.elapsedMs)
            if let code = finished.exitCode { structured["exitCode"] = .int(Int(code)) }
        }
        if let phpVersion { structured["php"] = .string(phpVersion) }
        if let framework { structured["framework"] = .string(framework) }
        var output = ""
        var dumps: [MCPJSON] = []
        for entry in entries {
            switch entry {
            case .output(let text, _): output += text
            case .dump(let value, let line, _): dumps.append(["value": .string(value), "line": line.map(MCPJSON.int) ?? .null])
            case .result(let value, let type): structured["result"] = ["value": .string(value), "type": .string(type)]
            default: break
            }
        }
        structured["output"] = .string(output)
        structured["dumps"] = .array(dumps)
        structured["errors"] = .array(errors.map { error in
            var object: [String: MCPJSON] = ["message": .string(error.message), "stage": .string(error.stage.rawValue)]
            if let name = error.className { object["class"] = .string(name) }
            if let line = error.snippetLine, error.inSnippet == true || error.file == nil { object["line"] = .int(line) }
            if let file = error.file { object["file"] = .string(file) }
            if let line = error.line { object["fileLine"] = .int(line) }
            return .object(object)
        })
        if !messages.isEmpty {
            structured["messages"] = .array(messages.map { message in
                var object: [String: MCPJSON] = ["level": .string(message.level.rawValue), "message": .string(message.message)]
                if let line = message.callerSnippetLine { object["line"] = .int(line) }
                if let file = message.file { object["file"] = .string(file) }
                if let line = message.line { object["fileLine"] = .int(line) }
                if let name = message.exception?.className { object["class"] = .string(name) }
                if let context = message.context { object["context"] = .string(context.plainText()) }
                return .object(object)
            })
        }
        let failed = finished.map { $0.status != .completed } ?? false
        return MCPToolResult(text: lines.joined(separator: "\n"), structured: .object(structured), isError: failed)
    }
}
