#if DEBUG
import Foundation
import RunletCore

/// Fixture-only live stream checks (#203). No restored tab ever starts a stream.
@MainActor
enum RedisStreamDebugSteps {
    static var totalSeconds: Int?
    static var waited = 0.0
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        guard name.hasPrefix("redis-stream-"), let tab = model.selectedTab else { return false }
        switch name {
        case "redis-stream-start":
            DebugRunTiming.start(tab)
            model.runRedis(tab, selectionOnly: false)
        case "redis-stream-pause": model.toggleRedisStreamPause(tab)
        case "redis-stream-resume": tab.redisStream?.buffer.resume()
        case "redis-stream-clear": model.clearRedisStream(tab)
        case "redis-stream-stop": model.stop(tab)
        case "redis-stream-expand": tab.redisStream?.expanded = tab.redisStream?.buffer.visible.first?.id
        case "redis-stream-limit": totalSeconds = Int(argument)
        case "redis-stream-state":
            let cards = tab.output.filter {
                if case .redisStream = $0 { return true }
                return false
            }.count
            RedisDebugSteps.log("redis-stream-controls: cards=\(cards) · state=\(tab.redisStream != nil)")
            RedisDebugSteps.log("redis-stream-note: \(tab.sqlRun?.redisNote ?? "none")")
            RedisDebugSteps.log("redis-stream-state: \(tab.redisStream?.summaryText ?? "none") · visible=\(tab.redisStream?.buffer.visible.count ?? 0) · paused=\(tab.redisStream?.buffer.isPaused ?? false)")
        case "redis-stream-publish":
            let parts = argument.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let channel = parts.first ?? "events"
            let count = max(1, min(2000, parts.count > 1 ? Int(parts[1]) ?? 1 : 1))
            let payload = parts.count > 2 ? parts[2] : "{\"event\":\"order.created\",\"id\":42}"
            let saved = model.sqlConnectionChoice(for: tab).savedConnection
            Task {
                do {
                    let snapshot = try await model.sqlSnapshot(for: tab, saved: saved)
                    defer { model.releaseSQLTunnel(snapshot) }
                    let command = "\(tab.redisStream?.info.kind == .ssubscribe ? "SPUBLISH" : "PUBLISH") \(RedisScript.quoted(channel)) \(RedisScript.quoted(payload))"
                    let parsed = try RedisScript.commandsToRunAll(in: Array(repeating: command, count: count).joined(separator: "\n"), selection: NSRange()).get()
                    let _: RedisReplyInfo = try await model.engine.runRedisPanel(target: snapshot, code: RedisTabRun.code(commands: parsed, connection: tab.sqlConnection, all: true), event: "redis", as: RedisReplyInfo.self, saved: saved)
                } catch { RedisDebugSteps.log("redis-stream-publish failed: \(error)") }
            }
        default: return false
        }
        return true
    }
}
#endif
