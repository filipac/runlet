import AppKit
import RunletCore
import SwiftUI

/// What the gutter marks on a line with magic comments.
enum InlineMarker: Equatable {
    /// The line ran (`hits` times).
    case hit(Int)
    /// A magic comment on the line shows nothing (the reason is in the inline text).
    case warning
}

/// Magic comments' values in one editor (#10): dim text after each line with the latest
/// value (`×N` when the line ran more than once), a gutter marker, and a hover panel with the
/// value tree and the list of hits.
///
/// Values only ever come from a run; they never start one. The next run clears them. A line
/// edited since the run loses its values, and lines above or below an edit keep theirs
/// (`InlineLineTracker`). Drawing touches only the lines with values that are on screen, and
/// an edit costs work per line with values, not per document.
@MainActor
final class InlineValueOverlay {
    private(set) var values = InlineValues()
    private var tracker = InlineLineTracker()
    private unowned let textView: CodeTextView
    private var redrawScheduled = false
    /// Where each line's values were last drawn (text view coordinates), for hover.
    private var drawnRects: [Int: NSRect] = [:]
    private let panel = InlineValuePanel()
    /// The line whose panel is showing.
    private(set) var panelLine: Int?
    var theme = EditorTheme.resolve(dark: false)
    /// Off (Settings): nothing is followed, drawn, or shown, also for a run already going.
    var isEnabled = true {
        didSet { if !isEnabled { clear() } }
    }
    /// Called when the gutter markers change.
    var onMarkersChange: (([Int: InlineMarker]) -> Void)?
    /// Called with the width the text view needs so the visible values fit (nil: none), for
    /// an editor without soft wrap, whose text view is only as wide as its text.
    var onWidthNeeded: ((CGFloat?) -> Void)?
    /// Characters folded away (#22, `EditorFolding`): their lines' values aren't drawn.
    var isHidden: ((Int) -> Bool)?
    private var requestedWidth: CGFloat?

    init(textView: CodeTextView) {
        self.textView = textView
    }

    var isEmpty: Bool { values.isEmpty }

    /// A run of `code` (the whole tab, or a selection starting at `selection`) is starting:
    /// forget earlier values and follow the lines that may show new ones.
    func begin(code: String, selection: SourceSelection?, editorText: String) {
        clear()
        guard isEnabled else { return }
        tracker = InlineLineTracker.forRun(code: code, selection: selection, editorText: editorText as NSString)
    }

    func apply(_ event: InlineEvent, editorLine: (Int) -> Int) {
        guard isEnabled else { return }
        values.apply(event, editorLine: editorLine)
        scheduleRedraw()
    }

    func clear() {
        let hadValues = !values.isEmpty
        values = InlineValues()
        tracker = InlineLineTracker()
        drawnRects = [:]
        hidePanel()
        if requestedWidth != nil {
            requestedWidth = nil
            onWidthNeeded?(nil)
        }
        if hadValues { scheduleRedraw() }
    }

    /// Follows an edit; values on edited lines are dropped.
    func textDidChange(range: NSRange, replacementLength: Int, newText: NSString) {
        guard !tracker.isEmpty else { return }
        for line in tracker.edit(range: range, replacementLength: replacementLength, newText: newText) {
            values.removeLine(line)
        }
        hidePanel()
        scheduleRedraw()
    }

    /// Where an original line is now, when it still shows its values.
    func currentRange(ofLine line: Int) -> NSRange? {
        tracker.range(ofLine: line)
    }

    /// The original line whose values are drawn at the editor line holding `characterIndex`.
    func line(containing characterIndex: Int) -> Int? {
        values.lines.first { line in
            guard let range = tracker.range(ofLine: line) else { return false }
            return characterIndex >= range.location && characterIndex <= NSMaxRange(range)
        }
    }

    var markers: [Int: InlineMarker] {
        var markers: [Int: InlineMarker] = [:]
        for line in values.lines {
            guard let range = tracker.range(ofLine: line) else { continue }
            let hits = values.hits(onLine: line)
            if hits > 0 {
                markers[range.location] = .hit(hits)
            } else if !values.rejections(onLine: line).isEmpty {
                markers[range.location] = .warning
            }
        }
        return markers
    }

