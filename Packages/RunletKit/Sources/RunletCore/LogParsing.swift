import Foundation

// MARK: - Log viewer (#20): levels, entries, and parsing

/// A PSR-3 / Monolog level. The raw values are Monolog's numbers, so a JSON log's numeric
/// `level` maps directly and the order is the severity order.
public enum LogLevel: Int, Sendable, Codable, CaseIterable, Comparable, Hashable {
    case debug = 100
    case info = 200
    case notice = 250
    case warning = 300
    case error = 400
    case critical = 500
    case alert = 550
    case emergency = 600

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// A level name as loggers write it, in any case: Monolog's (`DEBUG` … `EMERGENCY`) and
    /// the usual aliases (`WARN`, `ERR`, `FATAL`, `TRACE`, `CRIT`, `EMERG`, `INFORMATION`).
    public init?(name: String) {
        switch name.lowercased() {
        case "debug", "trace", "dbg": self = .debug
        case "info", "information", "informational": self = .info
        case "notice": self = .notice
        case "warning", "warn": self = .warning
        case "error", "err": self = .error
        case "critical", "crit", "fatal": self = .critical
        case "alert": self = .alert
        case "emergency", "emerg", "panic": self = .emergency
        default: return nil
        }
    }

    /// Monolog's number (100 … 600); a number between two levels takes the lower one.
    public init?(monolog value: Int) {
        guard value >= Self.debug.rawValue else { return nil }
        self = Self.allCases.last { $0.rawValue <= value } ?? .debug
    }

    /// "Debug", "Emergency".
    public var title: String {
        switch self {
        case .debug: "Debug"
        case .info: "Info"
        case .notice: "Notice"
        case .warning: "Warning"
        case .error: "Error"
        case .critical: "Critical"
        case .alert: "Alert"
        case .emergency: "Emergency"
        }
    }

    /// "DEBUG", as Monolog writes it.
    public var label: String { title.uppercased() }
}

/// One stack frame or file location found in a log entry: `#3 /app/User.php(42): save()`,
/// `at /app/User.php:42`, `/app/User.php on line 42`, or a snippet line (`eval()'d code(5)`).
public struct LogFrame: Sendable, Equatable, Hashable {
    /// The path as the logging process saw it (a container's or server's path for Docker and
    /// SSH targets). For a snippet frame, the runner's pseudo file.
    public var path: String
    public var line: Int?
    /// What was called there, for a `#n` trace line.
    public var function: String?
    /// A line of Runlet's snippet (`… : eval()'d code(5)`): the snippet's own line number.
    public var snippetLine: Int?
    /// Where in the text line the location sits (UTF-16 offsets), for a link.
    public var range: Range<Int>

    public init(path: String, line: Int?, function: String? = nil, snippetLine: Int? = nil, range: Range<Int>) {
        self.path = path
        self.line = line
        self.function = function
        self.snippetLine = snippetLine
        self.range = range
    }

    /// "User.php:42".
    public var shortLabel: String {
        if let snippetLine { return "snippet line \(snippetLine)" }
        return (path as NSString).lastPathComponent + (line.map { ":\($0)" } ?? "")
    }
}

/// One entry of a log: a header line and the lines that belong to it (a stack trace, a
/// multi-line message, Laravel's `[stacktrace]` inside the context).
public struct LogEntry: Sendable, Equatable, Identifiable {
    public enum Format: String, Sendable, Equatable {
        /// Monolog's line format: `[date] channel.LEVEL: message {context} [extra]`.
        case monolog
        /// Monolog's JSON formatter (or another JSON-lines logger): one object per line.
        case json
        /// PHP's own `error_log` format (WordPress `debug.log`): `[04-Oct-2026 10:00:00 UTC] PHP Warning: …`.
        case phpError
        /// Anything else, one entry per line (plus indented or `#n` lines after it).
        case plain
    }

