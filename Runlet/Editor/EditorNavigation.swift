import AppKit
import RunletCore
import RunletLanguage

/// What the editor needs from the app to open what PHPantom finds (#22).
@MainActor
protocol EditorNavigationHost: AnyObject {
    /// How the tab's target sees this Mac's files, and the external editor's name (nil: none).
    func navigationEnvironment() -> EditorNavigationEnvironment
    /// Opens a project file in the external editor at a 1-based line.
    func openInExternalEditor(path: String, line: Int)
    func revealInFinder(path: String)
}

struct EditorNavigationEnvironment {
    var pathMapping: EditorPathMapping = .host
    /// "PhpStorm", or nil when no external editor is set.
    var editorName: String?
}

/// Go to Definition, Find References, and code actions for one editor (#22). Locations come from
/// PHPantom in LSP coordinates and go through `NavigationResolver`: the tab's own code moves the
/// caret, a project file opens in the external editor, and vendor code (or anything else that
/// isn't a project file on this Mac) opens read-only in a peek. Code actions change the tab's
/// text only, as one undo step; nothing here runs code.
@MainActor
final class EditorNavigation: NSObject, NSPopoverDelegate {
    private unowned let controller: EditorController
    /// Set by the app when the tab binds its language service.
    var host: EditorNavigationHost?
    private var popover: NSPopover?
    private let message = InfoPopup(identifier: "navigation-message")
    private var messageWork: DispatchWorkItem?
    private var task: Task<Void, Never>?

    init(controller: EditorController) {
        self.controller = controller
        super.init()
        controller.textView.onCommandClick = { [weak self] index in
            guard let self, self.isAvailable else { return false }
            self.goToDefinition(at: index)
            return true
        }
        controller.textView.contextMenuItems = { [weak self] index in self?.menuItems(at: index) ?? [] }
    }

    private var textView: CodeTextView { controller.textView }

    /// A PHP tab with PHPantom bound.
    var isAvailable: Bool { controller.syntax == .php && controller.language != nil }

    /// What the visible popover shows ("peek", "references", "definitions", "actions"), for checks.
    private(set) var popoverKind: String?

    // MARK: Commands

    func goToDefinition(at offset: Int? = nil) {
        guard let binding = controller.language else { return }
        let offset = offset ?? textView.selectedRange().location
        let text = controller.text
        let position = TextLineIndex(text).position(at: offset)
        let word = Self.word(at: offset, in: text)
        run { [weak self] in
            guard await binding.session.supports(.definition) else { self?.say("PHPantom doesn't offer Go to Definition here.", at: offset); return }
            let locations = try await binding.definition(at: position)
            guard let self, self.controller.text == text else { return }
            let resolver = self.resolver(for: binding, text: text)
            let destinations = locations.map(resolver.destination)
            switch destinations.count {
            case 0: self.say(word.map { "No definition found for \($0)." } ?? "No definition found.", at: offset)
            case 1: self.navigate(to: destinations[0], from: offset)
            default:
                let rows = ReferenceList.make(locations, resolver: resolver, editorText: text) { [weak self] file, line in self?.lineText(file, line: line, session: binding.session) }
                self.showList(.definitions(rows, word: word), at: offset)
            }
        }
    }

    func findReferences(at offset: Int? = nil) {
        guard let binding = controller.language else { return }
        let offset = offset ?? textView.selectedRange().location
        let text = controller.text
        let position = TextLineIndex(text).position(at: offset)
        let word = Self.word(at: offset, in: text)
        run { [weak self] in
            guard await binding.session.supports(.references) else { self?.say("PHPantom doesn't offer Find References here.", at: offset); return }
            let locations = try await binding.references(at: position)
            guard let self, self.controller.text == text else { return }
            let resolver = self.resolver(for: binding, text: text)
            // Other tabs' code is read from the server's copy; files from disk.
            var cache: [String: [String]] = [:]
            let rows = ReferenceList.make(locations, resolver: resolver, editorText: text) { file, line in
                if cache[file.uri] == nil { cache[file.uri] = self.fileLines(file, session: binding.session) }
                return cache[file.uri].flatMap { line < $0.count ? $0[line] : nil }
            }
            guard !rows.isEmpty else { return self.say(word.map { "No references found for \($0)." } ?? "No references found.", at: offset) }
            self.showList(.references(rows, word: word, truncated: locations.count > ReferenceList.limit), at: offset)
        }
    }

