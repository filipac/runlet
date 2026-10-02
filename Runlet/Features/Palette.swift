import AppKit
import RunletCore
import SwiftUI

enum PaletteMode: Equatable {
    /// ⌘P: targets, snippets, recent files (prefixes switch scope).
    case anything
    /// ⇧⌘P: every command with its shortcut.
    case commands
}

/// One palette result.
struct PaletteItem: Identifiable {
    enum Kind: String { case command = "Command", target = "Target", snippet = "Snippet", file = "Recent", history = "History" }

    var id: String
    var kind: Kind
    var title: String
    var subtitle: String
    var symbol: String
    var badge: String?
    var isCurrent = false
    /// More text the search matches besides the title and subtitle (a history entry's code).
    var searchText: String?
    /// `newTab` is true for ⌘↩.
    var perform: @MainActor (_ newTab: Bool) -> Void
}

/// Open Anything (⌘P) and the Command Palette (⇧⌘P). Fuzzy search, ↑/↓ to move, ↩ to run,
/// ⌘↩ to open in a new tab, esc or a click outside to close. Choosing a target, snippet, or
/// file never runs code.
///
/// Open Anything scopes its search with a prefix: `/` local projects · `@` Docker profiles ·
/// `#` snippets · `!` history (the current tab's project first). Typing `>` first switches to
/// commands; ⌫ in an empty command search switches back. The mode is shown beside the field,
/// never as text in it that typing could replace.
struct PaletteView: View {
    @Environment(AppModel.self) private var model
    let controller: PaletteController
    @State private var selection = 0

