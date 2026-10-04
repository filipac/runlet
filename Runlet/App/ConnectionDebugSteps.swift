#if DEBUG
import AppKit
import RunletCore

/// RUNLET_DEBUG_STEPS for the Connection Manager (#180), for screenshots and scripted checks
/// with scratch data only (see `DebugSteps`):
/// `connections` (opens the window, as the status bar item does; `connections:off` closes it) ·
/// `connection-close:<n>` or `connection-close:<text>` (the nth row, 1-based in the window's
/// order, or the first row not closing yet whose title, destination, or id starts with the text:
/// its Close, which may ask first) · `connection-confirm:yes|no` (answers that question) · `connections-state`
/// (prints the count per kind, every row, the question, and the last Close) ·
/// `connections-wait:<kind>=<n>[:<seconds>]` (in `RunletApp`: holds the steps until that many rows
/// of a kind (`ssh`, `tunnel`, `database`, `phpRun`, `aiClient`, or `all`) are listed, at most 30 s).
@MainActor
enum ConnectionDebugSteps {
    /// Seconds `connections-wait` has held the steps.
    static var waited: Double = 0

    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        switch name {
        case "connections":
            if argument == "off" {
                NSApp.windows.first { $0.title == "Connections" }?.close()
            } else {
                model.showConnectionManager()
            }
        case "connection-close":
            let list = model.activeConnections
            let item: ActiveConnection?
            if let index = Int(argument) {
                item = list.items.indices.contains(index - 1) ? list.items[index - 1] : nil
            } else {
                // A row already closing is skipped, so the same text closes the next one.
                item = list.items.first { !$0.isClosing && ($0.title.hasPrefix(argument) || $0.destination.hasPrefix(argument) || $0.id.hasPrefix(argument)) }
            }
            guard let item else {
                log("connection-close: no row \(argument)")
                return true
            }
            model.requestCloseConnection(item.id)
            log("connection-close \(item.kind.rawValue) \(item.title): \(model.connectionManager.lastEvent ?? "-")")
        case "connection-confirm":
            model.answerCloseConnection(argument == "yes")
        case "connections-state":
            log(state(model))
        default:
            return false
        }
        return true
    }

    /// Whether `connections-wait:<kind>=<n>` is satisfied.
    static func reached(_ argument: String, model: AppModel) -> Bool {
        let spec = argument.split(separator: ":").first.map(String.init) ?? argument
        let parts = spec.split(separator: "=").map(String.init)
        guard parts.count == 2, let wanted = Int(parts[1]) else { return true }
        let list = model.activeConnections
        let count = parts[0] == "all" ? list.count : ActiveConnectionKind(rawValue: parts[0]).map(list.count(of:)) ?? 0
        return count == wanted
    }

    static func state(_ model: AppModel) -> String {
        let list = model.activeConnections
        let counts = ActiveConnectionKind.allCases.map { "\($0.rawValue)=\(list.count(of: $0))" }.joined(separator: " ")
        let rows = list.items.map { item in
            [item.kind.rawValue, item.title, item.destination, item.owner ?? "-", item.environment.rawValue,
             item.via.isEmpty ? "-" : "via " + item.via.map { $0.split(separator: ":").first.map(String.init) ?? $0 }.joined(separator: "+"),
             item.details.joined(separator: "; "), item.isClosing ? "closing" : "open",
             list.usage(of: item.id).map { "used by " + $0 } ?? ""].joined(separator: " | ")
        }
        let pending = model.connectionManager.pendingClose.map { "\($0.confirmation.title) — \($0.confirmation.message) [\($0.confirmation.button)]" } ?? "none"
        return "connections: \(list.count) (\(counts)) rows=\(rows) question=\(pending) last=\(model.connectionManager.lastEvent ?? "-") tooltip=\(list.tooltip.replacingOccurrences(of: "\n", with: " / "))"
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}
#endif
