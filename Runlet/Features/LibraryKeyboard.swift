import AppKit
import RunletCore
import SwiftUI

/// What ↩ does in the History and Snippets panes, by modifier. None of them runs code.
enum LibraryKeyAction {
    /// ↩: where Settings ▸ General ▸ History & Snippets says (like double-click).
    case open
    /// ⌘↩: a new tab with the entry's target.
    case openInNewTab
    /// ⇧↩: at the current tab's cursor, replacing a selection, without a `<?php` tag.
    case insert
}

/// Asks the frontmost window's History or Snippets search field to take keyboard focus (⌘Y,
/// ⇧⌘L, or typing in a list). The field may not exist yet when the panel was hidden, so the
/// request waits briefly for it to appear.
@MainActor
enum LibrarySearchFocus {
    struct Request {
        var pane: AppModel.InspectorPane
        /// Select the search text (a fresh search) instead of putting the caret after it.
        var selectAll: Bool
        var date = Date()
    }

    private static var pending: Request?

    static func request(_ pane: AppModel.InspectorPane, selectAll: Bool = true) {
        pending = Request(pane: pane, selectAll: selectAll)
        NotificationCenter.default.post(name: .librarySearchFocusRequested, object: nil)
    }

    /// The pending request for `pane`'s field in `window`, consumed; nil when there is none,
    /// it is stale, or `window` isn't the one the user is working in.
    static func take(_ pane: AppModel.InspectorPane, in window: NSWindow?) -> Request? {
        guard let request = pending, request.pane == pane, Date().timeIntervalSince(request.date) < 2,
              let window, window.isMainWindow || window.isKeyWindow else { return nil }
        pending = nil
        return request
    }
}

extension Notification.Name {
    static let librarySearchFocusRequested = Notification.Name("RunletLibrarySearchFocusRequested")
}

extension AppModel {
    /// ⇧↩ in History or Snippets: inserts `code` at the current tab's cursor (replacing the
    /// selection), without its opening `<?php` tag. Only edits; nothing runs.
    func insertLibraryCode(_ code: String) {
        guard let tab = selectedTab else { return }
        tab.editor.insert(HistoryLog.insertable(code))
    }

    /// Gives the keyboard to the active window's current tab, once its editor is on screen
    /// (a tab opened just now appears on the next update).
    func focusSelectedEditor(attempts: Int = 12) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
            guard let self else { return }
            if let editor = self.selectedTab?.editorIfLoaded, editor.textView.window != nil {
                editor.focus()
            } else if attempts > 1 {
                self.focusSelectedEditor(attempts: attempts - 1)
            }
        }
    }
}

/// The History and Snippets search field. Keyboard-first: while typing, ↑/↓ move the list's
/// selection, ↩ opens it (as Settings says), ⌘↩ opens it in a new tab, ⇧↩ inserts it at the
/// cursor, and esc clears the search, or, when it is empty, goes back to the editor.
struct LibrarySearchField: View {
    let prompt: String
    @Binding var text: String
    let identifier: String
    /// The pane whose focus requests (⌘Y, ⇧⌘L) this field answers.
    var pane: AppModel.InspectorPane?
    var onMove: ((Int) -> Void)?
    var onAction: ((LibraryKeyAction) -> Void)?
    var onEscape: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            LibrarySearchTextField(prompt: prompt, text: $text, identifier: identifier, pane: pane, onMove: onMove, onAction: onAction, onEscape: onEscape)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.1)))
    }
}

/// AppKit-backed so the list keys reach the pane before the field editor uses them.
private struct LibrarySearchTextField: NSViewRepresentable {
    let prompt: String
    @Binding var text: String
    let identifier: String
    let pane: AppModel.InspectorPane?
    let onMove: ((Int) -> Void)?
    let onAction: ((LibraryKeyAction) -> Void)?
    let onEscape: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FocusableSearchField {
        let field = FocusableSearchField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier(identifier)
        return field
    }

    func updateNSView(_ field: FocusableSearchField, context: Context) {
        context.coordinator.parent = self
        field.pane = pane
        field.placeholderString = prompt
        field.onCommandReturn = { onAction?(.openInNewTab) }
        field.show(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FocusableSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LibrarySearchTextField?

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent?.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let parent else { return false }
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                guard let onMove = parent.onMove else { return false }
                onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                guard let onMove = parent.onMove else { return false }
                onMove(1)
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                guard let onAction = parent.onAction else { return false }
                let modifiers = NSApp.currentEvent?.modifierFlags.intersection([.command, .shift, .option, .control]) ?? []
                onAction(modifiers.contains(.command) ? .openInNewTab : modifiers.contains(.shift) ? .insert : .open)
            case #selector(NSResponder.cancelOperation(_:)):
                if !textView.string.isEmpty {
                    textView.string = ""
                    parent.text = ""
                } else {
                    parent.onEscape?()
                }
            default:
                return false
            }
            return true
        }
    }
}

final class FocusableSearchField: NSTextField {
    var pane: AppModel.InspectorPane?
    var onCommandReturn: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(self, selector: #selector(focusRequested(_:)), name: .librarySearchFocusRequested, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows `text`, keeping the caret after it while editing.
    func show(_ text: String) {
        guard stringValue != text else { return }
        if let editor = currentEditor() {
            editor.string = text
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        } else {
            stringValue = text
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Opened by ⌘Y or ⇧⌘L: the field may appear only now.
        takeFocusIfRequested()
    }

    @objc private func focusRequested(_ notification: Notification) {
        takeFocusIfRequested()
    }

    private func takeFocusIfRequested() {
        guard let pane, let request = LibrarySearchFocus.take(pane, in: window) else { return }
        // After the SwiftUI update that is showing the field.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if self.currentEditor() == nil { window.makeFirstResponder(self) }
            let length = (self.stringValue as NSString).length
            self.currentEditor()?.selectedRange = request.selectAll ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0)
        }
    }

    /// ⌘↩ opens the selection in a new tab (key equivalents reach views before the field editor).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if currentEditor() != nil, event.keyCode == 36 || event.keyCode == 76, modifiers == .command, let onCommandReturn {
            onCommandReturn()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

extension KeyPress {
    /// Characters a search field would take as typing: no ⌘, ⌃, or ⌥, and no arrows, function
    /// keys, Return, Tab, Delete, or Escape.
    var isTyping: Bool {
        guard modifiers.isDisjoint(with: [.command, .control, .option]), !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value) && scalar != " "
        }
    }
}