    private func scheduleRedraw() {
        guard !redrawScheduled else { return }
        redrawScheduled = true
        // Hits can stream in fast: draw at most about 20 times a second.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.redrawScheduled = false
            self.textView.setNeedsDisplay(self.textView.visibleRect)
            self.onMarkersChange?(self.markers)
            if let line = self.panelLine { self.refreshPanel(line) }
        }
    }

    // MARK: Drawing

    /// Draws each visible line's values after its text.
    func draw(in dirtyRect: NSRect) {
        guard !values.isEmpty, let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            drawnRects = [:]
            return
        }
        let text = textView.string as NSString
        let origin = textView.textContainerOrigin
        let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let visible = textView.visibleRect
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let visibleCharacters = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        var rects: [Int: NSRect] = [:]
        var needed: CGFloat = 0
        for line in values.lines {
            guard let range = tracker.range(ofLine: line), range.length > 0, NSMaxRange(range) <= text.length,
                  NSIntersectionRange(range, visibleCharacters).length > 0 || NSLocationInRange(range.location, visibleCharacters),
                  let summary = values.summary(onLine: line) else { continue }
            // A folded line (#22) has nowhere to show its values.
            guard isHidden?(range.location) != true else { continue }
            let lastGlyph = layoutManager.glyphIndexForCharacter(at: NSMaxRange(range) - 1)
            guard lastGlyph < layoutManager.numberOfGlyphs else { continue }
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            let used = layoutManager.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            let baseline = fragment.minY + origin.y + layoutManager.location(forGlyphAt: lastGlyph).y
            let x = used.maxX + origin.x + font.pointSize * 1.2
            let string = attributed(summary, font: font)
            needed = max(needed, x + min(ceil(string.size().width), 900) + 16)
            let available = max(textView.bounds.maxX, visible.maxX) - x - 6
            guard available > font.pointSize * 3 else { continue }
            let width = min(ceil(string.size().width), available)
            let pill = NSRect(x: x - 5, y: fragment.minY + origin.y + 1, width: width + 10, height: fragment.height - 2)
            rects[line] = pill
            guard pill.intersects(dirtyRect) else { continue }
            theme.inlineBackground.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
            string.draw(with: NSRect(x: x, y: baseline - font.ascender, width: width, height: font.ascender - font.descender + 2),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        drawnRects = rects
        // Values past the right edge: ask for a wider text view (never while drawing).
        if needed > textView.bounds.maxX + 0.5, needed > (requestedWidth ?? 0) {
            requestedWidth = needed
            DispatchQueue.main.async { [weak self] in self?.onWidthNeeded?(needed) }
        }
    }

    /// Highlights magic comments behind the text (`ranges` from the highlighter).
    func drawCommentHighlights(_ ranges: [NSRange], in rect: NSRect) {
        guard !ranges.isEmpty, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let origin = textView.textContainerOrigin
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let length = (textView.string as NSString).length
        theme.magicCommentBackground.setFill()
        for range in ranges where NSMaxRange(range) <= length && NSIntersectionRange(range, characters).length > 0 {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphRange, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { box, _ in
                let pill = box.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: 1)
                NSBezierPath(roundedRect: pill, xRadius: 3, yRadius: 3).fill()
            }
        }
    }

    private func attributed(_ summary: InlineSummary, font: NSFont) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.inlineText, .paragraphStyle: paragraph]
        let count: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .semibold), .foregroundColor: theme.magicComment, .paragraphStyle: paragraph,
        ]
        let result = NSMutableAttributedString()
        for (index, part) in summary.parts.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "  ·  ", attributes: base)) }
            if let hits = part.count { result.append(NSAttributedString(string: "×\(hits) ", attributes: count)) }
            var attributes = base
            switch part.style {
            case .value: break
            case .error: attributes[.foregroundColor] = NSColor.systemRed.withAlphaComponent(0.85)
            case .warning: attributes[.foregroundColor] = theme.inlineWarning
            }
            result.append(NSAttributedString(string: part.text, attributes: attributes))
        }
        return result
    }

    // MARK: Hover panel

    /// The original line whose drawn values contain `point` (text view coordinates).
    func line(at point: NSPoint) -> Int? {
        drawnRects.first { $0.value.insetBy(dx: -2, dy: -1).contains(point) }?.key
    }

    func panelContainsMouse() -> Bool {
        panel.isVisible && panel.frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation)
    }

    /// Shows the value tree and hits of an original line under its values (or under the
    /// line's end when they are not drawn).
    func showPanel(forLine line: Int) {
        guard let anchor = anchorRect(forLine: line), let window = textView.window else { return }
        panelLine = line
        panel.show(details(forLine: line), below: window.convertToScreen(textView.convert(anchor, to: nil)), theme: theme, parent: window)
    }

    func hidePanel() {
        panelLine = nil
        panel.hide()
    }

    private func refreshPanel(_ line: Int) {
        guard panel.isVisible, tracker.range(ofLine: line) != nil else { return hidePanel() }
        panel.update(details(forLine: line))
    }

    private func details(forLine line: Int) -> InlineValueDetails {
        let current = tracker.range(ofLine: line).map { (textView.string as NSString).substring(to: $0.location).components(separatedBy: "\n").count } ?? line
        return InlineValueDetails(line: current, probes: values.probes(onLine: line), rejections: values.rejections(onLine: line))
    }

    private func anchorRect(forLine line: Int) -> NSRect? {
        if var rect = drawnRects[line] {
            // Values past the visible edge: anchor the panel inside the editor.
            rect.origin.x = max(textView.visibleRect.minX, min(rect.minX, textView.visibleRect.maxX - 120))
            return rect
        }
        guard let range = tracker.range(ofLine: line), range.length > 0, let layoutManager = textView.layoutManager else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: NSMaxRange(range) - 1)
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let origin = textView.textContainerOrigin
        let x = min(used.maxX + origin.x, textView.visibleRect.maxX - 60)
        return NSRect(x: max(textView.visibleRect.minX, x), y: used.minY + origin.y, width: 1, height: used.height)
    }
}

