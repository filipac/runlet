import AppKit
import RunletCore
import SwiftUI

/// The Quick Run panel's window (#25): borderless, above other apps' windows, and
/// non-activating, so it takes the keyboard without bringing Runlet's windows forward, as
/// Spotlight does. It never becomes main: menu commands keep their editor window.
final class QuickRunPanel: NSPanel {
    /// Whether the panel may take the keyboard. Scripted Debug runs (RUNLET_DEBUG_STEPS) show it
    /// without, with `orderFrontRegardless`: a floating panel with the keyboard would take it
    /// from whatever app the person checking is using.
    static let mayTakeKeyboard: Bool = {
        #if DEBUG
        return !ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("RUNLET_DEBUG_") }
        #else
        return true
        #endif
    }()

    weak var model: AppModel?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: QuickRunView.width, height: 120), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Quick Run"
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        setAccessibilityIdentifier("quick-run-panel")
    }

    override var canBecomeKey: Bool { Self.mayTakeKeyboard }
    override var canBecomeMain: Bool { false }

    /// Esc anywhere in the panel closes it (the editor's own Esc does too, once completions and
    /// the find bar don't need it).
    override func cancelOperation(_ sender: Any?) {
        model?.closeQuickRun()
    }

    /// The panel's keys come first: ⌘R runs it (nothing else does), ⌘↩ opens it in a tab, ⌘.
    /// stops it, and ⌘W closes it. Runlet may not be the active app while the panel has the
    /// keyboard, so the editing keys are sent to the editor here too.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let model else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command {
            switch (key, event.keyCode) {
            case ("r", _):
                model.runQuickRun()
                return true
            case (_, 36), (_, 76):
                model.openQuickRunInTab()
                return true
            case (".", _):
                model.stopQuickRun()
                return true
            case ("w", _):
                model.closeQuickRun()
                return true
            default:
                break
            }
        }
        if super.performKeyEquivalent(with: event) { return true }
        let action: Selector? = switch (key, flags) {
        case ("x", .command): #selector(NSText.cut(_:))
        case ("c", .command): #selector(NSText.copy(_:))
        case ("v", .command): #selector(NSText.paste(_:))
        case ("a", .command): #selector(NSText.selectAll(_:))
        case ("z", .command): Selector(("undo:"))
        case ("z", [.command, .shift]): Selector(("redo:"))
        case ("/", .command): #selector(CodeTextView.toggleLineComment(_:))
        default: nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return false
    }
}

/// Shows and places the Quick Run panel (#25). One panel for the app, made when it first opens.
@MainActor
final class QuickRunPanelController: NSObject, NSWindowDelegate {
    private(set) static var current: QuickRunPanelController?

    static func shared(model: AppModel) -> QuickRunPanelController {
        if let current { return current }
        let controller = QuickRunPanelController(model: model)
        current = controller
        return controller
    }

    let panel = QuickRunPanel()
    private let hosting: NSHostingView<AnyView>
    /// Where the panel's top-left corner was dragged to, for the rest of this launch.
    private var movedTopLeft: NSPoint?
    private var placing = false

    /// Whether the panel has the keyboard.
    var hasKeyboard: Bool { panel.isVisible && panel.isKeyWindow }

