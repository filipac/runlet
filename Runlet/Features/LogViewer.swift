import AppKit
import RunletCore
import SwiftUI

/// View ▸ Logs (#20): a target's logs next to the scratchpad. Files on this Mac (a local
/// project, the sandbox, a Docker profile's local folder) are read from their end and followed
/// at once; a file in a container or on a server, and a container's output, are read only after
/// Follow. Entries are parsed (Monolog lines and JSON, PHP's error log, plain lines), filtered
/// by level, search, and the last run, and their stack frames open in the editor. Nothing here
/// writes to a log, and log lines never leave this window: they aren't saved, sent to AI
/// clients, or written to Runlet's own logs.
struct LogViewerView: View {
    @Environment(AppModel.self) private var model
    @State private var showsOtherPath = false
    @State private var otherPath = ""
    @State private var atBottom = true

    var body: some View {
        let store = model.logViewer
        VStack(spacing: 0) {
            toolbar(store)
            Divider()
            HSplitView {
                sidebar(store)
                    .frame(minWidth: 180, idealWidth: 230, maxWidth: 280)
                VStack(spacing: 0) {
                    filterBar(store)
                    Divider()
                    content(store)
                }
                .frame(minWidth: 420)
            }
            Divider()
            footer(store)
        }
        .frame(minWidth: 680, minHeight: 360)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            store.isWindowOpen = true
            store.wasOpened = true
            if store.session == nil, store.target == nil { model.showLogs() }
        }
        .onDisappear { model.logViewerClosed() }
        .onChange(of: store.showsLastRun) { model.refreshLastRun() }
        .accessibilityIdentifier("log-viewer")
    }

    // MARK: Toolbar

    private func toolbar(_ store: LogViewerStore) -> some View {
        HStack(spacing: 8) {
            Picker("Target", selection: Binding(get: { store.target ?? .sandbox }, set: { model.selectLogTarget($0) })) {
                ForEach(model.logTargets, id: \.self) { target in
                    Label(model.targetLabel(target), systemImage: model.targetSymbol(target)).tag(target)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .accessibilityIdentifier("log-target")
            if let target = store.target { EnvironmentBadge(environment: model.library.environment(for: target), compact: true) }
            Spacer(minLength: 8)
            Button {
                model.reloadLog()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .help("Read the file's end again")
            .disabled(store.session?.source.isRemote ?? true)
            followButton(store.session)
            Button {
                model.toggleLogPause()
            } label: {
                Label(store.session?.isPaused == true ? "Resume" : "Pause", systemImage: store.session?.isPaused == true ? "play" : "pause")
            }
            .help("Pause keeps the list still while new entries keep arriving; Resume shows them.")
            .disabled(store.session == nil)
            .accessibilityIdentifier("log-pause")
            Button {
                model.clearLog()
            } label: {
                Label("Clear", systemImage: "clear")
            }
            .help("Empty the list. The log itself isn't changed.")
            .disabled(store.session == nil)
            .accessibilityIdentifier("log-clear")
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func followButton(_ session: LogSession?) -> some View {
        if let session, session.isFollowing || session.state == .starting {
            Button {
                model.stopFollowingLog()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .help(session.source.isRemote ? "Stop following: \(session.source.commandName) ends in the container or on the server too." : "Stop watching the file.")
            .accessibilityIdentifier("log-stop")
        } else {
            Button {
                model.followLog()
            } label: {
                Label("Follow", systemImage: "play.fill")
            }
            .help(session?.source.isRemote == true ? "Read new lines as they're written, with \(session?.source.commandName ?? "tail -F"). Stops when you click Stop or close this window." : "Watch the file for new lines.")
            .disabled(session == nil)
            .accessibilityIdentifier("log-follow")
        }
    }

    /// The target's logs: files on this Mac, then files in the container or on the server and
    /// the container's output (read only after Follow), with Find Logs and Other Path….
    private func sidebar(_ store: LogViewerStore) -> some View {
        let sources = store.target.map(model.logSources(for:)) ?? []
        let selected = store.session?.source.id
        return VStack(spacing: 0) {
            List {
                ForEach(LogSource.Group.allCases, id: \.self) { group in
                    let members = sources.filter { $0.group == group }
                    if !members.isEmpty {
                        Section(group.rawValue) {
                            ForEach(members) { source in
                                SourceRow(source: source, isSelected: source.id == selected)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.openLogSource(source) }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("log-sources")
            Divider()
            HStack(spacing: 6) {
                if let target = store.target, target.hasRemoteLogs {
                    Button {
                        model.findRemoteLogs()
                    } label: {
                        if store.finding.contains(target.stableKey) {
                            ProgressView().controlSize(.mini)
                        } else {
                            Label("Find Logs", systemImage: "magnifyingglass")
                        }
                    }
                    .help("List the log files in the container or on the server (names only, with find). Asks before connecting, and on production.")
                    .accessibilityIdentifier("log-find")
                }
                Button("Other Path…") { showsOtherPath = true }
                    .accessibilityIdentifier("log-other-path")
                Spacer()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(8)
        }
        .popover(isPresented: $showsOtherPath) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Other log file").font(.headline)
                Text(store.target.map { model.logHostFolder(for: $0) != nil } == true
                     ? "A path relative to the project folder on this Mac, or an absolute one."
                     : "An absolute path in the container or on the server, or one relative to the profile's directory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("storage/logs/worker.log", text: $otherPath)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                    .onSubmit(addOtherPath)
                HStack {
                    Spacer()
                    Button("Cancel") { showsOtherPath = false }
                    Button("Open", action: addOtherPath).keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
    }

    private func addOtherPath() {
        model.addOtherLogPath(otherPath)
        otherPath = ""
        showsOtherPath = false
    }

    // MARK: Filters

    private func filterBar(_ store: LogViewerStore) -> some View {
        @Bindable var store = store
        return HStack(spacing: 10) {
            Picker("Level", selection: $store.minimumLevel) {
                Text("All Levels").tag(LogLevel?.none)
                Divider()
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text(level == .debug ? "Debug and Up" : "\(level.title) and Up").tag(LogLevel?.some(level))
                }
            }
            .frame(width: 170)
            .help("Show this level and the ones above it. All Levels also shows lines without a level.")
            .accessibilityIdentifier("log-level")
            TextField("Search", text: $store.search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .accessibilityIdentifier("log-search")
            Toggle(isOn: $store.showsLastRun) {
                Label("Last Run", systemImage: "clock.arrow.circlepath")
            }
            .toggleStyle(.button)
            .help("Logs written by the last run on this target")
            .accessibilityIdentifier("log-last-run")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: List

    @ViewBuilder
    private func content(_ store: LogViewerStore) -> some View {
        if let session = store.session {
            let entries = model.visibleLogEntries(session)
            if entries.isEmpty {
                emptyState(session, store: store)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(entries) { entry in
                                LogEntryRow(entry: entry, session: session)
                                    .id(entry.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
                    } action: { _, isAtBottom in
                        atBottom = isAtBottom
                    }
                    .onChange(of: entries.last?.id) { _, last in
                        guard let last, session.isFollowing, !session.isPaused, atBottom, !store.showsLastRun else { return }
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                    .onAppear { if let last = entries.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
                    .accessibilityIdentifier("log-entries")
                }
            }
        } else {
            ContentUnavailableView {
                Label("No Logs Found", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text(noSourceText(store.target))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func noSourceText(_ target: TargetRef?) -> String {
        switch target {
        case .ssh?: "Use Find Logs to list the server's log files, or Other Path… for one Runlet doesn't know."
        case .docker?: "Use Find Logs to list the container's log files, or Other Path…."
        default: "Runlet looks in storage/logs (Laravel, nested folders too), var/log (Symfony), wp-content/debug.log (WordPress), and the driver's logPaths(). Use Other Path… for another file."
        }
    }

    @ViewBuilder
    private func emptyState(_ session: LogSession, store: LogViewerStore) -> some View {
        Group {
            switch session.state {
            case .loading, .starting:
                ProgressView(session.state == .starting ? "Starting \(session.source.commandName)…" : "Reading…")
            case .failed(let message):
                ContentUnavailableView("Can't Read the Log", systemImage: "exclamationmark.triangle", description: Text(message))
            default:
                if session.source.isRemote, !session.isFollowing, session.buffer.entries.isEmpty {
                    ContentUnavailableView {
                        Label("Not Following", systemImage: "play.circle")
                    } description: {
                        Text(remoteHint(session))
                    } actions: {
                        Button("Follow") { model.followLog() }
                    }
                } else if store.showsLastRun {
                    ContentUnavailableView("Nothing From the Last Run", systemImage: "clock.arrow.circlepath", description: Text(session.runNote ?? "The last run wrote nothing here."))
                } else if store.filter.isActive {
                    ContentUnavailableView.search(text: store.search)
                } else {
                    ContentUnavailableView("The Log Is Empty", systemImage: "doc.text", description: Text(session.isFollowing ? "New lines appear here as they're written." : "Nothing was read."))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func remoteHint(_ session: LogSession) -> String {
        let place: String
        switch session.source.kind {
        case .containerOutput: place = "the container's output with docker logs --follow --tail 500"
        case .containerFile(let path): place = "\(path) in the container with tail -F"
        case .serverFile(let path): place = "\(path) on the server with tail -F"
        case .hostFile(let path): place = path
        }
        return "Follow reads \(place). Nothing connects or runs until you click it; Stop or closing this window ends it, there too."
    }

    // MARK: Footer

    private func footer(_ store: LogViewerStore) -> some View {
        HStack(spacing: 6) {
            if let session = store.session {
                Circle().fill(statusColor(session)).frame(width: 7, height: 7)
                Text(statusText(session)).lineLimit(1)
                Text("·").foregroundStyle(.tertiary)
                Text(countText(session, store: store)).lineLimit(1).accessibilityIdentifier("log-counts")
                if let note = store.showsLastRun ? session.runNote : session.notices.last {
                    Text("·").foregroundStyle(.tertiary)
                    Text(note).lineLimit(1).truncationMode(.middle).help(note)
                }
            } else {
                Text(store.target.map { "Logs of \(model.targetLabel($0))" } ?? "")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func statusColor(_ session: LogSession) -> Color {
        switch session.state {
        case .following: session.isPaused ? .orange : .green
        case .failed: .red
        case .ended: .orange
        default: .secondary
        }
    }

    private func statusText(_ session: LogSession) -> String {
        switch session.state {
        case .loading: return "Reading…"
        case .starting: return "Starting…"
        case .idle: return session.source.isRemote ? "Not following" : "Not watching"
        case .following(let since):
            let what = session.source.isRemote ? "Following with \(session.source.commandName)" : "Watching the file"
            return (session.isPaused ? "Paused · \(session.newWhilePaused) new · " : "") + "\(what) since \(since.formatted(date: .omitted, time: .shortened))"
        case .ended(let message): return message
        case .failed(let message): return message
        }
    }

    private func countText(_ session: LogSession, store: LogViewerStore) -> String {
        let total = session.buffer.entries.count
        var parts = ["\(total.formatted()) entr\(total == 1 ? "y" : "ies")"]
        if store.filter.isActive || store.showsLastRun {
            parts[0] = "\(model.visibleLogEntries(session).count.formatted()) of " + parts[0]
        }
        if session.buffer.dropped > 0 {
            parts.append("\(session.buffer.dropped.formatted()) older dropped (keeps the last \(session.buffer.capacity.formatted()))")
        }
        if session.skippedHead > 0 {
            parts.append("from the last \(ByteCountFormatter.string(fromByteCount: Int64(LogTail.defaultBytes), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(session.fileSize ?? 0), countStyle: .file))")
        }
        return parts.joined(separator: " · ")
    }
}

/// A log in the sidebar: its path (or "Container output") and what Runlet knows of it.
private struct SourceRow: View {
    let source: LogSource
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(source.isRemote ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.title)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .fontWeight(isSelected ? .semibold : .regular)
                if let detail = source.detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? Color.accentColor.opacity(0.18) : .clear))
        .help(source.path ?? "docker logs --follow --tail 500")
        .accessibilityIdentifier("log-source-row")
    }

    private var symbol: String {
        switch source.kind {
        case .hostFile: "doc.text"
        case .containerFile: "shippingbox"
        case .serverFile: "server.rack"
        case .containerOutput: "text.alignleft"
        }
    }
}

extension TargetRef {
    /// Its logs can be in a container or on a server (Find Logs, Follow).
    var hasRemoteLogs: Bool {
        switch self {
        case .docker, .ssh: true
        case .sandbox, .local: false
        }
    }
}

/// One entry: time, level, channel, and message; a click shows its trace and context, whose
/// file locations are links.
private struct LogEntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: LogEntry
    let session: LogSession
    @State private var showsAll = false
    @State private var hovering = false

    /// Lines shown when an entry opens; Show All shows the rest.
    static let shownLines = 400

    private var expanded: Bool { session.expanded.contains(entry.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: entry.isMultiline || entry.context != nil ? (expanded ? "chevron.down" : "chevron.right") : "circle.fill")
                    .font(.system(size: entry.isMultiline || entry.context != nil ? 9 : 4))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Text(entry.timestampText.map(shortTime) ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .leading)
                    .help(entry.timestampText ?? "No time in this line")
                LevelBadge(level: entry.level)
                if let channel = entry.channel {
                    Text(channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                // The context, dimmed, after the message while the entry is closed.
                Text("\(entry.summary)\(Text(!expanded ? contextPreview : "").foregroundStyle(.secondary))")
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(expanded ? nil : 1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if entry.isMultiline {
                    Text("\(entry.lines.count + entry.omittedLines) line\(entry.lines.count + entry.omittedLines == 1 ? "" : "s")")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
                if hovering {
                    Button {
                        Pasteboard.copy(entry.copyText)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy Entry")
                }
            }
            if expanded { details }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy Entry") { Pasteboard.copy(entry.copyText) }
            Button("Copy Message") { Pasteboard.copy(entry.message) }
            if let context = entry.context { Button("Copy Context") { Pasteboard.copy(context) } }
            let frames = entry.frames
            if !frames.isEmpty {
                Divider()
                ForEach(Array(frames.prefix(8).enumerated()), id: \.offset) { _, frame in
                    Button("Open \(frame.shortLabel)") { model.openLogFrame(frame, target: session.target) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("log-entry")
    }

    /// `  {"batch":42}` for a closed row: the context's first line, shortened.
    private var contextPreview: String {
        guard let context = entry.context else { return "" }
        let first = context.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? context
        return "  " + String(first.prefix(160))
    }

    private var rowBackground: Color {
        switch entry.level {
        case .error?, .critical?, .alert?, .emergency?: Color.red.opacity(expanded ? 0.10 : 0.05)
        case .warning?: Color.orange.opacity(expanded ? 0.09 : 0.04)
        default: expanded ? Color.secondary.opacity(0.07) : .clear
        }
    }

    private func toggle() {
        guard entry.isMultiline || entry.context != nil || entry.summary != entry.message else { return }
        if expanded { session.expanded.remove(entry.id) } else { session.expanded.insert(entry.id) }
    }

    /// `10:22:33` from `2026-10-04 10:22:33` or `2026-10-04T10:22:33.123456+00:00`.
    private func shortTime(_ text: String) -> String {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "T" })
        guard parts.count >= 2 else { return text }
        return String(parts[1].prefix(8))
    }

    @ViewBuilder
    private var details: some View {
        let blocks = detailBlocks
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if let title = block.title {
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                FrameLinkedText(lines: block.lines, target: session.target)
            }
            if entry.omittedLines > 0 {
                Text("\(entry.omittedLines) more line\(entry.omittedLines == 1 ? "" : "s") weren't kept (Runlet keeps \(LogBuffer.maxLinesPerEntry.formatted()) lines per entry).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if hiddenLines > 0 {
                Button("Show All \((hiddenLines + Self.shownLines).formatted()) Lines") { showsAll = true }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(.leading, 18)
        .padding(.vertical, 4)
    }

    private struct Block {
        var title: String?
        var lines: [String]
    }

    /// Monolog and JSON entries: the message, then the context and extra (pretty when they are
    /// JSON). Other entries: their lines as read.
    private var detailBlocks: [Block] {
        var blocks: [Block] = []
        switch entry.format {
        case .monolog, .json:
            // The row shows a one-line message already.
            if entry.message != entry.summary { blocks.append(Block(title: nil, lines: entry.message.components(separatedBy: "\n"))) }
            if let context = entry.context { blocks.append(Block(title: "Context", lines: Self.pretty(context).components(separatedBy: "\n"))) }
            if let extra = entry.extra { blocks.append(Block(title: "Extra", lines: Self.pretty(extra).components(separatedBy: "\n"))) }
        case .phpError, .plain:
            blocks.append(Block(title: nil, lines: [entry.header] + entry.lines))
        }
        guard !showsAll else { return blocks }
        var room = Self.shownLines
        return blocks.compactMap { block in
            guard room > 0 else { return nil }
            defer { room -= block.lines.count }
            return Block(title: block.title, lines: Array(block.lines.prefix(room)))
        }
    }

    private var hiddenLines: Int {
        guard !showsAll else { return 0 }
        var total = entry.message.components(separatedBy: "\n").count
        if entry.format == .phpError || entry.format == .plain { total = entry.lines.count + 1 }
        if let context = entry.context { total += context.components(separatedBy: "\n").count }
        if let extra = entry.extra { total += extra.components(separatedBy: "\n").count }
        return max(0, total - Self.shownLines)
    }

    /// Indented JSON when the text is JSON. Laravel's multi-line exception isn't: it shows as
    /// written, with the JSON string's `\\` and `\/` read back as `\` and `/` (Copy Entry keeps
    /// the text as written).
    static func pretty(_ text: String) -> String {
        guard text.count < 256 * 1024, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              !(object is String),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return text.replacingOccurrences(of: "\\\\", with: "\\").replacingOccurrences(of: "\\/", with: "/")
        }
        return String(decoding: pretty, as: UTF8.self)
    }
}

/// Monospaced lines whose file locations (`/app/User.php(42)`, `at /app/User.php:42`, a
/// snippet's `eval()'d code(5)`) are links: they open in the external editor (or the tab's
/// line for a snippet), through the target's path mapping. A location with no counterpart on
/// this Mac stays text, with the reason as its tooltip.
private struct FrameLinkedText: View {
    @Environment(AppModel.self) private var model
    let lines: [String]
    let target: TargetRef

    var body: some View {
        let (text, frames) = attributed
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "runlet-log-frame", let index = Int(url.host() ?? ""), frames.indices.contains(index) else { return .discarded }
                model.openLogFrame(frames[index], target: target)
                return .handled
            })
    }

    private var attributed: (AttributedString, [LogFrame]) {
        var result = AttributedString()
        var frames: [LogFrame] = []
        for (number, line) in lines.enumerated() {
            var piece = AttributedString(line)
            for frame in LogFrames.find(in: line) {
                let utf16 = line.utf16
                guard frame.range.upperBound <= utf16.count,
                      let lower = String.Index(utf16.index(utf16.startIndex, offsetBy: frame.range.lowerBound), within: line),
                      let upper = String.Index(utf16.index(utf16.startIndex, offsetBy: frame.range.upperBound), within: line),
                      let start = AttributedString.Index(lower, within: piece),
                      let end = AttributedString.Index(upper, within: piece) else { continue }
                switch model.logFrameDestination(frame, target: target) {
                case .unavailable:
                    continue
                case .file, .tabLine:
                    piece[start..<end].link = URL(string: "runlet-log-frame://\(frames.count)")
                    frames.append(frame)
                }
            }
            result += piece
            if number < lines.count - 1 { result += AttributedString("\n") }
        }
        return (result, frames)
    }
}

/// A level as a coloured capsule (`ERROR`), or nothing for a line without one.
struct LevelBadge: View {
    let level: LogLevel?

    var body: some View {
        Text(level?.label ?? "—")
            .font(.caption2.weight(.bold).monospaced())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .frame(minWidth: 62)
            .background(Capsule().fill(color.opacity(level == nil ? 0.08 : 0.18)))
            .foregroundStyle(color)
            .accessibilityLabel(level?.title ?? "No level")
    }

    private var color: Color {
        switch level {
        case .emergency?, .alert?, .critical?, .error?: .red
        case .warning?: .orange
        case .notice?: .teal
        case .info?: .blue
        case .debug?, nil: .secondary
        }
    }
}
