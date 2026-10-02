import AppKit
import Observation
import RunletCore
import RunletExecution

/// One `runlet mcp` process connected to the MCP socket: an AI client's session.
@MainActor
@Observable
final class MCPConnection: Identifiable {
    let id: UUID
    let connectedAt = Date()
    var helperPID: pid_t?
    /// The client as it last described itself (self-reported; shown, never trusted).
    var client: MCPClientInfo?
    /// "Allow for this session": sandbox runs from this connection run without a sheet until
    /// it closes or Runlet quits. Only the user's tick on a sandbox sheet sets it.
    var sandboxAllowed = false
    var callCount = 0
    /// The tab its runs use, and the code last put there (reused only while unchanged).
    @ObservationIgnored var tabId: UUID?
    @ObservationIgnored var tabCode: String?

    init(id: UUID, helperPID: pid_t?) {
        self.id = id
        self.helperPID = helperPID
    }

    var displayName: String { (client ?? .unknown).displayName }
}

/// A run an AI client asked for, waiting for the user's answer on the approval sheet.
struct MCPApprovalRequest: Identifiable, Equatable {
    let id = UUID()
    let connectionId: UUID
    let callId: Int
    let clientName: String
    let target: TargetRef
    let targetName: String
    let environment: TargetEnvironment
    /// Where it runs: a folder, a container, or `user@host:directory`.
    let destination: String
    let code: String
    let prompt: MCPApprovalPolicy.Prompt
    /// For SSH targets: the host the run connects to ("deploy@app-prod").
    let sshHost: String?
    /// The window whose sheet asks, and when the request expires (set when shown).
    var windowId: UUID?
    var expiresAt: Date?
    var lineCount: Int { code.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").count }
}

/// The latest MCP run's report (kept while it runs, for `get_last_output`).
@MainActor
final class MCPRunBox {
    var report: MCPRunReport

    init(_ report: MCPRunReport) {
        self.report = report
    }
}

/// The MCP server's state in the app (#43): the socket listener, connected clients, the
/// approval queue, and the last run.
@MainActor
@Observable
final class MCPStore {
    var connections: [MCPConnection] = []
    /// Requests waiting for an answer, oldest first; `presented` is the one on screen.
    var queue: [MCPApprovalRequest] = []
    var presented: MCPApprovalRequest?
    var isListening = false
    var listenerError: String?
    /// Briefly true while a sheet that didn't come up is shown again (see `ensureMCPSheetShown`).
    var sheetSuppressed = false
    @ObservationIgnored var listener: MCPSocketListener?
    /// When the last approval sheet went away: the next one waits for its animation.
    @ObservationIgnored var lastDismissal = Date.distantPast
    @ObservationIgnored var lastRun: MCPRunBox?
    @ObservationIgnored var timeoutWork: DispatchWorkItem?

    private static var stores: [ObjectIdentifier: MCPStore] = [:]

    static func shared(for model: AppModel) -> MCPStore {
        let key = ObjectIdentifier(model)
        if let store = stores[key] { return store }
        let store = MCPStore()
        stores[key] = store
        return store
    }

    func connection(_ id: UUID) -> MCPConnection? { connections.first { $0.id == id } }
}

extension AppModel {
    var mcp: MCPStore { MCPStore.shared(for: self) }

    /// The socket `runlet mcp` connects to (honors RUNLET_DATA_DIR).
    var mcpSocketPath: String { MCPSocketPaths.socketPath(for: paths) }

    // MARK: Listening

    /// Settings ▸ AI Clients ▸ Allow AI clients to connect.
    func setMCPServerEnabled(_ enabled: Bool) {
        settings.mcpServerEnabled = enabled
        if enabled { startMCPServer() } else { stopMCPServer() }
    }

    func startMCPServerIfEnabled() {
        if settings.mcpServerEnabled { startMCPServer() }
    }

