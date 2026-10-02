import AppKit
import SwiftUI

/// Hosts one window's content, keyed by its WindowModel id. Wires the NSWindow to the model:
/// title/proxy icon, the "edited" dot for workspaces, the close-button guard, and focus.
struct WindowRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let windowId: UUID

    var body: some View {
        Group {
            if let window = model.window(windowId) {
                MainWindow()
                    .environment(window)
                    .navigationTitle(window.title)
                    .background(WindowAccessor(window: window, model: model))
            } else {
                ProgressView().frame(minWidth: 760, minHeight: 420)
            }
        }
        .task {
            _ = model.ensureWindow(windowId)
            model.openWindowAction = { id in openWindow(id: "main", value: id) }
            // Bring back the other windows from the last session (once).
            let pending = model.pendingLaunchWindowIds.filter { $0 != windowId }
            model.pendingLaunchWindowIds = []
            for id in pending { openWindow(id: "main", value: id) }
            // Files opened at launch are handled once a window is visible.
            try? await Task.sleep(for: .milliseconds(150))
            model.windowPresented()
        }
        .onDisappear { model.windowDidClose(windowId) }
    }
}

/// Reaches the hosting NSWindow to set document-like state SwiftUI doesn't expose.
struct WindowAccessor: NSViewRepresentable {
    let window: WindowModel
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = AccessorView()
        view.onWindow = { [weak coordinator = context.coordinator] nsWindow in
            coordinator?.attach(nsWindow, window: window, model: model)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.apply(window: window)
    }

    final class AccessorView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var nsWindow: NSWindow?
        weak var window: WindowModel?
        weak var model: AppModel?
        private var keyObserver: NSObjectProtocol?

        func attach(_ nsWindow: NSWindow, window: WindowModel, model: AppModel) {
            guard self.nsWindow !== nsWindow else { return }
            self.nsWindow = nsWindow
            self.window = window
            self.model = model
            nsWindow.tabbingMode = .disallowed
            // Closing asks first when code would be lost (workspace or scratch tabs).
            if let close = nsWindow.standardWindowButton(.closeButton) {
                close.target = self
                close.action = #selector(closeRequested(_:))
            }
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nsWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    self.model?.windowBecameActive(window.id)
                }
            }
            if nsWindow.isKeyWindow { model.windowBecameActive(window.id) }
            apply(window: window)
        }

        func apply(window: WindowModel) {
            guard let nsWindow else { return }
            nsWindow.representedURL = window.workspaceURL
            nsWindow.isDocumentEdited = window.isWorkspaceEdited
            nsWindow.setAccessibilityIdentifier("window-\(window.title)")
        }

        @objc func closeRequested(_ sender: Any?) {
            guard let nsWindow, let window, let model else { return }
            if model.confirmClose(window, presenting: nsWindow) {
                nsWindow.close()
            }
        }
    }
}
