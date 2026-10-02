import AppKit
import RunletCore
import RunletExecution

/// Terminal panel: per-window tabs running the user's own login shell (or a direct
/// executable such as `docker exec -it …`). Other features open tabs through
/// `AppModel.openTerminal` (a `TerminalRequest`); menu commands use `toggleTerminal()` and
/// `newTerminal()`.
extension AppModel {
    /// Wires `openTerminal` and the quit hook (idempotent; called by each window).
    func installTerminalSupport() {
        guard openTerminal == nil else { return }
        openTerminal = { [weak self] request in self?.openTerminal(request, in: nil) }
        // Quitting hangs up every shell (like closing Terminal windows).
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                for window in self?.windows ?? [] { window.terminals.hangUpAll() }
            }
        }
    }

    /// Initializes a window's panel visibility from the remembered setting (once).
    func prepareTerminalPanel(for window: WindowModel) {
        installTerminalSupport()
        if window.terminals.isVisible == nil { window.terminals.isVisible = settings.terminalVisible }
    }

    func isTerminalVisible(in window: WindowModel) -> Bool {
        window.terminals.isVisible ?? settings.terminalVisible
    }

    /// Shows or hides the window's panel and remembers the choice for new windows. Showing an
    /// empty panel starts a shell; showing moves focus into the terminal.
    func setTerminalVisible(_ visible: Bool, in window: WindowModel) {
        window.terminals.isVisible = visible
        if settings.terminalVisible != visible { settings.terminalVisible = visible }
        guard visible else { return }
        if window.terminals.sessions.isEmpty {
            newTerminal(in: window)
        } else {
            window.terminals.focusRequest += 1
        }
    }

    /// Shows or hides the terminal panel of the active window (suggested shortcut ⌃`).
    func toggleTerminal() {
        guard let window = activeWindow else { return }
        setTerminalVisible(!isTerminalVisible(in: window), in: window)
    }

    /// Opens a new shell tab in the active window, in the selected tab's target directory
    /// (suggested shortcut ⌃⇧`).
    func newTerminal() {
        guard let window = activeWindow else { return }
        newTerminal(in: window)
    }

    func newTerminal(in window: WindowModel, focus: Bool = true) {
        let place = terminalPlace(for: window.selectedTab)
        let shellName = (TerminalLaunch.userShell() as NSString).lastPathComponent
        openTerminal(TerminalRequest(title: place.name ?? shellName, workingDirectory: place.directory), in: window, focus: focus)
    }

    /// Opens `request` as a new tab in `window` (default: the active window) and shows the panel.
    func openTerminal(_ request: TerminalRequest, in window: WindowModel?, focus: Bool = true) {
        guard let window = window ?? activeWindow else { return }
        var request = request
        if request.workingDirectory == nil { request.workingDirectory = terminalPlace(for: window.selectedTab).directory }
        let home = NSHomeDirectory()
        let launch = Result {
            try TerminalLaunch.make(
                for: request,
                shell: TerminalLaunch.userShell(),
                baseEnvironment: ProcessInfo.processInfo.environment,
                home: home,
                language: TerminalLaunch.defaultLanguage(),
                termProgramVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            )
        }
        let session = TerminalSession(request: request, launch: launch)
        // The panel re-applies these from its view; doing it now gives the right column
        // count even if the process starts before the panel lays the view out.
        session.apply(theme: TerminalTheme(isDark: prefersDarkAppearance), fontSize: settings.fontSize, optionAsMeta: settings.terminalOptionAsMeta)
        session.onExit = { [weak self, weak window] session, code in
            // A clean exit closes the tab (like Terminal's "close if the shell exited
            // cleanly"); otherwise the tab stays so its output can be read.
            guard code == 0, let self, let window else { return }
            self.removeTerminal(session.id, in: window)
        }
        window.terminals.add(session, focus: focus)
        if window.terminals.isVisible != true {
            window.terminals.isVisible = true
            if !settings.terminalVisible { settings.terminalVisible = true }
        }
    }

    /// Closes a terminal tab. Asks first only when a program other than the session's own
    /// shell is running in the foreground (e.g. `vim`, a server); an idle shell just ends.
    func closeTerminal(_ id: UUID, in window: WindowModel) {
        guard let session = window.terminals.sessions.first(where: { $0.id == id }) else { return }
        if let job = session.foregroundJobName {
            let alert = NSAlert()
            alert.messageText = "Close this terminal?"
            alert.informativeText = "“\(job)” is still running in “\(session.title)”. Closing the terminal ends it."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        session.terminate()
        removeTerminal(id, in: window)
    }

    private func removeTerminal(_ id: UUID, in window: WindowModel) {
        let wasLast = window.terminals.remove(id)
        // Closing the last tab hides the panel (showing it again starts a new shell).
        if wasLast { setTerminalVisible(false, in: window) }
    }

    /// Ends every shell of a closing window.
    func terminateTerminals(in window: WindowModel) {
        window.terminals.terminateAll()
    }

    /// Opens a shell inside the Docker profile's container. The container is resolved like a
    /// run (`snapshot(for:)`): ambiguity or a recreated container asks the user, and nothing
    /// else is ever substituted silently.
    func openContainerShell(for tab: TabModel, in window: WindowModel) {
        guard case .docker(let id) = tab.target, let profile = library.dockerProfile(id) else { return }
        Task {
            do {
                let snapshot = try await snapshot(for: tab)
                guard let docker, let container = snapshot.containerId else {
                    throw TargetResolutionError(description: "The Docker CLI was not found. Install Docker or set its path in Settings.")
                }
                var argv = [docker.executable, "exec", "-it"]
                if let user = snapshot.user, !user.isEmpty { argv += ["--user", user] }
                argv += ["-w", snapshot.workingDirectory, container, "sh", "-c", "command -v bash >/dev/null && exec bash || exec sh"]
                let title = "\(profile.name) · \(snapshot.containerName ?? String(container.prefix(12)))"
                openTerminal(TerminalRequest(title: title, workingDirectory: profile.localSourcePath, executable: argv), in: window)
            } catch {
                // An ambiguous or recreated container already opened the choice sheet.
                if containerChoice == nil {
                    alert = AppAlert(title: "Could not open a shell in \(profile.name)", message: "\(error)")
                }
            }
        }
    }

    private var prefersDarkAppearance: Bool {
        switch settings.appearance {
        case .dark: true
        case .light: false
        case .system: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    /// Where a new shell starts for a tab's target, and a name for its tab: the project
    /// directory, the sandbox install, or a Docker profile's mapped source (else home).
    func terminalPlace(for tab: TabModel?) -> (directory: String, name: String?) {
        let home = NSHomeDirectory()
        guard let tab else { return (home, nil) }
        func existing(_ path: String?) -> String? {
            guard let path, !path.isEmpty else { return nil }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue ? path : nil
        }
        switch tab.target {
        case .sandbox:
            if let path = existing(sandbox?.installURL.path) { return (path, "Sandbox") }
        case .local(let id):
            if let project = library.localProject(id), let path = existing(project.path) { return (path, project.name) }
        case .docker(let id):
            if let profile = library.dockerProfile(id), let path = existing(profile.localSourcePath) { return (path, profile.name) }
        }
        return (home, nil)
    }
}
