#if DEBUG
import AppKit
import RunletCore
import RunletLanguage

/// RUNLET_DEBUG_STEPS for PHPantom navigation (#22), for screenshots and scripted checks (see
/// `DebugSteps`). Positions are 1-based `<line>:<column>` in the current tab:
/// `nav-definition:<pos>` (Go to Definition there, as F12 with the caret there) ·
/// `nav-click:<pos>` (a ⌘-click there) · `nav-references:<pos>` (Find References) ·
/// `nav-actions:<pos>[-<pos>]` (Show Code Actions for the caret or a selection) ·
/// `nav-choose:<row>` (chooses a row of the open references or code-action list, 0-based, as a
/// click does) · `nav-close` · `nav-undo` (Edit ▸ Undo in the editor) · `nav-menu:<pos>` (prints
/// the editor's context menu there) · `nav-state` (prints the popover, its rows or peek, the
/// message, the caret, the text, the undo action, the inlay hints, and the menu shortcuts) ·
/// `nav-wait:ready|done|hints|folds[:<seconds>]` (in `RunletApp`: holds the steps until PHPantom
/// is ready for the tab, the last request is answered, inlay hints are shown, or folding ranges
/// arrived) · `nav-fold:<line>|all|none|caret` (folds or unfolds; a line toggles the block that
/// starts there, as its gutter control does) · `nav-fold-state` (regions, folded text, gutter
/// controls, and the numbered rows) ·
/// `nav-host:log` (project files are logged instead of opening an external editor).
@MainActor
enum NavigationDebugSteps {
    static var waited: Double = 0
    /// `nav-host:log`: what would have opened in the external editor.
    static var loggedOpens: [String] = []

    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        guard name.hasPrefix("nav-") else { return false }
        guard let tab = model.selectedTab else { return true }
        let editor = tab.editor
        let navigation = editor.navigation
        switch name {
        case "nav-definition":
            navigation.goToDefinition(at: offset(argument, in: editor))
        case "nav-click":
            let index = offset(argument, in: editor)
            log("nav-click handled=\(editor.textView.onCommandClick?(index) ?? false)")
        case "nav-references":
            navigation.findReferences(at: offset(argument, in: editor))
        case "nav-actions":
            let ends = argument.split(separator: "-").map(String.init)
            let start = offset(ends[0], in: editor)
            let end = ends.count > 1 ? offset(ends[1], in: editor) : start
            editor.textView.setSelectedRange(NSRange(location: min(start, end), length: abs(end - start)))
            navigation.showCodeActions()
        case "nav-choose":
            navigation.debugChoose(Int(argument) ?? 0)
        case "nav-close":
            navigation.close()
        case "nav-undo":
            editor.textView.undoManager?.undo()
        case "nav-menu":
            let index = offset(argument, in: editor)
            let items = editor.textView.contextMenuItems?(index) ?? []
            log("nav-menu: \(items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: " | "))")
        case "nav-host":
            if argument == "log" { navigation.host = LoggingNavigationHost(base: navigation.host) }
        case "nav-fold":
            // `nav-fold:<line>` toggles the block starting on that 1-based line; `all`, `none`, `caret`.
            switch argument {
            case "all": editor.folding.foldAll()
            case "none": editor.folding.unfoldAll()
            case "caret": editor.folding.foldAtCaret()
            default:
                let start = TextLineIndex(editor.text).offset(of: LSPPosition(line: max(0, (Int(argument) ?? 1) - 1), character: 0))
                editor.folding.toggle(lineStart: start)
            }
        case "nav-fold-state":
            let folding = editor.folding
            let text = editor.text as NSString
            log("nav-fold-state regions=\(folding.regions.map { "\($0.startLine + 1)-\($0.endLine + 1)\($0.kind.map { " " + $0 } ?? "")" }.joined(separator: ", ")) "
                + "folded=\(folding.folded.map { text.substring(with: $0).debugDescription }.joined(separator: " | ")) "
                + "markers=\(folding.markers().sorted { $0.key < $1.key }.map { "\(TextLineIndex(editor.text).position(at: $0.key).line + 1)\($0.value ? "▸" : "▾")" }.joined(separator: " ")) "
                + "rows=\(editor.debugRulerLines)")
        case "nav-state":
            log(state(model, tab: tab))
        default:
            log("\(name)?")
        }
        return true
    }

    /// Whether `nav-wait:<what>` is satisfied.
    static func reached(_ what: String, model: AppModel) -> Bool {
        guard let tab = model.selectedTab else { return true }
        switch what {
        case "ready": return tab.languageState.isReady && tab.editorIfLoaded?.navigation.isAvailable == true
        case "hints": return !(tab.editorIfLoaded?.inlayHints.placed.isEmpty ?? true)
        case "folds": return tab.editorIfLoaded?.folding.hasRegions ?? false
        default: return !(tab.editorIfLoaded?.navigation.isBusy ?? false)
        }
    }

    private static func offset(_ position: String, in editor: EditorController) -> Int {
        let numbers = position.split(separator: ":").compactMap { Int($0) }
        let line = max(1, numbers.first ?? 1)
        let column = max(1, numbers.count > 1 ? numbers[1] : 1)
        return TextLineIndex(editor.text).offset(of: LSPPosition(line: line - 1, character: column - 1))
    }

    private static func state(_ model: AppModel, tab: TabModel) -> String {
        let editor = tab.editor
        let navigation = editor.navigation
        let caret = TextLineIndex(editor.text).position(at: editor.selectedRange.location)
        var parts = [
            "nav-state available=\(navigation.isAvailable) language=\(tab.languageState)",
            "popover=\(navigation.popoverKind ?? "none")",
        ]
        parts += navigation.debugPopoverLines.map { "  \($0)" }
        parts.append("message=\(navigation.messageText ?? "none")")
        parts.append("caret=\(caret.line + 1):\(caret.character + 1) selection=\(editor.selectedRange.length)")
        parts.append("undo=\(editor.textView.undoManager?.undoActionName ?? "")")
        parts.append("hints=\(editor.inlayHints.placed.map { "\($0.hint.label)@\($0.hint.offset)" }.joined(separator: " "))")
        parts.append("opened=\(loggedOpens.joined(separator: " | "))")
        parts.append("shortcuts=" + ["edit.goToDefinition", "edit.findReferences", "edit.codeActions", "view.inlayHints"].map { "\($0)=\(model.shortcut(for: $0)?.displayString ?? "none")" }.joined(separator: " "))
        parts.append("text<<\(editor.text)>>")
        return parts.joined(separator: "\n")
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}

