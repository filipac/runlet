import AppKit
import RunletCore
import SwiftUI

// Renaming a tab (#285): one field for the tab bar, the vertical tabs, and pinned tabs in both.
// A rename starts from a double-click on the tab, Rename… in its context menu, or Rename Tab…
// (the Window menu, the command palette, Open Anything). The field takes the keyboard with the
// whole title selected, so typing replaces it. Return commits, Esc cancels, and a click
// elsewhere commits, like Finder. An empty or whitespace-only name keeps the old title
// (`TabRename` in RunletCore). While it is open, keys go to the field, never to the editor, and
// ⌘W closes nothing; after Return or Esc the keyboard goes back to what had it (the editor).

/// One tab rename in progress: which tab, the text typed so far, and what had the keyboard
/// before it started.
@MainActor
final class TabRenameSession {
    let tabId: UUID
    /// The text typed so far, so a field SwiftUI makes again (a sidebar row it rebuilt, a switch
    /// of the tab layout) starts from it.
    var text: String
    /// What had the keyboard when the field first took it; it gets it back after Return or Esc.
    weak var previousResponder: NSResponder?
    var recordedPreviousResponder = false

    init(tabId: UUID, text: String) {
        self.tabId = tabId
        self.text = text
    }
}

extension AppModel {
    /// Starts renaming a tab: a double-click on it, Rename… in its context menu, and Rename Tab…
    /// all come here. Another tab's rename in the window commits first, as a click elsewhere
    /// would; a double-click inside the open field (selecting a word) doesn't start over.
    func beginRename(_ tabId: UUID) {
        guard let window = window(containing: tabId), let tab = window.tabs.first(where: { $0.id == tabId }) else { return }
        let session = TabRenameSession(tabId: tabId, text: tab.title)
        if let current = window.rename {
            guard current.tabId != tabId else { return }
            endRename(current.tabId, .focusLost, text: current.text)
            // What had the keyboard before that rename gets it back after this one.
            session.previousResponder = current.previousResponder
            session.recordedPreviousResponder = current.recordedPreviousResponder
        }
        window.rename = session
    }

    /// Ends the rename of `tabId`: Return and a focus loss give the tab the trimmed `text`
    /// unless it is empty; Esc keeps the title.
    func endRename(_ tabId: UUID, _ end: TabRename.End, text: String) {
        guard let window = window(containing: tabId), window.rename?.tabId == tabId else { return }
        window.rename = nil
        guard let tab = window.tabs.first(where: { $0.id == tabId }),
              TabRename.newTitle(after: end, text: text, current: tab.title) != nil else { return }
        renameTab(tabId, to: text)
    }

    /// A rename field left its window before the rename ended. SwiftUI may have made it again
    /// (a rebuilt sidebar row, a switch of the tab layout), and the new field carries on; when
    /// none came back (its row scrolled away), the rename commits, as a focus loss.
    func renameFieldDetached(_ tabId: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
            guard let self, let window = self.window(containing: tabId), let session = window.rename, session.tabId == tabId,
                  !TabRenameTextField.hasField(for: tabId) else { return }
            self.endRename(tabId, .focusLost, text: session.text)
        }
    }
}

extension View {
    /// A tab's clicks, in both layouts: a double-click renames it, a click selects it. While it
    /// is renamed neither gesture runs, so clicks in its field reach the field (to place the
    /// caret or select a word) instead of selecting the row or starting a drag.
    func tabClicks(renaming: Bool, rename: @escaping () -> Void, select: @escaping () -> Void) -> some View {
        let mask: GestureMask = renaming ? .subviews : .all
        return gesture(TapGesture(count: 2).onEnded(rename), including: mask)
            .gesture(TapGesture().onEnded(select), including: mask)
    }
}

/// A tab's title in its rename field: the font each layout uses for the title.
extension TabRenameField {
    static func font(weight: NSFont.Weight = .regular) -> NSFont {
        // SwiftUI's `.callout`, as the tab titles use.
        .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: weight)
    }
}

/// The rename field of the window's current rename, in place of `tab`'s title. AppKit-backed:
/// it takes the keyboard itself (a SwiftUI field in the vertical tabs' list never got it) and
/// decides what Return, Esc, and a focus loss do.
struct TabRenameField: View {
    @Environment(AppModel.self) private var model
    let session: TabRenameSession
    var font: NSFont = TabRenameField.font()

