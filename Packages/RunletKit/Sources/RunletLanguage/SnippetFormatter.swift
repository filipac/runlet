import Foundation
import RunletCore

/// Why Format Code (#36) left the text as it was.
public enum SnippetFormatError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The code doesn't parse; the formatter's message.
    case syntax(String)
    /// Formatting would change what a magic comment shows (1-based editor line).
    case magicComment(line: Int, comment: String)
    /// The formatted code lost or changed a comment (a safety net; not expected).
    case commentChanged(line: Int)
    /// The formatter binary is missing from this build.
    case unavailable
    case timedOut
    /// Any other formatter failure, with its message.
    case failed(String)

    public var description: String {
        switch self {
        case .syntax(let message):
            "The code has a syntax error, so it wasn't formatted: \(message)."
        case .magicComment(let line, let comment):
            "Formatting would change what the magic comment \(comment) on line \(line) shows, so the code wasn't formatted."
        case .commentChanged(let line):
            "Formatting would change the comment on line \(line), so the code wasn't formatted."
        case .unavailable:
            "The formatter (Mago) is missing from this build."
        case .timedOut:
            "The formatter took too long, so the code wasn't formatted."
        case .failed(let message):
            "The code couldn't be formatted: \(message)"
        }
    }
}

/// Formats a PHP tab's text with the bundled Mago formatter (#36), on this Mac and without PHP.
///
/// The text goes to `mago format --stdin-input` with an app-written config in a private
/// temporary directory, so a project's or the user's own `mago.toml` never applies and nothing
/// is written next to the code. Formatting never runs the code. Snippets usually have no
/// `<?php`: one is added for the formatter and removed again. An omitted final semicolon (which
/// the runner accepts) is added for the formatter and removed again. Magic comments must keep
/// what they show; when they wouldn't, or the code doesn't parse, the text is left unchanged.
public struct SnippetFormatter: Sendable {
    public struct Options: Sendable, Equatable {
        public var style: PHPFormatStyle
        public var quotes: PHPFormatQuotes
        public var indentWidth: Int
        public var useTabs: Bool
        /// The target's PHP version ("8.3", "7.4.33"). It decides where trailing commas may go.
        /// Unknown versions format for PHP 7.4, whose code is valid on every later version.
        public var phpVersion: String?

        public init(style: PHPFormatStyle = .per, quotes: PHPFormatQuotes = .single, indentWidth: Int = 4, useTabs: Bool = false, phpVersion: String? = nil) {
            self.style = style
            self.quotes = quotes
            self.indentWidth = indentWidth
            self.useTabs = useTabs
            self.phpVersion = phpVersion
        }

        public init(settings: AppSettings, phpVersion: String?) {
            self.init(style: settings.formatStyle, quotes: settings.formatQuotes, indentWidth: settings.tabWidth, useTabs: !settings.insertSpaces, phpVersion: phpVersion)
        }

        /// Mago's `[formatter]` table.
        var configTOML: String {
            [
                "# Written by Runlet for Format Code. Do not edit.",
                "[formatter]",
                "preset = \"\(style.magoPreset)\"",
                "single-quote = \(quotes == .single)",
                "tab-width = \(min(max(indentWidth, 1), 16))",
                "use-tabs = \(useTabs)",
                "",
            ].joined(separator: "\n")
        }

        /// `major.minor` for `--php-version`, within what the formatter knows (7.0–8.6).
        var magoPHPVersion: String {
            let parts = (phpVersion ?? "").split(separator: ".").prefix(2).compactMap { Int($0.prefix { $0.isNumber }) }
            guard parts.count == 2 else { return "7.4" }
            let version = (parts[0], parts[1])
            if version < (7, 0) { return "7.0" }
            if version > (8, 6) { return "8.6" }
            return "\(version.0).\(version.1)"
        }
    }

    public let executable: URL
    public var timeout: Duration

    public init(executable: URL, timeout: Duration = .seconds(10)) {
        self.executable = executable
        self.timeout = timeout
    }

