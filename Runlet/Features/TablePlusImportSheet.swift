import RunletCore
import SwiftUI

/// Import from TablePlus… (#188): every connection found in TablePlus's list, none selected,
/// with what each becomes; then a summary. Nothing connects.
struct TablePlusImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: TablePlusImportSession
    @State private var window: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let summary = session.summary {
                TablePlusImportSummaryView(summary: summary)
            } else if session.plan.rows.isEmpty {
                empty
            } else {
                optionsBar
                Divider()
                rows
            }
            Divider()
            footer
        }
        .frame(width: 820, height: 720)
        .background(WindowReader(window: $window))
        .onAppear { TablePlusImportSession.current = session }
        .accessibilityIdentifier("tableplus-import")
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 24)).foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.summary == nil ? "Import from TablePlus" : "Imported from TablePlus").font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        let rows = session.plan.rows
        guard !rows.isEmpty else { return session.source ?? "TablePlus's connection list" }
        let importable = rows.filter(\.canImport).count
        let found = "\(rows.count) connection\(rows.count == 1 ? "" : "s") in \(session.source ?? "TablePlus's list"), \(importable) Runlet can import."
        return session.summary == nil ? found + " Nothing connects; passwords are copied only if you ask." : "Nothing connected. Test Connection in a connection's editor checks it."
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "tray").font(.system(size: 30)).foregroundStyle(.secondary)
            Text(session.readError ?? "No connections found.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button("Choose File…") { model.chooseTablePlusFile(into: session, window: window) }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var optionsBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Picker("Save for", selection: $session.options.scope) {
                    Text("All targets").tag(TargetRef?.none)
                    let targets = scopeTargets
                    if !targets.isEmpty {
                        Divider()
                        ForEach(targets, id: \.self) { target in
                            Label(model.targetLabel(target), systemImage: model.targetSymbol(target)).tag(TargetRef?.some(target))
                        }
                    }
                }
                .frame(maxWidth: 300)
                .accessibilityIdentifier("tableplus-scope")
                Picker("Already saved", selection: $session.options.duplicates) {
                    Text("Skip").tag(TablePlusDuplicatePolicy.skip)
                    Text("Update").tag(TablePlusDuplicatePolicy.update)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
                .help("A connection imported before (Runlet remembers TablePlus's id), or one with the same name where it's saved. Update replaces its definition with TablePlus's.")
                .accessibilityIdentifier("tableplus-duplicates")
                Spacer()
                Button("Select All") { session.selectAll(true) }
                    .accessibilityIdentifier("tableplus-select-all")
                Button("Select None") { session.selectAll(false) }
                    .disabled(session.options.selected.isEmpty)
            }
            Toggle(isOn: $session.options.copyPasswords) {
                Text("Also copy passwords from TablePlus's Keychain items")
                Text("macOS asks you to allow each item. Passwords go only into Runlet's Keychain items, never into files, logs, or AI clients. SSH passwords and key passphrases are never copied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("tableplus-copy-passwords")
            let profiles = session.plan.newProfiles(options: session.options, library: model.library)
            if !profiles.isEmpty {
                Label {
                    Text("Creates \(profiles.count == 1 ? "an SSH profile" : "\(profiles.count) SSH profiles"): ")
                        + Text(profiles.map { "\($0.profile.name) (\($0.profile.destinationLabel), \(Self.loginLabel($0.profile)))" }.joined(separator: ", ")).bold()
                        + Text(". Nothing connects until a statement uses one.")
                } icon: {
                    Image(systemName: "server.rack").foregroundStyle(.teal)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("tableplus-new-profiles")
            }
            ForEach(session.plan.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(session.plan.rows) { row in
                        TablePlusImportRowView(session: session, row: row)
                            .id(row.id)
                        Divider()
                    }
                }
                .padding(.horizontal, 12)
            }
            .onChange(of: session.scrollTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: .top)
                session.scrollTarget = nil
            }
        }
    }

    private var footer: some View {
        HStack {
            if session.summary == nil {
                Button("Choose File…") { model.chooseTablePlusFile(into: session, window: window) }
                    .disabled(session.phase == .importing)
                    .accessibilityIdentifier("tableplus-choose-file")
            }
            Spacer()
            if session.phase == .importing {
                ProgressView().controlSize(.small)
                Text(session.options.copyPasswords ? "Reading TablePlus's Keychain items…" : "Importing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if session.summary != nil {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("tableplus-done")
            } else {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(session.phase == .importing)
                let count = session.plan.work(options: session.options, library: model.library).count
                Button(count == 0 ? "Import" : "Import \(count)") { model.performTablePlusImport(session) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(count == 0 || session.phase != .choosing)
                    .accessibilityIdentifier("tableplus-import-button")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Targets that can have saved connections, in the Targets pane's order.
    private var scopeTargets: [TargetRef] {
        let library = model.library
        let byName = { (a: (String, TargetRef), b: (String, TargetRef)) in a.0.localizedStandardCompare(b.0) == .orderedAscending }
        let projects = library.localProjects.map { ($0.name, TargetRef.local($0.id)) }.sorted(by: byName)
        let docker = library.dockerProfiles.map { ($0.name, TargetRef.docker($0.id)) }.sorted(by: byName)
        let ssh = library.sshProfiles.map { ($0.name, TargetRef.ssh($0.id)) }.sorted(by: byName)
        return (projects + docker + ssh).map(\.1)
    }

    static func loginLabel(_ profile: SSHProfile) -> String {
        switch profile.authentication {
        case .interactive: "password at Connect…"
        case .automatic: profile.identityFile.map { "key \(($0 as NSString).lastPathComponent)" } ?? "agent"
        }
    }
}

/// One TablePlus connection: a checkbox, what it is, and what it becomes.
private struct TablePlusImportRowView: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: TablePlusImportSession
    let row: TablePlusImportRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { session.isSelected(row) }, set: { session.setSelected(row, $0) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!row.canImport)
                .padding(.top, 1)
            if let driver = row.connection?.driver {
                DatabaseDriverIcon(driver: driver).padding(.top, 1)
            } else {
                Image(systemName: "nosign").foregroundStyle(.tertiary).frame(width: 18).padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.source.name).fontWeight(.medium)
                    environmentBadge
                    if row.usesTLS { badge("TLS", systemImage: "lock.fill", color: .secondary) }
                    if row.connection?.readOnly == true { badge("Read-only", systemImage: "lock.doc", color: .secondary) }
                    if let group = row.source.group {
                        Label(group, systemImage: "folder").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.canImport, row.usesSSH {
                    HStack(spacing: 6) {
                        Text("Connect through")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        sshPicker
                            .controlSize(.small)
                            .fixedSize()
                    }
                    .padding(.vertical, 1)
                }
                status
            }
            .opacity(row.canImport ? 1 : 0.55)
            Spacer(minLength: 8)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tableplus-row-\(row.source.name)")
    }

    /// "MySQL · db.acme.example.com:3306 · shop · user shop_ro · SSH deploy@bastion.example.com".
    private var details: String {
        var parts = [row.source.driver.isEmpty ? "No driver" : row.source.driver]
        let location = row.source.location
        if !location.isEmpty { parts.append(location) }
        if !row.source.database.isEmpty, row.source.path == nil { parts.append(row.source.database) }
        if !row.source.user.isEmpty { parts.append("user \(row.source.user)") }
        if let ssh = row.source.ssh { parts.append("SSH \(ssh.destination)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var environmentBadge: some View {
        switch row.environment {
        case .production: badge("Production", systemImage: "exclamationmark.shield.fill", color: .red)
        case .staging: badge("Staging", systemImage: nil, color: .orange)
        case .development: EmptyView()
        }
    }

    private func badge(_ text: String, systemImage: String?, color: Color) -> some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().strokeBorder(color.opacity(0.6)))
    }

    @ViewBuilder private var status: some View {
        if let reason = row.reason {
            Label(reason, systemImage: "xmark.circle").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let existing = session.plan.duplicate(of: row, scope: session.options.scope, in: model.library) {
            Label(session.options.duplicates == .skip
                  ? "Already saved as “\(existing.name)”: skipped"
                  : "Already saved as “\(existing.name)”: its definition is updated", systemImage: "doc.on.doc")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if !row.notes.isEmpty {
            Label(row.notes.joined(separator: " "), systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sshPicker: some View {
        let library = model.library
        let matching = session.plan.matchingProfiles(for: row, in: library)
        let others = library.sshProfiles.filter { profile in !matching.contains { $0.id == profile.id } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let canCreate = row.source.ssh.map { TablePlusImportPlan.profileProblem($0) == nil } ?? false
        return Picker("SSH", selection: Binding(
            get: { session.plan.sshChoice(for: row, options: session.options, in: library) ?? .direct },
            set: { session.options.sshChoices[row.id] = $0 }
        )) {
            if canCreate {
                Label("New SSH profile: \(newProfileName)", systemImage: "plus.circle").tag(TablePlusSSHChoice.newProfile)
            }
            ForEach(matching) { profile in
                Label(profile.name, systemImage: "server.rack").tag(TablePlusSSHChoice.existing(profile.id))
            }
            if !others.isEmpty {
                Section("Other SSH profiles") {
                    ForEach(others) { profile in
                        Text(profile.name).tag(TablePlusSSHChoice.existing(profile.id))
                    }
                }
            }
            Divider()
            Text("Don't import over SSH").tag(TablePlusSSHChoice.direct)
        }
        .labelsHidden()
        .help("TablePlus reaches this database through SSH. Runlet connects from this Mac through an SSH profile's tunnel.")
        .accessibilityIdentifier("tableplus-ssh-\(row.source.name)")
    }

    /// The name the new profile gets: as planned when the row is selected, else the SSH host.
    private var newProfileName: String {
        session.plan.newProfiles(options: session.options, library: model.library).first { $0.rowIDs.contains(row.id) }?.profile.name
            ?? row.source.ssh?.host ?? "SSH"
    }
}

/// What the import did.
private struct TablePlusImportSummaryView: View {
    let summary: TablePlusImportSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 18) {
                    count(summary.imported.count, "imported", "checkmark.circle.fill", .green)
                    count(summary.updated.count, "updated", "arrow.triangle.2.circlepath", .blue)
                    count(summary.skipped.count, "skipped", "minus.circle", .secondary)
                    count(summary.needsAttention.count, "need attention", "exclamationmark.triangle.fill", .orange)
                    count(summary.createdProfiles.count, "new SSH profiles", "server.rack", .teal)
                    if summary.passwordsCopied > 0 {
                        count(summary.passwordsCopied, summary.passwordsCopied == 1 ? "password copied" : "passwords copied", "key.fill", .secondary)
                    }
                }
                section("Needs Attention", summary.needsAttention, "exclamationmark.triangle.fill", .orange)
                section("New SSH Profiles", summary.createdProfiles, "server.rack", .teal)
                section("Imported", summary.imported, "checkmark.circle.fill", .green)
                section("Updated", summary.updated, "arrow.triangle.2.circlepath", .blue)
                section("Skipped", summary.skipped, "minus.circle", .secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("tableplus-summary")
    }

    private func count(_ value: Int, _ label: String, _ symbol: String, _ color: Color) -> some View {
        Label("\(value) \(label)", systemImage: symbol)
            .foregroundStyle(value == 0 ? .secondary : color)
            .font(.callout.weight(.medium))
    }

    @ViewBuilder
    private func section(_ title: String, _ entries: [TablePlusImportSummary.Entry], _ symbol: String, _ color: Color) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                ForEach(entries) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: symbol).foregroundStyle(color).frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                            ForEach(entry.details, id: \.self) { detail in
                                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The window hosting a view (for Choose File…'s sheet).
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if window !== nsView.window { DispatchQueue.main.async { window = nsView.window } }
    }
}

/// Import from TablePlus…, when its feature flag is on (#187): the button and its sheet.
struct TablePlusImportButton: View {
    @Environment(AppModel.self) private var model
    @State private var session: TablePlusImportSession?

    var body: some View {
        Group {
            if model.isEnabled(.tablePlusImport) {
                Button("Import from TablePlus…") { session = model.makeTablePlusImportSession() }
                    .accessibilityIdentifier("db-import-tableplus")
                    .sheet(item: $session) { session in
                        TablePlusImportSheet(session: session)
                    }
                    #if DEBUG
                    .onReceive(NotificationCenter.default.publisher(for: .debugOpenTablePlusImport)) { _ in
                        if session == nil { session = model.makeTablePlusImportSession() }
                    }
                    #endif
            }
        }
    }
}

#if DEBUG
extension Notification.Name {
    /// The `tableplus-open` Debug step: the visible Import from TablePlus… button opens its sheet.
    static let debugOpenTablePlusImport = Notification.Name("RunletDebugOpenTablePlusImport")
}
#endif