/// `nav-host:log`: logs project files instead of opening the external editor.
@MainActor
final class LoggingNavigationHost: EditorNavigationHost {
    private let base: EditorNavigationHost?

    init(base: EditorNavigationHost?) {
        self.base = base
    }

    func navigationEnvironment() -> EditorNavigationEnvironment {
        var environment = base?.navigationEnvironment() ?? EditorNavigationEnvironment()
        if environment.editorName == nil { environment.editorName = "Logged Editor" }
        return environment
    }

    func openInExternalEditor(path: String, line: Int) {
        NavigationDebugSteps.loggedOpens.append("\((path as NSString).lastPathComponent):\(line)")
        NavigationDebugSteps.log("nav-host open \(path):\(line)")
    }

    func revealInFinder(path: String) {
        NavigationDebugSteps.log("nav-host reveal \(path)")
    }
}

extension EditorNavigation {
    /// Chooses a row of the open list, as a click does.
    func debugChoose(_ row: Int) {
        (popoverContent as? NavigationListController)?.debugChoose(row)
    }

    /// The open popover's rows or peek, for `nav-state`.
    var debugPopoverLines: [String] {
        if let list = popoverContent as? NavigationListController { return list.rowTexts }
        if let peek = popoverContent as? CodePeekController {
            let text = peek.textView?.string ?? ""
            let selection = peek.textView?.selectedRange().location ?? 0
            let line = TextLineIndex(text).position(at: selection).line
            let lines = text.components(separatedBy: "\n")
            return ["peek \(peek.file.displayPath):\(peek.file.line) origin=\(peek.file.origin) runtime=\(peek.file.runtimePath ?? "none")",
                    "peek line: \(line < lines.count ? lines[line].trimmingCharacters(in: .whitespaces) : "")"]
        }
        return []
    }
}

extension NavigationListController {
    func debugChoose(_ row: Int) {
        guard row >= 0, row < rowTexts.count else { return }
        chooseRow(row)
    }
}
#endif
