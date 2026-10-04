import AppKit
import RunletCore

/// `runlet mcp`: an MCP server for AI clients (Claude Code, Claude Desktop, Cursor, …) on
/// standard input and output (#43). It answers the protocol itself and passes tool calls to
/// the running Runlet over its MCP socket, where every run waits for the user's approval.
/// Standard output carries only MCP messages; diagnostics go to standard error. See docs/mcp.md.
enum MCPCommand {
    /// Largest message accepted from the client (code is capped far lower; see `MCPTools`).
    static let maxMessageBytes = 4 << 20

    @MainActor
    static func run() -> Never {
        if isatty(STDIN_FILENO) != 0 {
            RunletTool.printError("""
            runlet mcp is an MCP server for AI clients: it reads JSON-RPC messages on standard input.
            Add it to your AI client instead (Runlet ▸ Settings ▸ AI Clients shows how). To open a
            folder named mcp, write: runlet ./mcp
            """)
            exit(RunletTool.Status.usage)
        }
        signal(SIGPIPE, SIG_IGN)
        let app = containingApp()
        let version = app.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "0"
        // RUNLET_DATA_DIR (development and tests) picks the same socket the app uses.
        let socketPath = MCPSocketPaths.socketPath(for: .standard)
        var launcher: (@Sendable () async -> MCPAppClient.LaunchOutcome)?
        // RUNLET_MCP_NO_LAUNCH (tests): report that Runlet isn't running instead of starting it.
        if let app, ProcessInfo.processInfo.environment["RUNLET_MCP_NO_LAUNCH"] == nil { launcher = { await MCPCommand.launch(app) } }
        let backend = MCPAppClient(socketPath: socketPath, launcher: launcher)
        backend.connectIfListening()
        let output = StandardOutput()
        let server = MCPServer(info: MCPServer.Info(version: version), backend: backend) { line in output.write(line) }

        let reader = Thread {
            var framer = JSONLineFramer(maxLineBytes: maxMessageBytes)
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var announced: MCPClientInfo?
            while true {
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                for item in framer.append(Data(buffer[0..<count])) {
                    switch item {
                    case .line(let line):
                        server.receive(line)
                        if let client = server.initializedClient, client != announced {
                            announced = client
                            backend.announce(client)
                        }
                    case .oversized(let size):
                        output.write(MCPJSON.object(["jsonrpc": "2.0", "error": ["code": -32600, "message": .string("Invalid request: the message is larger than \(maxMessageBytes / (1 << 20)) MB (\(size) bytes).")]]).serialized)
                    }
                }
            }
            // The client closed our input: stop waiting calls (the app withdraws their
            // approval sheets) and leave.
            server.shutdown()
            Thread.sleep(forTimeInterval: 0.2)
            backend.disconnect()
            exit(0)
        }
        reader.name = "runlet-mcp-stdin"
        reader.start()
        dispatchMain()
    }

    /// The Runlet.app this tool lives in (whatever its bundle id, so a development copy starts
    /// itself and never the installed app), else the one Launch Services knows.
    static func containingApp() -> URL? {
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            if app.pathExtension == "app", Bundle(url: app)?.bundleIdentifier?.hasPrefix(CommandLineTool.appBundleIdentifier) == true { return app }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: CommandLineTool.appBundleIdentifier)
    }

    /// Starts Runlet in the background when it isn't running. Starting it never runs code; the
    /// approval sheet brings it forward when a run is requested.
    @MainActor
    static func launch(_ app: URL) async -> MCPAppClient.LaunchOutcome {
        let identifier = Bundle(url: app)?.bundleIdentifier ?? CommandLineTool.appBundleIdentifier
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        if !running.isEmpty { return .alreadyRunning }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        // No update offer (#233), guided tour, or What's New (#232) in a session an AI client
        // started, until the user brings Runlet forward or launches it again.
        configuration.arguments = [UpdateCheckPolicy.launchedByMCPArgument]
        if let data = ProcessInfo.processInfo.environment["RUNLET_DATA_DIR"] { configuration.environment = ["RUNLET_DATA_DIR": data] }
        do {
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            return .launched
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Standard output, one MCP message per line, written whole (calls answer concurrently).
final class StandardOutput: @unchecked Sendable {
    private let lock = NSLock()

    func write(_ line: String) {
        var data = Data(line.utf8)
        data.append(0x0A)
        lock.withLock {
            var offset = 0
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                while offset < data.count {
                    let written = Darwin.write(STDOUT_FILENO, base + offset, data.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0, errno == EINTR {
                        continue
                    } else {
                        // The client is gone.
                        exit(0)
                    }
                }
            }
        }
    }
}
