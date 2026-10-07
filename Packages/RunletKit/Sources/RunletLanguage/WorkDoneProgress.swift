import Foundation

/// One `$/progress` operation of the language server (#336): PHPantom's indexing ("PHPantom:
/// Indexing", "PHPantom: Full index") or a long request ("Find References").
public struct LanguageServerProgress: Sendable, Equatable {
    public var token: String
    public var title: String
    public var message: String?
    /// 0–100, or nil when the server doesn't say.
    public var percentage: Int?

    public init(token: String, title: String, message: String? = nil, percentage: Int? = nil) {
        self.token = token
        self.title = title
        self.message = message
        self.percentage = percentage
    }

    public var isIndexing: Bool { title.localizedCaseInsensitiveContains("index") }

    /// The status bar's text: "Indexing… 42%", or "Find References…" without a percentage.
    public var statusText: String {
        var name = title
        if name.hasPrefix("PHPantom: ") { name = String(name.dropFirst("PHPantom: ".count)) }
        if isIndexing { name = "Indexing" }
        return name + "…" + (percentage.map { " \($0)%" } ?? "")
    }
}

/// What the language server is doing besides answering requests (#336): its progress, and the
/// files it asked Runlet to watch.
public struct LanguageServerActivity: Sendable, Equatable {
    /// The operation in progress, the latest one begun when several run.
    public var progress: LanguageServerProgress?
    /// The last operation that ended, with its closing message ("Indexed 5,678 classes").
    public var lastProgress: LanguageServerProgress?
    /// The globs the server registered; empty while Runlet isn't watching files for it.
    public var watchedPatterns: [String] = []

    public init(progress: LanguageServerProgress? = nil, lastProgress: LanguageServerProgress? = nil, watchedPatterns: [String] = []) {
        self.progress = progress
        self.lastProgress = lastProgress
        self.watchedPatterns = watchedPatterns
    }

    public var isWatchingFiles: Bool { !watchedPatterns.isEmpty }
}

/// Follows `$/progress` notifications (`begin`, `report`, `end`) by token.
public struct WorkDoneProgressTracker: Sendable, Equatable {
    private var active: [String: LanguageServerProgress] = [:]
    private var order: [String] = []
    public private(set) var last: LanguageServerProgress?

    public init() {}

    /// The operation to show: the latest one begun that hasn't ended.
    public var current: LanguageServerProgress? { order.last.flatMap { active[$0] } }

    /// Applies `$/progress` params. Returns whether anything changed. Reports and ends for a
    /// token that never began (or already ended) are ignored.
    @discardableResult
    public mutating func apply(_ params: JSONValue) -> Bool {
        guard let token = params["token"].flatMap(Self.key), let value = params["value"] else { return false }
        let percentage = value["percentage"]?.intValue.map { min(100, max(0, $0)) }
        switch value["kind"]?.stringValue {
        case "begin":
            active[token] = LanguageServerProgress(token: token, title: value["title"]?.stringValue ?? "", message: value["message"]?.stringValue, percentage: percentage)
            order.removeAll { $0 == token }
            order.append(token)
            return true
        case "report":
            guard var progress = active[token] else { return false }
            let before = progress
            if let message = value["message"]?.stringValue { progress.message = message }
            if let percentage { progress.percentage = percentage }
            active[token] = progress
            return progress != before
        case "end":
            guard var progress = active.removeValue(forKey: token) else { return false }
            order.removeAll { $0 == token }
            if let message = value["message"]?.stringValue { progress.message = message }
            last = progress
            return true
        default:
            return false
        }
    }

    /// The server stopped: nothing is in progress any more. The last ended operation stays.
    public mutating func reset() {
        active = [:]
        order = []
    }

    /// A progress token is a string or a number.
    static func key(_ token: JSONValue) -> String? {
        if let string = token.stringValue { return string }
        if let number = token.intValue { return "#\(number)" }
        return nil
    }
}

/// What the status bar's PHPantom item says (#336), from the server's state, its activity, and
/// the workspace's limitations.
public struct LanguageStatusSummary: Sendable, Equatable {
    public var title: String
    public var symbol: String
    /// The tooltip: the progress message while indexing.
    public var help: String
    public var isFailure: Bool
    /// Whether an operation is in progress (starting, indexing, restarting).
    public var isBusy: Bool

    public init(state: LanguageServerState, activity: LanguageServerActivity, limitations: [String]) {
        let notes = limitations.joined(separator: "\n")
        isFailure = false
        isBusy = false
        switch state {
        case .ready:
            if let progress = activity.progress {
                title = progress.statusText
                symbol = "arrow.triangle.2.circlepath"
                help = progress.message.map { "\(progress.title): \($0)" } ?? progress.title
                isBusy = true
            } else if notes.isEmpty {
                title = "PHPantom"
                symbol = "checkmark.seal"
                help = "Language server ready"
            } else {
                title = "PHPantom (limited)"
                symbol = "exclamationmark.circle"
                help = notes
            }
        case .starting:
            title = "Indexing…"
            symbol = "arrow.triangle.2.circlepath"
            help = "PHPantom is starting"
            isBusy = true
        case .restarting(let attempt):
            title = "Restarting (\(attempt))"
            symbol = "arrow.clockwise"
            help = "PHPantom stopped unexpectedly and is restarting"
            isBusy = true
        case .failed(let message):
            title = "PHPantom failed"
            symbol = "xmark.octagon"
            help = message
            isFailure = true
        case .stopped:
            title = "No completion"
            symbol = "minus.circle"
            help = notes.isEmpty ? "Language service is off for this tab" : notes
        }
    }

    /// The popover's state line: "Ready", "Indexing… 42%", "Starting…", "Failed", …
    public static func stateLine(state: LanguageServerState, activity: LanguageServerActivity) -> String {
        switch state {
        case .ready(let version):
            if let progress = activity.progress { return progress.statusText }
            return "Ready" + (version.map { " · version \($0)" } ?? "")
        case .starting: return "Starting…"
        case .restarting(let attempt): return "Restarting… (attempt \(attempt))"
        case .failed: return "Failed"
        case .stopped: return "Off"
        }
    }

    /// The watched globs as the popover lists them: `*.php · composer.json · composer.lock`.
    public static func watchedFiles(_ patterns: [String]) -> String {
        patterns.map { $0.hasPrefix("**/") ? String($0.dropFirst(3)) : $0 }.joined(separator: " · ")
    }
}
