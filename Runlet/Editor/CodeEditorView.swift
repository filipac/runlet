import AppKit
import SwiftUI

/// Hosts the selected tab's persistent editor. Switching tabs swaps which scroll view is
/// installed; editors are never recreated by SwiftUI updates.
struct CodeEditorView: NSViewRepresentable {
    let controller: EditorController
    /// Font, line height, ligatures, soft wrap, indentation, and appearance. Re-applied to the
    /// persistent editor only when it changes (or a different tab's editor is installed).
    var preferences: EditorPreferences

    func makeNSView(context: Context) -> EditorHostView {
        let host = EditorHostView()
        host.install(controller)
        return host
    }

    func updateNSView(_ host: EditorHostView, context: Context) {
        if host.controller !== controller {
            host.install(controller)
            host.appliedPreferences = nil
        }
        if host.appliedPreferences != preferences {
            controller.applySettings(preferences)
            host.appliedPreferences = preferences
        }
    }
}

final class EditorHostView: NSView {
    private(set) weak var controller: EditorController?
    var appliedPreferences: EditorPreferences?

    func install(_ controller: EditorController) {
        subviews.forEach { $0.removeFromSuperview() }
        self.controller = controller
        let scrollView = controller.scrollView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        DispatchQueue.main.async {
            if controller.revealStartOnNextInstall {
                self.layoutSubtreeIfNeeded()
                controller.revealStartIfRequested()
            }
            controller.focus()
        }
    }
}