    /// Code actions at the caret or selection, with the diagnostics shown there.
    func showCodeActions() {
        guard let binding = controller.language else { return }
        let selection = textView.selectedRange()
        let text = controller.text
        let index = TextLineIndex(text)
        let range = LSPRange(start: index.position(at: selection.location), end: index.position(at: NSMaxRange(selection)))
        let caretLine = range.start.line
        // Diagnostics on the selection, else on the caret's line.
        var diagnostics = controller.diagnostics.filter { NSIntersectionRange($0.range, selection).length > 0 || NSLocationInRange(selection.location, $0.range) }.map(\.diagnostic)
        if diagnostics.isEmpty { diagnostics = controller.diagnostics.map(\.diagnostic).filter { $0.range.start.line == caretLine } }
        let request = diagnostics.isEmpty ? range : diagnostics.reduce(range) { LSPRange(start: min($0.start, $1.range.start), end: max($0.end, $1.range.end)) }
        run { [weak self] in
            guard await binding.session.supports(.codeActions) else { self?.say("PHPantom doesn't offer code actions here.", at: selection.location); return }
            let actions = LSPCodeAction.ordered(try await binding.codeActions(range: request, diagnostics: diagnostics))
            guard let self, self.controller.text == text else { return }
            guard !actions.isEmpty else { return self.say("No code actions here.", at: selection.location) }
            // Actions whose edit is known and can't apply say why up front.
            let rows = actions.map { action -> CodeActionRow in
                var reason = action.disabledReason
                if reason == nil, let edit = action.edit, case .failure(let rejection) = ScratchEditPlanner.plan(edit, scratchURI: binding.uri, mapping: binding.mapping, editorText: text) {
                    reason = rejection.description
                }
                if reason == nil, action.edit == nil, !action.needsResolve { reason = "This action only runs a command on the language server, which Runlet doesn't do." }
                return CodeActionRow(action: action, unavailableReason: reason)
            }
            self.showList(.actions(rows), at: selection.location)
        }
    }

    // MARK: Light bulb

    private var bulbTask: Task<Void, Never>?
    private var bulbKey: String?

