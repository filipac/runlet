import AppKit
import RunletCore
import RunletExecution
import SwiftUI

/// The `runlet` tool inside this copy of Runlet, and where links to it are installed.
@MainActor
enum CommandLineToolSupport {
    static var tool: URL { Bundle.main.bundleURL.appendingPathComponent(CommandLineTool.bundledPath) }
    static var isBundled: Bool { FileManager.default.isExecutableFile(atPath: tool.path) }
    /// Run from a quarantined download, macOS moves the app to a random read-only location
    /// first; a link to it would break.
    static var isTranslocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

    /// Folders with a link to this copy of the tool: the usual two, plus `path`'s folders.
    static func installedLinks(path: String?) -> [URL] {
        var folders = CommandLineInstall.standardFolders()
        for entry in (path ?? "").split(separator: ":") {
            let folder = URL(fileURLWithPath: String(entry), isDirectory: true)
            if !folders.contains(where: { $0.standardizedFileURL.path == folder.standardizedFileURL.path }) { folders.append(folder) }
        }
        return folders.map(CommandLineInstall.link(in:)).filter { CommandLineInstall.status(of: $0, tool: tool) == .installed }
    }
}

/// Runlet ▸ Install Command-Line Tool…: one window, reused.
///
/// The window is sized by hand (#92). With `sizingOptions = [.preferredContentSize]`, AppKit
/// resized the window from inside its own layout pass whenever the content's height changed
/// (the shell's PATH arriving, a hint wrapping onto another line), which can mark the window for
/// another Update Constraints pass from within that pass: the loop AppKit ends with an
/// exception, i.e. a crash. Now the hosting controller adds no sizing constraints or preferred
/// size, the content reports its natural size, and the window follows it afterwards.
@MainActor
enum CommandLineToolWindow {
    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?

    static func show(model: AppModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: CommandLineToolView().environment(model))
        controller.sizingOptions = []
        let size = controller.sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(size)
        window.title = "Command-Line Tool"
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("command-line-tool-window")
        window.center()
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
                closeObserver = nil
                Self.window = nil
            }
        }
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
    }

    /// The content's natural size changed: resize the window to it, keeping its top edge. It
    /// happens after the current layout pass, and only for a change of a point or more, so a
    /// resize can't feed back into the layout that reported it.
    static func contentSizeChanged(_ size: CGSize) {
        DispatchQueue.main.async {
            guard let window, size.width > 0, size.height > 0 else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            guard abs(content.width - size.width) >= 1 || abs(content.height - size.height) >= 1 else { return }
            let resized = NSRect(x: content.minX, y: content.maxY - size.height, width: size.width, height: size.height)
            window.setFrame(window.frameRect(forContentRect: resized), display: true)
        }
    }
}

/// Explains the tool and installs a link to it in a folder the user picks. Nothing is written
/// anywhere else, and an existing file is never replaced (a link to another copy of Runlet
/// only after the user presses Replace).
struct CommandLineToolView: View {
    enum Choice: Hashable { case system, user, custom }

    @State private var choice: Choice = .system
    @State private var customFolder: URL?
    /// The user's login-shell PATH (loaded once), to say whether a folder is on it.
    @State private var shellPath: String?
    @State private var outcome: (text: String, failed: Bool)?
    /// Bumped after a change on disk so statuses are read again.
    @State private var revision = 0

    private let tool = CommandLineToolSupport.tool
    private let folders = CommandLineInstall.standardFolders()