    func startMCPServer() {
        guard mcp.listener == nil else { return }
        let listener = MCPSocketListener(path: mcpSocketPath, events: MCPSocketListener.Events(
            connected: { id, pid in
                DispatchQueue.main.async { MainActor.assumeIsolated { AppDelegate.model?.mcpConnected(id, pid: pid) } }
            },
            message: { id, message in
                DispatchQueue.main.async { MainActor.assumeIsolated { AppDelegate.model?.mcpReceived(message, from: id) } }
            },
            disconnected: { id in
                DispatchQueue.main.async { MainActor.assumeIsolated { AppDelegate.model?.mcpDisconnected(id) } }
            }
        ))
        do {
            try listener.start()
            mcp.listener = listener
            mcp.isListening = true
            mcp.listenerError = nil
        } catch {
            mcp.isListening = false
            mcp.listenerError = "\(error)"
        }
    }

    /// Stops listening: clients are disconnected and waiting requests withdrawn (nothing runs).
    func stopMCPServer() {
        mcp.listener?.stop()
        mcp.listener = nil
        mcp.isListening = false
        for connection in mcp.connections { mcpDisconnected(connection.id) }
    }

    private func mcpConnected(_ id: UUID, pid: pid_t?) {
        guard mcp.connection(id) == nil else { return }
        mcp.connections.append(MCPConnection(id: id, helperPID: pid))
    }

    /// A client went away: its waiting requests are withdrawn and its session allowance ends.
    /// Runs it started finish in their tabs.
    private func mcpDisconnected(_ id: UUID) {
        mcp.connections.removeAll { $0.id == id }
        mcp.queue.removeAll { $0.connectionId == id }
        if mcp.presented?.connectionId == id { dismissMCPApproval() }
    }

    /// Revokes a connection's "Allow for this session" (Settings ▸ AI Clients).
    func revokeMCPAllowance(_ id: UUID) {
        mcp.connection(id)?.sandboxAllowed = false
    }

    private func mcpSend(_ message: MCPBridge.AppMessage, to id: UUID) {
        mcp.listener?.send(message, to: id)
    }

    private func mcpReply(_ result: MCPToolResult, call: Int, to id: UUID) {
        mcpSend(.result(id: call, result: result), to: id)
    }

    private func mcpReceived(_ message: MCPBridge.ClientMessage, from id: UUID) {
        guard let connection = mcp.connection(id) else { return }
        switch message {
        case .hello(let version, let pid):
            connection.helperPID = connection.helperPID ?? pid
            if version != MCPBridge.version {
                mcpSend(.refused("This runlet tool (bridge \(version)) doesn't match the running Runlet (bridge \(MCPBridge.version)). Use the runlet inside the Runlet.app that is running."), to: id)
                mcp.listener?.disconnect(id)
                return
            }
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            mcpSend(.welcome(bridgeVersion: MCPBridge.version, appVersion: version), to: id)
        case .client(let client):
            connection.client = client
        case .call(let callId, let client, let call):
            connection.client = client
            connection.callCount += 1
            handleMCPCall(call, id: callId, connection: connection)
        case .cancel(let callId):
            // Withdraws a request still waiting for an answer; a started run goes on in its tab.
            mcp.queue.removeAll { $0.connectionId == id && $0.callId == callId }
            if let presented = mcp.presented, presented.connectionId == id, presented.callId == callId { dismissMCPApproval() }
        }
    }

    // MARK: Tools

    private func handleMCPCall(_ call: MCPToolCall, id callId: Int, connection: MCPConnection) {
        switch call {
        case .listTargets:
            refreshSSHStatuses()
            let json = MCPCatalog.targets(library, sandbox: MCPCatalog.SandboxInfo(label: targetLabel(.sandbox), status: mcpSandboxStatus), sshState: mcpSSHState)
            mcpReply(.json(json), call: callId, to: connection.id)
        case .listSnippets(let target, let query):
            mcpReply(mcpListSnippets(target: target, query: query), call: callId, to: connection.id)
        case .getSnippet(let snippetId):
            mcpReply(mcpGetSnippet(snippetId), call: callId, to: connection.id)
        case .addSnippet(let label, let code, let target):
            mcpReply(mcpAddSnippet(label: label, code: code, target: target), call: callId, to: connection.id)
        case .getLastOutput:
            guard let last = mcp.lastRun else {
                return mcpReply(.error("No run_php run yet since Runlet started."), call: callId, to: connection.id)
            }
            var result = last.report.toolResult()
            // Reading output is not a failed call, even when the run failed.
            result.isError = false
            mcpReply(result, call: callId, to: connection.id)
        case .runPHP(let query, let code):
            requestMCPRun(target: query, code: code, call: callId, connection: connection)
        }
    }

