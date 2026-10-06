import AppKit
import Observation
import RunletCore
import SwiftUI

/// One window's terminal tabs. Owned by the WindowModel; sessions end when the window closes
/// or Runlet quits.
@MainActor
@Observable
final class TerminalPanelModel {
    var sessions: [TerminalSession] = []
    var selectedId: UUID?
    /// nil until the window first appears; then initialized from `AppSettings.terminalVisible`
    /// and changed only by this window's own toggle.
    var isVisible: Bool?
    /// Bumped to move keyboard focus into the selected terminal.
    var focusRequest = 0
    /// The last focus request a terminal view acted on.
    @ObservationIgnored var handledFocusRequest = 0

    var selected: TerminalSession? { sessions.first { $0.id == selectedId } ?? sessions.last }

    func add(_ session: TerminalSession, focus: Bool = true) {
        sessions.append(session)
        select(session.id, focus: focus)
    }

    func select(_ id: UUID, focus: Bool = true) {
        selectedId = id
        if focus { focusRequest += 1 }
    }

    /// Adds a tab without selecting it or moving focus: the panel keeps showing its tab.
    func addInBackground(_ session: TerminalSession) {
        if selectedId == nil, let current = selected { selectedId = current.id }
        sessions.append(session)
    }

    /// Puts `session` in the place of tab `id` (Run Again) and selects it (in the background:
    /// selected only when tab `id` was, and without moving focus).
    func replace(_ id: UUID, with session: TerminalSession, inBackground: Bool = false) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            if inBackground { addInBackground(session) } else { add(session) }
            return
        }
        let wasSelected = selected?.id == id
        sessions[index] = session
        if !inBackground {
            select(session.id)
        } else if wasSelected {
            select(session.id, focus: false)
        }
    }

    /// Removes the tab (the caller has terminated or confirmed it). Returns true when it was the last one.
    @discardableResult
    func remove(_ id: UUID) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return sessions.isEmpty }
        sessions.remove(at: index)
        if selectedId == id, !sessions.isEmpty {
            selectedId = sessions[min(index, sessions.count - 1)].id
            focusRequest += 1
        }
        return sessions.isEmpty
    }

    func terminateAll() {
        for session in sessions { session.terminate() }
        sessions = []
        selectedId = nil
    }

    func hangUpAll() {
        for session in sessions { session.hangUp() }
    }
}

