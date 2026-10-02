import RunletCore
import RunletExecution
import SwiftUI

/// Import SSH Hosts from `~/.ssh/config`: one SSH profile per chosen `Host` alias, with its
/// directory (optional: Detect fills it in later) and environment (preselected from words such
/// as `prod` or `staging` in the alias or host name). Runlet reads the config file and asks
/// `ssh -G` what each alias resolves to; nothing connects.
struct SSHConfigImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The ids of the profiles that were added (in list order).
    var onImported: ([UUID]) -> Void = { _ in }

    struct Row: Identifiable {
        let alias: String
        var id: String { alias }
        var selected = false
        var directory = ""
        var environment = TargetEnvironment.development
        var environmentEdited = false
        var effective: [String: String]?
        /// A profile already uses this alias as its host.
        let existing: Bool
    }

    @State private var rows: [Row] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Hosts from ~/.ssh/config").font(.headline)
            Text("Choose the hosts to add as SSH profiles. Runlet reads \((model.sshConfigFile.path as NSString).abbreviatingWithTildeInPath) and asks `ssh -G` what each alias resolves to; nothing connects. Set each application's directory now, or later with Detect in the profile.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if loaded, rows.isEmpty {
                ContentUnavailableView("No Hosts", systemImage: "server.rack", description: Text("\((model.sshConfigFile.path as NSString).abbreviatingWithTildeInPath) has no Host entries without wildcards."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach($rows) { $row in
                        ImportRow(row: $row)
                    }
                }
                .listStyle(.inset)
                .overlay { if !loaded { ProgressView() } }
                .accessibilityIdentifier("ssh-import-list")
            }
            HStack {
                Button(allSelected ? "Select None" : "Select All") {
                    let select = !allSelected
                    for index in rows.indices where !rows[index].existing { rows[index].selected = select }
                }
                .disabled(rows.allSatisfy(\.existing))
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(importTitle) { importSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedCount == 0)
                    .accessibilityIdentifier("ssh-import-button")
            }
        }
        .padding(20)
        .frame(width: 760, height: 540)
        .task { await load() }
    }

    private var selectedCount: Int { rows.count(where: \.selected) }
    private var allSelected: Bool { rows.contains { !$0.existing } && rows.allSatisfy { $0.existing || $0.selected } }

    private var importTitle: String {
        selectedCount == 1 ? "Import 1 Host" : "Import \(selectedCount) Hosts"
    }

    /// Aliases from the config file (local), then `ssh -G` for each (reads the config only).
    private func load() async {
        guard !loaded else { return }
        let aliases = SSHConfigHosts.aliases(in: model.sshConfigFile)
        let existing = Set(model.library.sshProfiles.map(\.host))
        rows = aliases.map { alias in
            Row(alias: alias, environment: SSHHostImport.likelyEnvironment(alias: alias), existing: existing.contains(alias))
        }
        loaded = true
        let client = model.sshClient
        await withTaskGroup(of: (String, [String: String]?).self) { group in
            for alias in aliases {
                group.addTask { (alias, await client.effectiveConfiguration(host: alias)) }
            }
            for await (alias, values) in group {
                guard let index = rows.firstIndex(where: { $0.alias == alias }) else { continue }
                rows[index].effective = values
                if !rows[index].environmentEdited {
                    rows[index].environment = SSHHostImport.likelyEnvironment(alias: alias, hostname: values?["hostname"])
                }
            }
        }
    }

    private func importSelected() {
        var ids: [UUID] = []
        for row in rows where row.selected && !row.existing {
            let profile = SSHHostImport.profile(alias: row.alias, directory: row.directory, environment: row.environment)
            model.saveSSHProfile(profile)
            ids.append(profile.id)
        }
        onImported(ids)
        dismiss()
    }
}

/// One alias: a checkbox, what `ssh -G` says it resolves to, its directory, and environment.
private struct ImportRow: View {
    @Binding var row: SSHConfigImportSheet.Row

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $row.selected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(row.existing)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.alias).fontWeight(.medium)
                if row.existing {
                    Text("Already a profile").font(.caption).foregroundStyle(.secondary)
                } else if let effective = row.effective {
                    Text(SSHProfileForm.effectiveSummary(effective).replacingOccurrences(of: "\n", with: " · "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text("…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 230, alignment: .leading)
            TextField("Directory", text: $row.directory, prompt: Text("Directory (or set later)"))
                .textFieldStyle(.roundedBorder)
                .disabled(row.existing)
                .onChange(of: row.directory) { _, value in
                    if !value.isEmpty, !row.existing { row.selected = true }
                }
            Picker("Environment", selection: environmentBinding) {
                ForEach(TargetEnvironment.allCases, id: \.self) { environment in
                    Text(environment.displayName).tag(environment)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            .disabled(row.existing)
        }
        .padding(.vertical, 3)
        .opacity(row.existing ? 0.6 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ssh-import-row-\(row.alias)")
    }

    private var environmentBinding: Binding<TargetEnvironment> {
        Binding(
            get: { row.environment },
            set: { value in
                row.environment = value
                row.environmentEdited = true
            }
        )
    }
}