    private var mcpSandboxStatus: String? {
        switch sandboxStatus {
        case .ready: nil
        case .checking: "starting"
        case .needsImage(let image): "needs the \(image) image (the user can download it in Runlet)"
        case .unavailable(let reason): "unavailable: \(reason)"
        }
    }

    /// The local state of an SSH profile's shared connection (never contacts the server).
    func mcpSSHState(_ profile: SSHProfile) -> MCPApprovalPolicy.SSHState {
        switch refreshSSHStatus(profile.id) {
        case .connected: .connected
        case .disconnected, .expired: profile.authentication == .interactive ? .needsLogin : .willConnect
        }
    }

    /// A target name from a client, resolved like `runlet --target` (or why it can't be).
    private enum MCPResolution {
        case success(TargetRef)
        case failure(MCPToolResult)
    }

    private func mcpResolve(_ query: String) -> MCPResolution {
        let match = library.target(matching: query)
        if case .found(let target) = match { return .success(target) }
        return .failure(.error(MCPCatalog.targetProblem(query, match) ?? "Unknown target."))
    }

    private func mcpListSnippets(target query: String?, query search: String?) -> MCPToolResult {
        var target: TargetRef?
        if let query {
            switch mcpResolve(query) {
            case .success(let resolved): target = resolved
            case .failure(let error): return error
            }
        }
        var entries: [MCPJSON] = []
        for snippet in snippets {
            if let target, let own = snippet.target, own != target { continue }
            if let search, !matchesSearch(search, in: snippet.label, snippet.code) { continue }
            entries.append([
                "id": .string(snippet.id.uuidString),
                "label": .string(snippet.label),
                "kind": "personal",
                "target": snippet.target.map { .string(library.selector(for: validTarget($0))) } ?? "any",
                "preview": .string(MCPCatalog.preview(snippet.code)),
            ])
        }
        if let target {
            refreshProjectSnippets(for: target)
            for snippet in projectSnippets(for: target) {
                if let search, !matchesSearch(search, in: snippet.label, snippet.description ?? "", snippet.code) { continue }
                var entry: [String: MCPJSON] = [
                    "id": .string(MCPCatalog.projectSnippetID(target: target, fileName: snippet.fileURL.lastPathComponent)),
                    "label": .string(snippet.label),
                    "kind": "project",
                    "target": .string(library.selector(for: target)),
                    "preview": .string(MCPCatalog.preview(snippet.code)),
                ]
                if let description = snippet.description { entry["description"] = .string(description) }
                entries.append(.object(entry))
            }
        }
        return .json(["snippets": .array(entries)])
    }

    private func mcpGetSnippet(_ id: String) -> MCPToolResult {
        if let parsed = MCPCatalog.parseProjectSnippetID(id),
           let target = allTargets.first(where: { $0.stableKey == parsed.targetKey }) {
            refreshProjectSnippets(for: target)
            if let snippet = projectSnippets(for: target).first(where: { $0.fileURL.lastPathComponent == parsed.fileName }) {
                var object: [String: MCPJSON] = ["id": .string(id), "label": .string(snippet.label), "kind": "project", "target": .string(library.selector(for: target)), "code": .string(snippet.code)]
                if let description = snippet.description { object["description"] = .string(description) }
                return .json(.object(object))
            }
        }
        let personal = snippets.first { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }
            ?? { () -> Snippet? in
                let named = snippets.filter { $0.label.caseInsensitiveCompare(id) == .orderedSame }
                return named.count == 1 ? named[0] : nil
            }()
        guard let snippet = personal else { return .error("No snippet with the id “\(id)”. Use list_snippets for ids.") }
        return .json([
            "id": .string(snippet.id.uuidString),
            "label": .string(snippet.label),
            "kind": "personal",
            "target": snippet.target.map { .string(library.selector(for: validTarget($0))) } ?? "any",
            "code": .string(snippet.code),
        ])
    }