    private init(model: AppModel) {
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        super.init()
        panel.model = model
        panel.delegate = self
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        hosting.sizingOptions = []
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)
        panel.contentView = effect
        hosting.rootView = AnyView(QuickRunView(controller: self).environment(model))
    }

    /// Puts the panel on screen with the keyboard in its editor (scripted Debug runs: without the
    /// keyboard, and Runlet stays in the background).
    func show(_ tab: TabModel) {
        if !panel.isVisible { place(size: panel.frame.size, fresh: true) }
        if QuickRunPanel.mayTakeKeyboard {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        panel.makeFirstResponder(tab.editor.textView)
    }

    /// Takes the panel off screen. `releasing` is a tab that moves to a window (Open in Tab): its
    /// editor leaves the panel first.
    func hide(releasing tab: TabModel? = nil) {
        panel.orderOut(nil)
        if let tab, tab.editorIfLoaded?.scrollView.window === panel {
            tab.editor.scrollView.removeFromSuperview()
        }
    }

    /// The content's size changed (a new line, a result): the top edge stays where it is.
    func contentSizeChanged(_ size: CGSize) {
        place(size: size, fresh: !panel.isVisible)
    }

    /// A fresh panel opens where it was dragged to, or centered near the top of the screen with
    /// the pointer, as Spotlight does; afterwards it grows and shrinks downwards.
    private func place(size: CGSize, fresh: Bool) {
        guard size.width > 0, size.height > 0 else { return }
        let top: NSPoint
        if !fresh {
            top = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        } else if let movedTopLeft {
            top = movedTopLeft
        } else {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            top = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - (visible.height * 0.2).rounded())
        }
        var frame = NSRect(x: top.x.rounded(), y: (top.y - size.height).rounded(), width: size.width, height: size.height)
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame, frame.minY < visible.minY {
            frame.origin.y = visible.minY
        }
        guard frame != panel.frame else { return }
        placing = true
        panel.setFrame(frame, display: true)
        placing = false
        panel.invalidateShadow()
    }

    func windowDidMove(_ notification: Notification) {
        guard !placing, panel.isVisible else { return }
        movedTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }
}

/// The panel's content: a target, a small editor that grows with its lines, and the last run's
/// result, errors, and printed output.
struct QuickRunView: View {
    static let width: CGFloat = 640
    @Environment(AppModel.self) private var model
    let controller: QuickRunPanelController

    var body: some View {
        Group {
            if let tab = model.quickRun.tab {
                QuickRunContent(tab: tab)
            }
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { controller.contentSizeChanged($0) }
    }
}

private struct QuickRunContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let tab: TabModel
    @State private var editorHeight: CGFloat = 36
    @State private var outputHeight: CGFloat = 0

    var body: some View {
        let refusal = model.quickRun.refusal ?? model.quickRunRefusal(for: tab.target)
        let rows = shownRows
        VStack(alignment: .leading, spacing: 0) {
            header
            QuickRunEditorView(controller: tab.editor, preferences: preferences, code: tab.code, height: $editorHeight)
                .frame(height: editorHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
                .padding(.horizontal, 12)
                .accessibilityIdentifier("quick-run-editor")
            if let refusal {
                Label(refusal, systemImage: "hand.raised.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .accessibilityIdentifier("quick-run-refusal")
            }
            if !rows.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            item(row)
                                .padding(.bottom, row.continues || row.id == rows.last?.id ? 0 : 8)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { outputHeight = $0 }
                }
                .frame(height: min(max(outputHeight, 1), 340))
                .accessibilityIdentifier("quick-run-output")
            }
            footer
        }
    }

    /// The run's cards, without its header and finished line (the footer has its status).
    private var shownRows: [OutputRow] {
        tab.outputRows.rows.filter { row in
            switch row.item {
            case .header, .finished: false
            default: true
            }
        }
    }

    @ViewBuilder
    private func item(_ row: OutputRow) -> some View {
        if case .error(_, let error, let line) = row.item, error.interruptedByStop != true {
            QuickRunErrorRow(error: error, line: line, tab: tab)
        } else {
            OutputItemView(item: row.item, tab: tab, piece: row.piece)
        }
    }