/// Bottom panel with its own tab strip and the selected session's terminal. Height is
/// resizable by the handle on top and remembered in `AppSettings.terminalHeight`.
struct TerminalPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window
    @Environment(\.colorScheme) private var colorScheme
    /// Largest height that still leaves room for the editor.
    var maxHeight: Double
    @State private var liveHeight: Double?

    private var panel: TerminalPanelModel { window.terminals }

    var body: some View {
        let height = min(maxHeight, max(TerminalResizeHandle.minimum, liveHeight ?? model.settings.terminalHeight))
        VStack(spacing: 0) {
            TerminalResizeHandle(height: $liveHeight, committed: height, maximum: maxHeight) { value in
                model.settings.terminalHeight = value
            }
            TerminalTabStrip()
            Divider()
            if let session = panel.selected {
                TerminalNoticeBar(session: session)
                TerminalHostView(
                    session: session,
                    panel: panel,
                    theme: TerminalTheme(isDark: colorScheme == .dark),
                    fontSize: model.settings.fontSize,
                    optionAsMeta: model.settings.terminalOptionAsMeta,
                    focusRequest: panel.focusRequest
                )
            } else {
                Color(nsColor: .textBackgroundColor)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-panel")
        .onAppear {
            // A window that opens with the panel shown gets a shell, without taking focus.
            if panel.sessions.isEmpty { model.newTerminal(in: window, focus: false) }
        }
    }
}

/// Tabs, "+" (new shell; menu adds a container shell for Docker targets), and hide.
struct TerminalTabStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window

    private var panel: TerminalPanelModel { window.terminals }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(panel.sessions) { session in
                        tab(session)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            }
            Spacer(minLength: 4)
            newMenu
            Button {
                model.setTerminalVisible(false, in: window)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .help("Hide Terminal (⌃`)")
            .accessibilityIdentifier("terminal-hide-button")
        }
        .frame(height: 28)
        .background(.bar)
    }

    private var newMenu: some View {
        Menu {
            Button("New Shell") { model.newTerminal(in: window) }
            if let tab = window.selectedTab, case .docker(let id) = tab.target, let profile = model.library.dockerProfile(id) {
                Button("Shell in \(profile.name) Container") { model.openContainerShell(for: tab, in: window) }
            }
            if let tab = window.selectedTab, case .ssh(let id) = tab.target, let profile = model.library.sshProfile(id) {
                Button(model.sshShellTitle(profile)) { model.openSSHShell(for: tab, in: window) }
                if profile.container != nil {
                    Button(model.sshShellTitle(profile, onHost: true)) { model.openSSHShell(for: tab, in: window, onHost: true) }
                }
            }
            Divider()
            Toggle("Use Option as Meta Key", isOn: Binding(
                get: { model.settings.terminalOptionAsMeta },
                set: { model.settings.terminalOptionAsMeta = $0 }
            ))
        } label: {
            Image(systemName: "plus")
        } primaryAction: {
            model.newTerminal(in: window)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 4)
        .help("New Shell (⌃⇧`)")
        .accessibilityIdentifier("terminal-new-button")
    }

    @ViewBuilder
    private func tab(_ session: TerminalSession) -> some View {
        let selected = session.id == panel.selected?.id
        HStack(spacing: 5) {
            Image(systemName: session.symbolName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(session.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.callout)
                .frame(maxWidth: 200, alignment: .leading)
                .foregroundStyle(session.isRunning ? .primary : .secondary)
            switch session.state {
            case .exited(let code) where code == 0:
                Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    .help("Finished")
            case .exited(let code):
                Image(systemName: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.orange)
                    .help(code.map { "Exited with code \($0)" } ?? "Exited")
            case .failed(let message):
                Image(systemName: "xmark.octagon.fill").font(.caption).foregroundStyle(.red).help(message)
            default:
                EmptyView()
            }
            Button {
                model.closeTerminal(session.id, in: window)
            } label: {
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .buttonStyle(.borderless)
            .opacity(selected ? 1 : 0.5)
            .help("Close Terminal")
            .accessibilityIdentifier("terminal-close-\(session.title)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { panel.select(session.id) }
        .help(session.title)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("terminal-tab-\(session.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            if session.isFinishedCommand {
                Button("Run Again") { model.runTerminalAgain(session.id, in: window) }
            }
            Button("Close") { model.closeTerminal(session.id, in: window) }
        }
    }
}

/// A slim bar above the terminal: a command still waiting for the shell's first prompt
/// (Run Now / Don't Run), or a finished command tab (Run Again / Close). Nothing otherwise.
struct TerminalNoticeBar: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window
    let session: TerminalSession

    var body: some View {
        if session.isWaitingForShell, let command = session.request.commandLine {
            bar(icon: "hourglass", text: "“\(command)” runs when the shell shows its prompt. It may be waiting for an answer.") {
                Button("Run Now") { session.runPendingCommand() }
                    .accessibilityIdentifier("terminal-run-now")
                Button("Don't Run") { session.discardPendingCommand() }
                    .accessibilityIdentifier("terminal-dont-run")
            }
        } else if session.isFinishedCommand, case .exited(let code) = session.state {
            bar(icon: code == 0 ? "checkmark.circle" : "exclamationmark.circle", text: code.map { "Exited with code \($0)." } ?? "Exited.") {
                Button("Run Again") { model.runTerminalAgain(session.id, in: window) }
                    .accessibilityIdentifier("terminal-run-again")
                Button("Close") { model.closeTerminal(session.id, in: window) }
            }
        }
    }

    private func bar<Actions: View>(icon: String, text: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                actions()
                    .buttonStyle(.borderless)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            Divider()
        }
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-notice")
    }
}

/// Hosts the session's long-lived terminal view; starts the process once it has a size and
/// moves keyboard focus into it when asked.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession
    let panel: TerminalPanelModel
    let theme: TerminalTheme
    let fontSize: Double
    let optionAsMeta: Bool
    let focusRequest: Int

    func makeNSView(context: Context) -> TerminalContainerView {
        TerminalContainerView()
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        session.apply(theme: theme, fontSize: fontSize, optionAsMeta: optionAsMeta)
        container.host(session)
        if panel.handledFocusRequest != focusRequest {
            panel.handledFocusRequest = focusRequest
            container.focusWhenReady()
        }
    }

    static func dismantleNSView(_ container: TerminalContainerView, coordinator: ()) {
        container.unhost()
    }
}

final class TerminalContainerView: NSView {
    private(set) weak var session: TerminalSession?

    func host(_ session: TerminalSession) {
        guard self.session !== session || session.view.superview !== self else { return }
        unhost()
        self.session = session
        let view = session.view
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        needsLayout = true
    }

    func unhost() {
        if let view = session?.view, view.superview === self { view.removeFromSuperview() }
        session = nil
    }

    override func layout() {
        super.layout()
        guard let session else { return }
        if session.view.frame != bounds { session.view.frame = bounds }
        if bounds.width > 40, bounds.height > 20 { session.startIfNeeded() }
    }

    func focusWhenReady() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.session?.view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }
}

/// Draggable divider above the terminal panel (drag up to grow).
struct TerminalResizeHandle: View {
    static let minimum: Double = 90
    @Binding var height: Double?
    var committed: Double
    var maximum: Double
    var onCommit: (Double) -> Void
    @State private var startHeight: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startHeight ?? (height ?? committed)
                        if startHeight == nil { startHeight = start }
                        height = min(maximum, max(Self.minimum, start - value.translation.height))
                    }
                    .onEnded { _ in
                        if let height { onCommit(height) }
                        startHeight = nil
                        height = nil
                    }
            )
            .accessibilityIdentifier("terminal-resize-handle")
    }
}
