import AppKit

/// ⌘W acts on what is in front (#273). Close Tab used to close the active editor window's tab
/// whatever window had the keyboard, so ⌘W in a sheet (the table browser's value editor, a
/// connection editor…) or in another window (Logs, Profiles, Settings…) closed the project tab
/// behind it.
extension AppModel {
    enum CommandWTarget: Equatable {
        /// An editor window: Close Tab closes its tab (or its focused terminal).
        case editor
        /// A sheet: closed like Esc, which triggers its Cancel.
        case sheet
        /// Another window with a close button: closed.
        case window
        /// A panel or popover-like window that can't be closed: ⌘W does nothing.
        case ignored
    }

    /// What ⌘W acts on when `front` has the keyboard (nil: no key window, as for an editor).
    func commandWTarget(for front: NSWindow?) -> CommandWTarget {
        guard let front else { return .editor }
        if windows.contains(where: { $0.nsWindow === front }) { return .editor }
        if front.sheetParent != nil { return .sheet }
        if front.styleMask.contains(.closable) { return .window }
        return .ignored
    }

    /// Closes `front` for ⌘W unless it is an editor window. Returns false when it is one, so
    /// Close Tab goes on to close the tab.
    @discardableResult
    func closeFrontForCommandW(_ front: NSWindow?) -> Bool {
        switch commandWTarget(for: front) {
        case .editor:
            return false
        case .sheet:
            if let front { Self.pressEscape(in: front) }
        case .window:
            front?.performClose(nil)
        case .ignored:
            break
        }
        return true
    }

    /// Esc in `window`, through the application like a real press, so a sheet's Cancel
    /// (`.cancelAction`) or its own Esc handling runs and the sheet closes the way it chooses.
    private static func pressEscape(in window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                               charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else { continue }
            NSApp.sendEvent(event)
        }
    }
}
