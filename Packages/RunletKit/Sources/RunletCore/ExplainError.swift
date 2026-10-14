import Foundation

/// Explain or Fix This Error (#44): what is asked about an error card, built on the AI layer
/// (#368). The disclosure has three parts, each with a switch: the error, the tab's code, and
/// the source of the file the error was thrown in (off by default: it's project code). The
/// answer is an explanation and, when changing the tab's code fixes it, the whole corrected
/// code in a `runlet-fix` block, shown as a diff that applies only on a click.
public struct ExplainErrorInput: Sendable, Equatable {
    public var language: TabLanguage
    /// The error as text (`ExplainErrorPrompt.errorText`).
    public var error: String
    /// The tab's code.
    public var code: String
    /// The editor line the error points at, when it's in the tab's code (the error's text says
    /// so too).
    public var line: Int?
    /// The file the error was thrown in, when it isn't the tab's code.
    public var frameSource: FrameSourceExcerpt?

    public init(language: TabLanguage, error: String, code: String, line: Int? = nil, frameSource: FrameSourceExcerpt? = nil) {
        self.language = language
        self.error = error
        self.code = code
        self.line = line
        self.frameSource = frameSource
    }
}

/// Lines around the line a file's frame points at.
public struct FrameSourceExcerpt: Sendable, Equatable {
    /// The path as Runlet shows it: relative to the project, or the full path outside it.
    public var path: String
    public var line: Int
    public var excerpt: SourceExcerpt

    public init(path: String, line: Int, excerpt: SourceExcerpt) {
        self.path = path
        self.line = line
        self.excerpt = excerpt
    }

    /// "app/Services/Totals.php, around line 21:" and the lines, numbered, the error's marked.
    public var text: String {
        let width = String(excerpt.lines.last?.number ?? line).count
        let lines = excerpt.lines.map { line in
            let number = String(line.number)
            let pad = String(repeating: " ", count: max(0, width - number.count))
            return "\(line.number == excerpt.focusLine ? ">" : " ") \(pad)\(number) | \(line.text)"
        }
        return "\(path), around line \(line):\n" + lines.joined(separator: "\n")
    }
}

public enum ExplainErrorPrompt {
    /// Each part is cut to this many characters (with a note saying so).
    public static let maxPartCharacters = 20_000
    /// Room for the model's thinking, the explanation, and a corrected copy of the code.
    public static let maxOutputTokens = 16_000
    /// Lines shown on each side of the frame's line.
    public static let frameRadius = 15
    public static let fixInfoString = "runlet-fix"

    public static func instructions(language: TabLanguage) -> String {
        let what = language == .php ? "a PHP snippet" : "\(language.displayName) code"
        return """
        You help a developer understand an error from \(what) they ran in Runlet, a scratchpad app for macOS. \
        Explain what the error means and why this code caused it, in plain language and a few short paragraphs. \
        Use Markdown: inline code in backticks, and fenced code blocks only for code.

        If a change to the tab's code fixes the error, end your answer with the complete corrected code in one fenced \
        code block whose info string is \(fixInfoString), like this:

        ```\(fixInfoString)
        (the whole corrected code)
        ```

        Change only what the fix needs, and keep the rest of the code exactly as it is. If the code in the tab isn't \
        what needs to change (the cause is in a project file, the database, or the environment), say what to change \
        and leave the \(fixInfoString) block out. Runlet never runs your code: the developer reviews the change and decides.
        """
    }

    /// The disclosure the sheet shows: the error and the code on, the frame's source off.
    public static func disclosure(_ input: ExplainErrorInput, provider: AIProvider, model: String) -> AIDisclosure {
        var parts: [AIDisclosurePart] = []
        let error = AITextLimit.clamp(input.error, limit: maxPartCharacters)
        parts.append(AIDisclosurePart(id: "error", title: "The error", text: error.text, note: error.note))
        let clamped = AITextLimit.clamp(input.code, limit: maxPartCharacters)
        parts.append(AIDisclosurePart(id: "code", title: "The tab's \(input.language.displayName) code", text: clamped.text, note: clamped.note))
        if let frame = input.frameSource {
            let source = AITextLimit.clamp(frame.text, limit: maxPartCharacters)
            parts.append(AIDisclosurePart(id: "source", title: "The source where it was thrown", text: source.text, isIncluded: false, note: source.note))
        }
        return AIDisclosure(provider: provider, model: model, instructions: instructions(language: input.language), parts: parts,
                            maxOutputTokens: maxOutputTokens, effort: .medium)
    }

    /// The error as the model reads it: the class and message, where it happened (the tab's
    /// line, a file's path as Runlet shows it, or both when the tab's code called into the file),
    /// its cause, and up to 12 frames of the trace.
    /// `path` turns a path PHP reported into the path to show.
    public static func errorText(_ error: RunErrorInfo, line: Int?, path: (String) -> String) -> String {
        var lines = ["\(error.className ?? "Error"): \(error.message)"]
        if let line, error.inSnippet != true, let file = error.file {
            // Thrown in a file, from a line of the tab's code (the line the card links to).
            lines.append("Thrown in \(path(file))" + (error.line.map { " on line \($0)" } ?? "") + ", from line \(line) of the tab's code.")
        } else if let line {
            lines.append("On line \(line) of the tab's code.")
        } else if let file = error.file {
            lines.append("Thrown in \(path(file))" + (error.line.map { " on line \($0)" } ?? "") + ".")
        }
        if let previous = error.previous {
            lines.append("Caused by \(previous.className): \(previous.message)")
        }
        let frames = (error.trace ?? []).prefix(12).enumerated().map { index, frame -> String in
            let function = frame.function ?? "{main}"
            if frame.inSnippet == true, let snippetLine = frame.snippetLine {
                return "#\(index) \(function) (the tab's code, line \(snippetLine))"
            }
            if let file = frame.file {
                return "#\(index) \(function) (\(path(file))" + (frame.line.map { ":\($0)" } ?? "") + ")"
            }
            return "#\(index) \(function)"
        }
        if !frames.isEmpty {
            lines.append("Stack trace:")
            lines += frames
            if (error.trace?.count ?? 0) > 12 { lines.append("… \((error.trace?.count ?? 0) - 12) more frames") }
        }
        return lines.joined(separator: "\n")
    }
}