    /// Increasing in the order entries were read; stable while the entry is kept.
    public var id: Int
    public var format: Format
    /// The time the entry carries, when it could be read.
    public var timestamp: Date?
    /// The time as written (`2026-10-04 10:22:33`).
    public var timestampText: String?
    /// Whether the written time named its zone; times without one are read in the time zone
    /// the parser was given (this Mac's by default).
    public var timestampHasZone: Bool
    public var channel: String?
    public var level: LogLevel?
    /// The message: the header's text before the context, or the JSON object's message.
    public var message: String
    /// The context as written (Monolog's JSON, Laravel's multi-line exception), or the JSON
    /// object's `context` as compact JSON with sorted keys; nil when empty.
    public var context: String?
    /// Monolog's `extra`, the same way.
    public var extra: String?
    /// The first line as read.
    public var header: String
    /// The lines that belong to the entry after its header.
    public var lines: [String]
    /// Lines (and bytes) of the entry left out to keep memory bounded.
    public var omittedLines: Int
    /// Where the header line starts in the file (local files only).
    public var offset: UInt64?
    /// When Runlet read it while following (nil for the first read of a file).
    public var receivedAt: Date?

    public init(id: Int, format: Format, timestamp: Date? = nil, timestampText: String? = nil, timestampHasZone: Bool = false, channel: String? = nil, level: LogLevel? = nil, message: String, context: String? = nil, extra: String? = nil, header: String, lines: [String] = [], omittedLines: Int = 0, offset: UInt64? = nil, receivedAt: Date? = nil) {
        self.id = id
        self.format = format
        self.timestamp = timestamp
        self.timestampText = timestampText
        self.timestampHasZone = timestampHasZone
        self.channel = channel
        self.level = level
        self.message = message
        self.context = context
        self.extra = extra
        self.header = header
        self.lines = lines
        self.omittedLines = omittedLines
        self.offset = offset
        self.receivedAt = receivedAt
    }

    /// The whole entry as read: the header and its lines.
    public var text: String {
        lines.isEmpty ? header : ([header] + lines).joined(separator: "\n")
    }

    /// The entry has more than its header: a trace, a multi-line message or context.
    public var isMultiline: Bool { !lines.isEmpty || omittedLines > 0 }

    /// The message's first line, for the collapsed row.
    public var summary: String {
        let first = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? message
        return first.isEmpty ? header : first
    }

    /// Every stack frame and file location in the entry, in order, once each.
    public var frames: [LogFrame] {
        var seen = Set<String>()
        var result: [LogFrame] = []
        for line in [header] + lines {
            for frame in LogFrames.find(in: line) where seen.insert("\(frame.path):\(frame.line ?? 0):\(frame.snippetLine ?? 0)").inserted {
                result.append(frame)
            }
        }
        return result
    }

    /// The text Copy Entry puts on the pasteboard: the entry exactly as it was in the log.
    public var copyText: String {
        omittedLines > 0 ? text + "\n… \(omittedLines) more line\(omittedLines == 1 ? "" : "s") not kept" : text
    }
}

// MARK: - Line classification