/// The hover panel: a non-activating child window, like the other editor popups, so the
/// keyboard stays in the editor.
@MainActor
final class InlineValuePanel {
    private let panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200))
    private let effect = NSVisualEffectView()
    private var hosting: NSHostingView<InlineValueDetailsView>?
    private var anchor = NSRect.zero

    init() {
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 9
        effect.layer?.masksToBounds = true
        panel.contentView = effect
        panel.setAccessibilityIdentifier("inline-value-panel")
    }

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    func show(_ details: InlineValueDetails, below anchor: NSRect, theme: EditorTheme, parent: NSWindow) {
        self.anchor = anchor
        panel.appearance = parent.effectiveAppearance
        install(details)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func update(_ details: InlineValueDetails) {
        install(details)
    }

    func hide() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func install(_ details: InlineValueDetails) {
        let view = InlineValueDetailsView(details: details)
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.topAnchor.constraint(equalTo: effect.topAnchor),
                hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            self.hosting = hosting
        }
        let size = hosting?.fittingSize ?? NSSize(width: 480, height: 200)
        let frameSize = NSSize(width: InlineValueDetailsView.width, height: min(520, max(60, ceil(size.height))))
        var origin = NSPoint(x: anchor.minX - 6, y: anchor.minY - frameSize.height - 4)
        if let screen = panel.parent?.screen ?? NSScreen.main {
            if origin.y < screen.visibleFrame.minY { origin.y = anchor.maxY + 4 }
            origin.x = max(screen.visibleFrame.minX, min(origin.x, screen.visibleFrame.maxX - frameSize.width))
        }
        panel.setFrame(NSRect(origin: origin, size: frameSize), display: true)
    }
}

