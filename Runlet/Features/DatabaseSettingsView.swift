import RunletCore
import SwiftUI

/// Settings ▸ Databases (#142): the saved connections of all targets, which every SQL tab's
/// picker offers (the sandbox's too) and which always open from this Mac, and every target's
/// own saved connections. Nothing here connects, except Test Connection in the editor.
struct DatabaseSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            // #188, behind its feature flag (#187).
            if model.isEnabled(.tablePlusImport) {
                Section {
                    HStack {
                        Text("Bring saved connections over from TablePlus. Runlet reads TablePlus's list when you click, and its Keychain items only if you ask.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        TablePlusImportButton()
                    }
                } header: {
                    Text("Import")
                }
            }
            Section {
                DatabaseConnectionsList(allTargets: ())
            } header: {
                Text("All Targets")
            } footer: {
                Text("Offered in every SQL tab's connection picker, the Laravel sandbox's too. They open from this Mac with \(model.localConnectionPHP?.label ?? "Runlet's PHP (Settings ▸ PHP)"), so host names are resolved on this Mac. Runs use the stricter of the connection's marking and the tab's target's.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let targets = targetsWithConnections
            ForEach(targets, id: \.self) { target in
                Section {
                    DatabaseConnectionsList(target: target, mentionsAllTargets: false)
                } header: {
                    Label(model.targetLabel(target), systemImage: symbol(target))
                }
            }
            Section {
                Text(targets.isEmpty
                     ? "No target has saved connections of its own. Add one from an SQL tab's connection picker, or in a project's options or a Docker or SSH profile."
                     : "Add a connection to another target from an SQL tab's connection picker, or in a project's options or a Docker or SSH profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Targets")
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings-databases")
    }

    /// Saved targets that have connections of their own, in the Targets pane's order.
    private var targetsWithConnections: [TargetRef] {
        let library = model.library
        let byName = { (a: (String, TargetRef), b: (String, TargetRef)) in a.0.localizedStandardCompare(b.0) == .orderedAscending }
        let projects = library.localProjects.map { ($0.name, TargetRef.local($0.id)) }.sorted(by: byName)
        let docker = library.dockerProfiles.map { ($0.name, TargetRef.docker($0.id)) }.sorted(by: byName)
        let ssh = library.sshProfiles.map { ($0.name, TargetRef.ssh($0.id)) }.sorted(by: byName)
        return (projects + docker + ssh).map(\.1).filter { !library.databaseConnections(for: $0).isEmpty }
    }

    private func symbol(_ target: TargetRef) -> String {
        switch target {
        case .sandbox: "shippingbox"
        case .local: "folder"
        case .docker: "cube.box"
        case .ssh: "server.rack"
        }
    }
}
