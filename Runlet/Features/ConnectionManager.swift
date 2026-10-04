import AppKit
import RunletCore
import SwiftUI

/// Window ▸ Connections (#180): everything Runlet has open right now, grouped by kind, with a
/// Close per row. It only shows state Runlet already keeps: listing never connects, reads, or
/// runs anything. Its SSH rows look at the profiles' control sockets on this Mac again while
/// the window is open (a local check, as the status bar's SSH status does).
struct ConnectionManagerView: View {
    static let sceneId = "connections"

    @Environment(AppModel.self) private var model

    var body: some View {
        let list = model.activeConnections
        VStack(spacing: 0) {
            header(list)
            Divider()
            if list.isEmpty {
                ContentUnavailableView {
                    Label("No Active Connections", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("SSH connections, tunnels, database sessions, PHP runs, and AI clients appear here while they're open. Database sessions exist only while a statement runs.")
                }
                .accessibilityIdentifier("connections-empty")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(list.groups) { group in
                        Section {
                            ForEach(group.items) { item in
                                ConnectionRow(item: item, usage: list.usage(of: item.id))
                            }
                        } header: {
                            sectionHeader(group)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .accessibilityIdentifier("connections-list")
            }
        }
        .frame(minWidth: 560, minHeight: 320)
        .alert(model.connectionManager.pendingClose?.confirmation.title ?? "", isPresented: closeQuestion, presenting: model.connectionManager.pendingClose) { pending in
            Button(pending.confirmation.button, role: .destructive) { model.answerCloseConnection(true) }
            Button("Cancel", role: .cancel) { model.answerCloseConnection(false) }
        } message: { pending in
            Text(pending.confirmation.message)
        }
        .onAppear {
            model.connectionManager.isWindowOpen = true
            model.refreshSSHStatuses()
        }
        .onDisappear { model.connectionManager.isWindowOpen = false }
        // While the window is open, a shared connection that ended by itself (its idle time, a
        // network change) leaves the list: the control sockets on this Mac are looked at again
        // every few seconds. Nothing reaches the network.
        .task(id: model.connectionManager.isWindowOpen) {
            while model.connectionManager.isWindowOpen, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                model.refreshSSHStatuses()
            }
        }
    }

    private var closeQuestion: Binding<Bool> {
        Binding(
            get: { model.connectionManager.pendingClose != nil },
            set: { if !$0, model.connectionManager.pendingClose != nil { model.answerCloseConnection(false) } }
        )
    }

    private func header(_ list: ActiveConnectionList) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(list.summary)
                    .font(.headline)
                    .accessibilityIdentifier("connections-summary")
                Text("What Runlet has open right now. Close ends one thing; nothing here connects by itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func sectionHeader(_ group: ActiveConnectionList.Group) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: group.kind.symbol)
                Text(group.kind.sectionTitle)
                Text("\(group.items.count)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            .font(.subheadline.weight(.semibold))
            Text(group.kind.sectionNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connections-section-\(group.kind.rawValue)")
    }
}

/// One connection: what it is, where it goes, who uses it, since when, its marking, and Close.
private struct ConnectionRow: View {
    @Environment(AppModel.self) private var model
    let item: ActiveConnection
    /// "2 PHP runs and 1 SSH tunnel" for an SSH connection or tunnel that carries work.
    let usage: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.symbol)
                .foregroundStyle(item.isProduction ? Color.red : Color.secondary)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(item.kind == .database || item.kind == .phpRun ? .body.monospaced() : .body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    EnvironmentBadge(environment: item.environment, compact: true)
                }
                Text(item.destination)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    if let owner = item.owner {
                        Label(owner, systemImage: "rectangle.on.rectangle").labelStyle(.titleAndIcon)
                    }
                    since
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let usage {
                    Text("Used by \(usage)")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                        .accessibilityIdentifier("connection-usage")
                }
                if !item.details.isEmpty {
                    Text(item.details.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            closeButton
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Close") { model.requestCloseConnection(item.id) }
                .disabled(item.isClosing)
            if let tabId = item.ownerTabId {
                Button("Reveal Tab") { model.revealTab(tabId) }
            }
            Divider()
            Button("Copy Destination") { Pasteboard.copy(item.destination) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection-\(item.id)")
    }

    @ViewBuilder
    private var since: some View {
        if let startedAt = item.startedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text("since \(startedAt.formatted(date: .omitted, time: .shortened)) (\(ConnectionText.elapsed(since: startedAt, now: context.date)))")
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var closeButton: some View {
        if item.isClosing {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Closing…").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("connection-closing")
        } else {
            Button("Close") { model.requestCloseConnection(item.id) }
                .controlSize(.small)
                .help(item.kind.closeHelp)
                .accessibilityIdentifier("connection-close")
        }
    }
}

/// The status bar's count of active connections (#180). A click opens the Connection Manager;
/// the tooltip has the counts per kind. At zero it stays, dimmed, so the window is still a click away.
struct ConnectionsStatusItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let list = model.activeConnections
        Button {
            model.showConnectionManager()
        } label: {
            Label("\(list.count)", systemImage: "point.3.connected.trianglepath.dotted")
                .monospacedDigit()
        }
        .buttonStyle(.borderless)
        .foregroundStyle(list.isEmpty ? Color.secondary : Color.primary)
        .opacity(list.isEmpty ? 0.55 : 1)
        .help(list.tooltip)
        .accessibilityLabel(list.summary)
        .accessibilityIdentifier("connections-status")
    }
}