    private func mcpAddSnippet(label: String, code: String, target query: String?) -> MCPToolResult {
        var target: TargetRef?
        if let query {
            switch mcpResolve(query) {
            case .success(let resolved): target = resolved
            case .failure(let error): return error
            }
        }
        let snippet = saveSnippet(label: label, code: code, target: target)
        return .json([
            "id": .string(snippet.id.uuidString),
            "label": .string(snippet.label),
            "target": target.map { .string(library.selector(for: $0)) } ?? "any",
            "saved": "Saved in Runlet's Snippets. Nothing ran.",
        ])
    }

    /// Every saved target, sandbox first.
    private var allTargets: [TargetRef] {
        [.sandbox] + library.localProjects.map { .local($0.id) } + library.dockerProfiles.map { .docker($0.id) } + library.sshProfiles.map { .ssh($0.id) }
    }

    // MARK: Runs and approvals

    /// The approval situation of `target` for `connection`, as of now.
    private func mcpSituation(_ target: TargetRef, connection: MCPConnection) -> MCPApprovalPolicy.Situation {
        var ssh: MCPApprovalPolicy.SSHState?
        if case .ssh(let id) = target, let profile = library.sshProfile(id) { ssh = mcpSSHState(profile) }
        var grace = productionGuard.grace
        let graceActive = !grace.needsConfirmation(.run, on: target, environment: library.environment(for: target))
        return MCPApprovalPolicy.Situation(target: target, environment: library.environment(for: target), ssh: ssh, sandboxAllowedForSession: connection.sandboxAllowed, productionGraceActive: graceActive)
    }

    private func requestMCPRun(target query: String, code: String, call: Int, connection: MCPConnection) {
        let target: TargetRef
        switch mcpResolve(query) {
        case .success(let resolved): target = resolved
        case .failure(let error): return mcpReply(error, call: call, to: connection.id)
        }
        switch MCPApprovalPolicy.decide(mcpSituation(target, connection: connection)) {
        case .refuse(let reason):
            mcpReply(.error(reason + " Nothing ran."), call: call, to: connection.id)
        case .run:
            startMCPRun(target: target, code: code, call: call, connection: connection, how: "allowed for this session")
        case .ask(let prompt):
            let waiting = mcp.queue.filter { $0.connectionId == connection.id }.count + (mcp.presented?.connectionId == connection.id ? 1 : 0)
            guard waiting < MCPApprovalPolicy.maxWaitingPerConnection else {
                return mcpReply(.error("\(waiting) runs from this client are already waiting for the user's answer in Runlet. Wait for those first."), call: call, to: connection.id)
            }
            let request = MCPApprovalRequest(
                connectionId: connection.id,
                callId: call,
                clientName: connection.displayName,
                target: target,
                targetName: targetLabel(target),
                environment: library.environment(for: target),
                destination: productionDestination(target),
                code: code,
                prompt: prompt,
                sshHost: { if case .ssh(let id) = target { return library.sshProfile(id)?.destinationLabel } else { return nil } }()
            )
            mcp.queue.append(request)
            mcpSend(.status(id: call, message: "Waiting for the user to approve the run in Runlet"), to: connection.id)
            presentNextMCPApproval()
        }
    }