/// Reads one line of a log: a new entry's header (Monolog, JSON, PHP's error log) or a line
/// that continues the previous entry. Pure; used by `LogBuffer`.
public enum LogLineParser {
    /// `[2026-10-04 10:22:33] local.ERROR: message …` and Monolog's default
    /// `[2026-10-04T10:22:33.123456+00:00] app.INFO: …`.
    static let monologHeader = try! NSRegularExpression(pattern: #"^\[(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2}(?:[.,]\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)\] ([^\s\[\]]+?)\.([A-Za-z]+): ?(.*)$"#)
    /// `[04-Oct-2026 10:22:33 UTC] PHP Warning:  …` (PHP's `error_log`, WordPress `debug.log`).
    static let phpErrorHeader = try! NSRegularExpression(pattern: #"^\[(\d{2}-[A-Za-z]{3}-\d{4} \d{2}:\d{2}:\d{2})(?: ([A-Za-z0-9_/+\-]+))?\] (.*)$"#)
    /// `PHP Fatal error:  Uncaught …`, `PHP Warning:  …` inside a PHP error log line.
    static let phpErrorKind = try! NSRegularExpression(pattern: #"^(?:PHP )?(Fatal error|Parse error|Recoverable fatal error|Catchable fatal error|Core error|Compile error|Warning|Core warning|Compile warning|Notice|Deprecated|Strict Standards|User error|User warning|User notice|User deprecated):\s*(.*)$"#, options: [.caseInsensitive])
    /// A level word near the start of a plain line (`WARNING: [pool www] …`, `level=error`).
    static let plainLevel = try! NSRegularExpression(pattern: #"(?:^|[\s\[(|])(?:level=)?(DEBUG|INFO|NOTICE|WARNING|WARN|ERROR|ERR|CRITICAL|CRIT|ALERT|EMERGENCY|FATAL)(?=[\]):\s|]|$)"#)

    /// What a line is.
    public enum Kind: Equatable, Sendable {
        /// A new entry (its header line parsed; `lines` empty).
        case header(LogEntry)
        /// A line that may belong to the previous entry: indented, a `#n` trace line,
        /// `Stack trace:`, Laravel's `[stacktrace]` and `"}` lines.
        case continuation
        /// A line with nothing recognisable: a plain entry unless the previous entry takes
        /// every following line (Monolog and PHP error entries do).
        case plain
    }

    /// Classifies `line` (no trailing newline). Headers come back as entries with id 0.
    public static func classify(_ line: String, timeZone: TimeZone = .current) -> Kind {
        if line.first == "[" {
            if let entry = monolog(line, timeZone: timeZone) { return .header(entry) }
            if let entry = phpError(line) { return .header(entry) }
        }
        if line.first == "{", let entry = json(line, timeZone: timeZone) { return .header(entry) }
        if looksLikeContinuation(line) { return .continuation }
        return .plain
    }

    /// Indented lines, `#12 /path(3): …`, `Stack trace:`, `[stacktrace]`, `[previous
    /// exception]`, `"}`, `Next …`, `thrown in`, `Caused by`.
    public static func looksLikeContinuation(_ line: String) -> Bool {
        guard let first = line.first else { return true }
        if first == " " || first == "\t" { return true }
        if first == "#", line.dropFirst().first?.isNumber == true { return true }
        for prefix in ["Stack trace:", "[stacktrace]", "[previous exception]", "\"}", "\"]", "}", "Next ", "Caused by", "thrown in"] where line.hasPrefix(prefix) {
            return true
        }
        return false
    }

    /// A plain line as an entry (with a level when one is written near its start).
    public static func plain(_ line: String) -> LogEntry {
        var level: LogLevel?
        let ns = line as NSString
        let window = NSRange(location: 0, length: min(ns.length, 80))
        if let match = plainLevel.firstMatch(in: line, range: window) {
            level = LogLevel(name: ns.substring(with: match.range(at: 1)))
        }
        return LogEntry(id: 0, format: .plain, level: level, message: line, header: line)
    }

    static func monolog(_ line: String, timeZone: TimeZone) -> LogEntry? {
        let ns = line as NSString
        guard let match = monologHeader.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              let level = LogLevel(name: ns.substring(with: match.range(at: 3))) else { return nil }
        let stamp = ns.substring(with: match.range(at: 1))
        let parsed = LogTimestamps.iso(stamp, defaultZone: timeZone)
        let rest = ns.substring(with: match.range(at: 4))
        var entry = LogEntry(id: 0, format: .monolog, timestamp: parsed?.date, timestampText: stamp, timestampHasZone: parsed?.hasZone ?? false,
                             channel: ns.substring(with: match.range(at: 2)), level: level, message: rest, header: line)
        LogMonologParts.split(&entry)
        return entry
    }

    static func phpError(_ line: String) -> LogEntry? {
        let ns = line as NSString
        guard let match = phpErrorHeader.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let stamp = ns.substring(with: match.range(at: 1))
        let zone = match.range(at: 2).location == NSNotFound ? nil : ns.substring(with: match.range(at: 2))
        let rest = ns.substring(with: match.range(at: 3))
        var level: LogLevel?
        let restNS = rest as NSString
        if let kind = phpErrorKind.firstMatch(in: rest, range: NSRange(location: 0, length: restNS.length)) {
            level = phpLevel(restNS.substring(with: kind.range(at: 1)))
        }
        let date = LogTimestamps.phpErrorLog(stamp, zone: zone)
        return LogEntry(id: 0, format: .phpError, timestamp: date, timestampText: zone.map { "\(stamp) \($0)" } ?? stamp, timestampHasZone: date != nil && zone != nil,
                        level: level, message: rest, header: line)
    }

    /// How Monolog's ErrorHandler files PHP's error kinds.
    static func phpLevel(_ kind: String) -> LogLevel {
        switch kind.lowercased() {
        case "fatal error", "parse error", "recoverable fatal error", "catchable fatal error", "core error", "compile error", "user error": .critical
        case "warning", "core warning", "compile warning", "user warning": .warning
        default: .notice
        }
    }

    static func json(_ line: String, timeZone: TimeZone) -> LogEntry? {
        guard line.last == "}", let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any] else { return nil }
        let messageKey = ["message", "msg", "text"].first { object[$0] is String }
        let levelValue = object["level_name"] ?? object["level"] ?? object["severity"] ?? object["levelname"]
        // A JSON object without a message or level isn't a log entry (a pretty-printed context line).
        guard messageKey != nil || levelValue != nil else { return nil }
        var level: LogLevel?
        if let name = levelValue as? String { level = LogLevel(name: name) }
        if let number = levelValue as? NSNumber { level = LogLevel(monolog: number.intValue) }
        if level == nil, let number = object["level"] as? NSNumber { level = LogLevel(monolog: number.intValue) }
        var stamp: String?
        var date: Date?
        var hasZone = false
        for key in ["datetime", "@timestamp", "timestamp", "time", "ts"] {
            if let text = object[key] as? String {
                stamp = text
                if let parsed = LogTimestamps.iso(text, defaultZone: timeZone) {
                    date = parsed.date
                    hasZone = parsed.hasZone
                }
                break
            }
            if let number = object[key] as? NSNumber {
                var seconds = number.doubleValue
                if seconds > 100_000_000_000 { seconds /= 1000 }
                date = Date(timeIntervalSince1970: seconds)
                stamp = LogTimestamps.display(date!)
                hasZone = true
                break
            }
        }
        let channel = ["channel", "logger", "channel_name"].lazy.compactMap { object[$0] as? String }.first
        let message = messageKey.flatMap { object[$0] as? String } ?? ""
        return LogEntry(id: 0, format: .json, timestamp: date, timestampText: stamp, timestampHasZone: hasZone, channel: channel, level: level,
                        message: message, context: compactJSON(object["context"]), extra: compactJSON(object["extra"]), header: line)
    }

    /// Compact JSON with sorted keys for a context or extra value (one line, like Monolog's line
    /// format; the viewer indents it when the entry opens); nil for nothing or an empty one.
    static func compactJSON(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let dictionary = value as? [String: Any], dictionary.isEmpty { return nil }
        if let array = value as? [Any], array.isEmpty { return nil }
        if let string = value as? String { return string.isEmpty ? nil : string }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "\(value)"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Monolog message, context, and extra

/// Splits a Monolog line entry into message, context, and extra. Monolog writes
/// `message {context} [extra]`; Laravel's context carries an exception whose stack trace spans
/// the following lines, so the split looks at the whole entry. A message that itself holds
/// braces stays whole: the context is the leftmost bracketed value that, with an optional
/// second one, ends the entry.
enum LogMonologParts {
    /// Only this much of an entry is searched for its context.
    static let scanLimit = 64 * 1024

    static func split(_ entry: inout LogEntry) {
        let rest = restOfHeader(entry)
        let full = entry.lines.isEmpty ? rest : rest + "\n" + entry.lines.joined(separator: "\n")
        let utf16 = Array(full.utf16)
        guard utf16.count <= scanLimit else {
            entry.message = rest
            entry.context = nil
            entry.extra = nil
            return
        }
        var index = 0
        while index < utf16.count {
            let unit = utf16[index]
            // A candidate: `{` or `[` after a space (or at the very start of the text).
            if unit == 0x7B || unit == 0x5B, index == 0 || utf16[index - 1] == 0x20 {
                if let (contextEnd, extraRange) = trailingValues(utf16, from: index) {
                    let message = String(utf16CodeUnits: Array(utf16[..<index]), count: index).trimmingCharacters(in: .whitespaces)
                    let context = String(utf16CodeUnits: Array(utf16[index..<contextEnd]), count: contextEnd - index)
                    entry.message = message
                    entry.context = isEmptyValue(context) ? nil : context
                    if let extraRange {
                        let extra = String(utf16CodeUnits: Array(utf16[extraRange]), count: extraRange.count)
                        entry.extra = isEmptyValue(extra) ? nil : extra
                    } else {
                        entry.extra = nil
                    }
                    return
                }
            }
            index += 1
        }
        entry.message = full
        entry.context = nil
        entry.extra = nil
    }

    /// The header's text after `channel.LEVEL: `.
    static func restOfHeader(_ entry: LogEntry) -> String {
        let ns = entry.header as NSString
        guard let match = LogLineParser.monologHeader.firstMatch(in: entry.header, range: NSRange(location: 0, length: ns.length)) else { return entry.header }
        return ns.substring(with: match.range(at: 4))
    }

    static func isEmptyValue(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "[]" || trimmed == "{}" || trimmed.isEmpty
    }

    /// From `start` (a `{` or `[`): one balanced value, optionally whitespace and a second
    /// one, then only whitespace to the end. Returns where the first ends and the second's range.
    static func trailingValues(_ text: [UInt16], from start: Int) -> (Int, Range<Int>?)? {
        guard let firstEnd = balancedEnd(text, from: start) else { return nil }
        var index = firstEnd
        while index < text.count, isSpace(text[index]) { index += 1 }
        if index == text.count { return (firstEnd, nil) }
        guard text[index] == 0x7B || text[index] == 0x5B, let secondEnd = balancedEnd(text, from: index) else { return nil }
        var tail = secondEnd
        while tail < text.count, isSpace(text[tail]) { tail += 1 }
        return tail == text.count ? (firstEnd, index..<secondEnd) : nil
    }

    static func isSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x0A || unit == 0x0D || unit == 0x09 }

    /// The index after the bracket that closes the one at `start`, skipping strings (raw
    /// newlines inside them allowed: Laravel writes its stack trace that way); nil if it never closes.
    static func balancedEnd(_ text: [UInt16], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.count {
            let unit = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if unit == 0x5C {
                    escaped = true
                } else if unit == 0x22 {
                    inString = false
                }
            } else {
                switch unit {
                case 0x22: inString = true
                case 0x7B, 0x5B: depth += 1
                case 0x7D, 0x5D:
                    depth -= 1
                    if depth == 0 { return index + 1 }
                    if depth < 0 { return nil }
                default: break
                }
            }
            index += 1
        }
        return nil
    }
}

// MARK: - Frames

/// Finds stack frames and file locations in a log line.
public enum LogFrames {
    /// `#3 /app/User.php(42): App\User->save()` (PHP's trace format; also inside Laravel's
    /// context) and `#3 Standard input code(120) : eval()'d code(5): …` (a snippet line).
    static let traceLine = try! NSRegularExpression(pattern: #"^\s*#\d+ (.+?)\((\d+)\)(?:: (.*))?$"#)
    /// `/app/User.php:42`, `/app/User.php(42)`, `/app/User.php on line 42`.
    static let location = try! NSRegularExpression(pattern: #"(/[^\s"'(),:;\[\]{}<>|]+\.(?:php|phtml|inc))(?::(\d+)|\((\d+)\)| on line (\d+))"#)
    /// `eval()'d code(5)` or `eval()'d code:5` after the runner's own file.
    static let evalLine = try! NSRegularExpression(pattern: #"eval\(\)'d code(?:\((\d+)\)|:(\d+)| on line (\d+))"#)

    public static func find(in line: String) -> [LogFrame] {
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var frames: [LogFrame] = []
        if let match = traceLine.firstMatch(in: line, range: whole) {
            let pathRange = match.range(at: 1)
            let path = ns.substring(with: pathRange)
            let number = Int(ns.substring(with: match.range(at: 2)))
            let function = match.range(at: 3).location == NSNotFound ? nil : ns.substring(with: match.range(at: 3))
            if path.contains("eval()'d code") {
                frames.append(LogFrame(path: path, line: number, function: function, snippetLine: number, range: pathRange.location..<(match.range(at: 2).upperBound + 1)))
                return frames
            }
            if path.hasPrefix("/") {
                frames.append(LogFrame(path: path, line: number, function: function, range: pathRange.location..<(match.range(at: 2).upperBound + 1)))
                return frames
            }
        }
        if let match = evalLine.firstMatch(in: line, range: whole) {
            let number = [1, 2, 3].lazy.compactMap { index -> Int? in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : Int(ns.substring(with: range))
            }.first
            frames.append(LogFrame(path: "eval()'d code", line: number, snippetLine: number, range: match.range.location..<match.range.upperBound))
        }
        for match in location.matches(in: line, range: whole) {
            let path = ns.substring(with: match.range(at: 1))
            let number = [2, 3, 4].lazy.compactMap { index -> Int? in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : Int(ns.substring(with: range))
            }.first
            frames.append(LogFrame(path: path, line: number, range: match.range.location..<match.range.upperBound))
        }
        return frames
    }
}

// MARK: - Timestamps

/// Reads the times logs write. Pure; no `DateFormatter` in the hot path.
public enum LogTimestamps {
    static let isoPattern = try! NSRegularExpression(pattern: #"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?(Z|[+-]\d{2}:?\d{2})?$"#)
    static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

    /// `2026-10-04 10:22:33`, `2026-10-04T10:22:33.123456+00:00`, `…Z`, `…+0200`. Without a
    /// zone the time is read in `defaultZone`.
    public static func iso(_ text: String, defaultZone: TimeZone = .current) -> (date: Date, hasZone: Bool)? {
        let ns = text as NSString
        guard let match = isoPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func int(_ index: Int) -> Int? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : Int(ns.substring(with: range))
        }
        var components = DateComponents()
        components.year = int(1)
        components.month = int(2)
        components.day = int(3)
        components.hour = int(4)
        components.minute = int(5)
        components.second = int(6) ?? 0
        var zone = defaultZone
        var hasZone = false
        let zoneRange = match.range(at: 8)
        if zoneRange.location != NSNotFound {
            let zoneText = ns.substring(with: zoneRange)
            hasZone = true
            if zoneText == "Z" {
                zone = TimeZone(secondsFromGMT: 0)!
            } else {
                let sign = zoneText.hasPrefix("-") ? -1 : 1
                let digits = zoneText.dropFirst().filter(\.isNumber)
                let hours = Int(digits.prefix(2)) ?? 0
                let minutes = Int(digits.dropFirst(2)) ?? 0
                zone = TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60)) ?? defaultZone
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard var date = calendar.date(from: components) else { return nil }
        let fractionRange = match.range(at: 7)
        if fractionRange.location != NSNotFound, let fraction = Double("0." + ns.substring(with: fractionRange)) {
            date += fraction
        }
        return (date, hasZone)
    }

    /// PHP's error log: `04-Oct-2026 10:22:33` and its zone (`UTC`, `Europe/Bucharest`).
    /// Without a zone PHP wrote the server's local time, which Runlet can't know: nil.
    public static func phpErrorLog(_ text: String, zone: String?) -> Date? {
        guard let zone, let timeZone = TimeZone(identifier: zone) ?? TimeZone(abbreviation: zone) else { return nil }
        let parts = text.split(separator: " ")
        guard parts.count == 2 else { return nil }
        let day = parts[0].split(separator: "-")
        let time = parts[1].split(separator: ":")
        guard day.count == 3, time.count == 3, let month = months[day[1].lowercased()] else { return nil }
        var components = DateComponents()
        components.day = Int(day[0])
        components.month = month
        components.year = Int(day[2])
        components.hour = Int(time[0])
        components.minute = Int(time[1])
        components.second = Int(time[2])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: components)
    }

    /// `2026-10-04 10:22:33` in `zone` (this Mac's by default).
    public static func display(_ date: Date, zone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
