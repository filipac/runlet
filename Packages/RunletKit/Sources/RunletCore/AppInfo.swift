import Foundation

// App Info panels (#19): what the runner's `mode: "panels"` reports about a target's
// application (Laravel's `artisan about`, Symfony, WordPress, PHP, and the driver's own
// `panels()`), bounded and redacted again on this side.

/// One value of an App Info row: text, a number, a flag, nothing, or a short list.
public enum AppInfoValue: Sendable, Hashable, Codable {
    case text(String)
    case integer(Int)
    case number(Double)
    case flag(Bool)
    case list([String])
    case none

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else if let flag = try? container.decode(Bool.self) {
            self = .flag(flag)
        } else if let integer = try? container.decode(Int.self) {
            self = .integer(integer)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let items = try? container.decode([AppInfoValue].self) {
            self = .list(items.map(\.displayText))
        } else {
            // An object: not something the runner sends; shown as a placeholder.
            self = .text("(object)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .integer(let integer): try container.encode(integer)
        case .number(let number): try container.encode(number)
        case .flag(let flag): try container.encode(flag)
        case .list(let items): try container.encode(items)
        case .none: try container.encodeNil()
        }
    }

    /// How the popover shows it: flags as Yes/No, lists comma-separated, nothing as an em dash.
    public var displayText: String {
        switch self {
        case .text(let text): text
        case .integer(let integer): String(integer)
        case .number(let number): number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .flag(let flag): flag ? "Yes" : "No"
        case .list(let items): items.joined(separator: ", ")
        case .none: "—"
        }
    }

    /// What Copy puts on the pasteboard: lists one item per line.
    public var copyText: String {
        if case .list(let items) = self { return items.joined(separator: "\n") }
        return displayText
    }
}

public struct AppInfoRow: Sendable, Hashable, Codable, Identifiable {
    public var key: String
    public var value: AppInfoValue
    /// The value was hidden because it looked like a secret; it can't be copied.
    public var redacted: Bool

    public var id: String { key }

    public init(key: String, value: AppInfoValue, redacted: Bool = false) {
        self.key = key
        self.value = value
        self.redacted = redacted
    }

    enum CodingKeys: String, CodingKey { case key, value, redacted }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        value = try container.decodeIfPresent(AppInfoValue.self, forKey: .value) ?? .none
        redacted = try container.decodeIfPresent(Bool.self, forKey: .redacted) ?? false
    }
}

public struct AppInfoSection: Sendable, Hashable, Identifiable {
    public enum Origin: String, Sendable, Hashable {
        /// Runlet's own: the framework's details and PHP.
        case builtin
        /// The driver's `panels()`.
        case driver
    }

    public var title: String
    public var rows: [AppInfoRow]
    /// Rows the runner or the app left out (bounds).
    public var omittedRows: Int
    public var origin: Origin
    /// The driver that reported it ("Laravel", "AcmeApiDriver").
    public var source: String
    /// Position in the report, so two sections may share a title.
    public var index: Int

    public var id: String { "\(index):\(title)" }

    public init(title: String, rows: [AppInfoRow], omittedRows: Int = 0, origin: Origin = .builtin, source: String = "", index: Int = 0) {
        self.title = title
        self.rows = rows
        self.omittedRows = omittedRows
        self.origin = origin
        self.source = source
        self.index = index
    }
}

/// Bounds the app applies to decoded panels, matching the runner's (`Panels.php`).
public enum AppInfoLimits {
    public static let maxSections = 20
    public static let maxRows = 100
    public static let maxListItems = 50
    public static let maxTitleCharacters = 120
    public static let maxKeyCharacters = 200
    public static let maxValueCharacters = 2000
    public static let maxNotes = 20
}

/// Everything one App Info load returned for a target.
public struct AppInfoReport: Sendable, Equatable {
    public var sections: [AppInfoSection] = []
    /// Bounds, skipped panels, and built-ins Runlet could not read.
    public var notes: [String] = []
    /// Values hidden because they looked like secrets.
    public var redactedCount = 0
    /// Sections left out by the bounds.
    public var omittedSections = 0
    /// The driver's panels() failed (the built-in sections are still there).
    public var driverError: String?
    public var framework: String?
    public var frameworkVersion: String?
    public var driverName: String?
    public var driverFile: String?
    public var phpVersion: String?
    /// The project directory the runner booted in (on the target).
    public var workingDirectory: String?
    public var bootstrapMs: Int?
    /// Bootstrap failures, exit() or fatal errors, timeouts.
    public var errors: [RunErrorInfo] = []
    public var notices: [String] = []
    public var finished: FinishedInfo?
    public var loadedAt = Date()

    public init() {}

