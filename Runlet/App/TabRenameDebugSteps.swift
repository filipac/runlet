#if DEBUG
import AppKit
import RunletCore

/// RUNLET_DEBUG_STEPS for renaming a tab (#285), in either tab layout, with scratch data. They
/// need no key window, so Runlet can stay in the background (`ghost`):
///
/// - `rename-begin:<tab title>` starts renaming that tab of the active window, as Rename… in its
///   context menu (and a double-click) does; `perform:tabs.rename` is Rename Tab… for the
///   selected tab, and `palette:commands:rename tab` + `palette-return` (or
///   `palette:anything:rename`) runs it from the palette.
/// - `rename-begin-steal:<tab title>` starts it, then has the editor grab the keyboard right
///   after the field took it, as a closing palette giving its window the keyboard back could.
/// - `rename-state` prints the rename: the tab, whether its field has the keyboard, the
///   selection, the text, how often the field took the keyboard back, and what has the keyboard.
/// - `rename-type:<text>` types into the field, and `rename-key:<key>` presses a key in it
///   (named as for `key:`, e.g. `return`, `escape`, `tab`): key events handed to the field's
///   editor, through the same key bindings as real presses.
/// - `rename-blur:editor` gives the editor the keyboard, as a click in it does;
///   `rename-blur:click` is a click on a part of the window that takes no keyboard (the
///   field's click handling sees it, as its event monitor does).
///
/// ⌘W while renaming: `perform:file.closeTab`. `shot` draws a rename field's selection as an
/// active window would.
@MainActor
enum TabRenameDebugSteps {
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        switch name {
        case "rename-begin", "rename-begin-steal":
            guard let tab = model.activeWindow?.tabs.first(where: { $0.title == argument }) else {
                log("\(name): no tab \(argument)")
                return true
            }
            model.beginRename(tab.id)
            if name == "rename-begin-steal" { stealWhenFocused(model, attempts: 40) }
        case "rename-state":
            log(state(model))
        case "rename-type":
            guard let editor = fieldEditor(model, name) else { return true }
            for character in argument.replacingOccurrences(of: "\\c", with: ",") {
                send(DebugSteps.code(for: character) ?? 0, [], text: String(character), to: editor)
            }
        case "rename-key":
            guard let editor = fieldEditor(model, name), let (code, flags) = DebugSteps.keySpec(argument) else { return true }
            send(code, flags, to: editor)
            log("rename-key \(argument): " + state(model))
        case "rename-blur":
            guard let window = model.activeWindow?.nsWindow, let field = TabRenameTextField.field(in: window) else {
                log("rename-blur: no rename field")
                return true
            }
            if argument == "click" {
                // Just inside the window's top-left corner: the title bar, which takes no keyboard.
                let point = NSPoint(x: 4, y: window.frame.height - 4)
                guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return true }
                log("rename-blur click: ended=\(field.handleMouseDown(event))")
            } else if let editor = model.selectedTab?.editorIfLoaded {
                window.makeFirstResponder(editor.textView)
            }
        default:
            return false
        }
        return true
    }

    /// Once the field has the keyboard, the selected tab's editor takes it, as code would.
    private static func stealWhenFocused(_ model: AppModel, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) {
            guard let window = model.activeWindow?.nsWindow, let field = TabRenameTextField.field(in: window), field.hasKeyboard,
                  let editor = model.selectedTab?.editorIfLoaded else {
                if attempts > 1 { stealWhenFocused(model, attempts: attempts - 1) } else { log("rename-begin-steal: the field never took the keyboard") }
                return
            }
            editor.focus()
            log("rename-begin-steal: the editor took the keyboard; field has it now=\(field.hasKeyboard)")
        }
    }

    private static func fieldEditor(_ model: AppModel, _ step: String) -> NSTextView? {
        guard let field = TabRenameTextField.field(in: model.activeWindow?.nsWindow), field.hasKeyboard,
              let editor = field.currentEditor() as? NSTextView else {
            log("\(step): no rename field with the keyboard")
            return nil
        }
        return editor
    }

    /// One key press handed to the field's editor, as `editor-key` does for the code editor.
    private static func send(_ code: UInt16, _ flags: NSEvent.ModifierFlags, text: String? = nil, to editor: NSTextView) {
        guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: true) else { return }
        event.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
        if let text { event.keyboardSetUnicodeString(stringLength: text.utf16.count, unicodeString: Array(text.utf16)) }
        // A background window's text input context is inactive and would drop the key.
        editor.inputContext?.activate()
        NSEvent(cgEvent: event).map { editor.keyDown(with: $0) }
    }

    /// `rename-state: layout=… renaming=<title>|none pinned=… field=… keyboard=… selection=… all-selected=… text="…" reclaimed=… tabs=[…]`.
    static func state(_ model: AppModel) -> String {
        guard let window = model.activeWindow else { return "rename-state: no window" }
        let nsWindow = window.nsWindow
        let renamed = window.rename.flatMap { session in window.tabs.first { $0.id == session.tabId } }
        let field = TabRenameTextField.field(in: nsWindow)
        var parts = ["rename-state: layout=\(model.settings.tabLayout == .vertical ? "vertical" : "horizontal")",
                     "renaming=\(renamed?.title ?? "none")"]
        if let renamed { parts.append("pinned=\(renamed.isPinned ? "yes" : "no")") }
        parts.append("field=\(field == nil ? "no" : "yes")")
        parts.append("keyboard=\(keyboard(nsWindow))")
        if let field {
            let text = field.text
            if let editor = field.currentEditor(), field.hasKeyboard {
                let range = editor.selectedRange
                parts.append("selection=\(NSStringFromRange(range))")
                parts.append("all-selected=\(range.location == 0 && range.length == (text as NSString).length && range.length > 0 ? "yes" : "no")")
            }
            parts.append("text=\"\(text)\"")
            parts.append("reclaimed=\(field.reclaimCount)")
        }
        // Keys never reach the editor, and Esc doesn't hide the output pane.
        if let tab = window.selectedTab {
            let code = (tab.editorIfLoaded?.text ?? tab.code).replacingOccurrences(of: "\n", with: "\\n")
            parts.append("output=\(model.isOutputPaneShown(for: tab) ? "shown" : "hidden") code=\"\(code.prefix(40))\"")
        }
        let tabs = window.tabs.map { tab in "\(tab.id == window.selectedTab?.id ? "*" : "")\(tab.isPinned ? "📌" : "")\(tab.title)" }
        parts.append("tabs=\(tabs)")
        return parts.joined(separator: " ")
    }

    /// What has the window's keyboard: the rename field, the editor, another field, or the window.
    private static func keyboard(_ window: NSWindow?) -> String {
        guard let window, let responder = window.firstResponder else { return "none" }
        if responder === window { return "window" }
        if let editor = responder as? NSTextView, editor.isFieldEditor {
            if (editor.delegate as AnyObject?) is TabRenameTextField { return "rename-field" }
            return "field:\((editor.delegate as? NSView)?.accessibilityIdentifier() ?? "?")"
        }
        if responder is CodeTextView { return "editor" }
        return String(describing: type(of: responder))
    }

    /// For `shot`: Runlet draws in the background, where a selection is grey. Draws a rename
    /// field's selection in the active selection colour instead, until the returned closure runs.
    static func drawSelectionActive(in window: NSWindow) -> () -> Void {
        guard let field = TabRenameTextField.field(in: window), field.hasKeyboard, let editor = field.currentEditor() as? NSTextView,
              let layoutManager = editor.layoutManager else { return {} }
        let selection = editor.selectedRange()
        guard selection.length > 0 else { return {} }
        editor.setSelectedRange(NSRange(location: NSMaxRange(selection), length: 0))
        layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor, forCharacterRange: selection)
        return {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: selection)
            editor.setSelectedRange(selection)
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}
#endif