    public var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }

    static let syntheticTag = "<?php\n"

    /// The formatted text, or `text` itself when it's already formatted or blank.
    public func format(_ text: String, options: Options = Options()) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        guard isAvailable else { throw SnippetFormatError.unavailable }
        let tagless = !ScratchDocumentMapping.startsWithOpenTag(text)
        let source = tagless ? Self.syntheticTag + text : text
        var formatted: String
        do {
            formatted = try await runFormatter(source, options: options)
        } catch SnippetFormatError.syntax(let message) {
            // An omitted final semicolon is accepted by the runner: format with one, then take
            // it out again. Any other error is the one the code has as written.
            guard let closed = Self.closingFinalStatement(source),
                  let output = try? await runFormatter(closed, options: options) else {
                throw SnippetFormatError.syntax(message)
            }
            formatted = Self.removingFinalSemicolon(output)
        }
        try Self.verifyComments(before: source, after: formatted, lineOffset: tagless ? 1 : 0)
        var result = tagless ? Self.removingSyntheticTag(formatted) : formatted
        // Keep the text's own ending: a final line break only when it had one.
        if !text.hasSuffix("\n") {
            while result.hasSuffix("\n") { result.removeLast() }
        }
        return result
    }

    // MARK: Running Mago

    private func runFormatter(_ source: String, options: Options) async throws -> String {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("runlet-format-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw SnippetFormatError.failed("\(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: directory) }
        let config = directory.appendingPathComponent("mago.toml")
        do {
            try options.configTOML.write(to: config, atomically: true, encoding: .utf8)
        } catch {
            throw SnippetFormatError.failed("\(error.localizedDescription)")
        }
        var environment = ExecutableLocator.minimalEnvironment()
        // Mago looks for a global config in these; point them at the private directory.
        environment["HOME"] = directory.path
        environment["XDG_CONFIG_HOME"] = directory.path
        let arguments = [
            "--colors", "never", "--config", config.path, "--workspace", directory.path,
            "--no-version-check", "--no-extensions", "--threads", "1",
            "--allow-unsupported-php-version", "--php-version", options.magoPHPVersion,
            "format", "--stdin-input",
        ]
        let spec = ProcessSpec(executable: executable.path, arguments: arguments, environment: environment, workingDirectory: directory.path, standardInput: Data(source.utf8))
        let process: SupervisedProcess
        do {
            process = try SupervisedProcess.launch(spec)
        } catch {
            throw SnippetFormatError.failed("\(error)")
        }
        let timedOut = TimeoutFlag()
        let limit = timeout
        let watchdog = Task {
            try await Task.sleep(for: limit)
            timedOut.set()
            await process.terminate(grace: .milliseconds(200), timeout: .seconds(2))
        }
        let result = await process.collect()
        watchdog.cancel()
        if timedOut.isSet { throw SnippetFormatError.timedOut }
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        guard result.termination == .exited(0) else {
            throw Self.error(fromStderr: stderr, termination: result.termination)
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    /// Mago reports a parse error as `ERROR Failed to parse <stdin>: <message>`.
    static func error(fromStderr stderr: String, termination: ProcessTermination) -> SnippetFormatError {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines {
            if let range = line.range(of: "Failed to parse ") {
                let rest = line[range.upperBound...]
                let message = rest.range(of: ": ").map { String(rest[$0.upperBound...]) } ?? String(rest)
                return .syntax(message.trimmingCharacters(in: CharacterSet(charactersIn: ". ")))
            }
        }
        let errors = lines.filter { $0.hasPrefix("ERROR") }.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        let message = errors.first ?? lines.last ?? "the formatter exited with status \(termination.exitCode)"
        return .failed(String(message.prefix(300)))
    }

    // MARK: Snippet shape

    /// The source with a `;` right after its last code token, or nil when it already ends with
    /// one (or with a close tag), so there is no omitted final semicolon to add.
    static func closingFinalStatement(_ source: String) -> String? {
        let tokens = PHPScanner.tokens(source)
        guard let last = tokens.last(where: { !$0.isComment }), last.isCode, last.text != ";" else { return nil }
        var bytes = Array(source.utf8)
        bytes.insert(59, at: last.range.upperBound)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Formatted text without the `;` that `closingFinalStatement` added (the last code token).
    static func removingFinalSemicolon(_ formatted: String) -> String {
        let tokens = PHPScanner.tokens(formatted)
        guard let last = tokens.last(where: { !$0.isComment }), last.kind == .punctuation, last.text == ";" else { return formatted }
        var bytes = Array(formatted.utf8)
        var start = last.range.lowerBound
        let end = last.range.upperBound
        // `foo() ;` at the end of a line leaves no trailing space behind.
        if end == bytes.count || bytes[end] == 10 || bytes[end] == 13 {
            while start > 0, bytes[start - 1] == 32 || bytes[start - 1] == 9 { start -= 1 }
        }
        bytes.removeSubrange(start..<end)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The formatter's output without the `<?php` added for it, and the blank lines after it.
    static func removingSyntheticTag(_ formatted: String) -> String {
        var text = Substring(formatted)
        guard text.hasPrefix("<?php") else { return formatted }
        text = text.dropFirst(5)
        return String(text.drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
    }

    // MARK: Comment checks

    /// Magic comment forms (#10), as the runner recognizes them (`MagicComments::form`).
    static func isMagicComment(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == "//?" { return true }
        guard trimmed.hasPrefix("/*?"), trimmed.hasSuffix("*/"), trimmed.count >= 5 else { return false }
        let inner = trimmed.dropFirst(3).dropLast(2).trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty || inner == "." || inner.hasPrefix("->") || inner.hasPrefix("?->")
    }

    /// A comment compared without whitespace, and with `#` written as `//` (as Mago does).
    static func normalizedComment(_ text: String) -> String {
        var value = text
        if value.hasPrefix("#") { value = "//" + value.dropFirst() }
        return value.filter { !$0.isWhitespace }
    }

    /// Every comment survives in order, and each magic comment still follows the same code:
    /// the same last name, variable, or literal before it; for `/*?…*/` inside parentheses, the
    /// parentheses still close right after it (`$a + ($b /*?*/)` must not lose them); and a
    /// `//?` on a line of its own stays on a line of its own.
    static func verifyComments(before: String, after: String, lineOffset: Int) throws {
        let old = PHPScanner.tokens(before)
        let new = PHPScanner.tokens(after)
        let oldComments = old.indices.filter { old[$0].isComment }
        let newComments = new.indices.filter { new[$0].isComment }
        for (position, oldIndex) in oldComments.enumerated() {
            let line = max(1, old[oldIndex].line - lineOffset + 1)
            guard position < newComments.count else { throw SnippetFormatError.commentChanged(line: line) }
            let newIndex = newComments[position]
            let was = old[oldIndex], now = new[newIndex]
            let wasMagic = isMagicComment(was.text), isMagic = isMagicComment(now.text)
            guard normalizedComment(was.text) == normalizedComment(now.text) else {
                throw wasMagic ? SnippetFormatError.magicComment(line: line, comment: was.text) : SnippetFormatError.commentChanged(line: line)
            }
            guard wasMagic || isMagic else { continue }
            let moved = wasMagic != isMagic
                || anchor(before: oldIndex, in: old) != anchor(before: newIndex, in: new)
                || (was.kind == .blockComment && nextCode(after: oldIndex, in: old)?.text == ")" && nextCode(after: newIndex, in: new)?.text != ")")
                || (was.kind == .lineComment && startsLine(oldIndex, in: old) != startsLine(newIndex, in: new))
            if moved { throw SnippetFormatError.magicComment(line: line, comment: was.text) }
        }
        if newComments.count != oldComments.count {
            let extra = newComments.count > oldComments.count ? new[newComments[oldComments.count]].line : (old.last?.line ?? 0)
            throw SnippetFormatError.commentChanged(line: max(1, extra - lineOffset + 1))
        }
    }

    /// The last word or literal before a token (strings by kind: the formatter may requote them).
    private static func anchor(before index: Int, in tokens: [PHPToken]) -> String? {
        var cursor = index - 1
        while cursor >= 0 {
            let token = tokens[cursor]
            if token.kind == .string { return "\u{0}string" }
            if token.kind == .word { return token.text.lowercased() }
            if token.kind == .openTag || token.kind == .closeTag || token.kind == .inlineHTML { return nil }
            cursor -= 1
        }
        return nil
    }

    private static func nextCode(after index: Int, in tokens: [PHPToken]) -> PHPToken? {
        tokens[(index + 1)...].first { !$0.isComment }
    }

    /// Whether no code comes before the token on its line.
    private static func startsLine(_ index: Int, in tokens: [PHPToken]) -> Bool {
        guard let previous = tokens[..<index].last(where: { !$0.isComment }) else { return true }
        return !previous.isCode || previous.endLine < tokens[index].line
    }
}

/// Set once by the watchdog when it stops a formatter that took too long.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// How Format Code (#36) changes the editor: one replacement of the part that differs (so the
/// lines around it, their inline values, and the scroll position stay), and where the caret goes.
/// Offsets are UTF-16, like NSString's.
public struct FormattingEdit: Equatable, Sendable {
    /// The range of the old text to replace.
    public var location: Int
    public var length: Int
    public var replacement: String
    /// The caret in the new text.
    public var caret: Int

    public init(old: String, new: String, caret oldCaret: Int) {
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        // Never split a surrogate pair.
        if prefix > 0, UTF16.isLeadSurrogate(a[prefix - 1]) { prefix -= 1 }
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        if suffix > 0, UTF16.isTrailSurrogate(a[a.count - suffix]) { suffix -= 1 }
        location = prefix
        length = a.count - prefix - suffix
        let inserted = Array(b[prefix..<(b.count - suffix)])
        replacement = String(decoding: inserted, as: UTF16.self)
        let caret = min(max(oldCaret, 0), a.count)
        if caret <= prefix {
            self.caret = caret
        } else if caret >= a.count - suffix {
            self.caret = caret - a.count + b.count
        } else {
            // Inside the change: after as many non-blank characters as came before it. A caret
            // right before a character stays right before it, even when formatting puts blanks
            // or a line break in front of it (`{|echo` becomes `{` and an indented `|echo`).
            let changed = a[prefix..<caret]
            let count = changed.reduce(0) { $0 + (Self.isBlank($1) ? 0 : 1) }
            let touchesNext = !Self.isBlank(a[caret])
            var offset = 0, seen = 0
            while offset < inserted.count, seen < count {
                if !Self.isBlank(inserted[offset]) { seen += 1 }
                offset += 1
            }
            if touchesNext {
                while offset < inserted.count, Self.isBlank(inserted[offset]) { offset += 1 }
            }
            self.caret = prefix + offset
        }
    }

    private static func isBlank(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 || unit == 10 || unit == 13 }
}
