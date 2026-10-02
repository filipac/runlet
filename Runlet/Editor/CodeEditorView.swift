import AppKit
import SwiftUI

/// Hosts the selected tab's persistent editor. Switching tabs swaps which scroll view is
/// installed; editors are never recreated by SwiftUI updates.
struct CodeEditorView: NSViewRepresentable {
    let controller: EditorController
    var fontSize: CGFloat
    var tabWidth: Int
    var insertSpaces: Bool
    var isDark: Bool

    func makeNSView(context: Context) -> EditorHostView {
        let host = EditorHostView()
        host.install(controller)
        return host
    }

    func updateNSView(_ host: EditorHostView, context: Context) {
        let settingsKey = "\(fontSize)|\(tabWidth)|\(insertSpaces)|\(isDark)"
        if host.controller !== controller {
            host.install(controller)
            host.appliedSettings = nil
        }
        if host.appliedSettings != settingsKey {
            controller.applySettings(fontSize: fontSize, tabWidth: tabWidth, insertSpaces: insertSpaces, dark: isDark)
            host.appliedSettings = settingsKey
        }
    }
}

final class EditorHostView: NSView {
    private(set) weak var controller: EditorController?
    var appliedSettings: String?

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
        DispatchQueue.main.async { controller.focus() }
    }
}
