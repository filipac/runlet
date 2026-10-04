#if DEBUG
import AppKit
import RunletCore
import RunletLanguage

/// RUNLET_DEBUG_STEPS for moving and duplicating lines (#234), in the current tab's editor even
/// when Runlet is in the background (see `DebugSteps`): `lines:up|down|dup-up|dup-down` (the
/// command, as its shortcut does in the focused editor) · `lines:undo|redo` · `lines:select:<from
/// line>[:<column>]-<to line>[:<column>]` (1-based; a caret when both ends are the same) ·
/// `lines:focus:on|off` (the editor takes the keyboard, or the window does) · `lines:target:on|off`
/// (menu shortcuts, such as `key:opt+up`, act on the current tab's editor as if it had the
/// keyboard) · `lines:key:up|down|dup-up|dup-down` (the command as the menu runs it, so only a
/// focused editor moves lines) · `lines:menu` (prints Edit ▸ Lines' shortcuts and the catalog's problems, such as two commands with one default shortcut) ·
/// `lines-state` (prints the text, the selection, and the undo and redo names).
@MainActor
enum LineMoveDebugSteps {
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        guard name == "lines" || name == "lines-state" else { return false }
        guard let editor = model.selectedTab?.editor else { return true }
        if name == "lines-state" {
            log(state(editor))
            return true
        }
        let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first ?? "" {
        case "undo": editor.textView.undoManager?.undo()
        case "redo": editor.textView.undoManager?.redo()
        case "select":
            let ends = (parts.count > 1 ? parts[1] : "").split(separator: "-").map { $0.split(separator: ":").compactMap { Int($0) } }
            guard let from = ends.first, let to = ends.last, !from.isEmpty, !to.isEmpty else { return true }
            let index = TextLineIndex(editor.text)
            let start = index.offset(of: LSPPosition(line: from[0] - 1, character: (from.count > 1 ? from[1] : 1) - 1))
            let end = index.offset(of: LSPPosition(line: to[0] - 1, character: (to.count > 1 ? to[1] : 1) - 1))
            editor.textView.setSelectedRange(NSRange(location: min(start, end), length: abs(end - start)))
        case "target":
            EditorLineCommands.debugTarget = parts.count > 1 && parts[1] == "off" ? nil : editor
        case "focus":
            let window = editor.textView.window
            window?.makeFirstResponder(parts.count > 1 && parts[1] == "off" ? nil : editor.textView)
        case "key":
            guard let command = command(parts.count > 1 ? parts[1] : "") else { return true }
            EditorLineCommands.run(command, model: model)
            log("lines key \(parts.count > 1 ? parts[1] : ""): focused editor \(EditorLineCommands.focusedEditor() === editor ? "yes" : "no")")
        case "menu":
            // Edit ▸ Lines as AppKit has it, and whether the main menu takes an ⌥↑ press.
            let edit = NSApp.mainMenu?.items.first { $0.submenu?.items.contains { $0.title == "Lines" } == true }?.submenu
            let lines = edit?.items.first { $0.title == "Lines" }?.submenu
            let items = (lines?.items ?? []).map { item in
                let key = item.keyEquivalent.unicodeScalars.first.map { String(format: "U+%04X", $0.value) } ?? "none"
                return "\(item.title) key=\(key) modifiers=\(item.keyEquivalentModifierMask.rawValue) enabled=\(item.isEnabled)"
            }
            log("lines menu: \(items.joined(separator: " | ")); catalog problems: \(CommandCatalog.problems())")
            if let cgEvent = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 126, keyDown: true) {
                cgEvent.flags = .maskAlternate
                if let event = NSEvent(cgEvent: cgEvent) {
                    log("lines menu: ⌥↑ handled by the main menu: \(NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false), key window \(NSApp.keyWindow.map { _ in "yes" } ?? "none")")
                }
            }
        default:
            guard let command = command(parts.first ?? "") else {
                log("lines: unknown \(argument)")
                return true
            }
            log("lines \(argument): \(editor.perform(command) ? "changed" : "unchanged")")
        }
        return true
    }

    private static func command(_ name: String) -> LineCommand? {
        switch name {
        case "up": .moveUp
        case "down": .moveDown
        case "dup-up": .duplicateUp
        case "dup-down": .duplicateDown
        default: nil
        }
    }

    private static func state(_ editor: EditorController) -> String {
        let undo = editor.textView.undoManager
        let text = editor.text.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
        return "lines-state: selection=\(NSStringFromRange(editor.selectedRange)) undo=\"\(undo?.undoActionName ?? "")\" redo=\"\(undo?.redoActionName ?? "")\" folded=\(editor.folding.folded.map { NSStringFromRange($0) }) text=\"\(text)\""
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}
#endif
