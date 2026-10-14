import AppKit
import RunletCore

/// Explain or Fix This Error (#44): a sheet that first shows exactly what it would send (the
/// error, the tab's code, and the source where it was thrown, each with a switch) and sends only
/// when the user clicks Send. The answer streams in; a proposed fix shows as a diff, and only
/// Apply Fix changes the tab, as one undoable edit. Nothing here runs code, and production's
/// confirmations are untouched: running the fixed code is the user's Run.
@MainActor
@Observable
final class ExplainErrorSession: Identifiable {
    enum Phase: Equatable {
        /// The disclosure: nothing sent yet.
        case review
        case streaming
        /// The answer ended (complete, cut off, or stopped).
        case finished
        /// No answer: `error` says why.
        case failed
    }

    /// A fix the user applied, so it can be put back.
    struct AppliedFix: Equatable {
        var before: String
        var after: String
    }

    let id = UUID()
    /// The window whose sheet this is.
    let windowId: UUID?
    let tabId: UUID
    let tabTitle: String
    /// The tab's code when the sheet opened: what's sent, and what a fix replaces.
    let codeSent: String
    var disclosure: AIDisclosure
    var phase: Phase = .review
    var answerText = ""
    /// The model is thinking before it writes.
    var isThinking = false
    /// The model that answers, from the stream.
    var answeringModel: String?
    /// A fallback model answered after the chosen one declined (Anthropic).
    var fallback: (from: String?, to: String?)?
    var stopReason: AIStopReason?
    /// Stop was pressed: the answer is incomplete.
    var stopped = false
    var error: AIError?
    /// An alert over the sheet: what failed, and what to do next.
    var alert: AppAlert?
    var applied: AppliedFix?
    var copied = false
    @ObservationIgnored var task: Task<Void, Never>?

    init(windowId: UUID?, tabId: UUID, tabTitle: String, codeSent: String, disclosure: AIDisclosure) {
        self.windowId = windowId
        self.tabId = tabId
        self.tabTitle = tabTitle
        self.codeSent = codeSent
        self.disclosure = disclosure
    }

    var answer: AIAnswer { AIAnswer.parse(answerText) }

    /// The proposed code, ending with a line break when the tab's code does.
    var proposedFix: String? {
        guard var fix = answer.fix, phase != .streaming || !answer.isWritingFix else { return nil }
        if codeSent.hasSuffix("\n"), !fix.hasSuffix("\n") { fix += "\n" }
        return fix == codeSent ? nil : fix
    }
}

extension AppModel {
    /// The error Explain or Fix works on: the card's (`itemId`), or the tab's last error. An
    /// error that only reports Stop's cancel (#144) doesn't count.
    func explainableError(in tab: TabModel, itemId: Int? = nil) -> (id: Int, error: RunErrorInfo, line: Int?)? {
        for item in tab.output.reversed() {
            guard case .error(let id, let error, let line) = item, error.interruptedByStop != true else { continue }
            if let itemId, id != itemId { continue }
            return (id, error, line)
        }
        return nil
    }

    /// How an error's file paths read when they're sent: relative to the project, from
    /// `vendor/` for packages, and only the file's name elsewhere (never this Mac's folders).
    /// The chat's output context (#45) shows errors the same way.
    func errorDisplayPath(for tab: TabModel) -> (String) -> String {
        let resolver = frameSourceResolver(for: tab)
        return { file in
            if case .file(let source) = resolver.locate(file) { return source.displayPath }
            if let range = file.range(of: "/vendor/") { return String(file[file.index(after: range.lowerBound)...]) }
            return (file as NSString).lastPathComponent
        }
    }

    /// Why Explain or Fix Error can't run for the tab, or nil when it can.
    func explainErrorDisabledReason(for tab: TabModel?) -> String? {
        guard let tab else { return "Explain or Fix Error works on the current tab's last error." }
        if tab.isRunning { return "Explain or Fix Error works once the run ends." }
        if explainableError(in: tab) == nil { return "Explain or Fix Error works on a tab whose last run showed an error." }
        return nil
    }

    /// Output ▸ Explain or Fix Error…, and the error card's button: opens the sheet on the error,
    /// showing what would be sent. Sends nothing.
    func beginExplainError(_ tab: TabModel, itemId: Int? = nil) {
        guard !tab.isRunning, let (_, error, line) = explainableError(in: tab, itemId: itemId) else { return }
        explainError?.task?.cancel()
        let resolver = frameSourceResolver(for: tab)
        let text = ExplainErrorPrompt.errorText(error, line: line, path: errorDisplayPath(for: tab))
        let provider = settings.aiProvider
        let model = settings.aiModel(for: provider)
        // #45: Settings ▸ AI's reasoning level, when the model takes it.
        let effort = AIModelTraits.effort(settings.aiEffort(for: provider), provider, model)
        let windowId = window(containing: tab.id)?.id
        let code = tab.code
        var frame: FrameSourceFile?
        if tab.language == .php, error.inSnippet != true, let file = error.file, let errorLine = error.line, errorLine > 0,
           case .file(let source) = resolver.locate(file) {
            frame = source
        }
        refreshAIKeyStates()
        Task { [weak self] in
            var excerpt: FrameSourceExcerpt?
            if let frame, let errorLine = error.line {
                let read = await Task.detached(priority: .userInitiated) {
                    SourceExcerptReader.read(path: frame.hostPath, line: errorLine, limits: SourceExcerptLimits(radius: ExplainErrorPrompt.frameRadius))
                }.value
                if case .success(let lines) = read { excerpt = FrameSourceExcerpt(path: frame.displayPath, line: errorLine, excerpt: lines) }
            }
            guard let self else { return }
            let input = ExplainErrorInput(language: tab.language, error: text, code: code, line: line, frameSource: excerpt)
            self.explainError = ExplainErrorSession(windowId: windowId, tabId: tab.id, tabTitle: tab.title, codeSent: code,
                                                    disclosure: ExplainErrorPrompt.disclosure(input, provider: provider, model: model, effort: effort))
        }
    }

