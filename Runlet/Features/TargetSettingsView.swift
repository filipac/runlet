import RunletCore
import SwiftUI

/// Settings ▸ Targets: every saved local project, Docker profile, and SSH profile, with Edit
/// and Delete, and a button that opens the Docker profile manager window.
/// Deleting only removes Runlet's saved entry — folders, containers, and servers are untouched.
struct TargetSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Local Projects") {
                if model.library.localProjects.isEmpty {
                    Text("No projects yet. Use File ▸ Open Project… to add one.").foregroundStyle(.secondary)
                }
                ForEach(model.library.localProjects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { project in
                    row(title: project.name, detail: (project.path as NSString).abbreviatingWithTildeInPath, symbol: "folder",
                        missing: !FileManager.default.fileExists(atPath: project.path), environment: project.environment ?? .development) {
                        NotificationCenter.default.post(name: .editProjectRequested, object: project.id)
                    } delete: {
                        model.confirmDeleteTarget(.local(project.id))
                    }
                }
            }
            Section("Docker Profiles") {
                if model.library.dockerProfiles.isEmpty {
                    Text("No Docker profiles yet. Use Library ▸ New Docker Profile… to add one.").foregroundStyle(.secondary)
                }
                ForEach(model.library.dockerProfiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { profile in
                    row(title: profile.name, detail: "\(profile.identity.displayName) · \(profile.workingDirectory)" + (profile.localSourcePath.map { " · source " + ($0 as NSString).abbreviatingWithTildeInPath } ?? ""),
                        symbol: "cube.box", missing: false, environment: profile.environment ?? .development) {
                        NotificationCenter.default.post(name: .editDockerProfileRequested, object: profile.id)
                    } delete: {
                        model.confirmDeleteTarget(.docker(profile.id))
                    }
                }
                HStack {
                    Text("Edit, create, duplicate, and delete profiles side by side.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Manage Docker Profiles…") { model.showDockerProfileManager() }
                        .accessibilityIdentifier("settings-manage-docker-profiles")
                }
            }
            Section("SSH Hosts") {
                if model.library.sshProfiles.isEmpty {
                    Text("No SSH profiles yet. Use Library ▸ New SSH Profile… to add one.").foregroundStyle(.secondary)
                }
                ForEach(model.library.sshProfiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { profile in
                    row(title: profile.name, detail: TabCardText.sshSubtitle(profile) + (profile.localSourcePath.map { " · local " + ($0 as NSString).abbreviatingWithTildeInPath } ?? " · no local folder"),
                        symbol: "server.rack", missing: false, environment: profile.environment) {
                        NotificationCenter.default.post(name: .editSSHProfileRequested, object: profile.id)
                    } delete: {
                        model.confirmDeleteTarget(.ssh(profile.id))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func row(title: String, detail: String, symbol: String, missing: Bool, environment: TargetEnvironment = .development, edit: @escaping () -> Void, delete: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    EnvironmentBadge(environment: environment)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if missing {
                    Label("Folder not found", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Edit…", action: edit)
            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
            }
            .help("Delete from Runlet (the folder, container, or server is not touched)")
            .accessibilityIdentifier("delete-target-\(title)")
        }
    }
}