    private var query: String { controller.query }
    private var isCommandMode: Bool { controller.mode == .commands }

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if isCommandMode {
                    Label("Commands", systemImage: "command")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .fixedSize()
                        .accessibilityIdentifier("palette-mode")
                } else {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                }
                PaletteSearchField(
                    controller: controller,
                    placeholder: isCommandMode ? "Type a command" : "Search targets, snippets, files — > commands, / projects, @ Docker, # snippets, ! history",
                    onMove: { delta in selection = min(max(selection + delta, 0), max(0, results.count - 1)) },
                    onSubmit: { newTab in choose(results, newTab: newTab) }
                )
            }
            .padding(12)
            Divider()
            if items.isEmpty {
                Text("No matches").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            // Rows are identified by their item, never by position, so a reused
                            // row can't keep showing an earlier result.
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(item, selected: index == selection)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) {
                                        selection = index
                                        choose(items, newTab: false)
                                    }
                                    .onTapGesture { selection = index }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: min(CGFloat(items.count) * 40 + 8, 380))
                    .onChange(of: selection) {
                        if items.indices.contains(selection) { proxy.scrollTo(items[selection].id) }
                    }
                }
            }
            Divider()
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .frame(width: 620)
        // The panel is sized to the palette, which grows and shrinks with the results.
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { controller.contentSizeChanged($0) }
        .onChange(of: query) { selection = 0 }
        .onChange(of: controller.mode) { selection = 0 }
    }

    private var footer: String {
        guard isCommandMode else { return "↩ open · ⌘↩ new tab · > commands · / projects · @ Docker · # snippets · ! history" }
        let anything = model.shortcut(for: "library.openAnything").map { "⌫ or \($0.displayString)" } ?? "⌫"
        return "↩ run command · \(anything) open anything · esc close"
    }

    @ViewBuilder
    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .frame(width: 18)
                .foregroundStyle(selected ? Color.white : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.caption).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            Spacer()
            if item.isCurrent {
                Text("current").font(.caption).foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
            if let badge = item.badge {
                Text(badge)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.white.opacity(0.2) : Color.secondary.opacity(0.12)))
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(minHeight: 36)
        .background(selected ? Color.accentColor : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("palette-row")
    }

    // MARK: Results

    private var results: [PaletteItem] {
        var text = query
        var pool: [PaletteItem]
        if isCommandMode {
            pool = commandItems
        } else if text.hasPrefix("/") {
            text.removeFirst()
            pool = targetItems.filter { $0.id.hasPrefix("target.local") }
        } else if text.hasPrefix("@") {
            text.removeFirst()
            pool = targetItems.filter { $0.id.hasPrefix("target.docker") }
        } else if text.hasPrefix("#") {
            text.removeFirst()
            pool = snippetItems
        } else if text.hasPrefix("!") {
            text.removeFirst()
            pool = historyItems
        } else {
            pool = targetItems + snippetItems + fileItems
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(pool.prefix(60)) }
        // Best match first; equal scores keep the list's own order.
        let scored: [(item: PaletteItem, score: Int, index: Int)] = pool.enumerated().compactMap { index, item in
            FuzzyMatch.score(trimmed, fields: [item.title, item.subtitle] + (item.searchText.map { [$0] } ?? [])).map { (item, $0, index) }
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .prefix(60)
            .map(\.item)
    }

    private var commandItems: [PaletteItem] {
        CommandCatalog.all.filter { $0.isEnabled(model) && $0.id != "library.commandPalette" }.map { command in
            PaletteItem(id: "command.\(command.id)", kind: .command, title: command.title,
                        subtitle: (command.isChecked?(model) == true ? "On · " : "") + command.category.rawValue + (command.keywords.isEmpty ? "" : " · " + command.keywords),
                        symbol: "command", badge: model.shortcut(for: command.id)?.displayString) { _ in
                model.perform(command.id)
            }
        }
    }

    private var targetItems: [PaletteItem] {
        let current = model.selectedTab?.target
        var items: [PaletteItem] = [
            PaletteItem(id: "target.sandbox", kind: .target, title: model.targetLabel(.sandbox), subtitle: "Bundled Laravel application", symbol: "shippingbox", badge: "Sandbox", isCurrent: current == .sandbox) { newTab in
                useTarget(.sandbox, newTab: newTab)
            },
        ]
        items += model.library.localProjects.sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }.map { project in
            PaletteItem(id: "target.local.\(project.id)", kind: .target, title: project.name, subtitle: (project.path as NSString).abbreviatingWithTildeInPath, symbol: "folder", badge: "Local", isCurrent: current == .local(project.id)) { newTab in
                useTarget(.local(project.id), newTab: newTab)
            }
        }
        items += model.library.dockerProfiles.sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }.map { profile in
            PaletteItem(id: "target.docker.\(profile.id)", kind: .target, title: profile.name, subtitle: "\(profile.identity.displayName) · \(profile.workingDirectory)", symbol: "cube.box", badge: "Docker", isCurrent: current == .docker(profile.id)) { newTab in
                useTarget(.docker(profile.id), newTab: newTab)
            }
        }
        return items
    }

    private var snippetItems: [PaletteItem] {
        var items: [PaletteItem] = []
        if let target = model.selectedTab?.target {
            let project = model.projectName(for: target) ?? "Project"
            items += model.projectSnippets(for: target).map { snippet in
                PaletteItem(id: "project-snippet.\(snippet.id)", kind: .snippet, title: snippet.label, subtitle: project + " · " + (snippet.description ?? snippet.fileURL.lastPathComponent), symbol: "folder.badge.gearshape", badge: "Project") { newTab in
                    model.open(snippet, target: target, inNewTab: newTab)
                }
            }
        }
        return items + model.snippets.map { snippet in
            let firstLine = snippet.code.split(separator: "\n").first.map(String.init) ?? ""
            return PaletteItem(id: "snippet.\(snippet.id)", kind: .snippet, title: snippet.label, subtitle: (snippet.targetLabel.map { $0 + " · " } ?? "") + firstLine, symbol: "bookmark", badge: "Snippet") { newTab in
                model.open(snippet, inNewTab: newTab)
            }
        }
    }

    private var fileItems: [PaletteItem] {
        NSDocumentController.shared.recentDocumentURLs
            .filter { ["php", WorkspaceDocument.fileExtension].contains($0.pathExtension.lowercased()) }
            .prefix(15)
            .map { url in
                PaletteItem(id: "file.\(url.path)", kind: .file, title: url.lastPathComponent, subtitle: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                            symbol: url.pathExtension == WorkspaceDocument.fileExtension ? "rectangle.stack" : "doc.text", badge: url.pathExtension == WorkspaceDocument.fileExtension ? "Workspace" : "File") { _ in
                    model.open(url)
                }
            }
    }

    /// `!`: past runs, the current tab's project first. ↩ opens one where Settings says (like
    /// History's ↩), ⌘↩ in a new tab; neither runs it.
    private var historyItems: [PaletteItem] {
        let current = model.selectedTab?.target
        return HistoryLog.ordered(model.history, preferring: current).map { entry in
            let when = entry.timestamp.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
            return PaletteItem(id: "history.\(entry.id)", kind: .history, title: CodePreview.title(entry.code, maxLength: 80),
                               subtitle: "\(entry.targetLabel) · \(when) · \(entry.status.label)", symbol: entry.status.symbol,
                               badge: entry.target == current ? "This Project" : "History", searchText: String(entry.code.prefix(600))) { newTab in
                if newTab { model.restore(entry, inNewTab: true) } else { model.open(entry) }
            }
        }
    }

    private func useTarget(_ target: TargetRef, newTab: Bool) {
        if newTab {
            model.newTab(target: target)
        } else if let tab = model.selectedTab {
            model.setTarget(target, for: tab)
        }
    }

    private func choose(_ items: [PaletteItem], newTab: Bool) {
        guard items.indices.contains(selection) else { return }
        let item = items[selection]
        controller.close()
        // Run once the palette is gone and its window has focus again, so commands that
        // present sheets or panels, or act on the focused editor, work.
        DispatchQueue.main.async { item.perform(newTab) }
    }
}

