import AppKit
import RunletCore
import SwiftUI

/// Asks before running code an AI client sent over MCP (#43). Shows the client, the target,
/// where it runs, and all of the code. ⌘↩ runs; ↩ and Esc cancel. "Allow for this session"
/// appears only for the Laravel sandbox. Production targets get the production warning, and an
/// SSH host that isn't connected says approving will connect.
struct MCPApprovalSheet: View {
    @Environment(AppModel.self) private var model
    let request: MCPApprovalRequest
    @State private var allowSession = false

    private var isProduction: Bool { request.prompt.isProduction }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isProduction ? "exclamationmark.triangle.fill" : "sparkles")
                    .font(.system(size: 28))
                    .foregroundStyle(isProduction ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                VStack(alignment: .leading, spacing: 4) {
                    Text(isProduction ? "Run code from \(request.clientName) on production?" : "Run code from \(request.clientName)?")
                        .font(.headline)
                    Text("\(request.clientName) asks Runlet to run this PHP code. Nothing runs unless you press \(runTitle); Cancel tells the client you declined.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if isProduction {
                notice("\(request.targetName) is marked as production. The code below runs there with the application's real data. The 10-minute “don't ask again” never applies to AI clients.", symbol: "exclamationmark.octagon.fill", tint: .red)
                    .accessibilityIdentifier("mcp-production-warning")
            }
            if request.prompt.connectsSSH {
                notice("Not connected to \(request.sshHost ?? request.targetName). Pressing \(runTitle) connects over SSH with your keys or agent; Cancel connects to nothing.", symbol: "network", tint: .orange)
                    .accessibilityIdentifier("mcp-ssh-connect-warning")
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("Client").foregroundStyle(.secondary)
                    Text(request.clientName).fontWeight(.semibold)
                        .help("The name the AI client reports for itself.")
                }
                GridRow {
                    Text("Target").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(request.targetName).fontWeight(.semibold)
                        EnvironmentBadge(environment: request.environment)
                    }
                }
                if !request.destination.isEmpty, request.target != .sandbox {
                    GridRow {
                        Text("Where").foregroundStyle(.secondary)
                        Text(request.destination)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }
            .font(.callout)
            VStack(alignment: .leading, spacing: 4) {
                Text(request.lineCount == 1 ? "Code" : "Code · \(request.lineCount) lines").font(.caption).foregroundStyle(.secondary)
                ScrollView([.vertical, .horizontal]) {
                    Text(request.code)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 60, maxHeight: 260)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                .accessibilityIdentifier("mcp-approval-code")
            }
            if request.prompt.offersSessionAllowance {
                Toggle(isOn: $allowSession) {
                    Text("Allow sandbox runs from \(request.clientName) for this session")
                    Text("Until this client disconnects or Runlet quits. Other targets always ask.")
                }
                .accessibilityIdentifier("mcp-allow-session")
            }
            HStack {
                if let expires = request.expiresAt, expires > Date() {
                    HStack(spacing: 3) {
                        Text("Expires in")
                        Text(timerInterval: Date()...expires, countsDown: true)
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text("⌘↩ runs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // ↩ alone cancels: the safe choice is the default.
                Button("Cancel") { model.declineMCPRun(request) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("mcp-cancel")
                Button(runTitle, role: isProduction ? .destructive : nil) { model.approveMCPRun(request, allowSession: allowSession) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .tint(isProduction ? .red : nil)
                    .accessibilityIdentifier("mcp-run")
            }
        }
        .padding(20)
        .frame(width: 600)
        .onExitCommand { model.declineMCPRun(request) }
        .accessibilityIdentifier("mcp-approval")
    }

    private var runTitle: String { isProduction ? "Run on Production" : "Run" }

    private func notice(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.12)))
    }
}

/// How AI clients start `runlet mcp`.
@MainActor
enum MCPSetup {
    /// The tool inside this copy of Runlet. Debug builds can show another app path
    /// (`RUNLET_DEBUG_APP_PATH`, e.g. /Applications/Runlet.app) so screenshots show no
    /// personal folders.
    static var toolPath: String {
        var app = Bundle.main.bundleURL.path
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["RUNLET_DEBUG_APP_PATH"], !path.isEmpty { app = path }
        #endif
        return (app as NSString).appendingPathComponent(CommandLineTool.bundledPath)
    }

    static var claudeCodeCommand: String {
        "claude mcp add --transport stdio --scope user runlet -- \(shellQuoted(toolPath)) mcp"
    }

    /// The `mcpServers` entry, written by hand to keep the usual key order (command, then args).
    static var configJSON: String {
        let command = MCPJSON.string(toolPath).serialized
        return """
        {
          "mcpServers": {
            "runlet": {
              "command": \(command),
              "args": ["mcp"]
            }
          }
        }
        """
    }

    private static func shellQuoted(_ path: String) -> String {
        path.contains(where: { " '\"$`\\".contains($0) }) ? "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" : path
    }
}

/// Settings ▸ AI Clients: the MCP server switch, connected clients, client setup, and the
/// approval rules.
struct AIClientsSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.mcp
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.settings.mcpServerEnabled }, set: { model.setMCPServerEnabled($0) })) {
                    Text("Allow AI clients to connect")
                    Text("AI clients such as Claude Code, Claude Desktop, and Cursor can list your targets and snippets, save snippets, and ask to run PHP. Every run waits for your approval in Runlet.")
                }
                .accessibilityIdentifier("settings-mcp-enabled")
                LabeledContent("Status") {
                    if let error = store.listenerError, model.settings.mcpServerEnabled {
                        Text(error).foregroundStyle(.red)
                    } else if store.isListening {
                        Label("Listening on a private socket on this Mac", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Off").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("MCP Server")
            } footer: {
                Text("Runlet listens on a Unix socket only you can open, never on the network. Clients start runlet mcp, which talks to this socket; if Runlet isn't running, it starts Runlet (starting never runs anything).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Connected Clients") {
                if store.connections.isEmpty {
                    Text("No AI client is connected.").foregroundStyle(.secondary)
                }
                ForEach(store.connections) { connection in
                    LabeledContent {
                        if connection.sandboxAllowed {
                            Button("Revoke") { model.revokeMCPAllowance(connection.id) }
                                .help("Ask again before every sandbox run from this client")
                        }
                    } label: {
                        Text(connection.displayName + (connection.client?.version.map { " " + $0 } ?? ""))
                        Text(clientDetail(connection))
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Claude Code").fontWeight(.semibold)
                    Text("Run this in a terminal (user scope: every project):").font(.caption).foregroundStyle(.secondary)
                    CopyableCode(text: MCPSetup.claudeCodeCommand, identifier: "mcp-claude-code-command")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Claude Desktop and Cursor").fontWeight(.semibold)
                    Text("Add this to Claude Desktop's claude_desktop_config.json (Settings ▸ Developer ▸ Edit Config) or Cursor's ~/.cursor/mcp.json, next to any servers already there:").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    CopyableCode(text: MCPSetup.configJSON, identifier: "mcp-client-config")
                }
            } header: {
                Text("Set Up a Client")
            } footer: {
                Text("The command is the runlet tool inside this copy of Runlet. If you move Runlet.app, update it. Other MCP clients take the same command and the argument mcp.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Approvals") {
                rule("hand.raised", "Every run_php asks here first, showing the client, the target, and all of the code. Declining, or no answer within 5 minutes, runs nothing.")
                rule("shippingbox", "Only the Laravel sandbox can be allowed for the rest of a client's session.")
                rule("exclamationmark.triangle", "Production targets always ask, with a warning; the 10-minute “don't ask again” never applies to AI clients.")
                rule("server.rack", "SSH hosts are never connected silently: the sheet says when approving connects, and hosts that need a password or a code must be logged in with Connect… first.")
                rule("doc.text", "Listing targets, reading snippets, and saving snippets run nothing. Approved runs appear in a tab named after the client.")
            }
        }
        .formStyle(.grouped)
    }

    private func clientDetail(_ connection: MCPConnection) -> String {
        var parts = ["Connected " + connection.connectedAt.formatted(.relative(presentation: .named))]
        parts.append(connection.callCount == 1 ? "1 request" : "\(connection.callCount) requests")
        if connection.sandboxAllowed { parts.append("sandbox runs allowed for this session") }
        return parts.joined(separator: " · ")
    }

    private func rule(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }
}

/// Monospaced text with a Copy button.
private struct CopyableCode: View {
    let text: String
    let identifier: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(copied ? "Copied" : "Copy") {
                Pasteboard.copy(text)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            .controlSize(.small)
            .accessibilityIdentifier(identifier + "-copy")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        .accessibilityIdentifier(identifier)
    }
}
