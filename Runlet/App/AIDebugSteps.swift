#if DEBUG
import AppKit
import RunletCore

/// RUNLET_DEBUG_STEPS for AI providers (#368) and Explain or Fix This Error (#44), so Settings ▸
/// AI, the disclosure, a streamed answer, and a proposed fix can be checked and photographed
/// without a keyboard. Point the app at the local stand-in (`RUNLET_AI_BASE_URL`, with
/// `Tests/Fixtures/ai-stub/router.php` under `php -S`) and use made-up keys: a scratch
/// `RUNLET_DATA_DIR` keeps keys in memory, never in the Keychain.
///
/// - `ai-key:<provider>=<key>` types a key into Settings ▸ AI's field and saves it, as Save Key
///   does; `ai-draft:<provider>=<text>` only types it; `ai-remove:<provider>` removes the key
///   (without the confirmation).
/// - `ai-test:<provider>` presses Test Key. `ai-provider:<provider>` and
///   `ai-model:<provider>=<model id>` change Settings ▸ AI's choices.
/// - `ai-explain` opens the sheet on the current tab's last error, as Output ▸ Explain or Fix
///   Error… does; `ai-explain:card` as the error card's button does.
/// - `ai-part:<part id>=on|off` (`error`, `code`, `source`) switches a part of the disclosure.
/// - `ai-send`, `ai-stop`, `ai-apply`, `ai-undo`, `ai-review`, and `ai-close` press the sheet's
///   Send, Stop, Apply Fix, Undo Apply Fix, Ask Again…, and Done.
/// - `ai-wait:sheet|text|fix|done|tested[:<seconds>]` (in `AppDelegate`'s step runner) holds
///   the steps until the sheet is open, answer text arrived, the fix is being written, the
///   answer ended, or Test Key finished (30 s by default). The chat's `chat-…` conditions are
///   in `AIChatDebugSteps` (#45).
/// - `ai-state` prints a `RUNLET_DEBUG_STATE:` line: the provider and models, each key's state
///   (masked only), Test Key's result, and the sheet's phase, parts, answer, fix, and error.
/// - `ai-open-settings` runs AI Settings… as the sheet's Open AI Settings… button does, and
///   `ai-windows` prints the visible windows, front to back, by title (Settings is titled after
///   its tab), and whether the main window has a sheet.
@MainActor
enum AIDebugSteps {
    static var waited: Double = 0

    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        switch name {
        case "ai-key", "ai-draft":
            let (provider, value) = split(argument)
            guard let provider else { return true }
            model.ai.drafts[provider] = value
            if name == "ai-key" { model.saveAIKey(provider) }
        case "ai-remove":
            if let provider = AIProvider(rawValue: argument) { model.removeAIKey(provider) }
        case "ai-test":
            if let provider = AIProvider(rawValue: argument) { model.testAIKey(provider) }
        case "ai-provider":
            if let provider = AIProvider(rawValue: argument) { model.settings.aiProvider = provider }
        case "ai-model":
            let (provider, value) = split(argument)
            if let provider, !value.isEmpty { model.settings.setAIModel(value, for: provider) }
        case "ai-explain":
            if argument == "card", let tab = model.selectedTab, let error = model.explainableError(in: tab) {
                model.explainErrorCardItem = error.id
            }
            model.perform("output.explainError", source: argument == "card" ? .button : .script)
        case "ai-part":
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { model.setExplainErrorPart(parts[0], included: parts[1] == "on") }
        case "ai-send":
            model.sendExplainError()
        case "ai-stop":
            model.stopExplainError()
        case "ai-apply":
            model.applyExplainErrorFix()
        case "ai-undo":
            model.undoExplainErrorFix()
        case "ai-review":
            model.reviewExplainError()
        case "ai-close":
            model.closeExplainError()
        case "ai-state":
            log(state(model))
        case "ai-open-settings":
            model.perform("app.aiSettings", source: .button)
        case "ai-windows":
            let visible = NSApp.orderedWindows.filter { $0.isVisible && $0.styleMask.contains(.titled) && $0.sheetParent == nil }
            let titles = visible.map { $0.title.isEmpty ? String(describing: type(of: $0)) : $0.title }
            let sheet = NSApp.windows.contains { $0.isVisible && $0.attachedSheet != nil }
            log("ai-windows front-to-back=\(titles) sheet=\(sheet ? "open" : "none")")
        default:
            return false
        }
        return true
    }

    /// For `ai-wait`.
    static func reached(_ condition: String, model: AppModel) -> Bool {
        // The chat's conditions (#45).
        if let reached = AIChatDebugSteps.reached(condition, model: model) { return reached }
        let session = model.explainError
        switch condition.split(separator: ":").first.map(String.init) ?? "" {
        case "sheet": return session != nil
        case "text": return !(session?.answerText.isEmpty ?? true)
        case "fix": return session?.answer.isWritingFix == true || session?.answer.fix != nil
        case "done": return session.map { $0.phase == .finished || $0.phase == .failed } ?? false
        case "tested": return !AIProvider.allCases.contains { model.ai.testState($0) == .testing }
        default: return true
        }
    }

    static func state(_ model: AppModel) -> String {
        let keys = AIProvider.allCases.map { provider -> String in
            let key = switch model.ai.keyState(provider) {
            case .missing: "none"
            case .saved(let masked): "saved(\(masked ?? "?"))"
            }
            let test = switch model.ai.testState(provider) {
            case .idle: "idle"
            case .testing: "testing"
            case .succeeded(let count): "ok(\(count) models)"
            case .failed(let title, _): "failed(\(title))"
            }
            return "\(provider.rawValue): key=\(key) test=\(test) model=\(model.settings.aiModel(for: provider)) choices=\(model.aiModelChoices(provider).count)"
        }
        var line = "ai provider=\(model.settings.aiProvider.rawValue) " + keys.joined(separator: " · ")
        if let session = model.explainError {
            let parts = session.disclosure.parts.map { "\($0.id)=\($0.isIncluded ? "on" : "off")" }.joined(separator: ",")
            let answer = session.answer
            line += " · sheet=\(session.phase) parts=[\(parts)] chars=\(session.disclosure.characterCount) answer=\(session.answerText.count) chars"
            line += " blocks=\(answer.blocks.count) fix=\(session.proposedFix != nil ? "yes" : "no") applied=\(session.applied != nil)"
            line += " model=\(session.answeringModel ?? "-") stop=\(session.stopReason.map { "\($0)" } ?? "-") error=\(session.error?.title ?? "-") alert=\(session.alert?.title ?? "-")"
            if let tab = model.allTabs.first(where: { $0.id == session.tabId }) {
                line += " tabCode=\(tab.code == session.codeSent ? "unchanged" : "changed") autoRun=\(tab.autoRunEnabled)"
            }
        } else {
            line += " · sheet=none"
        }
        return line
    }

    private static func split(_ argument: String) -> (AIProvider?, String) {
        let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
        return (AIProvider(rawValue: parts.first ?? ""), parts.count > 1 ? parts[1] : "")
    }

    static func log(_ text: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(text)\n".utf8))
    }
}
#endif
