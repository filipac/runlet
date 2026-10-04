import AppKit
import RunletCore
import RunletLanguage
import SwiftUI

/// What a source excerpt (#8) shows: a line of the code the run sent, or a line of a file on
/// this Mac, or why a file can't be read here.
enum ExcerptSource: Hashable {
    /// A line of the run's code (1-based in that code; the excerpt numbers lines like the editor).
    case snippet(snippetLine: Int)
    case file(FrameSourceFile, line: Int)
    case unavailable(path: String, line: Int, reason: String)

    /// The excerpt for a location from a run's output, or nil when it has none to show (no line,
    /// PHP's "Standard input code" for the runner, or a tab that isn't PHP).
    @MainActor static func make(inSnippet: Bool?, snippetLine: Int?, file: String?, line: Int?, resolver: FrameSourceResolver) -> ExcerptSource? {
        if inSnippet == true {
            guard let snippetLine, snippetLine > 0 else { return nil }
            return .snippet(snippetLine: snippetLine)
        }
        guard let file, let line, line > 0 else { return nil }
        switch resolver.locate(file) {
        case .none: return nil
        case .file(let source): return .file(source, line: line)
        case .unavailable(let path, let reason): return .unavailable(path: path, line: line, reason: reason)
        }
    }

    var isProjectFile: Bool {
        if case .file(let file, _) = self { return file.origin == .project }
        return false
    }
}

extension AppModel {
    /// Where the files in the tab's last run's output are on this Mac (#8).
    func frameSourceResolver(for tab: TabModel) -> FrameSourceResolver {
        let mapping = editorPathMapping(for: tab)
        guard let snapshot = tab.currentRequestForDisplay?.target else { return FrameSourceResolver(mapping: mapping) }
        return FrameSourceResolver(mapping: mapping, snapshot: snapshot)
    }
}

