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
}

/// When production targets ask before running code. Every guarded action on a production
/// target asks, except snippet runs within a grace the user granted ("Don't ask again for
/// 10 minutes"). The grace lives in memory only: it resets on relaunch and when the target's
/// settings change (`revoke`). Project commands and listings always ask.
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
