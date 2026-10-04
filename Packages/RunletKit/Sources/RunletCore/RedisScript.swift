import Foundation

/// Redis tabs (#190): commands typed one per line, quoted the way redis-cli quotes them. A line
/// whose first character (after spaces) is `#` is a comment. Parsing is byte-based, so
/// `"\xff"` is one byte and binary values survive; the app sends each command's arguments,
/// never the line's text, to the runner.
public enum RedisScript {
    /// One command of a Redis tab.
    public struct Command: Sendable, Equatable {
        /// Its arguments as bytes.
        public var arguments: [[UInt8]]
        /// The line's text, without surrounding whitespace.
        public var text: String
        /// Its UTF-16 range in the tab's text.
        public var range: NSRange
        /// 1-based.
        public var line: Int

        public init(arguments: [[UInt8]], text: String, range: NSRange, line: Int) {
            self.arguments = arguments
            self.text = text
            self.range = range
            self.line = line
        }

        /// The command's name, upper case (`GET`); empty for a line without arguments.
        public var name: String { arguments.first.map { String(decoding: $0, as: UTF8.self).uppercased() } ?? "" }

        /// Each argument as text (bytes that aren't UTF-8 show as replacement characters).
        public var strings: [String] { arguments.map { String(decoding: $0, as: UTF8.self) } }

        /// As an SQL tab's statement (text, range, first line), for what Redis tabs share with
        /// SQL tabs (the run's info, the Connection Manager). The text is redacted (`displayText`).
        public var statement: SQLScript.Statement {
            SQLScript.Statement(text: displayText, range: range, startLine: line)
        }

        /// The line as typed, or rebuilt with `•••` for passwords (`AUTH`, `HELLO … AUTH`,
        /// `MIGRATE … AUTH`, `ACL SETUSER … >secret`, `CONFIG SET requirepass …`): what Run
        /// History, the output, confirmations, and logs show.
        public var displayText: String {
            let secrets = RedisScript.secretArguments(strings)
            guard !secrets.isEmpty else { return text }
            return arguments.enumerated().map { index, argument in
                secrets.contains(index) ? "•••" : RedisScript.quoted(argument)
            }.joined(separator: " ")
        }
    }

    public enum ParseError: Error, Sendable, Equatable, CustomStringConvertible {
        /// A quote that is never closed.
        case unbalancedQuotes
        /// A closing quote followed by something other than a space (`"a"b`).
        case quoteNotFollowedBySpace

        public var description: String {
            switch self {
            case .unbalancedQuotes: "A quote isn't closed."
            case .quoteNotFollowedBySpace: "A closing quote must be followed by a space or the end of the line."
            }
        }
    }

    /// A line of a Redis tab that holds a command (not blank, not a comment): parsed, or why not.
    public struct Line: Sendable, Equatable {
        public var text: String
        public var range: NSRange
        public var line: Int
        public var parsed: Result<[[UInt8]], ParseError>

        public var command: Command? {
            guard case .success(let arguments) = parsed, !arguments.isEmpty else { return nil }
            return Command(arguments: arguments, text: text, range: range, line: line)
        }
    }