    /// True when the application booted and the built-in sections arrived.
    public var hasSections: Bool { !sections.isEmpty }

    /// Adds one `panels` event: bounds and redacts its sections again (the runner already
    /// did; this keeps the app's own promise even for a runner it doesn't know).
    public mutating func add(panelsFrame payload: Data) throws {
        let frame = try JSONDecoder().decode(PanelsFrame.self, from: payload)
        let origin: AppInfoSection.Origin = frame.origin == "driver" ? .driver : .builtin
        let source = frame.source ?? (origin == .driver ? "Driver" : "Runlet")
        for section in frame.sections ?? [] {
            guard sections.count < AppInfoLimits.maxSections else {
                omittedSections += 1
                continue
            }
            var rows: [AppInfoRow] = []
            var omitted = section.omittedRows ?? 0
            for row in section.rows ?? [] {
                guard rows.count < AppInfoLimits.maxRows else {
                    omitted += 1
                    continue
                }
                let bounded = Self.bounded(row)
                let (checked, newlyRedacted) = AppInfoRedaction.redact(bounded)
                if newlyRedacted { redactedCount += 1 }
                rows.append(checked)
            }
            let title = Self.clip(section.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", AppInfoLimits.maxTitleCharacters)
            sections.append(AppInfoSection(title: title.isEmpty ? "Untitled" : title, rows: rows, omittedRows: omitted, origin: origin, source: source, index: sections.count))
        }
        redactedCount += frame.redacted ?? 0
        omittedSections += frame.omittedSections ?? 0
        for note in frame.notes ?? [] where notes.count < AppInfoLimits.maxNotes {
            notes.append(Self.clip(note, 1000))
        }
        if let error = frame.error, !error.isEmpty {
            if origin == .driver { driverError = Self.clip(error, 4000) } else { notes.append(Self.clip(error, 4000)) }
        }
        if origin == .driver, let file = frame.driverFile { driverFile = driverFile ?? file }
    }

    /// The row with its key, text, and list cut to the bounds.
    static func bounded(_ row: AppInfoRow) -> AppInfoRow {
        var row = row
        row.key = clip(row.key, AppInfoLimits.maxKeyCharacters)
        switch row.value {
        case .text(let text):
            row.value = .text(clip(text, AppInfoLimits.maxValueCharacters))
        case .list(let items):
            // One more item is allowed: the runner's own "… n more".
            guard items.count > AppInfoLimits.maxListItems + 1 else {
                row.value = .list(items.map { clip($0, AppInfoLimits.maxValueCharacters) })
                break
            }
            var kept = items.prefix(AppInfoLimits.maxListItems).map { clip($0, AppInfoLimits.maxValueCharacters) }
            kept.append("… \(items.count - AppInfoLimits.maxListItems) more")
            row.value = .list(kept)
        default:
            break
        }
        return row
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    private struct PanelsFrame: Decodable {
        struct Section: Decodable {
            var title: String?
            var rows: [AppInfoRow]?
            var omittedRows: Int?
        }

        var origin: String?
        var source: String?
        var sections: [Section]?
        var redacted: Int?
        var omittedSections: Int?
        var notes: [String]?
        var error: String?
        var driverFile: String?
    }
}

/// The App Info redaction rule, shared with the runner (`AppInfo::isSecretKey` and
/// `AppInfo::redactValue` in Resources/Runner/src/Panels.php; keep them in step):
///
/// - **By key.** A row whose key names a secret shows `••••••` instead of its value. The key
///   is split into words at case changes and punctuation ("DB_PASSWORD", "stripeSecret", "API
///   token"); it names a secret when a word is password, passwd, pwd, pass, passphrase,
///   secret, token, key, apikey, salt, credential, signature, cookie, dsn, or nonce (or their
///   plurals), or when the words run together contain password, passwd, secret, token,
///   apikey, privatekey, accesskey, or credential ("APIKEY", "dbpassword").
/// - **By value.** Anywhere in a value: the password in `scheme://user:password@host`
///   (the user stays), `password=…`/`token: …`/`api_key=…` pairs in connection and query
///   strings, Laravel `base64:` keys, JWTs, private key blocks, `Bearer`/`Basic` credentials,
///   and well-known token formats (Stripe `sk_live_…`, GitHub `ghp_…`/`github_pat_…`, GitLab
///   `glpat-…`, Slack `xox…-`, AWS `AKIA…`, Google `AIza…`).
public enum AppInfoRedaction {
    public static let mask = "••••••"

    static let secretWords: Set<String> = [
        "password", "passwords", "passwd", "pwd", "pass", "passphrase", "secret", "secrets", "token", "tokens",
        "key", "keys", "apikey", "salt", "salts", "credential", "credentials", "signature", "cookie", "cookies", "dsn", "nonce",
    ]
    static let secretParts = ["password", "passwd", "secret", "token", "apikey", "privatekey", "accesskey", "credential"]

    /// Whether `key` names a secret (see the rule above).
    public static func isSecretKey(_ key: String) -> Bool {
        let spaced = caseBoundary.stringByReplacingMatches(in: key, range: NSRange(key.startIndex..., in: key), withTemplate: "$1 $2")
        let words = spaced.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init)
        if words.contains(where: secretWords.contains) { return true }
        let joined = words.joined()
        return secretParts.contains { joined.contains($0) }
    }

    /// `value` with its secret-looking parts masked (lists item by item).
    public static func redactValue(_ value: AppInfoValue) -> AppInfoValue {
        switch value {
        case .text(let text): .text(redactText(text))
        case .list(let items): .list(items.map(redactText))
        default: value
        }
    }

    /// The row with its value hidden when its key names a secret, or its secret-looking parts
    /// masked; `true` when this changed it.
    public static func redact(_ row: AppInfoRow) -> (AppInfoRow, Bool) {
        if row.redacted { return (row, false) }
        var row = row
        if isSecretKey(row.key) {
            guard row.value != .text(mask) else { return (row, false) }
            row.value = .text(mask)
            row.redacted = true
            return (row, true)
        }
        let masked = redactValue(row.value)
        guard masked != row.value else { return (row, false) }
        row.value = masked
        row.redacted = true
        return (row, true)
    }

    public static func redactText(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for (pattern, template) in valuePatterns {
            result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }

    private static let caseBoundary = try! NSRegularExpression(pattern: "([a-z0-9])([A-Z])")

    private static let valuePatterns: [(NSRegularExpression, String)] = {
        let mask = NSRegularExpression.escapedTemplate(for: Self.mask)
        let rules: [(String, NSRegularExpression.Options, String)] = [
            (#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(-----END [A-Z0-9 ]*PRIVATE KEY-----|$)"#, [.dotMatchesLineSeparators], mask),
            (#"^base64:[A-Za-z0-9+/]{16,}={0,2}$"#, [], mask),
            (#"([a-z][a-z0-9+.\-]*://[^:/?#@\s]*):[^@/?#\s]+@"#, [.caseInsensitive], "$1:" + mask + "@"),
            (#"\b((?:[a-z0-9]+[_\-.])*(?:password|passwd|pwd|pass|secret|token|api[_\-]?key|access[_\-]?key|private[_\-]?key|auth[_\-]?key|signature|sig))(\s*[=:]\s*)("[^"]*"|'[^']*'|[^;&,\s]+)"#, [.caseInsensitive], "$1$2" + mask),
            (#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#, [], mask),
            (#"\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{10,}"#, [], mask),
            (#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, [], mask),
            (#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, [], mask),
            (#"\bglpat-[A-Za-z0-9_\-]{16,}"#, [], mask),
            (#"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#, [], mask),
            (#"\bAKIA[0-9A-Z]{16}\b"#, [], mask),
            (#"\bAIza[0-9A-Za-z_\-]{35}\b"#, [], mask),
            (#"\b(Bearer|Basic)\s+[A-Za-z0-9._~+/\-]{16,}=*"#, [], "$1 " + mask),
        ]
        return rules.map { (try! NSRegularExpression(pattern: $0.0, options: $0.1), $0.2) }
    }()
}

/// What opening App Info does (a click on the framework chip, Show App Info, or Refresh).
public enum AppInfoOpenAction: Sendable, Equatable {
    /// Show what is cached (or the load in progress): nothing runs.
    case show
    /// Load now: boots the application in a fresh runner.
    case load
    /// Ask first (production), then load.
    case confirmThenLoad
}

public enum AppInfoPolicy {
    /// Opening shows a cached result or a load in progress without running anything; it loads
    /// only when nothing is cached for the target, or on Refresh. A production target asks
    /// before every load (never covered by the snippet-run grace).
    public static func onOpen(hasResult: Bool, isLoading: Bool, refresh: Bool, environment: TargetEnvironment) -> AppInfoOpenAction {
        if isLoading { return .show }
        if hasResult && !refresh { return .show }
        return environment == .production ? .confirmThenLoad : .load
    }

    /// "just now", "5 s ago", "3 min ago", "2 h ago", "4 days ago": the age of a cached result.
    public static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<5: return "just now"
        case ..<60: return "\(seconds) s ago"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86400: return "\(seconds / 3600) h ago"
        default:
            let days = seconds / 86400
            return days == 1 ? "1 day ago" : "\(days) days ago"
        }
    }
}
