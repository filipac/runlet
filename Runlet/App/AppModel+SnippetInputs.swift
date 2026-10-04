import Foundation
import Observation
import RunletCore

/// A parameterised snippet waiting for its values (#14): `SnippetInputSheet` shows it on its
/// window. Confirming hands the code, with the values as PHP literals, to `open`; cancelling
/// opens nothing. Neither runs anything.
@MainActor
@Observable
final class SnippetInputRequest: Identifiable {
    let id = UUID()
    /// The window the sheet belongs to (the active one when the snippet was opened).
    let windowId: UUID?
    let title: String
    let summary: String?
    /// Where the snippet comes from, e.g. "Project snippet · refund-order.php".
    let source: String
    /// Declarations that could not be read; those inputs are left out.
    let problems: [SnippetInputProblem]
    /// The confirm button's title, e.g. "Open in New Tab".
    let actionTitle: String
    /// #207: a MongoDB snippet's values fill its JSON placeholders instead of PHP assignments;
    /// #205: a Redis snippet's fill its `$name` arguments as quoted Redis arguments.
    let language: TabLanguage
    var form: SnippetInputForm
    @ObservationIgnored let code: String
    @ObservationIgnored let open: @MainActor (String) -> Void

    init(windowId: UUID?, title: String, summary: String?, source: String, inputs: SnippetInputSet, actionTitle: String, code: String, language: TabLanguage = .php, open: @escaping @MainActor (String) -> Void) {
        self.language = language
        self.windowId = windowId
        self.title = title
        self.summary = summary
        self.source = source
        self.problems = inputs.problems
        self.actionTitle = actionTitle
        self.form = SnippetInputForm(inputs: inputs.inputs)
        self.code = code
        self.open = open
    }
}

extension AppModel {
    /// Hands a personal snippet's code to `open`, after asking for its inputs when it declares any.
    func askForInputs(of snippet: Snippet, action: String = "Open", open: @escaping @MainActor (String) -> Void) {
        askForInputs(snippet.inputs, code: snippet.openingCode, title: snippet.label, summary: snippet.description,
                     source: "Personal snippet", action: action, language: snippet.tabLanguage, open: open)
    }

    /// Hands a project snippet's code to `open`, after asking for its inputs when it declares any.
    func askForInputs(of snippet: ProjectSnippet, target: TargetRef, action: String = "Open", open: @escaping @MainActor (String) -> Void) {
        let project = projectName(for: target).map { " · \($0)" } ?? ""
        askForInputs(snippet.inputs, code: snippet.code, title: snippet.label, summary: snippet.description,
                     source: "Project snippet · \(snippet.fileURL.lastPathComponent)\(project)", action: action, language: snippet.language, open: open)
    }

    /// Calls `open` with `code` at once when there are no `@input` lines; otherwise shows the
    /// input form, and calls it with the code and its values only when the user confirms.
    func askForInputs(_ inputs: SnippetInputSet, code: String, title: String, summary: String?, source: String, action: String, language: TabLanguage = .php, open: @escaping @MainActor (String) -> Void) {
        guard !inputs.isEmpty else { return open(code) }
        snippetInputRequest = SnippetInputRequest(windowId: activeWindowId, title: title, summary: summary, source: source,
                                                  inputs: inputs, actionTitle: action, code: code, language: language, open: open)
    }

    /// The form's Open button: opens the code with the values. Never runs it.
    func confirmSnippetInputs(_ request: SnippetInputRequest) {
        // #207: a MongoDB snippet's values become JSON literals in its placeholders, never PHP;
        // #205: a Redis snippet's become quoted Redis arguments.
        let filled: String? = switch request.language {
        case .mongodb: request.form.values.map { MongoSnippets.substitute(request.code, values: $0) }
        case .redis: request.form.values.map { RedisSnippets.substitute(request.code, values: $0) }
        default: request.form.code(for: request.code)
        }
        guard snippetInputRequest === request, let code = filled else { return }
        snippetInputRequest = nil
        request.open(code)
        focusSelectedEditor()
    }

    /// Cancel, Escape, or closing the sheet: nothing opens.
    func cancelSnippetInputs(_ request: SnippetInputRequest) {
        guard snippetInputRequest === request else { return }
        snippetInputRequest = nil
    }

    /// ⇧↩ in Snippets: inserts a personal snippet at the cursor, with its inputs' values.
    func insert(_ snippet: Snippet) {
        askForInputs(of: snippet, action: "Insert") { [weak self] code in self?.insertLibraryCode(code) }
    }

    /// ⇧↩ in Snippets: inserts a project snippet at the cursor, with its inputs' values.
    func insert(_ snippet: ProjectSnippet, target: TargetRef) {
        askForInputs(of: snippet, target: target, action: "Insert") { [weak self] code in self?.insertLibraryCode(code) }
    }
}
