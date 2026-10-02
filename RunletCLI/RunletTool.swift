import AppKit
import RunletCore

/// `runlet`: opens folders, PHP files, and workspaces in Runlet from a terminal. It asks the
/// app to open them and waits for its answer; it never runs code, and neither does opening.
/// `runlet mcp` serves AI clients instead (MCPCommand.swift): their runs wait for the user's
/// approval in the app.
///
/// It lives in `Runlet.app/Contents/Helpers/runlet` and is installed as a symbolic link to
/// that file (Settings ▸ General ▸ Command-Line Tool), so it always talks to the copy of
/// Runlet it came with. See docs/cli.md.
@main
enum RunletTool {
    static func main() {
        exit(MainActor.assumeIsolated { run() })
    }

    /// Exit statuses (sysexits.h where one fits).
    enum Status {
        static let ok: Int32 = 0
        static let failed: Int32 = 1
        static let usage: Int32 = 64
        static let unavailable: Int32 = 69
    }

    @MainActor
    static func run() -> Int32 {
        let invocation: CommandLineTool.Invocation
        do {
            invocation = try CommandLineTool.parse(Array(CommandLine.arguments.dropFirst()), currentDirectory: currentDirectory()) { path in
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
                return isDirectory.boolValue ? .directory : .file
            }
        } catch {
            printError("runlet: \(error.description)\nTry 'runlet --help'.")
            return Status.usage
        }
        switch invocation {
        case .help:
            print(CommandLineTool.usage)
            return Status.ok
        case .version:
            let version = runletApp().flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
            print("runlet (Runlet \(version ?? "?"))")
            return Status.ok
        case .mcp:
            MCPCommand.run()
        case .open(let request):
            guard let app = runletApp() else {
                printError("runlet: can't find Runlet.app. Reinstall the command from Runlet ▸ Settings ▸ General.")
                return Status.unavailable
            }
            return Messenger(request: request, app: app).deliver()
        }
    }

    /// The shell's current folder as the user sees it (`$PWD` keeps symbolic links), else the
    /// process's.
    static func currentDirectory() -> String {
        let physical = FileManager.default.currentDirectoryPath
        if let logical = ProcessInfo.processInfo.environment["PWD"], logical.hasPrefix("/"),
           URL(fileURLWithPath: logical).resolvingSymlinksInPath().path == URL(fileURLWithPath: physical).resolvingSymlinksInPath().path {
            return logical
        }
        return physical
    }

    /// The Runlet.app this tool belongs to (the link is followed), else the one macOS knows.
    static func runletApp() -> URL? {
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            if app.pathExtension == "app", Bundle(url: app)?.bundleIdentifier == CommandLineTool.appBundleIdentifier { return app }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: CommandLineTool.appBundleIdentifier)
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Sends one request to Runlet and waits for the reply.
@MainActor
final class Messenger: NSObject {
    private var request: OpenRequest
    private let app: URL
    private var reply: OpenReply?
    private let center = DistributedNotificationCenter.default()
    /// How long to wait for Runlet: a cold start, or a question Runlet asks first (adding a
    /// workspace's targets), takes a while.
    private let timeout: TimeInterval = 60

    init(request: OpenRequest, app: URL) {
        self.request = request
        self.app = app
    }

    func deliver() -> Int32 {
        center.addObserver(self, selector: #selector(received(_:)), name: .init(CommandLineTool.replyNotification), object: nil, suspensionBehavior: .deliverImmediately)
        defer { center.removeObserver(self) }

        let environment = ProcessInfo.processInfo.environment
        if let pid = environment["RUNLET_CLI_PID"].flatMap(Int32.init) {
            // Tests: talk to exactly this Runlet process, and don't bring it forward.
            request.recipient = pid
            return finish(waitForReply(posting: true))
        }

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLineTool.appBundleIdentifier)
        if let instance = running.first(where: { $0.bundleURL?.resolvingSymlinksInPath() == app.resolvingSymlinksInPath() }) ?? running.first {
            request.recipient = instance.processIdentifier
            let status = finish(waitForReply(posting: true))
            // Through Launch Services, like `open -a`, so macOS lets Runlet come forward.
            if reply != nil { launch(instance.bundleURL ?? app, arguments: []) }
            return status
        }

        // Not running: start it with the request as a launch argument. Runlet answers it once
        // it is up; repeats of the request (in case it was already starting) are answered
        // without opening anything twice.
        guard let launched = launch(app, arguments: [CommandLineTool.launchArgument, request.encoded]) else { return RunletTool.Status.unavailable }
        request.recipient = launched.processIdentifier
        return finish(waitForReply(posting: true))
    }

    @objc private func received(_ notification: Notification) {
        guard let text = notification.object as? String, let reply = OpenReply.decode(text), reply.id == request.id else { return }
        self.reply = reply
    }

    /// Runs the run loop (where replies arrive) until the reply came or the time is up,
    /// repeating the request every half second while Runlet may still be starting.
    private func waitForReply(posting: Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var nextPost = Date()
        while reply == nil, Date() < deadline {
            if posting, Date() >= nextPost {
                center.postNotificationName(.init(CommandLineTool.requestNotification), object: request.encoded, userInfo: nil, deliverImmediately: true)
                nextPost = Date().addingTimeInterval(0.5)
            }
            if !RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return reply != nil
    }

    private func finish(_ answered: Bool) -> Int32 {
        guard answered, let reply else {
            RunletTool.printError("runlet: Runlet didn't answer. If it was just updated, quit and reopen it, then try again.")
            return RunletTool.Status.failed
        }
        for error in reply.errors { RunletTool.printError("runlet: \(error)") }
        return reply.errors.isEmpty ? RunletTool.Status.ok : RunletTool.Status.failed
    }

    /// Opens Runlet through Launch Services (starting it with `arguments`, or bringing a running
    /// copy forward) and returns it.
    @discardableResult
    private func launch(_ app: URL, arguments: [String]) -> NSRunningApplication? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.arguments = arguments
        // A scratch data folder (development and tests) carries over to the app.
        if let data = ProcessInfo.processInfo.environment["RUNLET_DATA_DIR"] { configuration.environment = ["RUNLET_DATA_DIR": data] }
        let result = LaunchResult()
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { application, error in
            result.set(application, error)
        }
        let deadline = Date().addingTimeInterval(30)
        while !result.done, Date() < deadline {
            if !RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        if let error = result.error {
            RunletTool.printError("runlet: couldn't open Runlet: \(error.localizedDescription)")
        }
        return result.application
    }
}

/// The outcome of `NSWorkspace.openApplication`, reported on another thread.
private final class LaunchResult: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var launched: NSRunningApplication?
    private var failure: Error?

    func set(_ application: NSRunningApplication?, _ error: Error?) {
        lock.withLock {
            launched = application
            failure = error
            finished = true
        }
    }

    var done: Bool { lock.withLock { finished } }
    var application: NSRunningApplication? { lock.withLock { launched } }
    var error: Error? { lock.withLock { failure } }
}
