#if DEBUG
import Foundation
import RunletCore

/// RUNLET_DEBUG_STEPS for parameterised snippets (#14), for screenshots and scripted checks
/// with scratch data (see `DebugSteps`):
/// `snippet-open:<label>` opens the current tab's project snippet, or else the personal
/// snippet, with that label as double-click does (`snippet-open-new:<label>`: in a new tab,
/// as ⌘↩); a snippet with inputs shows its form · `snippet-input:<name>=<value>` sets a field
/// of the open form as typing would (`\n` is a newline and `\c` a comma; a checkbox takes
/// true or false, a choice list one of its values) · `snippet-inputs:open` and
/// `snippet-inputs:cancel` press the form's Open (or Insert) and Cancel buttons ·
/// `snippet-inputs:state` prints the form's values and errors · `snippet-tab` prints the
/// selected tab's title, target, whole code, whether it has run, its output, and the number
/// of history entries. Opening never runs code; use the `run` step for that.
@MainActor
enum SnippetInputDebugSteps {
    /// Runs one step; false when `name` isn't one of these.
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        switch name {
        case "snippet-open", "snippet-open-new":
            let newTab = name == "snippet-open-new"
            if let target = model.selectedTab?.target, let snippet = model.projectSnippets(for: target).first(where: { $0.label == argument }) {
                if newTab { model.open(snippet, target: target, inNewTab: true) } else { model.open(snippet, target: target) }
            } else if let snippet = model.snippets.first(where: { $0.label == argument }) {
                if newTab { model.open(snippet, inNewTab: true) } else { model.open(snippet) }
            } else {
                log("\(name): no snippet labelled \(argument)")
            }
        case "snippet-input":
            guard let request = model.snippetInputRequest else {
                log("snippet-input: no input form")
                return true
            }
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let value = parts.count == 2 ? parts[1].replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\c", with: ",") : ""
            if parts.count != 2 || !request.form.set(parts[0], to: value) {
                log("snippet-input: can't set \(argument)")
            }
        case "snippet-inputs":
            guard let request = model.snippetInputRequest else {
                log("snippet-inputs: no input form")
                return true
            }
            switch argument {
            case "open":
                if !request.form.isValid { log("snippet-inputs: not valid: \(state(request))") }
                model.confirmSnippetInputs(request)
            case "cancel":
                model.cancelSnippetInputs(request)
            default:
                log("snippet-inputs: \(state(request))")
            }
        case "snippet-tab":
            guard let tab = model.selectedTab else {
                log("snippet-tab: no tab")
                return true
            }
            let code = (tab.editorIfLoaded?.text ?? tab.code).replacingOccurrences(of: "\n", with: "\\n")
            let output = tab.output.map(\.plainText).joined(separator: " | ").replacingOccurrences(of: "\n", with: "\\n")
            let ran = tab.lastRun.map { "\($0)" } ?? "never"
            log("snippet-tab: title=\(tab.title) target=\(model.targetLabel(tab.target)) tabs=\(model.activeWindow?.tabs.count ?? 0) history=\(model.history.count) ran=\(ran) output=\(output.prefix(400)) code=\(code)")
        default:
            return false
        }
        return true
    }

    private static func state(_ request: SnippetInputRequest) -> String {
        let fields = request.form.inputs.map { input in
            "$\(input.name)=" + (request.form.error(for: input).map { "invalid(\($0))" } ?? request.form.assignments[request.form.inputs.firstIndex(of: input)!])
        }
        return "\(request.title) [\(fields.joined(separator: "; "))] problems=\(request.problems.map(\.description))"
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}
#endif
