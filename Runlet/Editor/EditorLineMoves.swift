import AppKit
import RunletCore

/// Move Line Up/Down (⌥↑/⌥↓) and Duplicate Line Up/Down (⇧⌥↑/⇧⌥↓), #234. The text transform is
/// `LineMove` (RunletCore); this applies it to an editor.
///
/// - Each press is one undo step, named after the command. Consecutive moves don't coalesce:
///   undo steps back one press at a time, and puts the selection back where it was.
/// - A folded block (#22) moves as one line: lines touching it take all of it along, and lines
///   moving past it skip it whole. It stays folded.
/// - Only the editor with the keyboard in the key window, and only when it can be edited. In any
///   other view (a text field, the terminal, a read-only peek, the What's New window) the
///   shortcut keeps its usual meaning there.
enum LineCommand: CaseIterable {
    case moveUp, moveDown, duplicateUp, duplicateDown

    var commandId: String {
        switch self {
        case .moveUp: "edit.moveLineUp"
        case .moveDown: "edit.moveLineDown"
        case .duplicateUp: "edit.duplicateLineUp"
        case .duplicateDown: "edit.duplicateLineDown"
        }
    }

    var title: String {
        switch self {
        case .moveUp: "Move Line Up"
        case .moveDown: "Move Line Down"
        case .duplicateUp: "Duplicate Line Up"
        case .duplicateDown: "Duplicate Line Down"
        }
    }

    /// As in VS Code and Zed.
    var defaultShortcut: KeyCombo {
        switch self {
        case .moveUp: KeyCombo("up", [.option])
        case .moveDown: KeyCombo("down", [.option])
        case .duplicateUp: KeyCombo("up", [.option, .shift])
        case .duplicateDown: KeyCombo("down", [.option, .shift])
        }
    }

    var keywords: String {
        switch self {
        case .moveUp, .moveDown: "lines selection swap reorder shift"
        case .duplicateUp, .duplicateDown: "lines selection copy clone"
        }
    }

    var direction: LineMove.Direction { self == .moveUp || self == .duplicateUp ? .up : .down }
}

@MainActor
enum EditorLineCommands {
    /// Runs `command` in the editor with the keyboard, or gives the key back to whatever view has
    /// it (the menu took it first).
    static func run(_ command: LineCommand, model: AppModel) {
        if let editor = focusedEditor() {
            editor.perform(command)
            return
        }
        guard let event = NSApp.currentEvent, event.type == .keyDown, KeyCombo(event: event) == model.shortcut(for: command.commandId),
              let responder = NSApp.keyWindow?.firstResponder else { return }
        responder.keyDown(with: event)
    }

    #if DEBUG
    /// DEBUG step `lines:target:on`: shortcuts act on this editor while Runlet is in the background.
    static weak var debugTarget: EditorController?
    #endif

    /// The key window's editor, when it has the keyboard and can be edited.
    static func focusedEditor() -> EditorController? {
        #if DEBUG
        if let debugTarget { return debugTarget }
        #endif
        guard let view = NSApp.keyWindow?.firstResponder as? CodeTextView, view.isEditable else { return nil }
        return view.codeDelegate as? EditorController
    }
}

extension EditorController {
    /// Moves or duplicates the selection's lines as one undo step; false when nothing changed
    /// (the first line up, the last line down).
    @discardableResult
    func perform(_ command: LineCommand) -> Bool {
        guard textView.isEditable else { return false }
        let text = self.text
        let selection = selectedRange
        let spans = LineMove.lineSpans(covering: folding.folded, in: text)
        let result: LineMove.Result?
        switch command {
        case .moveUp, .moveDown: result = LineMove.move(command.direction, in: text, selection: selection, keepingTogether: spans)
        case .duplicateUp, .duplicateDown: result = LineMove.duplicate(command.direction, in: text, selection: selection, keepingTogether: spans)
        }
        guard let result else { return false }
        // The folds of the lines that make room are opened by the edit; they fold again below.
        let keptFolds = result.displaced.map { displaced in folding.folded.filter { NSIntersectionRange($0, displaced) == $0 } } ?? []
        hidePopups()
        let undoManager = textView.undoManager
        textView.breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        // Undo runs these in reverse: the text goes back first, then the selection.
        Self.registerSelection(selection, restoring: true, in: textView)
        for edit in result.edits { textView.replace(range: edit.range, with: edit.replacement) }
        // Before the selection asks for layout, so the block is laid out folded.
        folding.refold(keptFolds.map { NSRange(location: $0.location + result.displacedShift, length: $0.length) })
        textView.setSelectedRange(result.selection)
        Self.registerSelection(result.selection, restoring: false, in: textView)
        undoManager?.setActionName(command.title)
        undoManager?.endUndoGrouping()
        textView.breakUndoCoalescing()
        textView.scrollRangeToVisible(result.selection)
        return true
    }

    /// Registers an undo step that sets the selection (`restoring`), or one that only registers
    /// that for redo. Paired around a line command's edits, so undo and redo both end on the
    /// selection their side had, after the text system's own undo selected the changed text.
    private static func registerSelection(_ range: NSRange, restoring: Bool, in textView: CodeTextView) {
        textView.undoManager?.registerUndo(withTarget: textView) { view in
            MainActor.assumeIsolated {
                if restoring {
                    let length = (view.string as NSString).length
                    let start = min(range.location, length)
                    view.setSelectedRange(NSRange(location: start, length: min(range.length, length - start)))
                    view.scrollRangeToVisible(view.selectedRange())
                }
                registerSelection(range, restoring: !restoring, in: view)
            }
        }
    }
}
