#if DEBUG
import AppKit
import RunletCore

/// More RUNLET_DEBUG_STEPS steps (see `AppDelegate.runDebugInspectorCheck`), for checking
/// keyboard flows and file watching without UI scripting. Key events are sent to Runlet only,
/// so it has to be the active app (`activate` first):
/// `perform:<command id>` · `key:<[cmd+][shift+][opt+][ctrl+]name>` (a letter, digit, or
/// return, escape, delete, tab, up, down, left, right) · `type:<text>` · `state` (prints the
/// key window's focus and the active window's tabs) · `open:<path>` (like Finder) ·
/// `write:<path>|<text>` (appends in place) · `replace:<path>|<text>` (an atomic save) ·
/// `remove:<path>` · `edit:<text>` (inserts at the current tab's cursor) · `click:<accessibility
/// identifier>` · `dock[:<n>]` (lists the Dock menu, or chooses its nth item). In texts, `\n`
/// is a newline. A command that shows an alert should be pressed
/// with its shortcut (`key:cmd+s`), not `perform`: run from a step, `NSAlert.runModal` returns
/// at once.
@MainActor
enum DebugSteps {
    /// Runs one step; false when `name` isn't one of these.
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        switch name {
        case "perform":
            model.perform(argument)
        case "key":
            press(argument)
        case "type":
            for character in argument { key(code(for: character) ?? 0, text: String(character)) }
        case "state":
            log(state(model))
        case "open":
            AppDelegate.open(URL(fileURLWithPath: argument))
        case "write", "replace":
            let parts = argument.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return true }
            let text = parts[1].replacingOccurrences(of: "\\n", with: "\n")
            if name == "replace" {
                try? Data(text.utf8).write(to: URL(fileURLWithPath: parts[0]), options: .atomic)
            } else if let handle = FileHandle(forWritingAtPath: parts[0]) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                handle.closeFile()
            }
        case "remove":
            try? FileManager.default.removeItem(atPath: argument)
        case "edit":
            model.selectedTab?.editor.insert(argument.replacingOccurrences(of: "\\n", with: "\n"))
        case "click":
            click(argument)
        case "dock":
            // `dock` lists the Dock menu; `dock:<n>` chooses its nth item.
            let menu = DockMenu.make(model: model)
            log("dock menu: \(menu?.items.map(\.title) ?? [])")
            if let index = Int(argument), let menu, menu.items.indices.contains(index) { menu.performActionForItem(at: index) }
        default:
            return false
        }
        return true
    }

    /// Clicks the element with this accessibility identifier in the frontmost window that has it.
    private static func click(_ identifier: String) {
        let windows = NSApp.orderedWindows.filter(\.isVisible)
        guard let (window, frame) = windows.lazy.compactMap({ window in accessibilityFrame(of: identifier, in: window).map { (window, $0) } }).first else {
            return log("\(identifier) not found")
        }
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    private static func accessibilityFrame(of identifier: String, in element: AnyObject, depth: Int = 0) -> NSRect? {
        guard depth < 40 else { return nil }
        if element.accessibilityIdentifier?() == identifier { return element.accessibilityFrame?() }
        for child in element.accessibilityChildren?() ?? [] {
            if let frame = accessibilityFrame(of: identifier, in: child as AnyObject, depth: depth + 1) { return frame }
        }
        return nil
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }

    private static func state(_ model: AppModel) -> String {
        let keyWindow = NSApp.keyWindow
        var focus = keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        if let editor = keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSTextField {
            focus = "field:\(field.accessibilityIdentifier())"
        } else if keyWindow?.firstResponder is CodeTextView {
            focus = "editor"
        }
        let window = model.activeWindow
        let tabs = window?.tabs.map { tab in
            let code = (tab.editorIfLoaded?.text ?? tab.code).replacingOccurrences(of: "\n", with: "\\n")
            let issue = model.diskIssue(for: tab).map { " issue=\($0)" } ?? ""
            return "\(tab.id == window?.selectedTabId ? "*" : "")\(tab.title)\(tab.isFileDirty ? "•" : "") [\(model.targetLabel(tab.target))] \"\(code.prefix(60))\"\(issue)"
        } ?? []
        let floating = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.map { "\($0.title):\($0.level.rawValue)" }
        return "key=\(keyWindow.map { $0 is PalettePanel ? "palette" : $0.title } ?? "none") focus=\(focus) inspector=\(model.showInspector ? "\(model.inspectorPane)" : "hidden") windows=\(floating) tabs=\(tabs)"
    }

    /// ANSI key codes 0–50, by the character they type.
    private static let keyCodes = Array("asdfhgzxcv§bqweryt123465=97-80]ou[ip\rlj'k;\\,/nm.\t `")
    private static let named: [String: UInt16] = ["return": 36, "escape": 53, "delete": 51, "tab": 48, "space": 49, "up": 126, "down": 125, "left": 123, "right": 124]

    private static func code(for character: Character) -> UInt16? {
        keyCodes.firstIndex(of: Character(character.lowercased())).map(UInt16.init)
    }

    private static func press(_ spec: String) {
        var parts = spec.split(separator: "+").map(String.init)
        let name = parts.popLast() ?? ""
        var flags: NSEvent.ModifierFlags = []
        for modifier in parts {
            switch modifier {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: break
            }
        }
        guard let code = named[name] ?? name.first.flatMap(code(for:)) else { return log("unknown key \(spec)") }
        key(code, flags)
    }

    /// One key press, made the way the window server makes them (see `PaletteDebugCheck`), and
    /// queued like a real one, so `NSApp.currentEvent` is that press while it is handled.
    private static func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], text: String? = nil) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down) else { continue }
            event.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
            if let text { event.keyboardSetUnicodeString(stringLength: text.utf16.count, unicodeString: Array(text.utf16)) }
            if let event = NSEvent(cgEvent: event) { NSApp.postEvent(event, atStart: false) }
        }
    }
}
#endif