    /// The caret moved or diagnostics changed: on a line with diagnostics, ask (a moment later)
    /// whether there is a quick fix, and show a light bulb in the gutter when there is.
    func caretMoved() {
        guard let binding = controller.language, controller.syntax == .php else { return controller.showLightBulb(nil) }
        let text = controller.text
        let selection = textView.selectedRange()
        let index = TextLineIndex(text)
        let line = index.position(at: selection.location).line
        let diagnostics = controller.diagnostics.map(\.diagnostic).filter { $0.range.start.line <= line && line <= $0.range.end.line }
        guard !diagnostics.isEmpty else {
            bulbTask?.cancel()
            bulbKey = nil
            return controller.showLightBulb(nil)
        }
        let key = "\(line)|\(text.hashValue)|\(diagnostics.count)"
        guard key != bulbKey else { return }
        bulbKey = key
        controller.showLightBulb(nil)
        bulbTask?.cancel()
        bulbTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, await binding.session.supports(.codeActions) else { return }
            let range = LSPRange(start: index.position(at: selection.location), end: index.position(at: selection.location))
            let request = diagnostics.reduce(range) { LSPRange(start: min($0.start, $1.range.start), end: max($0.end, $1.range.end)) }
            guard let actions = try? await binding.codeActions(range: request, diagnostics: diagnostics), !Task.isCancelled,
                  let self, self.controller.text == text else { return }
            let fixable = actions.contains { $0.isQuickFix && $0.disabledReason == nil }
            self.controller.showLightBulb(fixable ? line : nil)
        }
    }

    /// Applies a chosen code action (resolving its edit first when the server computes it late).
    private func perform(_ row: CodeActionRow, at offset: Int) {
        guard let binding = controller.language else { return }
        if let reason = row.unavailableReason { return say(reason, at: offset) }
        let text = controller.text
        run { [weak self] in
            let action = try await binding.session.resolve(row.action)
            guard let self else { return }
            guard self.controller.text == text else { return self.say("The code changed; choose the action again.", at: offset) }
            guard let edit = action.edit else { return self.say("PHPantom returned no changes for “\(action.title)”.", at: offset) }
            switch ScratchEditPlanner.plan(edit, scratchURI: binding.uri, mapping: binding.mapping, editorText: text) {
            case .success(let edits): self.controller.applyCodeAction(edits, title: action.title)
            case .failure(let rejection): self.say(rejection.description, at: offset)
            }
        }
    }

    func close() {
        task?.cancel()
        popover?.close()
        popover = nil
        hideMessage()
    }

    // MARK: Destinations

    private func resolver(for binding: LanguageBinding, text: String) -> NavigationResolver {
        let environment = host?.navigationEnvironment() ?? EditorNavigationEnvironment()
        return NavigationResolver(scratchURI: binding.uri, mapping: binding.mapping, editorLineCount: TextLineIndex(text).lineCount,
                                  workspaceRoot: binding.session.workspace.rootPath, workspaceKind: binding.session.workspace.kind,
                                  pathMapping: environment.pathMapping, hasExternalEditor: environment.editorName != nil)
    }

    private func navigate(to destination: NavigationDestination, from offset: Int) {
        switch destination {
        case .scratch(let range):
            popover?.close()
            // A definition at a point selects the name there.
            var selection = TextLineIndex(controller.text).nsRange(of: range)
            if selection.length == 0, let word = Self.wordRange(at: selection.location, in: controller.text), word.location == selection.location {
                selection = word
            }
            textView.setSelectedRange(selection)
            textView.scrollRangeToVisible(selection)
            textView.window?.makeFirstResponder(textView)
            if selection.length > 0 { textView.showFindIndicator(for: selection) }
        case .hiddenLine(let variable, let type):
            if let variable {
                say("$\(variable) is provided by the project's driver" + (type.map { " (\($0))." } ?? "."), at: offset)
            } else {
                say("This is defined by a line Runlet adds before the snippet.", at: offset)
            }
        case .projectFile(let file):
            popover?.close()
            if let path = file.path { host?.openInExternalEditor(path: path, line: file.line) }
        case .peek(let file):
            guard let content = peekText(file) else { return say("\(file.displayPath) can't be read.", at: offset) }
            showPeek(file, text: content, at: offset)
        case .unavailable(let reason):
            say(reason, at: offset)
        }
    }

    /// A file's text for a peek: from disk, or the server's copy of an in-memory document.
    private func peekText(_ file: NavigationFile) -> String? {
        if let path = file.path {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path), (attributes[.size] as? Int ?? 0) <= 4_000_000 else { return nil }
            return (try? String(contentsOfFile: path, encoding: .utf8)) ?? (try? String(contentsOfFile: path, encoding: .isoLatin1))
        }
        return inMemoryTexts[file.uri]
    }

    /// The server's copies of in-memory documents seen by the last request.
    private var inMemoryTexts: [String: String] = [:]

    private func fileLines(_ file: NavigationFile, session: LanguageServerSession) -> [String]? {
        if file.path == nil { return inMemoryTexts[file.uri]?.components(separatedBy: "\n") }
        return peekText(file)?.components(separatedBy: "\n")
    }

    private func lineText(_ file: NavigationFile, line: Int, session: LanguageServerSession) -> String? {
        fileLines(file, session: session).flatMap { line < $0.count ? $0[line] : nil }
    }

    // MARK: Running requests

    /// A request is waiting for PHPantom.
    private(set) var isBusy = false

    /// Runs one request at a time; a new one replaces the previous. Errors are said briefly.
    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        task?.cancel()
        hideMessage()
        let session = controller.language?.session
        isBusy = true
        task = Task { [weak self] in
            defer { if !Task.isCancelled { self?.isBusy = false } }
            do {
                // In-memory documents (other tabs, Runlet's API) are read before the request's
                // answer is shown, so peeks and snippets can use them.
                if let session { self?.inMemoryTexts = await session.inMemoryDocuments() }
                try await body()
            } catch is CancellationError {
            } catch let error as LSPResponseError where error.isCancellation {
            } catch {
                self?.say("PHPantom didn't answer: \(error)", at: self?.textView.selectedRange().location ?? 0)
            }
        }
    }

    // MARK: Messages

    private func say(_ text: String, at offset: Int) {
        let content = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: max(11, (textView.font?.pointSize ?? 13) - 1)), .foregroundColor: NSColor.labelColor])
        message.show(content, near: textView.screenRect(forCharacterAt: offset), above: false, parent: textView.window)
        messageWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.message.hide() }
        messageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func hideMessage() {
        messageWork?.cancel()
        message.hide()
    }

    var messageText: String? { message.isVisible ? message.text : nil }

    // MARK: Popovers

    private func anchorRect(for offset: Int) -> NSRect {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return .zero }
        let length = (textView.string as NSString).length
        let range = Self.wordRange(at: offset, in: textView.string) ?? NSRange(location: min(offset, length), length: 0)
        let glyphs = layoutManager.glyphRange(forCharacterRange: range.length > 0 ? range : NSRange(location: range.location, length: min(1, length - range.location)), actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        if rect.width < 1 { rect.size.width = 1 }
        return rect
    }

    private func present(_ content: NSViewController, kind: String, at offset: Int) {
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = content
        popover.delegate = self
        popover.appearance = textView.effectiveAppearance
        self.popover = popover
        popoverKind = kind
        textView.scrollRangeToVisible(NSRange(location: min(offset, (textView.string as NSString).length), length: 0))
        popover.show(relativeTo: anchorRect(for: offset), of: textView, preferredEdge: .maxY)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        popover = nil
        popoverKind = nil
        textView.window?.makeFirstResponder(textView)
    }

    var isShowingPopover: Bool { popover?.isShown ?? false }
    var popoverContent: NSViewController? { popover?.contentViewController }

    private func showPeek(_ file: NavigationFile, text: String, at offset: Int) {
        let environment = host?.navigationEnvironment() ?? EditorNavigationEnvironment()
        let peek = CodePeekController(file: file, text: text, theme: controller.theme, font: textView.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular),
                                      editorName: file.path == nil ? nil : environment.editorName)
        peek.onOpen = { [weak self] in
            self?.popover?.close()
            if let path = file.path { self?.host?.openInExternalEditor(path: path, line: file.line) }
        }
        peek.onReveal = { [weak self] in
            if let path = file.path { self?.host?.revealInFinder(path: path) }
        }
        present(peek, kind: "peek", at: offset)
    }

    enum ListContent {
        case references([ReferenceItem], word: String?, truncated: Bool)
        case definitions([ReferenceItem], word: String?)
        case actions([CodeActionRow])
    }

    private func showList(_ content: ListContent, at offset: Int) {
        let list = NavigationListController(content: content, theme: controller.theme, fontSize: textView.font?.pointSize ?? 13)
        list.onChooseReference = { [weak self] item in
            self?.popover?.close()
            self?.navigate(to: item.destination, from: offset)
        }
        list.onChooseAction = { [weak self] row in
            self?.popover?.close()
            self?.perform(row, at: offset)
        }
        switch content {
        case .references: present(list, kind: "references", at: offset)
        case .definitions: present(list, kind: "definitions", at: offset)
        case .actions: present(list, kind: "actions", at: offset)
        }
    }

    // MARK: Context menu

    private func menuItems(at index: Int) -> [NSMenuItem] {
        guard isAvailable else { return [] }
        func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem { MenuClosure.item(title, action) }
        return [
            item("Go to Definition") { [weak self] in self?.goToDefinition(at: index) },
            item("Find References") { [weak self] in self?.findReferences(at: index) },
            item("Show Code Actions…") { [weak self] in
                guard let self else { return }
                if !NSLocationInRange(index, self.textView.selectedRange()) { self.textView.setSelectedRange(NSRange(location: index, length: 0)) }
                self.showCodeActions()
            },
            .separator(),
        ]
    }

    // MARK: Words

    static func wordRange(at offset: Int, in text: String) -> NSRange? {
        let string = text as NSString
        func isWord(_ unit: unichar) -> Bool {
            (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || unit == 36 || unit == 92 || unit > 127
        }
        var start = min(offset, string.length)
        var end = start
        while start > 0, isWord(string.character(at: start - 1)) { start -= 1 }
        while end < string.length, isWord(string.character(at: end)) { end += 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    static func word(at offset: Int, in text: String) -> String? {
        wordRange(at: offset, in: text).map { (text as NSString).substring(with: $0) }
    }
}

/// A code action as listed, and why it can't be applied (nil when it can).
struct CodeActionRow {
    var action: LSPCodeAction
    var unavailableReason: String?
}

/// Runs a closure for a menu item (the item keeps it as its represented object).
final class MenuClosure: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func invoke(_ sender: Any?) { handler() }

    static func item(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let closure = MenuClosure(handler)
        let item = NSMenuItem(title: title, action: #selector(invoke(_:)), keyEquivalent: "")
        item.target = closure
        item.representedObject = closure
        return item
    }
}

// MARK: - Requests and edits

extension LanguageBinding {
    func definition(at editorPosition: LSPPosition) async throws -> [LSPLocation] {
        await flush()
        return try await session.definition(uri: uri, position: mapping.toLSP(editorPosition))
    }

    func references(at editorPosition: LSPPosition) async throws -> [LSPLocation] {
        await flush()
        return try await session.references(uri: uri, position: mapping.toLSP(editorPosition))
    }

    /// Code actions for an editor range, with editor-coordinate diagnostics mapped back.
    func codeActions(range: LSPRange, diagnostics: [LSPDiagnostic]) async throws -> [LSPCodeAction] {
        await flush()
        let lspRange = LSPRange(start: mapping.toLSP(range.start), end: mapping.toLSP(range.end))
        let lspDiagnostics = diagnostics.map { diagnostic in
            var mapped = diagnostic
            mapped.range = LSPRange(start: mapping.toLSP(diagnostic.range.start), end: mapping.toLSP(diagnostic.range.end))
            return mapped
        }
        return try await session.codeActions(uri: uri, range: lspRange, diagnostics: lspDiagnostics)
    }
}

extension EditorController {
    /// Applies a code action's edits (back to front) as one undo step named after it, keeping
    /// the caret on the same code.
    func applyCodeAction(_ edits: [ScratchEdit], title: String) {
        // Where the caret's code ends up: moved by every change before it, or to the end of a
        // change it was inside.
        let original = selectedRange.location
        var shift = 0
        var inside: Int?
        for edit in edits.sorted(by: { $0.range.location < $1.range.location }) {
            let delta = (edit.text as NSString).length - edit.range.length
            if NSMaxRange(edit.range) <= original {
                shift += delta
            } else if edit.range.location < original, inside == nil {
                inside = edit.range.location + shift + (edit.text as NSString).length
            }
        }
        let caret = inside ?? original + shift
        textView.breakUndoCoalescing()
        textView.undoManager?.beginUndoGrouping()
        for edit in edits { textView.replace(range: edit.range, with: edit.text) }
        textView.undoManager?.setActionName(title)
        textView.undoManager?.endUndoGrouping()
        textView.breakUndoCoalescing()
        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(caret, length), length: 0))
        textView.scrollRangeToVisible(NSRange(location: min(caret, length), length: 0))
    }
}
