import AppKit
import RunletCore
import RunletExecution
import SwiftUI

/// A tab a project driver adds to the inspector (`inspectorTabs()`): the rows its list
/// command prints, each with Play / Pause for the tab's run command (in a terminal tab that
/// isn't shown until Logs) and its state.
///
/// The list runs on this Mac when the pane appears, on Refresh, and a moment after a row is
/// started or stopped; never periodically. Production targets list only on Refresh, and both
/// commands ask first there, like host commands.
struct DriverTabPane: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window: WindowModel?
    let tab: DriverInspectorTab
    let editorTab: TabModel

    private var target: TargetRef { editorTab.target }

    var body: some View {
        let state = model.driverTabListState(tab, target: target)
        VStack(spacing: 0) {
            header(state)
            Divider()
            content(state)
            if let notice = model.driverTabs.notices[DriverTabRowKey.listKey(target: target.stableKey, tab: tab.id)] {
                Divider()
                noticeBar(notice)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // When the pane appears, and for another target or tab.
        .task(id: "\(target.stableKey)|\(tab.id)") {
            model.refreshDriverTab(tab, target: target, window: window, automatic: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("driver-tab-\(tab.id)")
    }

    // MARK: Header

    private func header(_ state: DriverTabListState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: tab.symbol)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.title).font(.headline)
                    Text(model.targetLabel(target))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let listing = state.listing {
                        Text("Updated \(listing.loadedAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .accessibilityIdentifier("driver-tab-updated")
                    }
                }
                Spacer(minLength: 4)
                if state.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        model.refreshDriverTab(tab, target: target, window: window)
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .help("List again: runs “\(tab.listCommand)” on this Mac, in the project's folder")
                    .accessibilityIdentifier("driver-tab-refresh")
                }
            }
            if let message = state.listing?.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("driver-tab-message")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Body

    @ViewBuilder
    private func content(_ state: DriverTabListState) -> some View {
        let rows = model.driverTabRows(tab, target: target)
        VStack(spacing: 0) {
            if case .failed(let message, let output, _) = state {
                failure(message, output: output)
            }
            if let listing = state.listing, !listing.skipped.isEmpty {
                banner("Runlet ignored \(listing.skipped.count == 1 ? "an item" : "\(listing.skipped.count) items") the list printed: \(listing.skipped.prefix(5).joined(separator: ", ")).")
            }
            if !rows.isEmpty {
                List {
                    ForEach(rows) { item in
                        DriverTabRow(item: item, key: DriverTabRowKey(target: target.stableKey, tab: tab.id, row: item.id), tab: tab, editorTab: editorTab)
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("driver-tab-rows")
            } else {
                emptyState(state)
            }
        }
    }

    @ViewBuilder
    private func emptyState(_ state: DriverTabListState) -> some View {
        switch state {
        case .idle:
            ContentUnavailableView {
                Label("Not Listed Yet", systemImage: tab.symbol)
            } description: {
                Text(model.isProduction(target)
                    ? "This target is production, so Runlet lists \(tab.title) only when you ask, and asks first. It runs “\(tab.listCommand)” on this Mac."
                    : "Runlet runs “\(tab.listCommand)” on this Mac to list \(tab.title).")
            } actions: {
                Button("Refresh") { model.refreshDriverTab(tab, target: target, window: window) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading(nil):
            VStack(spacing: 10) {
                ProgressView()
                Text("Listing \(tab.title)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(_, _, nil):
            Spacer(minLength: 0)
        default:
            ContentUnavailableView {
                Label(tab.emptyText ?? "Nothing Listed", systemImage: tab.symbol)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("driver-tab-empty")
        }
    }

    /// The list command's error, with its stderr (or output).
    private func failure(_ message: String, output: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            if let output {
                ScrollView {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(6)
                }
                .frame(maxHeight: 140)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("driver-tab-error")
    }

    private func banner(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func noticeBar(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                model.driverTabs.notices[DriverTabRowKey.listKey(target: target.stableKey, tab: tab.id)] = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// One row: title, subtitle, badge, the run command's state, Play / Pause, and Logs.
private struct DriverTabRow: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window: WindowModel?
    let item: DriverInspectorTabListing.Item
    let key: DriverTabRowKey
    let tab: DriverInspectorTab
    let editorTab: TabModel

    var body: some View {
        let state = model.driverTabRowState(key)
        let starting = model.driverTabs.starting.contains(key)
        let hasTerminal = model.driverTabSession(key) != nil
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let badge = item.badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                            .accessibilityLabel(badge)
                    }
                }
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                stateLine(state, starting: starting)
            }
            Spacer(minLength: 4)
            if starting || state == .pausing {
                ProgressView().controlSize(.small)
            } else if state.isActive {
                Button {
                    model.pauseDriverTabRow(key, of: tab, target: editorTab.target)
                } label: {
                    Image(systemName: "pause.fill")
                }
                .buttonStyle(.borderless)
                .help("Pause: send Ctrl-C to “\(commandLine)”")
                .accessibilityLabel("Pause \(item.title)")
                .accessibilityIdentifier("driver-tab-pause-\(item.id)")
            } else {
                Button {
                    model.playDriverTabRow(item, of: tab, for: editorTab, in: window)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help("Play: run “\(commandLine)” on this Mac in a terminal tab until you pause it")
                .accessibilityLabel("Play \(item.title)")
                .accessibilityIdentifier("driver-tab-play-\(item.id)")
            }
            Button {
                model.showDriverTabRowLogs(key)
            } label: {
                Image(systemName: "text.alignleft")
            }
            .buttonStyle(.borderless)
            .disabled(!hasTerminal)
            .help(hasTerminal ? "Logs: its output, live" : "Logs: play it first; its output shows here")
            .accessibilityLabel("Logs of \(item.title)")
            .accessibilityIdentifier("driver-tab-logs-\(item.id)")
            .popover(isPresented: logsShown, arrowEdge: .leading) {
                DriverTabLogsPopover(item: item, key: key, tab: tab, editorTab: editorTab)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }

    /// Whether this row's Logs popover is open (closing it, with Esc or a click outside, keeps
    /// the command running).
    private var logsShown: Binding<Bool> {
        Binding {
            model.driverTabs.logsPopover == key && model.driverTabSession(key) != nil
        } set: { shown in
            if !shown, model.driverTabs.logsPopover == key { model.driverTabs.logsPopover = nil }
        }
    }

    private var commandLine: String { DriverInspectorTabCommands.runCommandLine(tab.runCommand, id: item.id) }

    @ViewBuilder
    private func stateLine(_ state: DriverTabRowState, starting: Bool) -> some View {
        DriverTabStateLine(state: state, starting: starting)
            .accessibilityIdentifier("driver-tab-state-\(item.id)")
    }
}

/// A row's run state: a coloured dot and "Running 3:12", "Stopped", "Exited with code 1", ….
struct DriverTabStateLine: View {
    let state: DriverTabRowState
    var starting = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            switch state {
            case .running(let since) where !starting:
                Text("Running ") + Text(timerInterval: since...Date.distantFuture, countsDown: false)
            case .pausing:
                Text("Stopping…")
            case .stopped:
                Text("Stopped")
            case .exited(let code):
                Text(code.map { "Exited with code \($0)" } ?? "Exited")
            case .failed(let message):
                Text("Could not start: \(message)").lineLimit(1)
            default:
                Text(starting ? "Starting…" : "Not running")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        if starting { return .orange }
        switch state {
        case .running: return .green
        case .pausing: return .orange
        case .exited(let code): return code == 0 ? .secondary.opacity(0.5) : .red
        case .failed: return .red
        case .idle, .stopped: return .secondary.opacity(0.5)
        }
    }
}

/// Logs: a read-only, live view of a row's terminal tab, with its state, Pause / Play, Copy,
/// and Open in Terminal (which moves it to the terminal panel as an interactive tab).
private struct DriverTabLogsPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window: WindowModel?
    @Environment(\.colorScheme) private var colorScheme
    let item: DriverInspectorTabListing.Item
    let key: DriverTabRowKey
    let tab: DriverInspectorTab
    let editorTab: TabModel

    var body: some View {
        let state = model.driverTabRowState(key)
        let starting = model.driverTabs.starting.contains(key)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(tab.title): \(item.title)")
                        .font(.headline)
                        .lineLimit(1)
                    DriverTabStateLine(state: state, starting: starting)
                        .accessibilityIdentifier("driver-tab-logs-state")
                }
                Spacer(minLength: 12)
                if starting || state == .pausing {
                    ProgressView().controlSize(.small)
                } else if state.isActive {
                    Button {
                        model.pauseDriverTabRow(key, of: tab, target: editorTab.target)
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .accessibilityIdentifier("driver-tab-logs-pause")
                } else {
                    Button {
                        model.playDriverTabRow(item, of: tab, for: editorTab, in: window)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .accessibilityIdentifier("driver-tab-logs-play")
                }
                Menu {
                    Button("Copy Visible Text") { copy(visibleOnly: true) }
                    Button("Copy All Output") { copy(visibleOnly: false) }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .menuStyle(.button)
                .fixedSize()
                .accessibilityIdentifier("driver-tab-logs-copy")
                Button {
                    model.promoteDriverTabRowLogs(key)
                } label: {
                    Label("Open in Terminal", systemImage: "terminal")
                }
                .help("Show it in the terminal panel as an ordinary tab, where you can type into it")
                .accessibilityIdentifier("driver-tab-logs-open")
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()
            if let (session, _) = model.driverTabSession(key) {
                let size = TerminalPeekView.size(for: session)
                TerminalPeekView(session: session, theme: TerminalTheme(isDark: colorScheme == .dark), fontSize: model.settings.fontSize,
                                 optionAsMeta: model.settings.terminalOptionAsMeta) {
                    model.driverTabs.logsPopover = nil
                }
                .frame(width: size.width, height: size.height)
                .accessibilityIdentifier("driver-tab-logs-terminal")
            } else {
                Text("Its terminal tab was closed.")
                    .foregroundStyle(.secondary)
                    .frame(width: 640, height: 120)
            }
        }
        .onExitCommand { model.driverTabs.logsPopover = nil }
    }

    private func copy(visibleOnly: Bool) {
        guard let (session, _) = model.driverTabSession(key) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.text(visibleOnly: visibleOnly), forType: .string)
    }
}