    /// The sheet's Send button: the user's consent for exactly the disclosure on screen. The
    /// answer streams into the sheet.
    func sendExplainError() {
        guard let session = explainError, session.phase != .streaming, !session.disclosure.isEmpty else { return }
        let provider = session.disclosure.provider
        guard hasAIKey(provider) else {
            let missing = AIError.missingKey(provider)
            session.alert = AppAlert(title: missing.title, message: missing.message)
            return
        }
        let disclosure = session.disclosure
        let consent = AIConsent(approving: disclosure)
        session.phase = .streaming
        session.answerText = ""
        session.isThinking = false
        session.answeringModel = nil
        session.fallback = nil
        session.stopReason = nil
        session.stopped = false
        session.error = nil
        session.applied = nil
        session.task = Task { [weak self, weak session] in
            guard let self else { return }
            do {
                for try await event in self.streamAI(disclosure, consent: consent) {
                    guard let session else { return }
                    switch event {
                    case .started(let model):
                        session.answeringModel = model.isEmpty ? nil : model
                    case .thinking:
                        session.isThinking = true
                    case .text(let text):
                        session.isThinking = false
                        session.answerText += text
                    case .fallback(let from, let to):
                        session.fallback = (from, to)
                        if let to { session.answeringModel = to }
                    case .finished(let finish):
                        self.finishExplainError(session, finish)
                    }
                }
                if let session, session.phase == .streaming { session.phase = .finished }
            } catch {
                guard let session else { return }
                self.failExplainError(session, error)
            }
        }
    }

    private func finishExplainError(_ session: ExplainErrorSession, _ finish: AIFinish) {
        session.isThinking = false
        session.stopReason = finish.reason
        if let model = finish.model { session.answeringModel = model }
        if case .refusal(let category, let explanation) = finish.reason {
            // A declined answer isn't an answer: what arrived before is dropped.
            session.answerText = ""
            let refused = AIError.refused(session.disclosure.provider, category: category, explanation: explanation)
            session.error = refused
            session.phase = .failed
            session.alert = AppAlert(title: refused.title, message: refused.message)
            return
        }
        session.phase = .finished
    }

    private func failExplainError(_ session: ExplainErrorSession, _ error: Error) {
        session.isThinking = false
        if let error = error as? CredentialStoreError {
            session.error = .missingKey(session.disclosure.provider)
            session.phase = .failed
            session.alert = AppAlert(title: "Couldn't read the key", message: error.description)
            return
        }
        let failure = AIErrorMapping.transport(error, provider: session.disclosure.provider)
        if failure == .cancelled {
            session.stopped = true
            session.phase = session.answerText.isEmpty ? .review : .finished
            return
        }
        session.error = failure
        session.phase = .failed
        session.alert = AppAlert(title: failure.title, message: failure.message)
    }

    /// The sheet's Stop button (⌘.): ends the request; what arrived stays, marked incomplete.
    func stopExplainError() {
        explainError?.task?.cancel()
    }

    /// Closes the sheet (Cancel, Done, Esc): a request still streaming is cancelled.
    func closeExplainError() {
        explainError?.task?.cancel()
        explainError = nil
    }

    /// Back to the disclosure, to change what's sent or send again.
    func reviewExplainError() {
        guard let session = explainError, session.phase != .streaming else { return }
        session.phase = .review
        session.error = nil
    }

    func setExplainErrorPart(_ id: String, included: Bool) {
        guard let session = explainError, session.phase == .review else { return }
        session.disclosure.setIncluded(id, included)
    }

    /// Apply Fix: the tab's code becomes the proposed code, as one undoable edit. Only when the
    /// tab still has the code that was sent; auto-run turns off, and nothing runs.
    func applyExplainErrorFix() {
        guard let session = explainError, session.applied == nil, let fix = session.proposedFix else { return }
        guard let tab = allTabs.first(where: { $0.id == session.tabId }) else {
            session.alert = AppAlert(title: "The tab is closed", message: "Copy the fix instead, and paste it into another tab.")
            return
        }
        guard tab.code == session.codeSent else {
            session.alert = AppAlert(title: "The tab's code changed", message: "It isn't the code that was sent anymore, so the fix may not fit. Ask again to get a fix for the current code.")
            return
        }
        tab.setAutoRunEnabled(false)
        tab.editor.applyReplacement(fix, actionName: "Apply Fix")
        session.applied = ExplainErrorSession.AppliedFix(before: session.codeSent, after: tab.code)
    }

    /// Undo Apply Fix: the tab's code goes back to what it was. Edit ▸ Undo in the editor does
    /// the same.
    func undoExplainErrorFix() {
        guard let session = explainError, let applied = session.applied,
              let tab = allTabs.first(where: { $0.id == session.tabId }) else { return }
        guard tab.code == applied.after else {
            session.alert = AppAlert(title: "The tab changed after the fix", message: "Use Edit ▸ Undo in the editor to step back through the changes.")
            return
        }
        tab.editor.applyReplacement(applied.before, actionName: "Undo Apply Fix")
        session.applied = nil
    }

    func copyExplainErrorAnswer() {
        guard let session = explainError, !session.answerText.isEmpty else { return }
        Pasteboard.copy(session.answerText)
        session.copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak session] in session?.copied = false }
    }
}