    /// Shows the oldest waiting request on a window without another sheet, brought forward.
    private func presentNextMCPApproval() {
        guard mcp.presented == nil, !mcp.queue.isEmpty else { return }
        // A sheet asked for while the previous one is still animating away never appears.
        let wait = 0.6 - Date().timeIntervalSince(mcp.lastDismissal)
        if wait > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                MainActor.assumeIsolated { self?.presentNextMCPApproval() }
            }
            return
        }
        var request = mcp.queue.removeFirst()
        guard let connection = mcp.connection(request.connectionId) else { return presentNextMCPApproval() }
        let window = mcpWindow(for: connection)
        request.windowId = window.id
        let timeout = mcpApprovalTimeout
        request.expiresAt = Date().addingTimeInterval(timeout)
        mcp.presented = request
        bringForwardForApproval(window)
        scheduleMCPSheetCheck(request.id)
        // No answer in time: withdrawn, and the client hears so.
        mcp.timeoutWork?.cancel()
        let id = request.id
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let presented = self.mcp.presented, presented.id == id else { return }
                let wait = timeout >= 120 ? "\(Int(timeout / 60)) minutes" : "\(Int(timeout)) seconds"
                self.mcpReply(.error("The user didn't answer in Runlet within \(wait), so the request expired. Nothing ran."), call: presented.callId, to: presented.connectionId)
                self.dismissMCPApproval()
            }
        }
        mcp.timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    /// How long a sheet waits for an answer. Debug builds: `RUNLET_DEBUG_MCP_APPROVAL_TIMEOUT`
    /// (seconds) shortens it for the end-to-end check.
    private var mcpApprovalTimeout: TimeInterval {
        #if DEBUG
        if let seconds = ProcessInfo.processInfo.environment["RUNLET_DEBUG_MCP_APPROVAL_TIMEOUT"].flatMap(TimeInterval.init), seconds > 0 { return seconds }
        #endif
        return MCPApprovalPolicy.timeout
    }

    /// Whether the presented request's sheet is attached to its window (Debug steps wait for it).
    var mcpSheetAttached: Bool {
        guard let presented = mcp.presented, !mcp.sheetSuppressed, let window = presented.windowId.flatMap(self.window(_:)) else { return false }
        return window.nsWindow?.attachedSheet != nil
    }

    private func scheduleMCPSheetCheck(_ id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.ensureMCPSheetShown(id) }
        }
    }

    /// Keeps the presented request on screen while it waits: when SwiftUI didn't attach its
    /// sheet (another sheet was coming or going), shows it again; when its window closed,
    /// moves it to another window. A request never waits unseen.
    private func ensureMCPSheetShown(_ id: UUID) {
        guard var presented = mcp.presented, presented.id == id else { return }
        guard let window = presented.windowId.flatMap(self.window(_:)) else {
            // Its window closed: ask in another one.
            if let connection = mcp.connection(presented.connectionId) {
                let other = mcpWindow(for: connection)
                presented.windowId = other.id
                mcp.presented = presented
                bringForwardForApproval(other)
            }
            return scheduleMCPSheetCheck(id)
        }
        // Not on screen yet (a new window), or showing a sheet: look again later.
        guard let nsWindow = window.nsWindow, nsWindow.isVisible, nsWindow.attachedSheet == nil else { return scheduleMCPSheetCheck(id) }
        mcp.sheetSuppressed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mcp.sheetSuppressed = false
                self.scheduleMCPSheetCheck(id)
            }
        }
    }

    /// The window for a connection's sheet: the one with its tab, else the active one, else
    /// any without a sheet; a new window when every window is busy with another sheet.
    private func mcpWindow(for connection: MCPConnection) -> WindowModel {
        let preferred = [connection.tabId.flatMap { window(containing: $0) }, activeWindow].compactMap { $0 }
        let free = (preferred + windows).first { window in
            guard let nsWindow = window.nsWindow else { return false }
            return nsWindow.attachedSheet == nil && nsWindow.isVisible
        }
        if let free { return free }
        let window = makeWindow()
        openWindowAction?(window.id)
        return window
    }

    private func bringForwardForApproval(_ window: WindowModel) {
        activeWindowId = window.id
        #if DEBUG
        // Screenshot runs keep Runlet invisible and the user's keyboard where it is.
        if DebugSteps.isGhosted { return }
        #endif
        if window.nsWindow?.isMiniaturized == true { window.nsWindow?.deminiaturize(nil) }
        NSApp.activate()
        window.nsWindow?.makeKeyAndOrderFront(nil)
        NSApp.requestUserAttention(.criticalRequest)
    }

    private func dismissMCPApproval() {
        mcp.timeoutWork?.cancel()
        mcp.timeoutWork = nil
        mcp.presented = nil
        mcp.sheetSuppressed = false
        mcp.lastDismissal = Date()
        presentNextMCPApproval()
    }

    /// Cancel on the sheet (or Esc): the client hears the user declined; nothing runs.
    func declineMCPRun(_ request: MCPApprovalRequest) {
        guard mcp.presented?.id == request.id else { return }
        mcpReply(.error("The user declined to run this code in Runlet. Nothing ran."), call: request.callId, to: request.connectionId)
        dismissMCPApproval()
    }

    /// Run on the sheet. Runs exactly the code and target shown, after checking that the
    /// target still is what the sheet described. `allowSession` only counts for the sandbox.
    func approveMCPRun(_ request: MCPApprovalRequest, allowSession: Bool) {
        guard mcp.presented?.id == request.id else { return }
        dismissMCPApproval()
        guard let connection = mcp.connection(request.connectionId) else { return }
        // Edited or removed while the sheet was up (or the SSH login ended): ask again instead.
        let now = MCPApprovalPolicy.decide(mcpSituation(request.target, connection: connection))
        let stillValid = validTarget(request.target) == request.target && library.environment(for: request.target) == request.environment
        guard stillValid, now == .ask(request.prompt) || now == .run else {
            return mcpReply(.error("The target changed while the request waited for approval, so nothing ran. Try again."), call: request.callId, to: request.connectionId)
        }
        if allowSession, request.prompt.offersSessionAllowance, request.target == .sandbox {
            connection.sandboxAllowed = true
        }
        startMCPRun(target: request.target, code: request.code, call: request.callId, connection: connection, how: allowSession && request.target == .sandbox ? "approved, and allowed for this session" : "approved", windowId: request.windowId)
    }

    /// Runs approved code in the connection's tab (new, or its previous one when unchanged)
    /// and answers the call when the run ends.
    private func startMCPRun(target: TargetRef, code: String, call: Int, connection: MCPConnection, how: String, windowId: UUID? = nil) {
        let tab = mcpTab(for: connection, target: target, code: code, windowId: windowId)
        let report = MCPRunBox(MCPRunReport(clientName: connection.displayName, tabTitle: tab.title, targetLabel: targetLabel(target)))
        mcp.lastRun = report
        let connectionId = connection.id
        let client = connection.displayName
        mcpSend(.status(id: call, message: "Running on \(targetLabel(target)) in Runlet"), to: connectionId)
        startRun(tab, code: code, selection: nil, observer: RunObserver(
            started: { request in
                report.report.targetLabel = request.target.label
                tab.note("Requested by \(client) over MCP; \(how).")
            },
            event: { kind in report.report.apply(kind) },
            failed: { message in report.report.failBeforeLaunch(message) },
            ended: { [weak self] in
                self?.mcpReply(report.report.toolResult(), call: call, to: connectionId)
            }
        ))
    }

    private func mcpTab(for connection: MCPConnection, target: TargetRef, code: String, windowId: UUID?) -> TabModel {
        let title = connection.displayName
        if let id = connection.tabId, let window = window(containing: id), let tab = window.tabs.first(where: { $0.id == id }),
           !tab.isRunning, (tab.editorIfLoaded?.text ?? tab.code) == connection.tabCode {
            if tab.target != target { setTarget(target, for: tab) }
            tab.replaceCode(code)
            window.selectedTabId = tab.id
            connection.tabCode = code
            return tab
        }
        let window = windowId.flatMap(self.window(_:)) ?? activeWindow ?? makeWindow()
        let tab = newTab(target: target, code: code, title: title, in: window)
        connection.tabId = tab.id
        connection.tabCode = code
        return tab
    }
}