/// A few highlighted lines of source around a line, the line itself marked (#8). Read off the
/// main thread and kept for the run (`SourceExcerptStore`). A click on a line opens it: the
/// tab's own line in the editor, a project file in the external editor, and vendor code, files
/// outside the project, or any file when no editor is set, in the read-only peek (#22).
struct SourceExcerptView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let source: ExcerptSource
    let tab: TabModel
    @State private var outcome: SourceExcerptStore.Outcome?
    @State private var peek: ExcerptPeek?

    /// Excerpts read before a tab has a run request share this id.
    private static let noRun = UUID()

    private struct LoadKey: Hashable {
        var source: ExcerptSource
        var run: UUID
    }

    var body: some View {
        content
            .task(id: LoadKey(source: source, run: tab.currentRequestForDisplay?.runId ?? Self.noRun)) { await load() }
            .popover(item: $peek, arrowEdge: .trailing) { peek in
                CodePeekView(peek: peek)
                    .frame(width: 680, height: 360)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch source {
        case .unavailable(let path, let line, let reason):
            unavailable(path: path, line: line, reason: reason)
        case .snippet, .file:
            switch outcome {
            case .success(let excerpt):
                lines(excerpt.dedented())
            case .failure(let failure):
                if case .file(let file, let line) = source {
                    unavailable(path: file.hostPath, line: line, reason: failure.message)
                }
            case nil:
                EmptyView()
            }
        }
    }

    private func load() async {
        let run = tab.currentRequestForDisplay?.runId ?? Self.noRun
        switch source {
        case .snippet(let snippetLine):
            guard let request = tab.currentRequestForDisplay else { return }
            outcome = await SourceExcerptStore.shared.snippet(request, snippetLine: snippetLine)
        case .file(let file, let line):
            outcome = await SourceExcerptStore.shared.file(file.hostPath, line: line, run: run)
        case .unavailable:
            break
        }
    }

    // MARK: Lines

    private var font: Font { .system(size: 11, design: .monospaced) }

    private func lines(_ excerpt: SourceExcerpt) -> some View {
        let theme = EditorTheme.resolve(dark: colorScheme == .dark)
        let highlighted = Self.highlight(excerpt, theme: theme)
        let digits = String(excerpt.lines.last?.number ?? 1).count
        return VStack(alignment: .leading, spacing: 0) {
            if case .file(let file, _) = source, file.isLocalCopy {
                localCopyNote(file)
            }
            ForEach(Array(excerpt.lines.enumerated()), id: \.element.number) { index, line in
                let focused = line.number == excerpt.focusLine
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(String(line.number))
                        .foregroundStyle(Color(nsColor: focused ? theme.text : theme.gutterText))
                        .fontWeight(focused ? .semibold : .regular)
                        .frame(width: CGFloat(digits) * 7 + 2, alignment: .trailing)
                    Text(highlighted[index])
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .font(font)
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                .background(focused ? Color(nsColor: theme.errorLine) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { open(line: line.number) }
                .pointerStyle(.link)
                .help(help(line: line.number))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { open(line: line.number) }
                .accessibilityIdentifier(focused ? "excerpt-focus-line" : "excerpt-line")
            }
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: theme.background)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.25)))
        .contextMenu {
            Button("Copy Code") { Pasteboard.copy(excerpt.lines.map(\.text).joined(separator: "\n")) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("source-excerpt")
    }

    /// Docker and SSH: the lines come from the profile's local folder, not from what ran.
    private func localCopyNote(_ file: FrameSourceFile) -> some View {
        HStack(spacing: 6) {
            Text("local copy")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.orange.opacity(0.18)))
                .foregroundStyle(Color.orange)
            Text("may differ from \(file.runtimeLocation ?? "the target")")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 3)
        .help("Read from \(file.hostPath) on this Mac. \(file.runtimeLocation.map { "On \($0)" } ?? "On the target") the file is \(file.runtimePath), which may differ.")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("excerpt-local-copy")
    }

    private func unavailable(path: String, line: Int, reason: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "doc.questionmark").foregroundStyle(.secondary)
            Text("Source not available here")
                .foregroundStyle(.secondary)
            Text("\(path):\(line)")
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.caption)
        .help(reason)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("excerpt-unavailable")
    }

    /// Each line's text colored like the editor. The lines are highlighted together, so a
    /// comment or string that spans them keeps its color.
    static func highlight(_ excerpt: SourceExcerpt, theme: EditorTheme) -> [AttributedString] {
        let joined = excerpt.lines.map(\.text).joined(separator: "\n") as NSString
        let tokens = PHPHighlighter.tokenize(joined)
        var offset = 0
        return excerpt.lines.map { line in
            let length = (line.text as NSString).length
            let lineRange = NSRange(location: offset, length: length)
            offset += length + 1
            var text = AttributedString(line.text)
            text.foregroundColor = Color(nsColor: theme.text)
            for token in tokens {
                let overlap = NSIntersectionRange(token.range, lineRange)
                guard overlap.length > 0 else { continue }
                let local = NSRange(location: overlap.location - lineRange.location, length: overlap.length)
                if let range = Range(local, in: text) {
                    text[range].foregroundColor = Color(nsColor: theme.color(for: token.kind))
                }
            }
            return text
        }
    }

    // MARK: Opening a line

    private var opensInEditor: Bool {
        guard case .file(let file, _) = source else { return false }
        return file.origin == .project && model.settings.externalEditor != .none
    }

    private func help(line: Int) -> String {
        switch source {
        case .snippet: return "Go to line \(line)"
        case .file(let file, _):
            return opensInEditor ? "\(model.openInEditorTitle): \(file.hostPath):\(line)" : "Show \(file.fileName):\(line) read-only"
        case .unavailable: return ""
        }
    }

    private func open(line: Int) {
        switch source {
        case .snippet:
            tab.editor.goTo(line: line)
        case .file(let file, _):
            if opensInEditor {
                model.openInExternalEditor(path: file.hostPath, line: line)
            } else {
                Task { peek = await ExcerptPeek.load(file, line: line) }
            }
        case .unavailable:
            break
        }
    }
}

/// A file's text for the read-only peek, read off the main thread (at most 4 MB, as #22's).
struct ExcerptPeek: Identifiable {
    let id = UUID()
    let file: NavigationFile
    let text: String

    static func load(_ source: FrameSourceFile, line: Int) async -> ExcerptPeek? {
        let path = source.hostPath
        let text = await Task.detached(priority: .userInitiated) { () -> String? in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? Int ?? 0) <= 4_000_000 else { return nil }
            return (try? String(contentsOfFile: path, encoding: .utf8)) ?? (try? String(contentsOfFile: path, encoding: .isoLatin1))
        }.value
        guard let text else { return nil }
        return ExcerptPeek(file: NavigationFile(frameSource: source, line: line), text: text)
    }
}

