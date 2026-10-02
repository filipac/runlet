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

/// "Connected" / "Not connected" with Connect… or Disconnect, for the profile form.
struct SSHConnectionControls: View {
    @Environment(AppModel.self) private var model
    let profileId: UUID
    /// Called before Connect… opens its terminal tab (the sheet saves and closes first).
    var beforeConnect: () -> Bool = { true }

    var body: some View {
        let status = model.sshStatus(profileId)
        let saved = model.library.sshProfile(profileId) != nil
        HStack(spacing: 8) {
            Circle().fill(status.tint).frame(width: 8, height: 8)
            Text(model.isConnectingSSH(profileId) ? "Logging in…" : status.label)
                .accessibilityIdentifier("ssh-connection-status")
            Spacer()
            if status == .connected {
                Button("Disconnect") { model.disconnectSSH(profileId) }
                    .accessibilityIdentifier("ssh-disconnect-button")
            } else {
                Button(saved ? "Connect…" : "Save and Connect…") {
                    if beforeConnect() { model.connectSSH(profileId) }
                }
                .disabled(model.isConnectingSSH(profileId))
                .accessibilityIdentifier("ssh-connect-button")
            }
        }
        .onAppear { model.refreshSSHStatus(profileId) }
    }
}
