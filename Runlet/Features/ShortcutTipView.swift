import AppKit
import RunletCore
import SwiftUI

// Shortcut tips (#345): the tip a click on a command shows, over the tab's editor and output.
// Only these views read the tip, so it coming and going redraws nothing else in the window
// (#320). Nothing here takes the keyboard: the tip is part of the window, never a window of its
// own, and its button isn't focusable.

/// One edge of the tab's editor and output where a tip can show: `.bottom` (above the status
/// bar) or `.top`, when the caret's line is at the bottom.
struct ShortcutTipHost: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window
    let edge: VerticalEdge

    var body: some View {
        let current = model.shortcutTips.current
        ZStack {
            if let tip = current, tip.windowId == window.id, tip.edge == edge {
                ShortcutTipView(tip: tip)
                    .padding(10)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: current?.id)
    }
}

/// The tip: the shortcut as key caps, a sentence, and Don't Show Again.
struct ShortcutTipView: View {
    @Environment(AppModel.self) private var model
    let tip: ShortcutTip

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    ForEach(Array(tip.keys.enumerated()), id: \.offset) { _, key in
                        ShortcutKeyCap(key: key)
                    }
                }
                Text(tip.predicate)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // One element for VoiceOver, which reads the keys by name.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tip.text)
            .accessibilityAddTraits(.isStaticText)
            Button("Don't Show Again") { model.dontShowShortcutTip(tip) }
                .controlSize(.small)
                .focusable(false)
                .fixedSize()
                .help("Don't show this command's shortcut tip again. Settings ▸ General ▸ Tips turns off every tip.")
                .accessibilityIdentifier("shortcut-tip-dont-show")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shortcut-tip")
    }
}

/// One key of a shortcut, drawn like a key cap.
private struct ShortcutKeyCap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.callout.weight(.medium))
            .frame(minWidth: 13)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.5)))
    }
}

/// Behind the tab's editor and output: tells the tip presenter where they are, so a tip finds
/// out whether the caret's line is where it would show (`ShortcutTipPresenter.edge(in:)`).
struct ShortcutTipAnchor: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window

    func makeNSView(context: Context) -> NSView {
        AnchorView(presenter: model.shortcutTips, windowId: window.id)
    }

    func updateNSView(_ view: NSView, context: Context) {}

    /// Draws nothing and is never hit, so clicks go to the editor and output above it. It
    /// registers itself once it is in a window: SwiftUI makes a new one when the tab or the tab
    /// layout changes, and may make one it never shows.
    private final class AnchorView: NSView {
        private weak var presenter: ShortcutTipPresenter?
        private let windowId: UUID

        init(presenter: ShortcutTipPresenter, windowId: UUID) {
            self.presenter = presenter
            self.windowId = windowId
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { presenter?.setAnchor(self, for: windowId) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var isOpaque: Bool { false }
    }
}