/// #22's `CodePeekController` in a SwiftUI popover.
struct CodePeekView: NSViewControllerRepresentable {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    let peek: ExcerptPeek

    func makeNSViewController(context: Context) -> CodePeekController {
        let settings = model.settings
        let font = EditorFonts.font(family: settings.editorFontName, size: CGFloat(settings.fontSize), ligatures: settings.ligatures)
        let editorName: String? = settings.externalEditor == .none ? nil : model.externalEditorName
        let controller = CodePeekController(file: peek.file, text: peek.text, theme: EditorTheme.resolve(dark: colorScheme == .dark), font: font, editorName: editorName)
        let path = peek.file.path
        let line = peek.file.line
        controller.onOpen = { [model, dismiss] in
            dismiss()
            if let path { model.openInExternalEditor(path: path, line: line) }
        }
        controller.onReveal = { [model] in
            if let path { model.revealInFinder(path: path) }
        }
        return controller
    }

    func updateNSViewController(_ controller: CodePeekController, context: Context) {}
}

/// A stack trace in an error card: each frame's function and location. A frame with source can
/// open to show its excerpt (#8); the first project frame is open at first, the rest (the
/// snippet's own frames, vendor code, files that can't be read) closed.
struct StackTraceView: View {
    @Environment(AppModel.self) private var model
    let trace: [RunErrorInfo.Frame]
    let tab: TabModel
    /// The excerpt the card already shows, which the trace doesn't open again.
    var shownSource: ExcerptSource?
    @State private var showTrace = false
    /// Frames opened or closed by hand, against their default.
    @State private var toggled: Set<Int> = []

    var body: some View {
        let resolver = model.frameSourceResolver(for: tab)
        let sources = trace.map { frame -> ExcerptSource? in
            guard tab.language == .php else { return nil }
            return ExcerptSource.make(inSnippet: frame.inSnippet, snippetLine: frame.snippetLine, file: frame.file, line: frame.line, resolver: resolver)
        }
        let openAtFirst = sources.firstIndex { $0?.isProjectFile == true && $0 != shownSource }
        VStack(alignment: .leading, spacing: 2) {
            Button {
                showTrace.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(showTrace ? 90 : 0))
                        .frame(width: 10)
                    Text("Stack trace (\(trace.count))")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("stack-trace-toggle")
            if showTrace {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(trace.enumerated()), id: \.offset) { index, frame in
                        let isOpen = (index == openAtFirst) != toggled.contains(index)
                        row(index: index, frame: frame, source: sources[index], isOpen: isOpen)
                        if isOpen, let source = sources[index] {
                            SourceExcerptView(source: source, tab: tab)
                                .padding(.leading, 16)
                                .padding(.bottom, 4)
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private func row(index: Int, frame: RunErrorInfo.Frame, source: ExcerptSource?, isOpen: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if source != nil {
                Button {
                    if toggled.contains(index) { toggled.remove(index) } else { toggled.insert(index) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isOpen ? "Hide the source" : "Show the source")
                .accessibilityLabel(isOpen ? "Hide the source of frame \(index)" : "Show the source of frame \(index)")
                .accessibilityIdentifier("stack-frame-toggle-\(index)")
            } else {
                Spacer().frame(width: 10)
            }
            Text("#\(index)").foregroundStyle(.secondary).monospacedDigit()
            Text(frame.function ?? "{main}").font(.system(.caption, design: .monospaced))
            if frame.inSnippet == true, let snippetLine = frame.snippetLine, let request = tab.currentRequestForDisplay {
                let editorLine = request.editorLine(forSnippetLine: snippetLine)
                Button("line \(editorLine)") { tab.editor.goTo(line: editorLine) }.buttonStyle(.link)
            } else if let file = frame.file {
                FileLocationLink(path: file, line: frame.line, label: "\((file as NSString).lastPathComponent):\(frame.line ?? 0)", tab: tab)
            }
            if case .file(let file, _) = source, file.origin == .vendor {
                Text("vendor").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
