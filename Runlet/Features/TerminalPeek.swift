import AppKit
import SwiftUI

/// A read-only, live view of a terminal tab: shows the session's own terminal view (its colours
/// and whole scrollback, following new output) while this is on screen, and gives it back to the
/// terminal panel when it goes away. Nothing typed, pasted, or clicked reaches the process: the
/// view never becomes first responder, and the session's view drops input meanwhile. Scrolling
/// and the scroller still work.
struct TerminalPeekView: NSViewRepresentable {
    let session: TerminalSession
    var theme: TerminalTheme
    var fontSize: Double
    var optionAsMeta: Bool
    /// Esc while the peek has the keyboard.
    var onCancel: () -> Void = {}

    /// A size for the peek that keeps the session's columns and rows (so the process isn't
    /// resized just by looking at it), within `width` and `height`.
    @MainActor
    static func size(for session: TerminalSession, width: ClosedRange<CGFloat> = 420...900, height: ClosedRange<CGFloat> = 180...480) -> CGSize {
        let optimal = session.view.getOptimalFrameSize().size
        func clamp(_ value: CGFloat, _ range: ClosedRange<CGFloat>, fallback: CGFloat) -> CGFloat {
            guard value.isFinite, value > 0 else { return fallback }
            return min(range.upperBound, max(range.lowerBound, value))
        }
        return CGSize(width: clamp(optimal.width, width, fallback: 640), height: clamp(optimal.height, height, fallback: 320))
    }

    func makeNSView(context: Context) -> PeekContainerView {
        let container = PeekContainerView()
        container.onCancel = onCancel
        container.borrow(session)
        return container
    }

    func updateNSView(_ container: PeekContainerView, context: Context) {
        container.onCancel = onCancel
        // Another run of the same row: show its session instead.
        if container.session !== session { container.borrow(session) }
        session.apply(theme: theme, fontSize: fontSize, optionAsMeta: optionAsMeta)
    }

    static func dismantleNSView(_ container: PeekContainerView, coordinator: ()) {
        container.giveBack()
    }
}

final class PeekContainerView: NSView {
    private(set) weak var session: TerminalSession?
    var onCancel: () -> Void = {}

    func borrow(_ session: TerminalSession) {
        giveBack()
        self.session = session
        session.isBorrowed = true
        session.view.isReadOnly = true
        let view = session.view
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        needsLayout = true
    }

    /// Puts the view back in the terminal panel's hands (it re-hosts it when it shows it).
    func giveBack() {
        guard let session else { return }
        self.session = nil
        let view = session.view
        if view.superview === self { view.removeFromSuperview() }
        view.isReadOnly = false
        session.isBorrowed = false
    }

    override func layout() {
        super.layout()
        guard let session, session.view.superview === self else { return }
        if session.view.frame != bounds { session.view.frame = bounds }
        if bounds.width > 40, bounds.height > 20 { session.startIfNeeded() }
    }

    /// Clicks never reach the terminal (no focus, no mouse reports), except on its scroller.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSScroller ? hit : self
    }

    override func scrollWheel(with event: NSEvent) {
        if let view = session?.view, view.superview === self { view.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }

    // A click makes the peek (never the terminal view) first responder, so Esc closes it and
    // nothing typed reaches the process.
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel() }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }
}