    /// The lines of `text` that hold a command, in order. `firstLine` numbers the first line
    /// (a selection's lines keep their numbers in the tab), `offset` moves the ranges.
    public static func lines(in text: String, firstLine: Int = 1, offset: Int = 0) -> [Line] {
        let string = text as NSString
        var result: [Line] = []
        var number = firstLine
        var start = 0
        let length = string.length
        while start <= length {
            var lineEnd = 0, contentsEnd = 0
            string.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            let raw = string.substring(with: NSRange(location: start, length: contentsEnd - start))
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                let leading = (raw as NSString).range(of: trimmed).location
                let range = NSRange(location: offset + start + (leading == NSNotFound ? 0 : leading), length: (trimmed as NSString).length)
                let parsed = parse(trimmed)
                // A line of only spaces between quotes ("") parses to an empty argument, which is fine;
                // a line that parses to nothing isn't a command.
                if case .success(let arguments) = parsed, arguments.isEmpty {
                    // nothing
                } else {
                    result.append(Line(text: trimmed, range: range, line: number, parsed: parsed))
                }
            }
            if lineEnd == start || lineEnd >= length {
                break
            }
            start = lineEnd
            number += 1
        }
        return result
    }

    /// redis-cli's argument splitting (`sdssplitargs`): arguments are separated by spaces;
    /// `"…"` understands `\n`, `\r`, `\t`, `\b`, `\a`, `\xHH`, and `\` before any other
    /// character; `'…'` only `\'`. A closing quote must be followed by a space.
    public static func parse(_ line: String) -> Result<[[UInt8]], ParseError> {
        let bytes = Array(line.utf8)
        let end = bytes.count
        var p = 0
        var arguments: [[UInt8]] = []
        func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 11 || c == 12 || c == 0 }
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 65...70: c - 55
            case 97...102: c - 87
            default: nil
            }
        }
        while true {
            while p < end, isSpace(bytes[p]) { p += 1 }
            if p >= end { return .success(arguments) }
            var inDouble = false, inSingle = false, done = false
            var current: [UInt8] = []
            while !done {
                if inDouble {
                    if p >= end { return .failure(.unbalancedQuotes) }
                    let c = bytes[p]
                    if c == 92, p + 3 < end, bytes[p + 1] == 120, let high = hex(bytes[p + 2]), let low = hex(bytes[p + 3]) {
                        current.append(high << 4 | low)
                        p += 3
                    } else if c == 92, p + 1 < end {
                        p += 1
                        switch bytes[p] {
                        case 110: current.append(10)
                        case 114: current.append(13)
                        case 116: current.append(9)
                        case 98: current.append(8)
                        case 97: current.append(7)
                        default: current.append(bytes[p])
                        }
                    } else if c == 34 {
                        if p + 1 < end, !isSpace(bytes[p + 1]) { return .failure(.quoteNotFollowedBySpace) }
                        done = true
                    } else {
                        current.append(c)
                    }
                } else if inSingle {
                    if p >= end { return .failure(.unbalancedQuotes) }
                    let c = bytes[p]
                    if c == 92, p + 1 < end, bytes[p + 1] == 39 {
                        p += 1
                        current.append(39)
                    } else if c == 39 {
                        if p + 1 < end, !isSpace(bytes[p + 1]) { return .failure(.quoteNotFollowedBySpace) }
                        done = true
                    } else {
                        current.append(c)
                    }
                } else {
                    if p >= end {
                        done = true
                        break
                    }
                    let c = bytes[p]
                    if isSpace(c) {
                        done = true
                    } else if c == 34 {
                        inDouble = true
                    } else if c == 39 {
                        inSingle = true
                    } else {
                        current.append(c)
                    }
                }
                if p < end { p += 1 }
            }
            arguments.append(current)
        }
    }

    /// An argument as redis-cli would accept it back: bare when it has no spaces, quotes, or
    /// bytes that need escaping; else in double quotes with escapes.
    public static func quoted(_ bytes: [UInt8]) -> String {
        let plain = !bytes.isEmpty && bytes.allSatisfy { $0 > 32 && $0 < 127 && $0 != 34 && $0 != 39 && $0 != 92 }
        if plain { return String(decoding: bytes, as: UTF8.self) }
        if let text = String(bytes: bytes, encoding: .utf8), !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
            return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var result = "\""
        for byte in bytes {
            switch byte {
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 10: result += "\\n"
            case 13: result += "\\r"
            case 9: result += "\\t"
            case 32..<127: result.append(Character(UnicodeScalar(byte)))
            default: result += String(format: "\\x%02x", byte)
            }
        }
        return result + "\""
    }

    /// `quoted` for text (a key from the key browser, …).
    public static func quoted(_ text: String) -> String { quoted(Array(text.utf8)) }

    // MARK: What runs

    /// Why a Redis tab has nothing (or too much) to run.
    public enum ScopeError: Error, Sendable, Equatable, CustomStringConvertible {
        case empty
        case nothingSelected
        case multipleCommands(count: Int)
        case parse(line: Int, ParseError)

        public var title: String {
            switch self {
            case .empty: "No Redis command to run"
            case .nothingSelected: "Nothing selected"
            case .multipleCommands: "Run one command at a time"
            case .parse: "Runlet can't read this command"
            }
        }

        public var description: String {
            switch self {
            case .empty:
                "This tab has no Redis command to run (only blank lines or # comments)."
            case .nothingSelected:
                "Select the command to run, or press Run to run the command at the caret."
            case .multipleCommands(let count):
                "The selection holds \(count) commands. Run runs one: select a single line, or put the caret on one and press Run without a selection. Run All runs them all, in order."
            case .parse(let line, let error):
                "Line \(line): \(error.description) Quote arguments the way redis-cli does: \"a b\" or 'a b', with \\\" inside double quotes."
            }
        }
    }

    /// What Run sends from a Redis tab: with a selection, the one command it holds; without
    /// one, the command on the caret's line, else the next one below, else the last one above.
    public static func commandToRun(in text: String, selection: NSRange, selectionOnly: Bool = false) -> Result<Command, ScopeError> {
        let string = text as NSString
        let location = min(max(0, selection.location), string.length)
        let selection = NSRange(location: location, length: min(max(0, selection.length), string.length - location))
        if selection.length > 0 {
            let found = selectedLines(in: string, selection: selection)
            guard found.count <= 1 else { return .failure(.multipleCommands(count: found.count)) }
            guard let line = found.first else { return .failure(.empty) }
            return command(of: line)
        }
        if selectionOnly { return .failure(.nothingSelected) }
        let all = lines(in: text)
        guard !all.isEmpty else { return .failure(.empty) }
        let caretLine = string.lineRange(for: NSRange(location: location, length: 0))
        if let onLine = all.first(where: { $0.range.location >= caretLine.location && ($0.range.location < NSMaxRange(caretLine) || caretLine.length == 0 && $0.range.location == caretLine.location) }) {
            return command(of: onLine)
        }
        if let next = all.first(where: { $0.range.location >= location }) { return command(of: next) }
        return command(of: all[all.count - 1])
    }

    /// Run All: every command of the selection, or of the tab without one. A line Runlet can't
    /// read refuses the whole run, before anything is sent.
    public static func commandsToRunAll(in text: String, selection: NSRange) -> Result<[Command], ScopeError> {
        let string = text as NSString
        let location = min(max(0, selection.location), string.length)
        let selection = NSRange(location: location, length: min(max(0, selection.length), string.length - location))
        let found = selection.length > 0 ? selectedLines(in: string, selection: selection) : lines(in: text)
        guard !found.isEmpty else { return .failure(.empty) }
        var commands: [Command] = []
        for line in found {
            switch command(of: line) {
            case .success(let command): commands.append(command)
            case .failure(let error): return .failure(error)
            }
        }
        return .success(commands)
    }

    private static func command(of line: Line) -> Result<Command, ScopeError> {
        switch line.parsed {
        case .failure(let error): return .failure(.parse(line: line.line, error))
        case .success: return line.command.map { .success($0) } ?? .failure(.empty)
        }
    }

    private static func selectedLines(in string: NSString, selection: NSRange) -> [Line] {
        let before = string.substring(to: selection.location)
        let firstLine = before.reduce(into: 1) { count, character in if character.isNewline { count += 1 } }
        return lines(in: string.substring(with: selection), firstLine: firstLine, offset: selection.location)
    }

    // MARK: Secrets

    /// Indices of the arguments that are passwords: `AUTH [user] password`, `HELLO … AUTH user
    /// password`, `MIGRATE … AUTH password` / `AUTH2 user password`, `ACL SETUSER name >pw <pw
    /// #hash !hash`, `CONFIG SET requirepass|masterauth value`. They never show in Run
    /// History, the output, confirmations, or logs, and the runner scrubs them from its events.
    public static func secretArguments(_ arguments: [String]) -> Set<Int> {
        guard let first = arguments.first?.uppercased() else { return [] }
        var secrets = Set<Int>()
        let upper = arguments.map { $0.uppercased() }
        switch first {
        case "AUTH":
            if arguments.count >= 2 { secrets.insert(arguments.count - 1) }
        case "HELLO":
            if let index = upper.firstIndex(of: "AUTH"), index + 2 < arguments.count { secrets.insert(index + 2) }
        case "MIGRATE":
            for (index, word) in upper.enumerated() {
                if word == "AUTH", index + 1 < arguments.count { secrets.insert(index + 1) }
                if word == "AUTH2", index + 2 < arguments.count { secrets.insert(index + 2) }
            }
        case "ACL":
            if upper.count > 2, upper[1] == "SETUSER" {
                for index in 3..<arguments.count where [">", "<", "#", "!"].contains(where: { arguments[index].hasPrefix($0) }) {
                    secrets.insert(index)
                }
            }
        case "CONFIG":
            if upper.count > 3, upper[1] == "SET" {
                var index = 2
                while index + 1 < arguments.count {
                    let key = upper[index]
                    if key.contains("PASS") || key.contains("AUTH") || key == "MASTERUSER" { secrets.insert(index + 1) }
                    index += 2
                }
            }
        default:
            break
        }
        return secrets
    }

    /// `text` with the passwords of every command line replaced by `•••` (Run History, the
    /// production confirmation). A line Runlet can't read that starts with a command that takes
    /// a password keeps only that word.
    public static func redacted(_ text: String) -> String {
        var result = text as NSString
        for line in lines(in: text).reversed() {
            let replacement: String
            if let command = line.command {
                let shown = command.displayText
                guard shown != command.text else { continue }
                replacement = shown
            } else if case .failure = line.parsed,
                      let first = line.text.split(separator: " ").first.map({ $0.uppercased() }),
                      ["AUTH", "HELLO", "MIGRATE", "ACL", "CONFIG"].contains(first) {
                replacement = first + " •••"
            } else {
                continue
            }
            result = result.replacingCharacters(in: line.range, with: replacement) as NSString
        }
        return result as String
    }

    // MARK: Highlighting

    public enum TokenKind: Sendable, Equatable {
        /// A command Runlet knows (`GET`), and a container's subcommand (`CONFIG GET`).
        case command
        /// Any other first word of a line.
        case unknownCommand
        /// An option word (`WITHSCORES`, `MATCH`, `EX`, …).
        case option
        case string
        case number
        case comment
        /// Any other argument.
        case argument
    }

    public struct Token: Sendable, Equatable {
        public var range: NSRange
        public var kind: TokenKind
    }

    /// Option words coloured as such.
    static let optionWords: Set<String> = [
        "EX", "PX", "EXAT", "PXAT", "NX", "XX", "GT", "LT", "KEEPTTL", "GET", "WITHSCORES", "WITHSCORE", "MATCH", "COUNT", "TYPE",
        "LIMIT", "BYSCORE", "BYLEX", "REV", "STORE", "STOREDIST", "WITHVALUES", "ASC", "DESC", "ALPHA", "BY", "BLOCK", "STREAMS",
        "MAXLEN", "MINID", "NOMKSTREAM", "LEFT", "RIGHT", "BEFORE", "AFTER", "ASYNC", "SYNC", "WEIGHTS", "AGGREGATE", "SUM",
        "MIN", "MAX", "CH", "INCR", "IDLE", "TIME", "RETRYCOUNT", "FORCE", "JUSTID", "LASTID", "NOMKSTREAM", "WITHCODE",
    ]

    /// Tokens for the editor: per line, the command (and a container's subcommand), quoted
    /// strings, numbers, option words, and `#` comments.
    public static func tokenize(_ string: NSString) -> [Token] {
        let length = string.length
        var buffer = [unichar](repeating: 0, count: length)
        string.getCharacters(&buffer, range: NSRange(location: 0, length: length))
        var tokens: [Token] = []
        var i = 0
        var wordIndex = 0
        var firstWord = ""
        func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 }
        func isNewline(_ c: unichar) -> Bool { c == 10 || c == 13 }
        while i < length {
            let c = buffer[i]
            if isNewline(c) {
                wordIndex = 0
                firstWord = ""
                i += 1
                continue
            }
            if isSpace(c) { i += 1; continue }
            let start = i
            if wordIndex == 0, c == 35 { // # comment line
                while i < length, !isNewline(buffer[i]) { i += 1 }
                tokens.append(Token(range: NSRange(location: start, length: i - start), kind: .comment))
                continue
            }
            if c == 34 || c == 39 {
                i += 1
                while i < length, !isNewline(buffer[i]) {
                    if c == 34, buffer[i] == 92, i + 1 < length, !isNewline(buffer[i + 1]) { i += 2; continue }
                    if c == 39, buffer[i] == 92, i + 1 < length, buffer[i + 1] == 39 { i += 2; continue }
                    if buffer[i] == c { i += 1; break }
                    i += 1
                }
                let kind: TokenKind = wordIndex == 0 ? .unknownCommand : .string
                tokens.append(Token(range: NSRange(location: start, length: i - start), kind: kind))
                wordIndex += 1
                continue
            }
            while i < length, !isSpace(buffer[i]), !isNewline(buffer[i]) { i += 1 }
            let range = NSRange(location: start, length: i - start)
            let word = string.substring(with: range).uppercased()
            let kind: TokenKind
            if wordIndex == 0 {
                firstWord = word
                kind = RedisCommands.isKnown(word) ? .command : .unknownCommand
            } else if wordIndex == 1, RedisCommands.containers.contains(firstWord), RedisCommands.isKnown(firstWord + "|" + word) {
                kind = .command
            } else if Double(word) != nil || word == "+INF" || word == "-INF" {
                kind = .number
            } else if optionWords.contains(word) {
                kind = .option
            } else {
                kind = .argument
            }
            tokens.append(Token(range: range, kind: kind))
            wordIndex += 1
        }
        return tokens
    }
}
