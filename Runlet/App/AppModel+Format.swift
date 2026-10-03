import AppKit
import RunletCore
import RunletLanguage

// Format Code (#36): formats a PHP tab with the bundled Mago formatter, on demand (Edit ▸ Format
// Code) and, when Settings ▸ Editor ▸ Format before run is on, before Run. Formatting never runs
// code, needs no PHP, and leaves the text untouched when it fails. SQL tabs are never formatted.
extension AppModel {
    var snippetFormatter: SnippetFormatter { SnippetFormatter(executable: resources.mago) }

    /// Why Format Code can't format the tab, or nil when it can.
    func formatCodeDisabledReason(for tab: TabModel?) -> String? {
        guard let tab else { return "Open a tab to format its code." }
        if tab.language == .sql { return "Format Code formats PHP tabs; SQL tabs aren't formatted." }
        if tab.isFormatting { return "The tab is being formatted." }
        if !snippetFormatter.isAvailable { return "The formatter (Mago) is missing from this build." }
        return nil
    }

    /// Edit ▸ Format Code: formats the whole tab (Mago formats whole files, not ranges). One
    /// undo step; the caret stays on the same code. A failure shows above the editor.
    func formatCode(_ tab: TabModel) {
        guard formatCodeDisabledReason(for: tab) == nil else { return }
        Task { _ = await format(tab, reportSyntaxErrors: true) }
    }

    /// Formats the tab's text and applies it to the editor. Returns false when the text was
    /// left as it was (an error, or the tab changed while the formatter ran).
    @discardableResult
    func format(_ tab: TabModel, reportSyntaxErrors: Bool) async -> Bool {
        guard tab.language == .php, !tab.isFormatting else { return false }
        let editor = tab.editor
        let text = editor.text
        let version = tab.documentVersion
        let options = SnippetFormatter.Options(settings: settings, phpVersion: phpVersionHint(for: tab.target))
        tab.isFormatting = true
        defer { tab.isFormatting = false }
        do {
            let formatted = try await snippetFormatter.format(text, options: options)
            // Typing while the formatter ran wins: never replace newer text.
            guard tab.documentVersion == version, tab.language == .php, editor.text == text else { return false }
            tab.formatIssue = nil
            editor.applyFormatting(formatted)
            return true
        } catch let error as SnippetFormatError {
            if case .syntax = error, !reportSyntaxErrors { return false }
            if tab.documentVersion == version { tab.formatIssue = error.description }
            return false
        } catch {
            if tab.documentVersion == version { tab.formatIssue = "The code couldn't be formatted: \(error.localizedDescription)" }
            return false
        }
    }

    /// Format before run: whether Run should format this tab first. Only explicit runs of a
    /// whole PHP tab; never Run Selection, automatic runs, or SQL tabs.
    func shouldFormatBeforeRun(_ tab: TabModel, automatically: Bool, useSelection: Bool) -> Bool {
        settings.formatBeforeRun && !automatically && !useSelection && tab.language == .php && snippetFormatter.isAvailable
    }
}