/// The palette's search field. AppKit-backed so the palette decides where the caret goes (after
/// the text; SwiftUI's field selects everything on focus, so the first key typed replaced it)
/// and handles the list keys itself.
private struct PaletteSearchField: NSViewRepresentable {
    let controller: PaletteController
    let placeholder: String
    let onMove: (Int) -> Void
    let onSubmit: (_ newTab: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SearchTextField {
        let field = SearchTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .preferredFont(forTextStyle: .title3)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("palette-search")
        return field
    }

    func updateNSView(_ field: SearchTextField, context: Context) {
        context.coordinator.parent = self
        field.onCommandReturn = { onSubmit(true) }
        field.placeholderString = placeholder
        field.show(controller.query)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SearchTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteSearchField?

        func controlTextDidChange(_ notification: Notification) {
            guard let parent, let field = notification.object as? SearchTextField else { return }
            parent.controller.edit(field.stringValue)
            // A leading ">" switched to commands and was consumed.
            field.show(parent.controller.query)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let parent else { return false }
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
            case #selector(NSResponder.cancelOperation(_:)):
                parent.controller.close()
            case #selector(NSResponder.deleteBackward(_:)):
                return parent.controller.leaveCommandModeIfEmpty()
            default:
                return false
            }
            return true
        }
    }
}

private final class SearchTextField: NSTextField {
    var onCommandReturn: (() -> Void)?

    /// Shows `text` with the caret after it and nothing selected.
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
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        // The caret after the text instead of AppKit's select-all.
        currentEditor()?.selectedRange = NSRange(location: (stringValue as NSString).length, length: 0)
        return true
    }

    /// ⌘↩ opens the selection in a new tab (key equivalents reach views before the field editor).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if currentEditor() != nil, event.keyCode == 36 || event.keyCode == 76, modifiers == .command {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// One window's palette. It is a borderless child panel over the window, not a sheet: a click
/// anywhere outside it closes it (and is swallowed, like a popover's), and the menus' shortcuts
/// keep working while it is open, so Open Anything and Command Palette switch an open palette
/// between the two modes, or close it when it already shows that mode.
@MainActor
@Observable
final class PaletteController {
    /// What the palette lists.
    private(set) var mode: PaletteMode = .anything
    /// The search text. Command mode is not part of it, so typing can't replace it.
    private(set) var query = ""
    /// The window the palette opens over (set by `paletteHost(_:)`).
    @ObservationIgnored weak var hostWindow: NSWindow?
    @ObservationIgnored private var panel: PalettePanel?
    @ObservationIgnored private var clickMonitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    var isPresented: Bool { panel != nil }

    /// Opens the palette in `mode`, switches an open palette to it (keeping the typed text),
    /// or closes the palette when it already shows `mode`.
    func toggle(_ mode: PaletteMode, model: AppModel) {
        guard isPresented else { return open(mode, model: model) }
        if self.mode == mode {
            close()
        } else {
            query = PaletteQuery.carriedOver(query)
            self.mode = mode
        }
    }

    /// The search text as typed. A ">" typed first in Open Anything switches to commands and is
    /// consumed.
    func edit(_ text: String) {
        if mode == .anything, text.hasPrefix(">") {
            query = PaletteQuery.carriedOver(text)
            mode = .commands
        } else {
            query = text
        }
    }

    /// ⌫ in an empty command search goes back to Open Anything. Returns whether it did.
    func leaveCommandModeIfEmpty() -> Bool {
        guard mode == .commands, query.isEmpty else { return false }
        mode = .anything
        return true
    }

    /// Closes the palette and gives its window keyboard focus back.
    func close() {
        dismiss(focusing: hostWindow)
    }

    private func open(_ mode: PaletteMode, model: AppModel) {
        guard let parent = hostWindow, parent.isVisible else { return }
        self.mode = mode
        query = ""
        let content = NSHostingController(rootView: PaletteView(controller: self).environment(model))
        content.sizingOptions = []
        let panel = PalettePanel(content: content, controller: self)
        panel.appearance = parent.effectiveAppearance
        self.panel = panel
        place(size: content.sizeThatFits(in: CGSize(width: 10_000, height: 10_000)))
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)

