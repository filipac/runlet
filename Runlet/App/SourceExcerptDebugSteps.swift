#if DEBUG
import AppKit
import RunletCore

/// Debug steps for source excerpts in error cards (#8):
/// `excerpt-state` prints, for the current tab's error cards (and `\Runlet\error()` cards with a
/// Throwable), the card's own excerpt and every frame's: where the source comes from (the run's
/// code, a project, vendor, or outside file, a local copy, or why it isn't available), whether the
/// frame is open at first, and the excerpt's lines with the failing one marked `>`.
@MainActor
enum SourceExcerptDebugSteps {
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        guard name == "excerpt-state" else { return false }
        guard let tab = model.selectedTab else {
            log("excerpt-state: no tab")
            return true
        }
        let resolver = model.frameSourceResolver(for: tab)
        var cards: [(title: String, own: ExcerptSource?, frames: [ExcerptSource?])] = []
        for item in tab.output {
            switch item {
            case .error(_, let error, _):
                let own = ExcerptSource.make(inSnippet: error.inSnippet, snippetLine: error.snippetLine, file: error.file, line: error.line, resolver: resolver)
                let frames = (error.trace ?? []).map { ExcerptSource.make(inSnippet: $0.inSnippet, snippetLine: $0.snippetLine, file: $0.file, line: $0.line, resolver: resolver) }
                cards.append(("error \(error.className ?? "Error")", own, frames))
            case .snippetMessage(_, let message, _):
                guard let exception = message.exception else { continue }
                let own = ExcerptSource.make(inSnippet: exception.inSnippet, snippetLine: exception.snippetLine, file: exception.file, line: exception.line, resolver: resolver)
                let frames = (exception.trace ?? []).map { ExcerptSource.make(inSnippet: $0.inSnippet, snippetLine: $0.snippetLine, file: $0.file, line: $0.line, resolver: resolver) }
                cards.append(("\(message.level.rawValue) \(exception.className)", own, frames))
            default:
                continue
            }
        }
        let request = tab.currentRequestForDisplay
        Task {
            var lines = ["excerpt-state: \(cards.count) card(s)"]
            for card in cards {
                lines.append("  \(card.title): \(await describe(card.own, request: request))")
                let open = StackTraceView.openAtFirst(card.frames, shown: card.own)
                for (index, frame) in card.frames.enumerated() {
                    lines.append("    #\(index)\(index == open ? " [open]" : ""): \(await describe(frame, request: request))")
                }
            }
            log(lines.joined(separator: "\n"))
        }
        return true
    }

    private static func describe(_ source: ExcerptSource?, request: RunRequest?) async -> String {
        guard let source else { return "none" }
        let run = request?.runId ?? UUID()
        let label: String
        let outcome: SourceExcerptStore.Outcome?
        switch source {
        case .snippet(let line):
            label = "snippet line \(line)"
            outcome = if let request { await SourceExcerptStore.shared.snippet(request, snippetLine: line) } else { nil }
        case .file(let file, let line):
            label = "\(file.origin) \(file.displayPath):\(line)\(file.isLocalCopy ? " (local copy of \(file.runtimePath) on \(file.runtimeLocation ?? "?"))" : "")"
            outcome = await SourceExcerptStore.shared.file(file.hostPath, line: line, run: run)
        case .unavailable(let path, let line, let reason):
            return "unavailable \(path):\(line) — \(reason)"
        }
        switch outcome {
        case .success(let excerpt):
            let text = excerpt.lines.map { "\($0.number == excerpt.focusLine ? ">" : " ")\($0.number) \($0.text)" }.joined(separator: " | ")
            return "\(label) [\(text)]"
        case .failure(let failure):
            return "\(label) — Source not available here: \(failure.message)"
        case nil:
            return "\(label) — no run"
        }
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}
#endif