/// A model's answer as Runlet shows it (#44): paragraphs and code blocks, with the
/// `runlet-fix` block taken out as the proposed fix.
public struct AIAnswer: Sendable, Equatable {
    public enum Block: Sendable, Equatable {
        /// Markdown text without code blocks.
        case text(String)
        /// A fenced code block; `isOpen` while it's still being written.
        case code(language: String?, String, isOpen: Bool)
    }

    public var blocks: [Block]
    /// The `runlet-fix` block's code, once its fence is closed.
    public var fix: String?
    /// A `runlet-fix` block is being written.
    public var isWritingFix: Bool

    public init(blocks: [Block], fix: String?, isWritingFix: Bool = false) {
        self.blocks = blocks
        self.fix = fix
        self.isWritingFix = isWritingFix
    }

    /// Splits text into blocks at code fences (three or more backticks or tildes). A fence
    /// that isn't closed yet is an open block, so a streamed answer shows code as it comes.
    public static func parse(_ text: String) -> AIAnswer {
        var blocks: [Block] = []
        var fix: String?
        var writingFix = false
        var prose: [String] = []
        var code: [String] = []
        var fence: (marker: String, language: String?)?

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.text(joined)) }
            prose = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open.marker), trimmed.drop(while: { $0 == open.marker.first }).trimmingCharacters(in: .whitespaces).isEmpty {
                    let body = code.joined(separator: "\n")
                    if open.language == ExplainErrorPrompt.fixInfoString {
                        fix = body
                    } else {
                        blocks.append(.code(language: open.language, body, isOpen: false))
                    }
                    fence = nil
                    code = []
                } else {
                    code.append(line)
                }
                continue
            }
            if let marker = fenceMarker(trimmed) {
                flushProse()
                let info = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                fence = (marker, info.isEmpty ? nil : String(info.split(separator: " ").first ?? ""))
                continue
            }
            prose.append(line)
        }
        flushProse()
        if let open = fence {
            if open.language == ExplainErrorPrompt.fixInfoString {
                writingFix = true
            } else {
                blocks.append(.code(language: open.language, code.joined(separator: "\n"), isOpen: true))
            }
        }
        return AIAnswer(blocks: blocks, fix: fix, isWritingFix: writingFix)
    }

    private static func fenceMarker(_ line: Substring) -> String? {
        for character in ["`", "~"] where line.hasPrefix(String(repeating: character, count: 3)) {
            let run = line.prefix { String($0) == character }
            // A backtick fence's info string has no backticks (CommonMark).
            if character == "`", line.dropFirst(run.count).contains("`") { return nil }
            return String(run)
        }
        return nil
    }

    private static func fenceMarker(_ line: String) -> String? { fenceMarker(Substring(line)) }
}

/// A line-by-line diff (#44), for showing a proposed change.
public enum LineDiff {
    public enum Change: Sendable, Equatable {
        case same(String)
        case removed(String)
        case added(String)
    }

    /// A row of a diff with context: a line with its numbers in the old and new text, or a gap
    /// of unchanged lines left out.
    public enum Row: Sendable, Equatable {
        case line(Change, old: Int?, new: Int?)
        case gap(Int)
    }

    public static func changes(from old: String, to new: String) -> [Change] {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        let difference = b.difference(from: a)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Change] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                result.append(.removed(a[i]))
                i += 1
            } else if j < b.count, inserted.contains(j) {
                result.append(.added(b[j]))
                j += 1
            } else if i < a.count, j < b.count {
                result.append(.same(a[i]))
                i += 1
                j += 1
            } else if i < a.count {
                result.append(.removed(a[i]))
                i += 1
            } else {
                result.append(.added(b[j]))
                j += 1
            }
        }
        return result
    }

    /// The changes with `context` unchanged lines around each, and gaps for the rest.
    public static func rows(from old: String, to new: String, context: Int = 3) -> [Row] {
        let all = changes(from: old, to: new)
        var numbered: [(Change, Int?, Int?)] = []
        var oldLine = 0, newLine = 0
        for change in all {
            switch change {
            case .same:
                oldLine += 1
                newLine += 1
                numbered.append((change, oldLine, newLine))
            case .removed:
                oldLine += 1
                numbered.append((change, oldLine, nil))
            case .added:
                newLine += 1
                numbered.append((change, nil, newLine))
            }
        }
        let changed = numbered.indices.filter { if case .same = numbered[$0].0 { false } else { true } }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for index in changed {
            for near in max(0, index - context)...min(numbered.count - 1, index + context) { keep.insert(near) }
        }
        var rows: [Row] = []
        var skipped = 0
        for index in numbered.indices {
            if keep.contains(index) {
                if skipped > 0 { rows.append(.gap(skipped)) }
                skipped = 0
                rows.append(.line(numbered[index].0, old: numbered[index].1, new: numbered[index].2))
            } else {
                skipped += 1
            }
        }
        if skipped > 0 { rows.append(.gap(skipped)) }
        return rows
    }
}
