import AppKit
import RunletCore

/// Receives what the `runlet` tool asks to open: a distributed notification while Runlet
/// runs, or a launch argument when the tool started it. A request is handled once, only by the
/// Runlet process it names, and only opens things; the tool may repeat it until the reply
/// (`OpenReply`, with anything that couldn't be opened) reaches it.
@MainActor
enum CommandLineRequests {
    private static var replies: [UUID: OpenReply] = [:]
    private static var handling: Set<UUID> = []
    private static let listener = Listener()

    /// Called once the app has finished launching.
    static func start() {
        DistributedNotificationCenter.default().addObserver(listener, selector: #selector(Listener.received(_:)), name: .init(CommandLineTool.requestNotification), object: nil, suspensionBehavior: .deliverImmediately)
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: CommandLineTool.launchArgument), arguments.indices.contains(index + 1),
           let request = OpenRequest.decode(arguments[index + 1]) {
            receive(request, fromLaunch: true)
        }
    }

    static func receive(_ request: OpenRequest, fromLaunch: Bool = false) {
        // Several copies of Runlet can run; a launch argument is always for this one.
        if !fromLaunch, request.recipient != ProcessInfo.processInfo.processIdentifier { return }
        if let reply = replies[request.id] { return send(reply) }
        guard handling.insert(request.id).inserted else { return }
        whenWindowIsUp {
            guard let model = AppDelegate.model else { return }
            let reply = OpenReply(id: request.id, errors: model.open(request))
            replies[request.id] = reply
            handling.remove(request.id)
            send(reply)
        }
    }

    /// Requests that arrive during launch wait for the first window, like Finder's.
    private static func whenWindowIsUp(attempts: Int = 300, _ body: @escaping @MainActor () -> Void) {
        if AppDelegate.model?.hasPresentedWindow == true || attempts <= 0 {
            body()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
                MainActor.assumeIsolated { whenWindowIsUp(attempts: attempts - 1, body) }
            }
        }
    }

    private static func send(_ reply: OpenReply) {
        DistributedNotificationCenter.default().postNotificationName(.init(CommandLineTool.replyNotification), object: reply.encoded, userInfo: nil, deliverImmediately: true)
    }

    private final class Listener: NSObject {
        @objc func received(_ notification: Notification) {
            guard let text = notification.object as? String, let request = OpenRequest.decode(text) else { return }
            CommandLineRequests.receive(request)
        }
    }
}

extension AppModel {
    /// Opens what `runlet` asked for, in order, and returns what couldn't be opened, worded
    /// for the terminal. Folders become local projects; files open in tabs (on `--target`
    /// when given); workspaces open in their own windows. Never runs code.
    func open(_ request: OpenRequest) -> [String] {
        var target: TargetRef?
        if let name = request.target {
            switch library.target(matching: name) {
            case .found(let match):
                target = match
            case .notFound:
                return ["no target named “\(name)”. Use “sandbox”, a local project's name or folder, or a Docker profile's name."]
            case .ambiguous(let matches):
                return ["“\(name)” matches more than one target: \(matches.joined(separator: "; ")). Put local: or docker: before the name."]
            }
        }
        let opensTabs = request.items.contains { if case .workspace = $0 { false } else { true } } || request.items.isEmpty
        let window = request.newWindow && opensTabs ? makeWindow() : activeWindow ?? makeWindow()
        let placeholder = request.newWindow ? window.tabs.first : nil
        activeWindowId = window.id

        var errors: [String] = []
        for item in request.items {
            let url = URL(fileURLWithPath: item.path)
            switch item {
            case .folder:
                openFolder(url, in: window)
            case .file:
                activeWindowId = window.id
                if let tab = openFile(url) {
                    if let target { setTarget(target, for: tab) }
                } else {
                    errors.append("couldn't open \(item.path) (Runlet shows why)")
                }
            case .workspace:
                if openWorkspace(url) == nil { errors.append("didn't open the workspace \(item.path)") }
            }
        }
        if request.items.isEmpty, let target { openTargetInTab(target, in: window) }
        // A new window's own empty tab goes once something opened next to it.
        if let placeholder, window.tabs.count > 1, placeholder.isBlankScratch, window.selectedTabId != placeholder.id {
            closeTab(placeholder.id)
        }
        if opensTabs {
            activeWindowId = window.id
            openWindowAction?(window.id)
        }
        return errors
    }

    /// A folder from `runlet`, Finder, or the Dock: saved as a local project (or the saved one
    /// for that folder reused) and opened in the current tab when it's blank, else a new tab.
    func openFolder(_ url: URL, in window: WindowModel? = nil) {
        let project = openProject(at: url)
        openTargetInTab(.local(project.id), in: window)
    }
}
