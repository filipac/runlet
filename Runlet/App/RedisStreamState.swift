import Foundation
import Observation
import RunletCore

/// One memory-only card per run (#203). Output/AI consumers see summaryText, never its rows.
@Observable
final class RedisStreamState: Equatable {
    let info: RedisStreamInfo
    var buffer = RedisStreamBuffer()
    var expanded: Int?
    init(_ info: RedisStreamInfo) {
        self.info = info
    }
    static func == (lhs: RedisStreamState, rhs: RedisStreamState) -> Bool {
        lhs === rhs
    }
    var summaryText: String {
        buffer.historyText(command: info.command, connection: info.connection)
    }
    var endNote: String? {
        guard let end = buffer.end else { return nil }
        switch end.reason {
        case .idle:
            return "Ended after 10 minutes without a message."
        case .total:
            return "Ended at the stream’s total time limit (30 minutes by default)."
        case .stopped:
            return "Stopped. The connection is closed."
        case .closed, .error:
            return end.message ?? "The connection closed."
        }
    }
}
