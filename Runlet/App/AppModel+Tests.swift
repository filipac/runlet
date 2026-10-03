import AppKit
import RunletCore
import RunletExecution

// MARK: - Tests group (N37, #40)

extension AppModel {
    /// The key `ProjectCommandsStore.launching` holds while a target's tests are being opened.
    static func testsLaunchKey(_ target: TargetRef) -> String { "tests:" + target.stableKey }

    /// The folder on this Mac where a target's test runner is checked and test files are picked:
    /// the sandbox install or a local project's folder. nil for Docker profiles and SSH hosts,
    /// which choose on the target as the tests start.
    func testsLocalDirectory(for target: TargetRef) -> String? {
        switch target {
        case .sandbox: sandbox?.installURL.path
        case .local(let id): library.localProject(id)?.path
        case .docker, .ssh: nil
        }
    }

    /// The project's directory on a Docker or SSH target (an SSH profile's container step's,
    /// when it has one), which the File… prompt's relative paths start from.
    func testsWorkingDirectory(for target: TargetRef) -> String? {
        switch target {
        case .docker(let id): library.dockerProfile(id)?.workingDirectory
        case .ssh(let id): library.sshProfile(id).map { $0.container?.workingDirectory ?? $0.remoteDirectory }
        case .sandbox, .local: nil
        }
    }

    /// The runner a local project or the sandbox uses (checked on this Mac from its files, with
    /// no PHP run); nil for Docker and SSH targets, or when there are no tests to run.
    func testDetection(for target: TargetRef) -> ProjectTests.Detection? {
        testsLocalDirectory(for: target).flatMap { ProjectTests.detect(projectDirectory: $0) }
    }

    /// Whether the Commands pane shows the Tests group: for local projects and the sandbox when
    /// they have a runner and tests; for Docker profiles and SSH hosts always (the target
    /// chooses, and explains in the terminal when it has no runner).
    func offersTests(for target: TargetRef) -> Bool {
        switch target {
        case .sandbox, .local: testDetection(for: target) != nil
        case .docker, .ssh: true
        }
    }

    /// Runs the target's tests (all, a file, or a `--filter`) in a terminal tab. Resolved like a
    /// project command when it starts: the Docker container again (never a different one
    /// without asking), and an SSH host is reached only now, through the shared connection (a
    /// password or 2FA host must be connected with Connect… first). Call only from an explicit
    /// user action: opening, importing, or restoring code never runs tests. Production targets
    /// are refused (`ProjectTests.isAllowed(on:)`): the Tests group is disabled there, and this
    /// checks again.
    func runTests(_ action: ProjectTests.Action, in tab: TabModel, window: WindowModel? = nil) {
        let target = tab.target
        guard ProjectTests.isAllowed(on: library.environment(for: target)) else {
            projectCommands.notice = ProjectCommandNotice(commandName: "Tests", kind: .failed(ProjectTests.productionReason))
            return
        }
        let store = projectCommands
        let key = Self.testsLaunchKey(target)
        guard !store.launching.contains(key) else { return }
        let window = window ?? self.window(containing: tab.id)
        store.launching.insert(key)
        Task {
            defer { store.launching.remove(key) }
            do {
                let snapshot = try await self.snapshot(for: tab)
                // The tab may have switched targets, or the target been marked production,
                // while it resolved.
                guard tab.target == target else { return }
                guard ProjectTests.isAllowed(on: self.library.environment(for: target)) else {
                    throw ExecutionError.invalidTarget(ProjectTests.productionReason)
                }
                var request = try ProjectTests.terminalRequest(target: snapshot, action: action, runner: self.testDetection(for: target)?.runner, place: self.replPlace(for: target), dockerExecutable: self.docker?.executable, ssh: self.sshClient)
                // `ssh` itself starts in the profile's local folder, like Shell on Host.
                if target.isSSH { request.workingDirectory = self.library.localFolder(for: target) }
                if self.openTerminal != nil {
                    store.notice = nil
                    self.openTerminal(request, in: window)
                } else {
                    let text = ProjectCommandLauncher.shellText(request)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    store.notice = ProjectCommandNotice(commandName: "Tests", kind: .copied(text))
                }
            } catch {
                // An ambiguous or recreated container already opened the choice sheet.
                guard self.containerChoice == nil else { return }
                store.notice = ProjectCommandNotice(commandName: "Tests", kind: .failed("\(error)"))
            }
        }
    }

    /// Run a File… on a local project or the sandbox: an open panel limited to the project's
    /// folder (starting in its first test folder), then the file relative to the project.
    func chooseTestFile(in tab: TabModel, window: WindowModel? = nil) {
        guard let directory = testsLocalDirectory(for: tab.target) else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let start = testDetection(for: tab.target)?.testLocations.first { !$0.contains("*") && !$0.hasSuffix(".php") }
        let panel = NSOpenPanel()
        panel.title = "Run a Test File"
        panel.message = "Choose a test file in \(root.lastPathComponent). It runs with \(testDetection(for: tab.target)?.runner.displayName ?? "the project's test runner")."
        panel.prompt = "Run"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = start.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        let delegate = TestFilePanelDelegate(root: root)
        panel.delegate = delegate
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak tab] response in
            _ = delegate // kept alive until the panel closes
            guard response == .OK, let self, let tab, let url = panel.url else { return }
            guard let path = ProjectTests.relativePath(of: url, in: root) else {
                self.projectCommands.notice = ProjectCommandNotice(commandName: "Tests", kind: .failed("\(url.lastPathComponent) isn't in \(root.lastPathComponent). Choose a test file inside the project's folder."))
                return
            }
            self.runTests(.file(path), in: tab, window: window)
        }
        if let host = (window ?? self.window(containing: tab.id))?.nsWindow, host.isVisible, host.attachedSheet == nil {
            panel.beginSheetModal(for: host, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }
}

/// Keeps the Run a File… panel inside the project's folder: files and folders elsewhere are
/// dimmed, and a path typed with ⌘⇧G that leads out of it is refused.
private final class TestFilePanelDelegate: NSObject, NSOpenSavePanelDelegate {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    private func isInside(_ url: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        isInside(url)
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard ProjectTests.relativePath(of: url, in: root) != nil else {
            throw NSError(domain: "Runlet", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a file inside \(root.lastPathComponent)."])
        }
    }
}
