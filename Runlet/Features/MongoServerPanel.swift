import AppKit
import RunletCore
import SwiftUI

/// The MongoDB Server section (#207), like SQL's (#150) and Redis's: a `serverStatus` summary
/// and the server's operations (`$currentOp`) with Kill Op. Nothing reads by itself: Read Server
/// Details, and the refresh interval the user turns on (never on production).
struct MongoServerPanelView: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel
    @Bindable var state: MongoServerState
    @State private var filter = ""

    var body: some View {
        let production = model.isProduction(tab.target, connection: model.sqlConnectionChoice(for: tab).savedConnection)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    model.loadMongoServer(tab)
                } label: {
                    Label(state.report == nil ? "Read Server Details" : "Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(state.loading)
                .help("Reads serverStatus and $currentOp on the tab's connection. Nothing changes. Production asks first.")
                .accessibilityIdentifier("mongo-server-read")
                if state.loading { ProgressView().controlSize(.small) }
                Spacer()
                refreshMenu(production: production)
            }
            if let date = state.readAt {
                Text("Read \(date.formatted(date: .omitted, time: .standard))" + (state.refreshInterval.map { " · refreshes every \($0) s" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let kill = state.lastKill {
                Label(kill.detail, systemImage: kill.outcome == .killed ? "checkmark.circle" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(kill.outcome == .failed ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mongo-kill-outcome")
            }
            if let report = state.report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(report.summary).font(.callout.weight(.semibold)).textSelection(.enabled).accessibilityIdentifier("mongo-server-summary")
                        details(report)
                        operations(report)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if !state.loading {
                Text("Read Server Details shows the server's version, uptime, connections, memory and replica set state (serverStatus), and its operations (currentOp), read when you press it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .onDisappear { model.setMongoServerRefresh(nil, for: tab) }
        .accessibilityIdentifier("mongo-server-panel")
    }

    @ViewBuilder
    private func refreshMenu(production: Bool) -> some View {
        let intervals = MongoServerPanel.refreshIntervals(isProduction: production)
        Menu {
            Button("Off") { model.setMongoServerRefresh(nil, for: tab) }
            ForEach(intervals, id: \.self) { seconds in
                Button("Every \(seconds) s") { model.setMongoServerRefresh(seconds, for: tab) }
            }
        } label: {
            Label(state.refreshInterval.map { "\($0) s" } ?? "Refresh: Off", systemImage: "timer")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .disabled(production || state.report == nil)
        .help(production ? "Refreshing by itself is never available on production: Runlet asks before every read there." : "Read the operations again every few seconds while this section shows. Off by default.")
        .accessibilityIdentifier("mongo-server-refresh")
    }

    @ViewBuilder
    private func details(_ report: MongoServerReport) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
            if let host = report.status?.host ?? report.host {
                row("Host", host)
            }
            if let replica = report.replica, let set = replica.setName {
                row("Replica set", "\(set) · \(replica.state ?? "?")" + (replica.primary.map { " · primary \($0)" } ?? ""))
            }
            if let connections = report.status?.connections {
                row("Connections", "\(connections.current.formatted()) current, \(connections.available.formatted()) available" + (connections.totalCreated.map { ", \($0.formatted()) created" } ?? ""))
            }
            if let memory = report.status?.memory {
                row("Memory", "\(memory.residentMB.formatted()) MB resident, \(memory.virtualMB.formatted()) MB virtual")
            }
            if let engine = report.status?.storageEngine { row("Storage engine", engine) }
            if let counters = report.status?.opcounters, !counters.isEmpty {
                row("Operations since start", ["insert", "query", "update", "delete", "getmore", "command"].compactMap { name in counters[name].map { "\(name) \($0.formatted())" } }.joined(separator: " · "))
            }
            if let error = report.errors?["serverStatus"] {
                row("serverStatus", error)
            }
        }
        .font(.caption)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func operations(_ report: MongoServerReport) -> some View {
        let all = report.operations ?? []
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = all.sorted { !$0.isServerThread && $1.isServerThread }.filter { operation in
            (!state.hideRunlet || !operation.isRunlet || operation.own == true)
                && (query.isEmpty || [operation.ns, operation.op, operation.client, operation.command, operation.appName, operation.desc].compactMap { $0?.lowercased() }.contains { $0.contains(query) })
        }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Operations (\(all.count))").font(.callout.weight(.semibold))
                Spacer()
                Toggle("Hide Runlet's", isOn: $state.hideRunlet).toggleStyle(.checkbox).controlSize(.small)
                    .help("Hides the operations Runlet's own runs are doing (tagged runlet:…), except the panel's own read")
            }
            TextField("Filter by namespace, operation, client, or command", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .accessibilityIdentifier("mongo-operation-filter")
            if report.ownOnly == true {
                Text("This user may list only its own operations (no inprog privilege).").font(.caption).foregroundStyle(.secondary)
            }
            if let error = report.errors?["currentOp"] {
                Text("currentOp: \(error)").font(.caption).foregroundStyle(.red)
            }
            ForEach(shown) { operation in
                operationRow(operation)
            }
        }
    }

    private func operationRow(_ operation: MongoServerReport.Operation) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("#\(operation.opid)").font(.system(.caption, design: .monospaced).weight(.semibold))
                    Text(operation.op ?? "?").font(.caption.weight(.semibold))
                    if let ns = operation.ns { Text(ns).font(.system(.caption, design: .monospaced)) }
                    if operation.own == true { Text("(this panel)").font(.caption).foregroundStyle(.secondary) }
                    if operation.isServerThread { Text("server thread").font(.caption).foregroundStyle(.secondary) }
                    if operation.waitingForLock == true { Text("waiting for a lock").font(.caption2.weight(.semibold)).foregroundStyle(.orange) }
                }
                Text([operation.runningText, operation.client.map { "client \($0)" }, operation.users.map { "as " + $0.joined(separator: ", ") }, operation.appName, operation.desc].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let command = operation.command, !command.isEmpty, command != "[]" {
                    Text(command)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 4)
            if state.killing == operation.opid {
                ProgressView().controlSize(.small)
            } else if operation.own != true, !operation.isServerThread {
                Button("Kill…") { model.askKillMongoOperation(tab, operation: operation) }
                    .controlSize(.small)
                    .help("killOp \(operation.opid): ends this operation at its next interruption point. Runlet asks first, on every connection.")
                    .accessibilityIdentifier("mongo-kill-\(operation.opid)")
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mongo-operation-row")
    }
}