    var body: some View {
        RenameTextField(session: session, font: font,
                        onEnd: { end, text in model.endRename(session.tabId, end, text: text) },
                        onDetach: { model.renameFieldDetached(session.tabId) })
            // A light box around the name, as in Finder; it doesn't change the tab's size.
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .padding(.horizontal, -4)
                    .padding(.vertical, -1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1)
                    .padding(.horizontal, -4)
                    .padding(.vertical, -1)
            }
            .accessibilityLabel("Tab name")
    }
}

private struct RenameTextField: NSViewRepresentable {
    let session: TabRenameSession
    let font: NSFont
    let onEnd: (TabRename.End, String) -> Void
    let onDetach: () -> Void

    func makeNSView(context: Context) -> TabRenameTextField {
        let field = TabRenameTextField(session: session)
        field.font = font
        field.onEnd = onEnd
        field.onDetach = onDetach
        return field
    }

    func updateNSView(_ field: TabRenameTextField, context: Context) {
        field.onEnd = onEnd
        field.onDetach = onDetach
        if field.font != font { field.font = font }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TabRenameTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 120, height: nsView.intrinsicContentSize.height)
    }
}

/// The rename field itself. It takes the keyboard on the run-loop turn after it appears (once
/// no palette is open over its window: closing, a palette gives the keyboard back to the
/// window), tries again until it has it, and takes it back when code grabs it right after the
/// start (`TabRename.reclaimsFocus`).
final class TabRenameTextField: NSTextField, NSTextFieldDelegate {
    /// The rename fields on screen, for ⌘W, the debug steps, and fields SwiftUI makes again.
    private static let fields = NSHashTable<TabRenameTextField>.weakObjects()

    let tabId: UUID
    private weak var session: TabRenameSession?
    var onEnd: ((TabRename.End, String) -> Void)?
    var onDetach: (() -> Void)?
    /// Return, Esc, or a focus loss ended the rename; nothing else happens after that.
    private(set) var ended = false
    /// Leaving the window: its editing ends without the user.
    private var detaching = false
    /// System uptime when the field took the keyboard.
    private var focusedAt: TimeInterval?
    /// How often it took the keyboard back from code (debug steps print it).
    private(set) var reclaimCount = 0
    private var savedSelection: NSRange?
    private var mouseMonitor: Any?

    init(session: TabRenameSession) {
        tabId = session.tabId
        self.session = session
        super.init(frame: .zero)
        stringValue = session.text
        isEditable = true
        isSelectable = true
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        cell?.isScrollable = true
        cell?.wraps = false
        lineBreakMode = .byClipping
        delegate = self
        setAccessibilityIdentifier("tab-rename-field")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The name as typed so far.
    var text: String { currentEditor()?.string ?? stringValue }

    /// Whether the field has its window's keyboard.
    var hasKeyboard: Bool {
        guard let editor = currentEditor(), let window else { return false }
        return window.firstResponder === editor
    }

    static func hasField(for tabId: UUID) -> Bool {
        fields.allObjects.contains { $0.tabId == tabId && $0.window != nil && !$0.ended }
    }

    /// The open rename field in `window`, if any.
    static func field(in window: NSWindow?) -> TabRenameTextField? {
        guard let window else { return nil }
        return fields.allObjects.first { $0.window === window && !$0.ended }
    }

    // MARK: Taking the keyboard

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, window != nil, !ended {
            detaching = true
            removeMouseMonitor()
            onDetach?()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !ended else { return }
        detaching = false
        Self.fields.add(self)
        installMouseMonitor()
        // SwiftUI is still adding the field: take the keyboard on the next turn.
        DispatchQueue.main.async { [weak self] in self?.takeKeyboard(attempts: 60) }
    }

    /// Takes the keyboard with the whole name selected once no palette is open over the
    /// window; otherwise tries again shortly (for about two seconds).
    private func takeKeyboard(attempts: Int) {
        guard !ended, !detaching, let window, !hasKeyboard else { return }
        if !Self.paletteIsOpen(over: window) {
            recordPreviousResponder(in: window)
            if window.makeFirstResponder(self), let editor = currentEditor() {
                editor.selectedRange = NSRange(location: 0, length: (editor.string as NSString).length)
                focusedAt = ProcessInfo.processInfo.systemUptime
                return
            }
        }
        guard attempts > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
            self?.takeKeyboard(attempts: attempts - 1)
        }
    }

