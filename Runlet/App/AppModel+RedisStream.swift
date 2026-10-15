import RunletCore

extension AppModel {
    /// Pause only the visible rows; resuming also works after the run ends (#203).
    func toggleRedisStreamPause(_ tab: TabModel) {
        guard let state = tab.redisStream else { return }
        if state.buffer.isPaused {
            state.buffer.resume()
        } else if state.buffer.isActive {
            state.buffer.pause()
        }
    }

    /// Clear retained payloads without ending the stream or resetting totals (#203).
    func clearRedisStream(_ tab: TabModel) {
        tab.redisStream?.buffer.clear()
        tab.redisStream?.expanded = nil
    }
}