    private var preferences: EditorPreferences {
        var preferences = EditorPreferences(settings: model.settings, dark: colorScheme == .dark)
        // A few lines that wrap, without the line numbers' gutter.
        preferences.softWrap = true
        return preferences
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill").foregroundStyle(Color.accentColor)
            Text("Quick Run").font(.headline)
            Menu {
                ForEach(model.quickRunTargets, id: \.self) { target in
                    Button {
                        model.setQuickRunTarget(target)
                    } label: {
                        Label(model.targetLabel(target) + TargetMenu.environmentSuffix(model.library.environment(for: target)), systemImage: model.targetSymbol(target))
                    }
                }
            } label: {
                Label(model.targetLabel(tab.target), systemImage: model.targetSymbol(tab.target))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Where Quick Run runs the code. Production targets are never offered.")
            .accessibilityIdentifier("quick-run-target")
            EnvironmentBadge(environment: model.library.environment(for: tab.target))
            Spacer()
            if tab.isRunning {
                Button {
                    model.stopQuickRun()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderless)
                .help("Stop (⌘.)")
            }
            Button {
                model.closeQuickRun()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close (Esc). The code stays for next time.")
            .accessibilityIdentifier("quick-run-close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            status
            Spacer()
            Text("⌘R run · esc close")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open in Tab") { model.openQuickRunInTab() }
                .controlSize(.small)
                .help("Move the code and its target into a new tab in Runlet's window (⌘↩). Nothing runs.")
                .disabled(tab.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("quick-run-open-in-tab")
            Text("⌘↩").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var status: some View {
        switch tab.runState {
        case .idle:
            Text(tab.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Type PHP, then press ⌘R" : "Nothing runs until you press ⌘R")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .preparing, .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Running on \(model.targetLabel(tab.target))…").font(.caption).foregroundStyle(.secondary)
            }
        case .stopping:
            Text("Stopping…").font(.caption).foregroundStyle(.secondary)
        case .finished(let info):
            Label("\(info.status.label) · \(info.elapsedMs.formatted()) ms", systemImage: info.status.symbol)
                .font(.caption)
                .foregroundStyle(info.status.color)
                .accessibilityIdentifier("quick-run-status")
        }
    }
}

/// An error in the panel, compactly: its class, message, and line. Open in Tab shows the whole
/// card, with the source and the stack trace.
private struct QuickRunErrorRow: View {
    let error: RunErrorInfo
    let line: Int?
    let tab: TabModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(error.className ?? "Error").font(.callout.weight(.semibold))
                    if let line {
                        Button("line \(line)") { tab.editor.goTo(line: line) }
                            .buttonStyle(.link)
                            .font(.caption)
                            .accessibilityIdentifier("quick-run-error-line")
                    }
                }
                Text(error.message)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.red.opacity(0.3)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("quick-run-error")
    }
}

/// The panel's editor: the tab's own editor (PHP highlighting, completion, magic comments),
/// without line numbers, as tall as its lines up to ten.
private struct QuickRunEditorView: NSViewRepresentable {
    let controller: EditorController
    var preferences: EditorPreferences
    /// The text, so an edit measures the height again.
    var code: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        QuickRunEditorStyle.apply(to: controller)
        context.coordinator.height = $height
        context.coordinator.measure(controller, lineHeight: preferences.lineHeight)
    }

    @MainActor
    final class Coordinator {
        var height: Binding<CGFloat>?

        /// The text's height, between one line and ten, plus the editor's insets.
        func measure(_ controller: EditorController, lineHeight multiple: CGFloat) {
            let textView = controller.textView
            guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let line = layout.defaultLineHeight(for: textView.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)) * multiple
            let used = max(layout.usedRect(for: container).height, line)
            let measured = (min(used, line * 10) + textView.textContainerInset.height * 2).rounded(.up)
            guard let height, abs(height.wrappedValue - measured) > 0.5 else { return }
            DispatchQueue.main.async { height.wrappedValue = measured }
        }
    }
}

/// How the panel shows a tab's editor (#25), and how Open in Tab gives it back to a window.
@MainActor
enum QuickRunEditorStyle {
    /// No line numbers' gutter and no horizontal scroller: a few lines that wrap.
    static func apply(to controller: EditorController) {
        if controller.scrollView.rulersVisible { controller.scrollView.rulersVisible = false }
        if controller.scrollView.hasHorizontalScroller { controller.scrollView.hasHorizontalScroller = false }
    }

    /// The line numbers return; the window applies the editor settings (soft wrap) when it shows it.
    static func restore(_ controller: EditorController) {
        controller.scrollView.rulersVisible = true
    }
}