        // A click outside closes the palette and goes no further, so it can't close a tab or
        // run code by accident; the clicked window takes focus if it can.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, event.window !== panel else { return event }
            guard panel.isVisible else {
                self.dismiss(focusing: nil)
                return event
            }
            self.dismiss(focusing: event.window.flatMap { $0.canBecomeKey ? $0 : nil } ?? self.hostWindow)
            ClickSwallower.swallowRest(of: event)
            return nil
        }
        // Focus moving to another window or app, or the window closing, closes it too.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss(focusing: nil) }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss(focusing: nil) }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss(focusing: nil) }
            },
        ]
    }

    private func dismiss(focusing window: NSWindow?) {
        guard let panel else { return }
        self.panel = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        window?.makeKeyAndOrderFront(nil)
        // Released on the next turn: this can run inside the panel's own event handling.
        DispatchQueue.main.async { withExtendedLifetime(panel) {} }
    }

    func contentSizeChanged(_ size: CGSize) {
        place(size: size)
    }

    /// Centred on the window just below its toolbar; the top edge stays put while the height
    /// follows the results.
    private func place(size: CGSize) {
        guard let panel, let parent = hostWindow, size.width > 0, size.height > 0 else { return }
        let top = parent.frame.minY + parent.contentLayoutRect.maxY - 10
        var frame = NSRect(x: (parent.frame.midX - size.width / 2).rounded(), y: top - size.height, width: size.width, height: size.height)
        if let visible = parent.screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = max(frame.minY, visible.minY)
        }
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }
}

/// The palette's borderless window. It takes keyboard focus but never becomes main, so the
/// window below keeps its active look and stays the target of menu commands.
final class PalettePanel: NSPanel {
    private let content: NSViewController
    private(set) weak var controller: PaletteController?

    init(content: NSViewController, controller: PaletteController) {
        self.content = content
        self.controller = controller
        super.init(contentRect: NSRect(x: 0, y: 0, width: 620, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        title = "Palette"
        isReleasedWhenClosed = false
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        content.view.frame = effect.bounds
        content.view.autoresizingMask = [.width, .height]
        effect.addSubview(content.view)
        contentView = effect
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        controller?.close()
    }
}

/// Swallows the rest of a click (drags and the release) whose mouse-down was swallowed, so
/// nothing under the pointer sees half a click.
private enum ClickSwallower {
    static func swallowRest(of down: NSEvent) {
        let (dragged, up): (NSEvent.EventType, NSEvent.EventType) = switch down.type {
        case .rightMouseDown: (.rightMouseDragged, .rightMouseUp)
        case .otherMouseDown: (.otherMouseDragged, .otherMouseUp)
        default: (.leftMouseDragged, .leftMouseUp)
        }
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, NSEvent.EventTypeMask(type: dragged), NSEvent.EventTypeMask(type: up)]) { event in
            if event.type == dragged { return nil }
            if let current = monitor { NSEvent.removeMonitor(current) }
            monitor = nil
            // A new click (the release went missing) passes through.
            return event.type == up ? nil : event
        }
    }
}

/// Gives a window's palette controller its NSWindow.
private struct PaletteAnchor: NSViewRepresentable {
    let controller: PaletteController

    func makeNSView(context: Context) -> NSView { AnchorView(controller: controller) }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class AnchorView: NSView {
        weak var controller: PaletteController?

        init(controller: PaletteController) {
            self.controller = controller
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { controller?.hostWindow = window }
        }
    }
}

extension View {
    /// Opens `controller`'s palette over this view's window.
    func paletteHost(_ controller: PaletteController) -> some View {
        background(PaletteAnchor(controller: controller))
    }
}

