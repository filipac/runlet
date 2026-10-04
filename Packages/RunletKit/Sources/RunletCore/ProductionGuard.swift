import Foundation

/// What runs code on a target and may need a production confirmation (N14).
public enum GuardedAction: Sendable, Equatable {
    /// A snippet run (Run or Run Selection): the only action the grace covers.
    case run
    /// Listing project commands, which boots the application.
    case listCommands
    /// A project command (on the target, or a host command for it on this Mac).
    case command
    /// A shell on the target's server (or in its container there): what is typed runs there.
    case shell
    /// The target's own REPL (Tinker, PsySH, `php -a`): every line typed runs there, with no
    /// further confirmation, so it always asks and never grants or uses the grace.
    case repl
    /// An SQL tab's statement (#35). It always asks on production, never uses the grace, and
    /// the confirmation shows the statement with a warning when it can write.
    case sql
    case mongodb
    /// Loading App Info (#19), which boots the application to read its details.
    case appInfo
    /// Loading an SQL tab's schema for completion (#128): boots the application and reads its
    /// table and column names.
    case sqlSchema
    /// Show Definition in the schema explorer (#148): reads one table's or view's definition
    /// from the catalog, the way Load Schema reads names; it asks on production like Load Schema.
    case sqlDefinition
    /// The Database pane's Server section (#150): reads the server's version, sizes, or
    /// sessions from its catalog and status. It asks on production before each read, and its
    /// refresh interval is never available there. Cancel Query and Kill Session always ask, on
    /// every connection, with their own confirmation.
    case sqlServer
    /// Explain Statement in an SQL tab (#147): the plan only, or Explain Analyze, which runs
    /// the statement. Always asks on production, like `sql`.
    case sqlExplain(analyze: Bool)
    /// A Redis tab's command, or Run All's commands (#190). Always asks on production, never
    /// uses the grace; the confirmation shows the commands (passwords as •••) with a warning
    /// when they can write.
    case redis
    /// The key browser's reads (#190): a SCAN page, a key's value, a key's memory usage.
    case redisKeys
    /// The Redis server panel (#190): INFO and CLIENT LIST. Kill Client always asks, on every
    /// connection, with its own confirmation.
    case redisServer
}

/// When production targets ask before running code. Every guarded action on a production
/// target asks, except snippet runs within a grace the user granted ("Don't ask again for
/// 10 minutes"). The grace lives in memory only: it resets on relaunch and when the target's
/// settings change (`revoke`). Project commands, listings, shells, REPLs, and App Info always ask.
public struct ProductionGrace: Sendable, Equatable {
    public static let interval: TimeInterval = 10 * 60
    /// How many lines of what will run a confirmation shows.
    public static let previewLines = 12

    /// Grace end per target (`TargetRef.stableKey`).
    public private(set) var until: [String: Date] = [:]

    public init() {}

    public mutating func needsConfirmation(_ action: GuardedAction, on target: TargetRef, environment: TargetEnvironment, now: Date = Date()) -> Bool {
        guard environment == .production else { return false }
        guard action == .run else { return true }
        guard let end = until[target.stableKey] else { return true }
        if end > now { return false }
        until[target.stableKey] = nil
        return true
    }

    /// "Don't ask again for 10 minutes" for snippet runs on `target`.
    public mutating func grant(_ target: TargetRef, now: Date = Date()) {
        until[target.stableKey] = now.addingTimeInterval(Self.interval)
    }

    public mutating func revoke(_ target: TargetRef) {
        until[target.stableKey] = nil
    }

    /// The first `limit` lines of what will run, and its total line count.
    public static func preview(of text: String, limit: Int = previewLines) -> (text: String, lineCount: Int) {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        return (lines.prefix(limit).joined(separator: "\n"), lines.count)
    }
}