    var body: some View {
        let _ = revision
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "apple.terminal")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("The runlet Command").font(.title3.weight(.semibold))
                    Text("Open folders, PHP files, and workspaces in Runlet from a terminal. It only opens them; nothing runs until you press Run.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            examples

            VStack(alignment: .leading, spacing: 8) {
                Text("Install a link to the command in:").font(.headline)
                Picker("Folder", selection: $choice) {
                    folderLabel(folders[0], detail: systemDetail).tag(Choice.system)
                    folderLabel(folders[1], detail: pathDetail(folders[1], noPassword: true)).tag(Choice.user)
                    customLabel.tag(Choice.custom)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .accessibilityIdentifier("cli-choice")
                if choice == .custom {
                    Button(customFolder == nil ? "Choose Folder…" : "Choose Another Folder…") { chooseFolder() }
                        .controlSize(.small)
                        .padding(.leading, 20)
                }
            }

            if let folder = selectedFolder {
                planText(for: folder)
            }
            problems

            if let outcome {
                Label(outcome.text, systemImage: outcome.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(outcome.failed ? Color.orange : Color.green)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("cli-outcome")
            }
            HStack(spacing: 8) {
                Spacer(minLength: 8)
                if let folder = selectedFolder, canRemove(folder) {
                    Button("Remove Link") { uninstall(folder) }
                        .accessibilityIdentifier("cli-uninstall")
                }
                Button("Done") { CommandLineToolWindow.close() }
                    .keyboardShortcut(.cancelAction)
                Button(installTitle) { if let folder = selectedFolder { install(folder) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canInstall)
                    .accessibilityIdentifier("cli-install")
            }
        }
        .padding(20)
        .frame(width: 560)
        // Its natural height, whatever the window's size; the window follows it (#92).
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { CommandLineToolWindow.contentSizeChanged($0) }
        .task {
            #if DEBUG
            // Checks install into a scratch folder only (never the user's PATH).
            if let folder = ProcessInfo.processInfo.environment["RUNLET_DEBUG_CLI_FOLDER"] {
                customFolder = URL(fileURLWithPath: folder, isDirectory: true)
                choice = .custom
            }
            #endif
            shellPath = await HostShellEnvironment.shared.environment()["PATH"]
        }
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: 3) {
            example("runlet .", "this folder as a project")
            example("runlet app/Models/User.php", "a file, saved back when you save")
            example("runlet -t sandbox scratch.php", "a file on a chosen target")
            example("runlet --help", "everything else")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func example(_ command: String, _ meaning: String) -> some View {
        HStack(spacing: 10) {
            Text(command).font(.system(.callout, design: .monospaced)).frame(width: 230, alignment: .leading)
            Text(meaning).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func folderLabel(_ folder: URL, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text((folder.path as NSString).abbreviatingWithTildeInPath).font(.system(.body, design: .monospaced))
                statusBadge(folder)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var customLabel: some View {
        if let customFolder {
            folderLabel(customFolder, detail: pathDetail(customFolder, noPassword: !CommandLineInstall.needsAdministrator(for: customFolder)))
        } else {
            Text("Another folder…")
        }
    }

    @ViewBuilder
    private func statusBadge(_ folder: URL) -> some View {
        switch CommandLineInstall.status(of: CommandLineInstall.link(in: folder), tool: tool) {
        case .installed: badge("Installed", .green)
        case .linkedElsewhere: badge("Another Runlet", .orange)
        case .blocked: badge("Something else is there", .red)
        case .notInstalled: EmptyView()
        }
    }

    private func badge(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.13)))
    }

    private var systemDetail: String {
        let password = CommandLineInstall.needsAdministrator(for: folders[0]) ? "macOS asks for an administrator password." : "No password needed."
        return "On every shell's PATH by default. " + password
    }

    private func pathDetail(_ folder: URL, noPassword: Bool) -> String {
        var detail = noPassword ? "No password needed. " : "macOS asks for an administrator password. "
        if let shellPath {
            detail += CommandLineInstall.isOnPath(folder, path: shellPath)
                ? "It's on your shell's PATH."
                : "It isn't on your shell's PATH yet; add this line to ~/.zprofile: \(CommandLineInstall.pathExport(for: folder))"
        }
        return detail
    }

    private var selectedFolder: URL? {
        switch choice {
        case .system: folders[0]
        case .user: folders[1]
        case .custom: customFolder
        }
    }

    private func status(_ folder: URL) -> CommandLineInstall.Status {
        CommandLineInstall.status(of: CommandLineInstall.link(in: folder), tool: tool)
    }

    @ViewBuilder
    private func planText(for folder: URL) -> some View {
        let link = CommandLineInstall.link(in: folder)
        let text: String = switch status(folder) {
        case .notInstalled: "Runlet will create a link: \(link.path) → \(tool.path)"
        case .installed: "\(link.path) already links to this copy of Runlet."
        case .linkedElsewhere(let other): "\(link.path) links to another copy of Runlet (\(other)). Replace makes it link to this one."
        case .blocked: "\(link.path) is a file that isn't Runlet's link. Runlet won't replace it: move it away or pick another folder."
        }
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("cli-plan")
    }

    @ViewBuilder
    private var problems: some View {
        if !CommandLineToolSupport.isBundled {
            Label("This build of Runlet has no command-line tool (\(tool.path) is missing).", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout)
        } else if CommandLineToolSupport.isTranslocated {
            Label("Move Runlet to the Applications folder and open it from there first: macOS is running it from a temporary location, and a link to it would break.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var installTitle: String {
        if let folder = selectedFolder, case .linkedElsewhere = status(folder) { return "Replace" }
        return "Install"
    }

    private var canInstall: Bool {
        guard CommandLineToolSupport.isBundled, !CommandLineToolSupport.isTranslocated, let folder = selectedFolder else { return false }
        switch status(folder) {
        case .notInstalled, .linkedElsewhere: return true
        case .installed, .blocked: return false
        }
    }

    private func canRemove(_ folder: URL) -> Bool {
        switch status(folder) {
        case .installed, .linkedElsewhere: true
        case .notInstalled, .blocked: false
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder for the runlet link. It should be on your shell's PATH."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        customFolder = url
        choice = .custom
    }

    private func install(_ folder: URL) {
        let link = CommandLineInstall.link(in: folder)
        let replacing = status(folder) != .notInstalled
        do {
            if CommandLineInstall.needsAdministrator(for: folder) {
                try runWithAdministrator(CommandLineInstall.administratorInstallScript(tool: tool, link: link))
            } else {
                try CommandLineInstall.install(tool: tool, at: link, replacing: replacing)
            }
            var text = "Installed \((link.path as NSString).abbreviatingWithTildeInPath). Open a new terminal window and try runlet --help."
            if let shellPath, !CommandLineInstall.isOnPath(folder, path: shellPath) {
                text += " Add \(CommandLineInstall.pathExport(for: folder)) to ~/.zprofile first."
            }
            outcome = (text, false)
        } catch AdministratorError.cancelled {
            outcome = nil
        } catch {
            outcome = ("Couldn't install: \(error.localizedDescription)", true)
        }
        revision += 1
    }

    private func uninstall(_ folder: URL) {
        let link = CommandLineInstall.link(in: folder)
        do {
            if CommandLineInstall.needsAdministrator(for: folder) {
                try runWithAdministrator(CommandLineInstall.administratorUninstallScript(link: link))
            } else {
                try CommandLineInstall.uninstall(link: link, tool: tool)
            }
            outcome = ("Removed \((link.path as NSString).abbreviatingWithTildeInPath).", false)
        } catch AdministratorError.cancelled {
            outcome = nil
        } catch {
            outcome = ("Couldn't remove the link: \(error.localizedDescription)", true)
        }
        revision += 1
    }

    enum AdministratorError: LocalizedError {
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: "Cancelled."
            case .failed(let message): message
            }
        }
    }

    /// Runs one of `CommandLineInstall`'s scripts; macOS asks for an administrator's password.
    private func runWithAdministrator(_ source: String) throws {
        var info: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw AdministratorError.failed("The installer script couldn't be prepared.") }
        script.executeAndReturnError(&info)
        guard let info else { return }
        if (info[NSAppleScript.errorNumber] as? Int) == -128 { throw AdministratorError.cancelled }
        throw AdministratorError.failed(info[NSAppleScript.errorMessage] as? String ?? "The installer failed.")
    }
}

/// Settings ▸ General ▸ Command-Line Tool.
struct CommandLineToolSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var installed: [URL] = []

    var body: some View {
        Section {
            LabeledContent {
                // Opened on the next turn of the run loop, not while Settings handles the click (#92).
                Button(installed.isEmpty ? "Install…" : "Manage…") { DispatchQueue.main.async { CommandLineToolWindow.show(model: model) } }
                    .accessibilityIdentifier("settings-cli-install")
            } label: {
                Text("runlet command")
                Text(installed.isEmpty ? "Not installed" : "Installed: " + installed.map { ($0.path as NSString).abbreviatingWithTildeInPath }.joined(separator: ", "))
            }
        } header: {
            Text("Command-Line Tool")
        } footer: {
            Text("In a terminal, runlet . opens the folder as a project and runlet file.php opens a file. It never runs code.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            let path = await HostShellEnvironment.shared.environment()["PATH"]
            installed = CommandLineToolSupport.installedLinks(path: path)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            // Back from the installer window: show what it changed.
            Task { installed = CommandLineToolSupport.installedLinks(path: await HostShellEnvironment.shared.environment()["PATH"]) }
        }
    }
}