/// What the hover panel shows for one line.
struct InlineValueDetails {
    /// The editor line now.
    var line: Int
    var probes: [InlineValues.Probe]
    var rejections: [InlineValues.Rejection]
}

/// The panel's content: per magic comment on the line, the selected hit's value tree (the
/// latest by default), the error or time, and the list of hits to pick from.
struct InlineValueDetailsView: View {
    static let width: CGFloat = 500
    let details: InlineValueDetails
    @State private var selected: [Int: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(details.probes) { probe in
                probeSection(probe)
            }
            ForEach(Array(details.rejections.enumerated()), id: \.offset) { _, rejection in
                VStack(alignment: .leading, spacing: 3) {
                    header(rejection.comment, detail: "Line \(details.line) · not shown")
                    Text(rejection.reason).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(width: Self.width, alignment: .leading)
    }

    private func header(_ comment: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Text(comment.isEmpty ? "//?" : comment)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundStyle(Color(nsColor: .systemOrange))
            Text(detail).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func probeSection(_ probe: InlineValues.Probe) -> some View {
        let shown = probe.recent.first { $0.number == selected[probe.id] } ?? probe.last
        VStack(alignment: .leading, spacing: 6) {
            header(probe.comment, detail: Self.hitsText(probe, line: details.line))
            if let shown {
                hitBody(probe, shown)
            } else if probe.hits == 0 {
                Text("Not reached in this run.").font(.callout).foregroundStyle(.secondary)
            }
            if probe.recent.count > 1 {
                hitList(probe, selected: shown?.number)
            }
        }
    }

    @ViewBuilder
    private func hitBody(_ probe: InlineValues.Probe, _ hit: InlineValues.Hit) -> some View {
        if let error = hit.error {
            Text("\(error.className): \(error.message)")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if let ms = hit.ms {
            // The first mark of a run counts from the start: its time equals its offset.
            Text("\(InlineValues.duration(ms)) since \(abs((hit.t ?? -1) - ms) < 0.05 ? "the snippet started" : "the previous /*?.*/")")
                .font(.callout)
        } else if let value = hit.value {
            ScrollView([.vertical, .horizontal]) {
                ValueTreeView(node: value, expansion: .firstLevel)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: Self.treeHeight(value))
        } else if probe.kind == .reached {
            Text(hit.t.map { "Reached \(InlineValues.duration($0)) after the snippet started." } ?? "Reached.").font(.callout)
        } else {
            Text("Runlet stopped sending values after 16 MB in this run.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func hitList(_ probe: InlineValues.Probe, selected: Int?) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(probe.recent.reversed()) { hit in
                    Button {
                        self.selected[probe.id] = hit.number
                    } label: {
                        HStack(spacing: 10) {
                            Text("#\(hit.number)").foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                            Text(hit.t.map { "+" + InlineValues.duration($0) } ?? "").foregroundStyle(.secondary).frame(width: 78, alignment: .trailing)
                            Text(Self.hitSummary(hit)).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                        .background(hit.number == selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(height: min(132, CGFloat(probe.recent.count) * 19 + 4))
    }

    static func hitsText(_ probe: InlineValues.Probe, line: Int) -> String {
        var text = "Line \(line)"
        switch probe.hits {
        case 0: return text
        case 1: text += " · ran once"
        default: text += " · ran \(probe.hits.formatted()) times"
        }
        if probe.hits > InlineValues.maxRecent { text += " · values for the first \(InlineValues.maxRecent), then sampled" }
        return text
    }

    static func hitSummary(_ hit: InlineValues.Hit) -> String {
        if let error = hit.error { return "⚠︎ " + error.message }
        if let ms = hit.ms { return InlineValues.duration(ms) }
        if let value = hit.value { return value.compactSummary(budget: 60) }
        return hit.sampled ? "(sampled)" : "✓"
    }

    static func treeHeight(_ value: ValueNode) -> CGFloat {
        let rows = 1 + (value.entries?.count ?? 0)
        return min(240, CGFloat(rows) * 19 + 8)
    }
}
