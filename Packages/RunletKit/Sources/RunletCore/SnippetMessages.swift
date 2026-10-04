import Foundation

/// A card the snippet asked for (#196): `\Runlet\notice()`, `\Runlet\warning()`, or
/// `\Runlet\error()`, or the same methods on `\Runlet\Inspector`. The runner sends it as a
/// `notice` event with a `level` (and `user: true`); Runlet's own notices have neither and stay
/// `RunEvent.Kind.notice`. None of them ends the run or marks it failed: an error card is not an
/// `error` event, so Run History, the run's status, and notifications never count it.
public struct SnippetMessage: Sendable, Codable, Equatable {
    public enum Level: String, Sendable, Codable, CaseIterable {
        case notice, warning, error

        public var title: String {
            switch self {
            case .notice: "Notice"
            case .warning: "Warning"
            case .error: "Error"
            }
        }

        /// Copy Output's and the Plain transcript's marker, like Runlet's own notices and warnings.
        public var symbol: String {
            switch self {
            case .notice: "ℹ︎"
            case .warning: "⚠︎"
            case .error: "✖︎"
            }
        }
    }

    /// The Throwable passed to `error()`: where it was thrown (and the snippet line that led
    /// there), its stack trace without Runlet's frames, and its cause.
    public struct Exception: Sendable, Codable, Equatable {
        public var className: String
        public var inSnippet: Bool?
        public var snippetLine: Int?
        public var file: String?
        public var line: Int?
        public var trace: [RunErrorInfo.Frame]?
        public var previous: RunErrorInfo.Previous?

        public init(className: String, inSnippet: Bool? = nil, snippetLine: Int? = nil, file: String? = nil, line: Int? = nil, trace: [RunErrorInfo.Frame]? = nil, previous: RunErrorInfo.Previous? = nil) {
            self.className = className
            self.inSnippet = inSnippet
            self.snippetLine = snippetLine
            self.file = file
            self.line = line
            self.trace = trace
            self.previous = previous
        }
    }

    public var level: Level
    public var message: String
    /// Asked for by the snippet (or a project driver), not by Runlet itself.
    public var user: Bool?
    /// Where it was called: the snippet line, else the first project file outside `vendor/`.
    public var inSnippet: Bool?
    public var snippetLine: Int?
    public var file: String?
    public var line: Int?
    /// The `$context` argument, bounded by the runner like the inspector's values.
    public var context: ValueNode?
    /// Bytes of the message the runner left out (it keeps 16 KB).
    public var omittedBytes: Int?
    public var exception: Exception?

    public init(level: Level, message: String, user: Bool? = true, inSnippet: Bool? = nil, snippetLine: Int? = nil, file: String? = nil, line: Int? = nil, context: ValueNode? = nil, omittedBytes: Int? = nil, exception: Exception? = nil) {
        self.level = level
        self.message = message
        self.user = user
        self.inSnippet = inSnippet
        self.snippetLine = snippetLine
        self.file = file
        self.line = line
        self.context = context
        self.omittedBytes = omittedBytes
        self.exception = exception
    }

    enum CodingKeys: String, CodingKey {
        case level, message, user, inSnippet, snippetLine, file, line, context, omittedBytes, exception
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A level a newer runner might add reads as a notice.
        let rawLevel = try? c.decodeIfPresent(String.self, forKey: .level)
        level = rawLevel.flatMap { Level(rawValue: $0) } ?? .notice
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        user = try c.decodeIfPresent(Bool.self, forKey: .user)
        inSnippet = try c.decodeIfPresent(Bool.self, forKey: .inSnippet)
        snippetLine = try c.decodeIfPresent(Int.self, forKey: .snippetLine)
        file = try c.decodeIfPresent(String.self, forKey: .file)
        line = try c.decodeIfPresent(Int.self, forKey: .line)
        context = try c.decodeIfPresent(ValueNode.self, forKey: .context)
        omittedBytes = try c.decodeIfPresent(Int.self, forKey: .omittedBytes)
        exception = try c.decodeIfPresent(Exception.self, forKey: .exception)
    }

    /// The snippet line that called it, when the snippet did.
    public var callerSnippetLine: Int? { inSnippet == true ? snippetLine : nil }

    /// "RuntimeException: Sync failed", or the message alone.
    public var text: String {
        guard let exception else { return message }
        return message.isEmpty ? exception.className : exception.className + ": " + message
    }

    /// "Warning (line 3): Cache is cold", for Copy Output, the Plain transcript, and MCP results.
    /// `line` is the line to name (the editor's, or the client's code's); without it, the file.
    public func summary(line: Int?) -> String {
        var location = ""
        if let line {
            location = " (line \(line))"
        } else if let file {
            location = " (\(file)" + (self.line.map { ":\($0)" } ?? "") + ")"
        }
        var text = level.title + location + ": " + self.text
        if let omittedBytes, omittedBytes > 0 { text += " … (\(omittedBytes) more bytes)" }
        if let previous = exception?.previous { text += "\nCaused by \(previous.className): \(previous.message)" }
        if let context { text += "\nContext: " + context.plainText() }
        return text
    }

    /// A runner `notice` event: the snippet's card when it has a `level` (#196), else Runlet's own
    /// notice, a plain `{message}` as every runner before #196 sent.
    public static func noticeEvent(payload: Data) throws -> RunEvent.Kind {
        let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        if object?["level"] is String, let message = try? JSONDecoder().decode(SnippetMessage.self, from: payload) {
            return .snippetMessage(message)
        }
        return .notice(object?["message"] as? String ?? "")
    }
}

/// How many cards of each level a run showed, for the run's footer ("2 warnings, 1 error").
public struct SnippetMessageCounts: Sendable, Equatable {
    public var notices = 0
    public var warnings = 0
    public var errors = 0

    public init(notices: Int = 0, warnings: Int = 0, errors: Int = 0) {
        self.notices = notices
        self.warnings = warnings
        self.errors = errors
    }

    public mutating func add(_ level: SnippetMessage.Level) {
        switch level {
        case .notice: notices += 1
        case .warning: warnings += 1
        case .error: errors += 1
        }
    }

    /// "2 warnings, 1 error"; notices are left out, and nil when there are no warnings or errors.
    public var footer: String? {
        let parts = [(warnings, "warning"), (errors, "error")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
