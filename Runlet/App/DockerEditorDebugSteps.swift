#if DEBUG
import AppKit
import RunletCore

/// RUNLET_DEBUG_STEPS for the Docker profile form's container list (#318), in the New Docker
/// Profile sheet or the Profiles window, for scripted checks with the fixture containers only
/// (see `DebugSteps`):
///
/// - `docker-editor:open-new` opens New Docker Profile (the sheet); `docker-editor:profiles-new`
///   opens the Profiles window and starts a new Docker profile there (its + button);
///   `docker-editor:profiles-revert` presses the Profiles window's Revert.
/// - `docker-editor:click:<container name>` clicks that row of the Running Containers list: a
///   mouse down and up posted to Runlet only, so the list's table handles them as a click (the
///   app stays in the background). `docker-editor:select:<container name>` selects the row the
///   way AppKit does for the keyboard (the table's selection changes, then SwiftUI hears of it).
/// - `docker-editor:refresh` is the list's Refresh button; `docker-editor:refresh-click:<name>`
///   starts a refresh and clicks that row while it runs.
/// - `docker-editor:search:<text>` sets the list's search field.
/// - `docker-editor:user:<text>` and `docker-editor:name:<text>` type into Execution user and Name.
/// - `docker-editor:state` prints the form: the highlighted row (as the table draws it and as the
///   form holds it), the profile's container, name, user, working directory, and local source.
@MainActor
enum DockerEditorDebugSteps {
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        guard name == "docker-editor" else { return false }
        let parts = argument.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let action = parts.first ?? ""
        let value = parts.count > 1 ? parts[1] : ""
        switch action {
        case "open-new":
            model.perform("library.newDockerProfile")
        case "profiles-new":
            model.showProfileManager()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .debugProfileManager, object: nil, userInfo: ["action": "new-docker"])
            }
        case "profiles-revert":
            NotificationCenter.default.post(name: .debugProfileManager, object: nil, userInfo: ["action": "revert"])
        case "click":
            click(value)
        case "select":
            select(value)
        case "refresh-click":
            post("refresh")
            DispatchQueue.main.async { click(value) }
        case "state":
            post("state", value: tableSelection() ?? "none")
        default:
            // refresh, search, user, name
            post(action, value: value)
        }
        return true
    }

    private static func post(_ action: String, value: String = "") {
        NotificationCenter.default.post(name: .debugDockerEditor, object: nil, userInfo: ["action": action, "value": value])
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }

    private static let rowPrefix = "docker-container-row-"

    /// The container list's table and the row showing `container`, scrolled into view.
    private static func row(of container: String) -> (NSWindow, NSTableView, Int)? {
        for window in NSApp.windows where window.isVisible {
            for table in views(of: NSTableView.self, in: window.contentView?.superview ?? window.contentView) where table.numberOfRows > 0 {
                for row in 0..<table.numberOfRows {
                    table.scrollRowToVisible(row)
                    table.layoutSubtreeIfNeeded()
                    if let view = table.rowView(atRow: row, makeIfNecessary: false), identifier(in: view, prefix: rowPrefix) == rowPrefix + container {
                        return (window, table, row)
                    }
                }
            }
        }
        return nil
    }

    /// The container whose row the list's table draws as selected.
    private static func tableSelection() -> String? {
        for window in NSApp.windows where window.isVisible {
            for table in views(of: NSTableView.self, in: window.contentView?.superview ?? window.contentView) where table.selectedRow >= 0 {
                if let view = table.rowView(atRow: table.selectedRow, makeIfNecessary: true), let id = identifier(in: view, prefix: rowPrefix) {
                    return String(id.dropFirst(rowPrefix.count))
                }
            }
        }
        return nil
    }

    private static func click(_ container: String) {
        guard let (window, table, row) = row(of: container) else { return log("docker-editor click: no row \(container)") }
        let rect = table.convert(table.rect(ofRow: row), to: nil)
        let point = NSPoint(x: rect.midX, y: rect.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    private static func select(_ container: String) {
        guard let (_, table, row) = row(of: container) else { return log("docker-editor select: no row \(container)") }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private static func identifier(in element: AnyObject, prefix: String, depth: Int = 0) -> String? {
        guard depth < 12 else { return nil }
        if let id = element.accessibilityIdentifier?(), id.hasPrefix(prefix) { return id }
        for child in element.accessibilityChildren?() ?? [] {
            if let id = identifier(in: child as AnyObject, prefix: prefix, depth: depth + 1) { return id }
        }
        return nil
    }

    private static func views<V: NSView>(of type: V.Type, in view: NSView?) -> [V] {
        guard let view else { return [] }
        let own: [V] = (view as? V).map { [$0] } ?? []
        return own + view.subviews.flatMap { views(of: type, in: $0) }
    }
}

extension Notification.Name {
    /// DEBUG steps `docker-editor:…` (#318): the open Docker profile form's list and fields.
    static let debugDockerEditor = Notification.Name("RunletDebugDockerEditor")
    /// DEBUG steps `docker-editor:profiles-new|profiles-revert` (#318): the Profiles window.
    static let debugProfileManager = Notification.Name("RunletDebugProfileManager")
}
#endif