    /// Open Anything or the command palette over `window`: it gives the window the keyboard
    /// back as it closes, so the field waits until it has gone.
    private static func paletteIsOpen(over window: NSWindow) -> Bool {
        window.childWindows?.contains { $0 is PalettePanel && $0.isVisible } ?? false
    }

    private func recordPreviousResponder(in window: NSWindow) {
        guard let session, !session.recordedPreviousResponder else { return }
        session.recordedPreviousResponder = true
        var responder = window.firstResponder
        // Another field's editing: that field, not the shared field editor.
        if let editor = responder as? NSTextView, editor.isFieldEditor { responder = editor.delegate as? NSResponder }
        if responder === window || responder === self { responder = nil }
        session.previousResponder = responder
    }

    /// Code took the keyboard right after the start: take it back, with what was typed and selected.
    private func reclaimKeyboard() {
        guard !ended, !detaching, let window, !hasKeyboard, window.makeFirstResponder(self), let editor = currentEditor() else { return }
        let length = (editor.string as NSString).length
        let selection = savedSelection ?? NSRange(location: 0, length: length)
        editor.selectedRange = NSMaxRange(selection) <= length ? selection : NSRange(location: 0, length: length)
        reclaimCount += 1
    }

    // MARK: Ending

    /// Ends the rename once. After Return or Esc the keyboard goes back to what had it before.
    private func finish(_ end: TabRename.End, givingKeyboardBack: Bool) {
        guard !ended else { return }
        ended = true
        removeMouseMonitor()
        let text = self.text
        let previous = session?.previousResponder
        onEnd?(end, text)
        guard givingKeyboardBack, let window else { return }
        window.makeFirstResponder(Self.usable(previous, in: window))
    }

    /// `responder` if it is still in `window`.
    private static func usable(_ responder: NSResponder?, in window: NSWindow) -> NSResponder? {
        guard let view = responder as? NSView else { return nil }
        return view.window === window ? view : nil
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
             #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            finish(.commit, givingKeyboardBack: true)
        case #selector(NSResponder.cancelOperation(_:)):
            // Esc cancels the rename and nothing else (no completion list, no other Esc handler).
            finish(.cancel, givingKeyboardBack: true)
        default:
            return false
        }
        return true
    }

    func controlTextDidChange(_ notification: Notification) {
        session?.text = text
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !ended, !detaching else { return }
        let movement = notification.userInfo?[NSText.movementUserInfoKey] as? Int ?? TabRename.TextMovement.other
        let end = TabRename.end(forTextMovement: movement)
        if end == .focusLost, let focusedAt,
           TabRename.reclaimsFocus(secondsSinceFocused: ProcessInfo.processInfo.systemUptime - focusedAt, byUser: Self.isUserEvent(NSApp.currentEvent, since: focusedAt)) {
            savedSelection = (notification.userInfo?["NSFieldEditor"] as? NSTextView)?.selectedRange()
            DispatchQueue.main.async { [weak self] in self?.reclaimKeyboard() }
            return
        }
        finish(end, givingKeyboardBack: end != .focusLost)
    }

    /// A click or key press of the user's since the field took the keyboard.
    private static func isUserEvent(_ event: NSEvent?, since uptime: TimeInterval) -> Bool {
        guard let event, event.timestamp >= uptime else { return false }
        return [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown].contains(event.type)
    }

    // MARK: Clicks elsewhere

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { _ = self?.handleMouseDown(event) }
            return event
        }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    /// A click anywhere else in the window commits the rename, as in Finder, even on something
    /// that doesn't take the keyboard (an empty part of the tab bar); the click goes on. When
    /// nothing took the keyboard, it goes back to what had it. A click in the field edits it.
    /// Returns whether the click ended the rename.
    @discardableResult
    func handleMouseDown(_ event: NSEvent) -> Bool {
        guard !ended, !detaching, let window, event.window === window else { return false }
        guard !bounds.contains(convert(event.locationInWindow, from: nil)) else { return false }
        let editor = currentEditor()
        let previous = session?.previousResponder
        finish(.focusLost, givingKeyboardBack: false)
        DispatchQueue.main.async { [weak window, weak self] in
            guard let window else { return }
            // Nothing took it: the window has it, or this field still does.
            let responder = window.firstResponder
            let unclaimed = responder === window
                || ((responder as? NSTextView).map { $0.isFieldEditor && $0 === editor && ($0.delegate as AnyObject?) === self && self != nil } ?? false)
            guard unclaimed else { return }
            window.makeFirstResponder(Self.usable(previous, in: window))
        }
        return true
    }
}
