import AppKit
import RunletLanguage

/// A read-only look at a definition outside the tab (#22): vendor code, a file outside the
/// project, Runlet's snippet API, or another tab's code. Highlighted like the editor, scrolled to
/// the definition's line, which is marked. Nothing here can be edited or run.
@MainActor
final class CodePeekController: NSViewController {
    let file: NavigationFile
    private let text: String
    private let theme: EditorTheme
    private let font: NSFont
    private let editorName: String?
    var onOpen: (() -> Void)?
    var onReveal: (() -> Void)?
    private(set) var textView: NSTextView?

    /// Files longer than this show the lines around the definition only.
    static let maxPeekLength = 600_000

    init(file: NavigationFile, text: String, theme: EditorTheme, font: NSFont, editorName: String?) {
        self.file = file
        self.text = text
        self.theme = theme
        self.font = font
        self.editorName = editorName
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 360))
        root.setAccessibilityIdentifier("code-peek")

        let title = NSTextField(labelWithString: "\(file.fileName):\(file.line)")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        title.setAccessibilityIdentifier("code-peek-title")

        var details: [String] = []
        switch file.origin {
        case .vendor: details.append("Vendor code")
        case .project: details.append("Project file")
        case .outsideProject: details.append("Outside the project")
        case .inMemory: details.append(file.displayPath)
        }
        if file.origin != .inMemory {
            let directory = (file.displayPath as NSString).deletingLastPathComponent
            if !directory.isEmpty { details.append(directory) }
        }
        details.append("read-only")
        let subtitle = NSTextField(labelWithString: details.joined(separator: " · "))
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.toolTip = file.path

        var header: [NSView] = [title, subtitle]
        if let runtime = file.runtimePath {
            let where_ = NSTextField(labelWithString: "On \(file.runtimeLocation ?? "the target"): \(runtime)")
            where_.font = .systemFont(ofSize: 11)
            where_.textColor = .secondaryLabelColor
            where_.lineBreakMode = .byTruncatingMiddle
            header.append(where_)
        }
        let labels = NSStackView(views: header)
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var buttons: [NSView] = []
        if file.path != nil {
            if let editorName {
                let open = NSButton(title: "Open in \(editorName)", target: self, action: #selector(openPressed))
                open.controlSize = .small
                open.setAccessibilityIdentifier("code-peek-open")
                buttons.append(open)
            }
            let reveal = NSButton(title: "Reveal in Finder", target: self, action: #selector(revealPressed))
            reveal.controlSize = .small
            buttons.append(reveal)
        }
        let buttonStack = NSStackView(views: buttons)
        buttonStack.spacing = 6
        buttonStack.setContentHuggingPriority(.required, for: .horizontal)

        let top = NSStackView(views: [labels, buttonStack])
        top.orientation = .horizontal
        top.alignment = .top
        top.distribution = .fill
        top.spacing = 12

        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = theme.background
        if let textView = scroll.documentView as? NSTextView {
            configure(textView)
            self.textView = textView
        }
        let separator = NSBox()
        separator.boxType = .separator

        for view in [top, separator, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            separator.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    /// The text shown, and the line it starts at in the file (0-based).
    private var excerpt: (text: String, firstLine: Int) {
        guard (text as NSString).length > Self.maxPeekLength else { return (text, 0) }
        let lines = text.components(separatedBy: "\n")
        let first = max(0, file.range.start.line - 400)
        let last = min(lines.count, file.range.start.line + 400)
        return (lines[first..<last].joined(separator: "\n"), first)
    }

    private func configure(_ textView: NSTextView) {
        let (shown, firstLine) = excerpt
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.backgroundColor = theme.background
        textView.insertionPointColor = theme.text
        textView.setAccessibilityIdentifier("code-peek-text")
        let paragraph = NSMutableParagraphStyle()
        paragraph.defaultTabInterval = ("m" as NSString).size(withAttributes: [.font: font]).width * 4
        paragraph.tabStops = []
        let storage = NSTextStorage(string: shown, attributes: [.font: font, .foregroundColor: theme.text, .paragraphStyle: paragraph])
        let string = shown as NSString
        for token in PHPHighlighter.tokenize(string) where NSMaxRange(token.range) <= string.length {
            storage.addAttribute(.foregroundColor, value: theme.color(for: token.kind), range: token.range)
        }
        // The definition's line.
        let line = file.range.start.line - firstLine
        let index = TextLineIndex(shown)
        let start = index.offset(of: LSPPosition(line: line, character: 0))
        let lineRange = string.lineRange(for: NSRange(location: min(start, string.length), length: 0))
        storage.addAttribute(.backgroundColor, value: theme.bracketMatch, range: lineRange)
        textView.layoutManager?.replaceTextStorage(storage)
        let target = index.offset(of: LSPPosition(line: line, character: file.range.start.character))
        textView.setSelectedRange(NSRange(location: min(target, string.length), length: 0))
        targetRange = lineRange
    }

    private var targetRange = NSRange(location: 0, length: 0)

    override func viewDidAppear() {
        super.viewDidAppear()
        scrollToTarget()
    }

    /// Puts the definition's line about a third of the way down.
    func scrollToTarget() {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer, let clip = textView.enclosingScrollView?.contentView else { return }
        layoutManager.ensureLayout(for: container)
        let glyphs = layoutManager.glyphRange(forCharacterRange: targetRange, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        let y = max(0, rect.minY + textView.textContainerOrigin.y - clip.bounds.height / 3)
        clip.scroll(to: NSPoint(x: 0, y: y))
        textView.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    @objc private func openPressed() { onOpen?() }
    @objc private func revealPressed() { onReveal?() }
}

/// Find References, several definitions, or code actions (#22) in a popover list. Return or a
/// click chooses a row; Escape closes.
@MainActor
final class NavigationListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let content: EditorNavigation.ListContent
    private let theme: EditorTheme
    private let fontSize: CGFloat
    var onChooseReference: ((ReferenceItem) -> Void)?
    var onChooseAction: ((CodeActionRow) -> Void)?
    private let table = KeyTableView()

    init(content: EditorNavigation.ListContent, theme: EditorTheme, fontSize: CGFloat) {
        self.content = content
        self.theme = theme
        self.fontSize = fontSize
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var count: Int {
        switch content {
        case .references(let rows, _, _), .definitions(let rows, _): rows.count
        case .actions(let rows): rows.count
        }
    }

    private var isActions: Bool {
        if case .actions = content { return true }
        return false
    }

    private var titleText: String {
        switch content {
        case .references(let rows, let word, let truncated):
            let noun = rows.count == 1 ? "reference" : "references"
            let count = truncated ? "First \(rows.count)" : "\(rows.count)"
            return word.map { "\(count) \(noun) to \($0)" } ?? "\(count) \(noun)"
        case .definitions(let rows, let word):
            return word.map { "\(rows.count) definitions of \($0)" } ?? "\(rows.count) definitions"
        case .actions:
            return "Code Actions"
        }
    }

    private var rowHeight: CGFloat { isActions ? 24 : 40 }

    override func loadView() {
        let width: CGFloat = isActions ? 420 : 560
        let visibleRows = min(count, isActions ? 10 : 9)
        let height = CGFloat(visibleRows) * rowHeight + 38
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.setAccessibilityIdentifier(isActions ? "code-actions" : "references")

        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail

        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
        table.headerView = nil
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.onReturn = { [weak self] in self?.chooseSelected() }
        table.setAccessibilityIdentifier(isActions ? "code-actions-list" : "references-list")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        for view in [title, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
        ])
        view = root
        table.reloadData()
        if count > 0 { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(table)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = isActions ? 1 : 2
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        switch content {
        case .references(let rows, _, _), .definitions(let rows, _):
            label.attributedStringValue = attributed(rows[row])
            label.toolTip = "\(rows[row].label):\(rows[row].line)"
        case .actions(let rows):
            label.attributedStringValue = attributed(rows[row])
            label.toolTip = rows[row].unavailableReason
        }
        return cell
    }

    private func attributed(_ item: ReferenceItem) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let name = item.isInTab ? item.label : (item.label as NSString).lastPathComponent
        result.append(NSAttributedString(string: "\(name):\(item.line)", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        if !item.isInTab {
            let directory = (item.label as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                result.append(NSAttributedString(string: "  " + directory, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            }
        }
        result.append(NSAttributedString(string: "\n"))
        let code = NSFont.monospacedSystemFont(ofSize: max(10, fontSize - 2), weight: .regular)
        let snippet = NSMutableAttributedString(string: item.snippet.isEmpty ? " " : item.snippet, attributes: [.font: code, .foregroundColor: NSColor.secondaryLabelColor])
        if let highlight = item.highlight, highlight.upperBound <= snippet.length {
            snippet.addAttributes([.foregroundColor: NSColor.labelColor, .font: NSFont.monospacedSystemFont(ofSize: max(10, fontSize - 2), weight: .bold)],
                                  range: NSRange(location: highlight.lowerBound, length: highlight.count))
        }
        result.append(snippet)
        return result
    }

    private func attributed(_ row: CodeActionRow) -> NSAttributedString {
        let enabled = row.unavailableReason == nil
        let result = NSMutableAttributedString(string: row.action.title.replacingOccurrences(of: "`", with: ""),
                                               attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: enabled ? NSColor.labelColor : NSColor.tertiaryLabelColor])
        let kind: String? = switch row.action.kind {
        case let kind? where kind.hasPrefix("quickfix"): "Quick fix"
        case let kind? where kind.hasPrefix("refactor"): "Refactor"
        case let kind? where kind.hasPrefix("source"): "Source"
        default: nil
        }
        if let kind {
            result.append(NSAttributedString(string: "  " + kind, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return result
    }

    @objc private func clicked() {
        guard table.clickedRow >= 0 else { return }
        choose(table.clickedRow)
    }

    private func chooseSelected() {
        guard table.selectedRow >= 0 else { return }
        choose(table.selectedRow)
    }

    private func choose(_ row: Int) {
        switch content {
        case .references(let rows, _, _), .definitions(let rows, _): onChooseReference?(rows[row])
        case .actions(let rows): onChooseAction?(rows[row])
        }
    }

    /// The rows' text, for checks.
    var rowTexts: [String] {
        (0..<count).map { row in
            switch content {
            case .references(let rows, _, _), .definitions(let rows, _): "\(rows[row].label):\(rows[row].line) \(rows[row].snippet)"
            case .actions(let rows): rows[row].action.title + (rows[row].unavailableReason.map { " [\($0)]" } ?? "")
            }
        }
    }
}

/// A table that chooses its selected row on Return.
final class KeyTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }
}
