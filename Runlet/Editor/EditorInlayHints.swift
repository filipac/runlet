import AppKit
import RunletLanguage

/// PHPantom's inlay hints (#22): parameter names before arguments and inferred types, drawn as
/// small labels inside the code without changing the text.
///
/// Each hint needs room: the character before it gets a `.kern` (extra advance) as wide as the
/// label, carrying a marker so only these kerns are ever removed, and the label is drawn in that
/// gap over the text. The characters and the undo history are never touched, so copying, running,
/// saving, and Format Code see the code as typed. Hints are asked for the visible lines only
/// (plus a margin), a moment after scrolling or typing stops; an edit drops the hints it touches
/// and moves the rest with the text until the next answer.
@MainActor
final class EditorInlayHints {
    private weak var textView: CodeTextView?
    var theme = EditorTheme.resolve(dark: false) { didSet { textView?.needsDisplay = true } }
    /// View ▸ Show Inlay Hints (saved in Settings).
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { scheduleRefresh(after: .zero) } else { clear() }
        }
    }
    weak var binding: LanguageBinding? {
        didSet {
            clear()
            if binding != nil { scheduleRefresh(after: .milliseconds(400)) }
        }
    }

    /// A hint in the text: where it is and how wide its gap is.
    struct Placed: Equatable {
        var hint: EditorInlayHint
        var width: CGFloat
    }

    private(set) var placed: [Placed] = []
    /// Characters folded away (`EditorFolding`): their hints aren't drawn.
    var isHidden: ((Int) -> Bool)?
    private var refreshTask: Task<Void, Never>?
    /// Bumped by every edit, so an answer for older text is dropped.
    private var generation = 0
    private static let marker = NSAttributedString.Key("RunletInlayHint")

    init(textView: CodeTextView) {
        self.textView = textView
        let clip = textView.enclosingScrollView?.contentView
        NotificationCenter.default.addObserver(self, selector: #selector(viewChanged), name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(viewChanged), name: NSView.frameDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: textView)
    }

    private var fontSize: CGFloat { textView?.font?.pointSize ?? 13 }
    private var labelFont: NSFont { NSFont.systemFont(ofSize: max(9, fontSize - 2), weight: .regular) }

    @objc private func viewChanged() { scheduleRefresh(after: .milliseconds(250)) }
    @objc private func textChanged() { scheduleRefresh(after: .milliseconds(450)) }

    /// The editor font or size changed: the gaps are re-measured.
    func fontChanged() {
        guard !placed.isEmpty else { return }
        apply(placed.map(\.hint))
    }

    func scheduleRefresh(after delay: Duration) {
        refreshTask?.cancel()
        guard isEnabled, binding != nil else { return }
        refreshTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func refresh() async {
        guard isEnabled, let binding, let textView, let lines = visibleLines(in: textView) else { return }
        let text = textView.string
        let generation = generation
        let lineCount = TextLineIndex(text).lineCount
        let range = InlayHintPlacement.requestRange(visibleLines: lines, editorLineCount: lineCount, mapping: binding.mapping)
        guard let hints = try? await binding.inlayHints(range: range), !Task.isCancelled,
              self.generation == generation, isEnabled, textView.string == text else { return }
        apply(InlayHintPlacement.place(hints, mapping: binding.mapping, editorText: text))
    }

    /// The 0-based editor lines on screen.
    private func visibleLines(in textView: NSTextView) -> ClosedRange<Int>? {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }
        let text = textView.string as NSString
        let glyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let index = TextLineIndex(textView.string)
        let first = index.position(at: min(characters.location, text.length)).line
        let last = index.position(at: min(NSMaxRange(characters), text.length)).line
        return first...max(first, last)
    }

    /// Replaces the hints in the text with `hints`.
    func apply(_ hints: [EditorInlayHint]) {
        guard let textView, let storage = textView.textStorage else { return }
        let length = storage.length
        let font = labelFont
        let next = hints.filter { $0.offset > 0 && $0.offset <= length }.map { hint in
            Placed(hint: hint, width: ceil((hint.label as NSString).size(withAttributes: [.font: font]).width) + 12)
        }
        guard next != placed else { return }
        storage.beginEditing()
        removeKerns(from: storage)
        for item in next {
            storage.addAttributes([.kern: item.width, Self.marker: true], range: NSRange(location: item.hint.offset - 1, length: 1))
        }
        storage.endEditing()
        placed = next
        textView.needsDisplay = true
    }

    func clear() {
        refreshTask?.cancel()
        guard !placed.isEmpty, let storage = textView?.textStorage else {
            placed = []
            return
        }
        storage.beginEditing()
        removeKerns(from: storage)
        storage.endEditing()
        placed = []
        textView?.needsDisplay = true
    }

    private func removeKerns(from storage: NSTextStorage) {
        for item in placed {
            let range = NSRange(location: item.hint.offset - 1, length: 1)
            guard NSMaxRange(range) <= storage.length, storage.attribute(Self.marker, at: range.location, effectiveRange: nil) != nil else { continue }
            storage.removeAttribute(.kern, range: range)
            storage.removeAttribute(Self.marker, range: range)
        }
    }

    /// An edit replaced `edited.length - delta` characters at `edited.location` (called while
    /// the text storage processes it). New text never takes a hint's gap, hints the edit touches
    /// go, and the others move with their text until the next answer.
    func textStorage(_ storage: NSTextStorage, willProcessEditing edited: NSRange, changeInLength delta: Int) {
        generation += 1
        refreshTask?.cancel()
        if edited.length > 0, NSMaxRange(edited) <= storage.length {
            storage.removeAttribute(.kern, range: edited)
            storage.removeAttribute(Self.marker, range: edited)
        }
        guard !placed.isEmpty else { return }
        let replacedEnd = edited.location + edited.length - delta
        var kept: [Placed] = []
        for var item in placed {
            let offset = item.hint.offset
            if offset < edited.location {
                kept.append(item)
            } else if offset > replacedEnd {
                item.hint.offset += delta
                kept.append(item)
            } else {
                // Touched: remove its gap if its character is still there.
                let kernAt = offset - 1
                if kernAt < edited.location, kernAt >= 0, kernAt < storage.length, storage.attribute(Self.marker, at: kernAt, effectiveRange: nil) != nil {
                    storage.removeAttribute(.kern, range: NSRange(location: kernAt, length: 1))
                    storage.removeAttribute(Self.marker, range: NSRange(location: kernAt, length: 1))
                }
            }
        }
        placed = kept
    }

    // MARK: Drawing

    /// Draws the labels in their gaps (over the text, so a selection doesn't hide them).
    func draw(in dirtyRect: NSRect) {
        guard isEnabled, !placed.isEmpty, let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let origin = textView.textContainerOrigin
        let length = (textView.string as NSString).length
        let font = labelFont
        let visible = layoutManager.characterRange(forGlyphRange: layoutManager.glyphRange(forBoundingRect: dirtyRect, in: container), actualGlyphRange: nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.inlineText]
        for item in placed where item.hint.offset - 1 >= visible.location && item.hint.offset - 1 <= NSMaxRange(visible) && item.hint.offset <= length {
            guard isHidden?(item.hint.offset - 1) != true else { continue }
            let before = layoutManager.glyphIndexForCharacter(at: item.hint.offset - 1)
            guard before < layoutManager.numberOfGlyphs else { continue }
            var fragmentGlyphs = NSRange()
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: before, effectiveRange: &fragmentGlyphs)
            let location = layoutManager.location(forGlyphAt: before)
            // The gap ends where the next glyph starts on the same row, else at the row's end.
            let gapEnd: CGFloat
            if item.hint.offset < length, case let after = layoutManager.glyphIndexForCharacter(at: item.hint.offset), NSLocationInRange(after, fragmentGlyphs) {
                gapEnd = fragment.minX + layoutManager.location(forGlyphAt: after).x
            } else {
                gapEnd = layoutManager.lineFragmentUsedRect(forGlyphAt: before, effectiveRange: nil).maxX
            }
            let label = item.hint.label as NSString
            let size = label.size(withAttributes: attributes)
            let baseline = origin.y + fragment.minY + location.y
            let pill = NSRect(x: origin.x + gapEnd - item.width + 3, y: baseline - font.ascender - 2, width: item.width - 6, height: font.ascender - font.descender + 3)
            guard pill.intersects(dirtyRect) else { continue }
            theme.inlineBackground.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 3, yRadius: 3).fill()
            // On the code's baseline.
            label.draw(with: NSRect(x: pill.minX + (pill.width - size.width) / 2, y: baseline - font.ascender, width: size.width, height: size.height), options: [.usesLineFragmentOrigin], attributes: attributes)
        }
    }
}

extension LanguageBinding {
    /// Inlay hints for an LSP range of the current text.
    func inlayHints(range: LSPRange) async throws -> [InlayHint] {
        await flush()
        return try await session.inlayHints(uri: uri, range: range)
    }
}
