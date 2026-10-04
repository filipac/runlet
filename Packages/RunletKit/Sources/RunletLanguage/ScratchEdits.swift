import Foundation

/// One replacement in the editor's text (UTF-16 offsets).
public struct ScratchEdit: Sendable, Equatable {
    public var range: NSRange
    public var text: String

    public init(range: NSRange, text: String) {
        self.range = range
        self.text = text
    }
}

/// Why a code action's edit isn't applied (#22).
public enum ScratchEditRejection: Error, Sendable, Equatable, CustomStringConvertible {
    /// The edit changes files besides the tab (their names). Multi-file edits are deferred.
    case otherFiles([String])
    /// The edit creates, renames, or deletes files.
    case resourceOperations
    /// The edit replaces text Runlet adds and never shows (`<?php`, `@var` lines, the final `;`).
    case hiddenText
    /// Two edits overlap.
    case overlapping
    /// Nothing changes.
    case empty

    public var description: String {
        switch self {
        case .otherFiles(let names):
            let list = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? ", …" : "")
            return "This action also changes \(list). Runlet only applies changes to the tab's own code."
        case .resourceOperations:
            return "This action creates, renames, or deletes files. Runlet only applies changes to the tab's own code."
        case .hiddenText:
            return "This action changes lines Runlet adds before the snippet, so it isn't applied."
        case .overlapping:
            return "This action's changes overlap, so it isn't applied."
        case .empty:
            return "This action changes nothing."
        }
    }
}

public enum ScratchEditPlanner {
    /// The editor replacements for `edit`, back to front (apply them in order). Only edits to
    /// `scratchURI` are accepted, and none may touch the hidden lines: an insertion before the
    /// snippet (an import after `<?php`) goes to its start, one after it to its end.
    public static func plan(_ edit: LSPWorkspaceEdit, scratchURI: String, mapping: ScratchDocumentMapping, editorText: String) -> Result<[ScratchEdit], ScratchEditRejection> {
        guard edit.resourceOperations.isEmpty else { return .failure(.resourceOperations) }
        let others = edit.changes.filter { $0.key != scratchURI && !$0.value.isEmpty }.keys
        if !others.isEmpty {
            let names = others.map { uri in URL(string: uri).map { $0.lastPathComponent } ?? uri }.sorted()
            return .failure(.otherFiles(names))
        }
        let edits = edit.changes[scratchURI] ?? []
        guard !edits.isEmpty else { return .failure(.empty) }

        let lspText = mapping.lspText(for: editorText)
        let index = TextLineIndex(lspText)
        let editorLength = editorText.utf16.count
        let suffixLength = mapping.hasSyntheticTag ? ScratchDocumentMapping.syntheticSuffix.utf16.count : 0
        let prefixLength = lspText.utf16.count - editorLength - suffixLength
        let editorEnd = prefixLength + editorLength

        var planned: [(order: Int, edit: ScratchEdit)] = []
        for (order, textEdit) in edits.enumerated() {
            var start = index.offset(of: textEdit.range.start)
            var end = max(start, index.offset(of: textEdit.range.end))
            if start == end {
                // Insertions in hidden text land at the nearest end of the snippet.
                if start < prefixLength { start = prefixLength; end = prefixLength }
                if start > editorEnd { start = editorEnd; end = editorEnd }
            } else if start < prefixLength || end > editorEnd {
                return .failure(.hiddenText)
            }
            planned.append((order, ScratchEdit(range: NSRange(location: start - prefixLength, length: end - start), text: textEdit.newText)))
        }
        // Front to back to find overlaps; insertions at one point keep the server's order.
        let forward = planned.sorted { ($0.edit.range.location, $0.order) < ($1.edit.range.location, $1.order) }
        for (previous, next) in zip(forward, forward.dropFirst()) where NSMaxRange(previous.edit.range) > next.edit.range.location {
            return .failure(.overlapping)
        }
        if planned.allSatisfy({ $0.edit.range.length == 0 && $0.edit.text.isEmpty }) { return .failure(.empty) }
        return .success(forward.reversed().map(\.edit))
    }

    /// `editorText` with `edits` (from `plan`) applied, for checks and tests.
    public static func apply(_ edits: [ScratchEdit], to editorText: String) -> String {
        let text = NSMutableString(string: editorText)
        for edit in edits { text.replaceCharacters(in: edit.range, with: edit.text) }
        return text as String
    }
}

/// An inlay hint placed in the editor's text (#22).
public struct EditorInlayHint: Sendable, Equatable {
    /// UTF-16 offset of the character the hint is drawn before.
    public var offset: Int
    public var label: String
    public var kind: InlayHint.Kind
    public var tooltip: String?

    public init(offset: Int, label: String, kind: InlayHint.Kind, tooltip: String? = nil) {
        self.offset = offset
        self.label = label
        self.kind = kind
        self.tooltip = tooltip
    }
}

public enum InlayHintPlacement {
    /// Hints in editor offsets, by offset. Only parameter names and inferred types are kept
    /// (PHPantom 0.10 also sends kindless "N references" hints after declarations, which Runlet
    /// leaves out), and none on hidden lines, past a line's end, or at the start of a line.
    /// Two hints at one offset keep the first.
    public static func place(_ hints: [InlayHint], mapping: ScratchDocumentMapping, editorText: String) -> [EditorInlayHint] {
        let index = TextLineIndex(editorText)
        let string = editorText as NSString
        var byOffset: [Int: EditorInlayHint] = [:]
        for hint in hints {
            guard let kind = hint.kind, hint.position.line >= mapping.lineOffset else { continue }
            let position = mapping.toEditor(hint.position)
            guard position.line < index.lineCount, position.character > 0 else { continue }
            let offset = index.offset(of: position)
            // Clamped: the position is past the end of its line.
            guard index.position(at: offset) == position, offset <= string.length else { continue }
            let previous = string.character(at: offset - 1)
            guard previous != 0x0A, previous != 0x0D else { continue }
            let label = hint.label.trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, byOffset[offset] == nil else { continue }
            byOffset[offset] = EditorInlayHint(offset: offset, label: label, kind: kind, tooltip: hint.tooltip)
        }
        return byOffset.values.sorted { $0.offset < $1.offset }
    }

    /// The LSP range to ask hints for: the visible editor lines `visibleLines` (0-based,
    /// inclusive) plus `margin` lines either side, clamped to the snippet.
    public static func requestRange(visibleLines: ClosedRange<Int>, margin: Int = 20, editorLineCount: Int, mapping: ScratchDocumentMapping) -> LSPRange {
        let first = max(0, visibleLines.lowerBound - margin)
        let last = min(max(0, editorLineCount - 1), visibleLines.upperBound + margin)
        return LSPRange(start: mapping.toLSP(LSPPosition(line: first, character: 0)), end: mapping.toLSP(LSPPosition(line: last + 1, character: 0)))
    }
}
