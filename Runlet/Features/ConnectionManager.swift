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
                    Text("SSH connections, tunnels, database sessions, PHP runs, and AI clients appear here while they're open. Database sessions exist only while a statement runs. Runs waiting for a free run slot appear as queued.")
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
                Text("\(group.activeCount)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                if group.queuedCount > 0 {
                    // #183: queued runs are listed but not counted.
                    Label("\(group.queuedCount) queued", systemImage: "hourglass")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .background(Capsule().strokeBorder(Color.secondary.opacity(0.35)))
                }
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
/// A run waiting for a free run slot (#183) says Queued, since when, and its place in line.
private struct ConnectionRow: View {
    @Environment(AppModel.self) private var model
    let item: ActiveConnection
    /// "2 PHP runs and 1 SSH tunnel" for an SSH connection or tunnel that carries work.
    let usage: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.symbol)
                .foregroundStyle(item.isProduction ? Color.red : Color.secondary)
                .opacity(item.isQueued ? 0.5 : 1)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(item.kind == .database || item.kind == .phpRun ? .body.monospaced() : .body.weight(.medium))
                        .foregroundStyle(item.isQueued ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if item.isQueued { queuedBadge }
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
                    if let usage {
                        // What ends with it: an SSH connection's runs and tunnels, a tunnel's statements.
                        Text("· Used by \(usage)")
                            .foregroundStyle(Color.orange)
                            .accessibilityIdentifier("connection-usage")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let note = item.queueNote {
                    Label(note, systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("connection-queue-note")
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
        .padding(.vertical, 2)
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

    /// #183: waiting for a free run slot; it has opened nothing yet.
    private var queuedBadge: some View {
        Text("Queued")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().strokeBorder(Color.secondary.opacity(0.45)))
            .help("Waiting for a free run slot: Runlet runs a few runs at once and starts this one when one ends. Nothing is open for it yet, so it isn't counted.")
            .accessibilityIdentifier("connection-queued")
    }

    @ViewBuilder
    private var since: some View {
        if let startedAt = item.startedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                // A queued run: since it joined the queue; once it runs, since it got its slot.
                Text("\(item.isQueued ? "Queued since" : "since") \(startedAt.formatted(date: .omitted, time: .shortened)) (\(ConnectionText.elapsed(since: startedAt, now: context.date)))")
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
                .help(item.closeHelp)
                .accessibilityIdentifier("connection-close")
        }
    }
}

/// The status bar's count of active connections (#180). A click opens the Connection Manager;
/// the tooltip has the counts per kind. At zero it stays, dimmed, so the window is still a click away.
/// Runs waiting for a free run slot (#183) aren't counted: an hourglass with their number follows.
struct ConnectionsStatusItem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let list = model.activeConnections
        Button {
            model.showConnectionManager()
        } label: {
            HStack(spacing: 4) {
                Label("\(list.count)", systemImage: "point.3.connected.trianglepath.dotted")
                if list.queuedCount > 0 {
                    Label("\(list.queuedCount)", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("connections-status-queued")
                }
            }
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