#if DEBUG
/// Development aid: with RUNLET_DEBUG_PALETTE=anything|commands, drives the palette with key
/// and mouse events sent to Runlet only (no UI scripting), using the menus' own (possibly
/// remapped) shortcuts: open, type "dock", switch modes and back, close with the same
/// shortcut; in Open Anything type "> docker" (commands), ⌫ until it is back in Open Anything,
/// ⌘↩ (the sandbox in a new tab); then click the window's New Tab button, which must only
/// close the palette, and click it again. Logs each step to stderr, snapshots the windows when
/// RUNLET_SNAPSHOT_DIR is set, and quits. Use with RUNLET_DATA_DIR pointing at scratch data.
enum PaletteDebugCheck {
    static func runIfRequested(model: AppModel?) {
        guard let model, let name = ProcessInfo.processInfo.environment["RUNLET_DEBUG_PALETTE"],
              let mode = ["anything": PaletteMode.anything, "commands": .commands][name] else { return }
        let first = mode == .commands ? "library.commandPalette" : "library.openAnything"
        let other = mode == .commands ? "library.openAnything" : "library.commandPalette"
        Task {
            try? await Task.sleep(for: .seconds(2))
            // Activation finishes asynchronously and gives the window key focus back.
            NSApp.activate()
            for _ in 0..<30 where !NSApp.isActive { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(500))
            await step("\(name) shortcut opens", model) { press(first, model) }
            await step("typed dock", model, snapshot: true) { typeText("dock") }
            await step("other shortcut switches", model, snapshot: true) { press(other, model) }
            await step("first shortcut switches back", model) { press(first, model) }
            await step("first shortcut again closes", model) { press(first, model) }
            await step("Open Anything shortcut opens", model) { press("library.openAnything", model) }
            await step("typed > docker (commands)", model, snapshot: true) { typeText("> docker") }
            await step("⌫ ×8: empty, then back to Open Anything", model) { for _ in 0..<8 { key(51) } }
            await step("⌘↩ opens sandbox in a new tab", model) { key(36, .command) }
            await step("Command Palette shortcut opens", model) { press("library.commandPalette", model) }
            await step("click on New Tab only closes", model) { click("new-tab-button") }
            await step("click on New Tab adds a tab", model) { click("new-tab-button") }
            exit(0)
        }
    }

    private static func step(_ label: String, _ model: AppModel, snapshot: Bool = false, _ action: () -> Void) async {
        action()
        try? await Task.sleep(for: .milliseconds(700))
        let panel = NSApp.windows.compactMap { $0 as? PalettePanel }.first { $0.isVisible }
        let key = NSApp.keyWindow.map { $0 is PalettePanel ? "palette" : $0.title } ?? "none"
        let editor = NSApp.keyWindow?.firstResponder as? NSTextView
        let state = panel?.controller.map { "mode=\($0.mode) query=\"\($0.query)\"" } ?? "closed"
        log("\(label): \(state) active=\(NSApp.isActive) key=\(key) caret=\(editor.map { NSStringFromRange($0.selectedRange()) } ?? "-") size=\(panel.map { NSStringFromSize($0.frame.size) } ?? "-") tabs=\(model.activeWindow?.tabs.count ?? 0)")
        if snapshot, let directory = WindowSnapshots.directory { WindowSnapshots.capture(into: directory) }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_PALETTE: \(message)\n".utf8))
    }

    /// ANSI key codes 0–47, by the character they type.
    private static let keyCodes = Array("asdfhgzxcv§bqweryt123465=97-80]ou[ip\rlj'k;\\,/nm.")

    private static func press(_ id: String, _ model: AppModel) {
        guard let combo = model.shortcut(for: id), let code = keyCodes.firstIndex(where: { String($0) == combo.key }) else { return log("\(id): no shortcut this check can press") }
        var flags: NSEvent.ModifierFlags = []
        if combo.modifiers.contains(.command) { flags.insert(.command) }
        if combo.modifiers.contains(.shift) { flags.insert(.shift) }
        if combo.modifiers.contains(.option) { flags.insert(.option) }
        if combo.modifiers.contains(.control) { flags.insert(.control) }
        key(UInt16(code), flags)
    }

    private static func typeText(_ text: String) {
        for character in text { key(UInt16(keyCodes.firstIndex(of: character) ?? 0), text: String(character)) }
    }

    /// One key press, made the way the window server makes them: menus match shortcuts on the
    /// keyboard layout data that only such events carry. `text` replaces the typed characters.
    private static func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], text: String? = nil) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down) else { continue }
            event.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
            if let text { event.keyboardSetUnicodeString(stringLength: text.utf16.count, unicodeString: Array(text.utf16)) }
            if let event = NSEvent(cgEvent: event) { NSApp.sendEvent(event) }
        }
    }

    private static func click(_ identifier: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let frame = accessibilityFrame(of: identifier, in: window) else { return log("\(identifier) not found") }
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    private static func accessibilityFrame(of identifier: String, in element: AnyObject, depth: Int = 0) -> NSRect? {
        guard depth < 40 else { return nil }
        if element.accessibilityIdentifier?() == identifier { return element.accessibilityFrame?() }
        for child in element.accessibilityChildren?() ?? [] {
            if let frame = accessibilityFrame(of: identifier, in: child as AnyObject, depth: depth + 1) { return frame }
        }
        return nil
    }
}
#endif
