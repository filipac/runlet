import RunletCore
import SwiftUI

/// Live Redis output (#203): one bounded card, observed independently of the output pane.
struct RedisStreamCard: View {
    @Environment(AppModel.self) private var model
    let state: RedisStreamState
    let tab: TabModel
    @State private var atBottom = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(state.buffer.status).font(.caption.bold())
                    .foregroundStyle(state.buffer.isActive ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.info.command).font(.system(.callout, design: .monospaced).weight(.semibold))
                    Text("\(state.info.connection) · database \(state.info.db)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(state.buffer.isPaused ? "Resume" : "Pause") { model.toggleRedisStreamPause(tab) }
                    .disabled(!state.buffer.isActive && !state.buffer.isPaused).accessibilityIdentifier("redis-stream-pause")
                Button("Clear") { model.clearRedisStream(tab) }
                    .accessibilityIdentifier("redis-stream-clear")
                Button("Stop") { model.stop(tab) }
                    .disabled(!state.buffer.isActive).accessibilityIdentifier("redis-stream-stop")
            }
            Text("\(state.buffer.received.formatted()) messages · \(state.buffer.skipped.formatted()) skipped · \(state.buffer.duration, specifier: "%.1f") s")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if state.buffer.isPaused {
                Text("Paused · \(state.buffer.newWhilePaused.formatted()) new").font(.caption).foregroundStyle(.orange)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(state.buffer.visible) { message in
                            row(message).id(message.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 280)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 24
                } action: { _, bottom in atBottom = bottom }
                .onChange(of: state.buffer.visible.last?.id) { _, last in
                    if atBottom, !state.buffer.isPaused, let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            if state.buffer.visible.isEmpty { Text(state.buffer.isActive ? "Waiting for messages…" : "No messages kept.").font(.caption).foregroundStyle(.secondary) }
            if let note = state.buffer.droppedNote { Text(note).font(.caption).foregroundStyle(.orange) }
            if let note = state.endNote { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("redis-stream-card")
    }

    private func row(_ message: RedisStreamMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { state.expanded = state.expanded == message.id ? nil : message.id } label: {
                HStack(spacing: 8) {
                    Image(systemName: state.expanded == message.id ? "chevron.down" : "chevron.right").frame(width: 10)
                    Text(Date(timeIntervalSince1970: message.time), format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).secondFraction(.fractional(3)))
                        .foregroundStyle(.secondary)
                    if let channel = message.channel { Text(channel).foregroundStyle(.tint) }
                    if let pattern = message.pattern { Text(pattern).foregroundStyle(.secondary) }
                    if let db = message.db { Text("db \(db)").foregroundStyle(.secondary) }
                    if let client = message.client { Text(client).foregroundStyle(.secondary) }
                    Text(message.text).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(.caption, design: .monospaced))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("redis-stream-row")
            if state.expanded == message.id {
                ValueContentView(node: valueNode(message), label: nil, expansion: model.settings.valueExpansion, preview: nil, initialMode: StringViewers(node: valueNode(message))?.jsonTree != nil ? .json : nil)
                    .padding(.leading, 18)
                if message.omitted > 0 { Text("\(message.omitted.formatted()) payload bytes omitted.").font(.caption).foregroundStyle(.secondary) }
            }
            Divider().opacity(0.4)
        }
        .padding(.vertical, 4)
    }

    private func valueNode(_ message: RedisStreamMessage) -> ValueNode {
        var id = 0
        return RedisValue.string(message.text).valueNode(nextId: &id)
    }
}
