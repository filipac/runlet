import AppKit
import RunletCore
import RunletExecution
import SwiftUI

extension SSHConnectionStatus {
    var label: String {
        switch self {
        case .connected: "Connected"
        case .disconnected: "Not connected"
        case .expired: "Login ended"
        }
    }

    var tint: Color {
        switch self {
        case .connected: .green
        case .disconnected: .secondary
        case .expired: .orange
        }
    }
}

/// Above an SSH tab's editor: asks to Connect… when the profile logs in with a password or
/// code and isn't connected (or its login ended), when a run failed for a reason Connect…
/// fixes (an unknown host key, rejected keys), and while a login is in progress.
struct SSHConnectionBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window
    let tab: TabModel

    var body: some View {
        if case .ssh(let id) = tab.target, let profile = model.library.sshProfile(id), let message = message(profile) {
            HStack(spacing: 8) {
                Image(systemName: model.isConnectingSSH(id) ? "key.horizontal" : "network.slash")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if model.isConnectingSSH(id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Connect…") { model.connectSSH(id, in: window) }
                        .accessibilityIdentifier("ssh-banner-connect")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ssh-connection-banner")
        }
    }

    private func message(_ profile: SSHProfile) -> String? {
        let status = model.sshStatus(profile.id)
        if model.isConnectingSSH(profile.id) {
            return "Log in to \(profile.destinationLabel) in the terminal below. OpenSSH asks for the password or code there; Runlet never sees it."
        }
        guard status != .connected else { return nil }
        if profile.authentication == .interactive {
            return status == .expired
                ? "The login to \(profile.destinationLabel) has ended. Connect again to run code."
                : "Not connected to \(profile.destinationLabel). Connect to log in; runs reuse the login until you disconnect."
        }
        // Agent and key profiles connect by themselves; offer Connect… only after a run
        // failed for a reason it fixes (an unknown host key, rejected keys, a login that ended).
        if case .finished(let info) = tab.runState, info.reason == "launch-failed",
           tab.output.contains(where: { item in
               if case .error(_, let error, _) = item { return error.stage == .launch && error.message.contains("Connect…") }
               return false
           }) {
            return "Runlet couldn't log in to \(profile.destinationLabel) without asking. Connect… opens a terminal where you can check the host key or log in."
        }
        return nil
    }
}

/// Above an SSH tab without a local folder: offers a local checkout that looks like the
/// server's project (same git remote, composer.json name, or folder name). Applied only
/// with a click.
struct SSHLocalFolderBanner: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel

    var body: some View {
        if case .ssh(let id) = tab.target, let profile = model.library.sshProfile(id), profile.localSourcePath == nil,
           let suggestion = model.sshConnections.folderSuggestions[id]?.first {
            HStack(spacing: 8) {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.blue)
                Text("Completion is limited because this profile has no local folder. \((suggestion.path as NSString).abbreviatingWithTildeInPath) looks like this project (\(suggestion.reason.description)).")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Use for Completion") { model.useSuggestedFolder(suggestion.path, for: id) }
                    .accessibilityIdentifier("ssh-use-suggested-folder")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(0.1))
        }
    }
}

/// Above an SSH tab whose local folder differs from the server's checkout (drift check on).
struct SSHDriftBanner: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel

    var body: some View {
        if case .ssh(let id) = tab.target, let profile = model.library.sshProfile(id),
           let warning = model.sshConnections.drift[id], !model.sshConnections.dismissedDrift.contains(id) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.yellow)
                Text(warning)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer()
                Button("Check Again") { model.checkDriftOnServer(profile) }
                    .help("Reads the server's checkout again (a read-only PHP check) and compares it with the local folder")
                Button {
                    model.sshConnections.dismissedDrift.insert(id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Hide until the checkouts differ in another way")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.yellow.opacity(0.14))
            .accessibilityIdentifier("ssh-drift-banner")
        }
    }
}

/// "Connected" / "Not connected" with Connect… or Disconnect, for the profile form.
struct SSHConnectionControls: View {
    @Environment(AppModel.self) private var model
    let profileId: UUID
    /// Connect… for the form's current values (the sheet steps aside first); nil connects
    /// the saved profile.
    var connect: (() -> Void)?

    var body: some View {
        let status = model.sshStatus(profileId)
        HStack(spacing: 8) {
            Circle().fill(status.tint).frame(width: 8, height: 8)
            Text(model.isConnectingSSH(profileId) ? "Logging in…" : status.label)
                .accessibilityIdentifier("ssh-connection-status")
            Spacer()
            if status == .connected {
                Button("Disconnect") { model.disconnectSSH(profileId) }
                    .accessibilityIdentifier("ssh-disconnect-button")
            } else {
                Button("Connect…") {
                    if let connect { connect() } else { model.connectSSH(profileId) }
                }
                .disabled(model.isConnectingSSH(profileId))
                .accessibilityIdentifier("ssh-connect-button")
            }
        }
        .onAppear { model.refreshSSHStatus(profileId) }
    }
}
