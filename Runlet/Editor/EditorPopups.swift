import AppKit
import RunletLanguage

/// A non-activating child panel used for completion lists and info tooltips.
final class PopupPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        hidesOnDeactivate = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        level = .popUpMenu
        collectionBehavior = [.transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Completion list shown under the cursor. Keyboard focus stays in the editor; the editor
/// forwards navigation keys here.
@MainActor
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 220))
    private let tableView = NSTableView()
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var items: [CompletionItem] = []
    var onAccept: ((CompletionItem) -> Void)?
    var onSelectionChange: ((CompletionItem) -> Void)?

    override init() {
        super.init()
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        tableView.setAccessibilityIdentifier("completion-list")

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(scroll)
        effect.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            detailLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),
            detailLabel.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -6),
        ])
        panel.contentView = effect
    }

    var isVisible: Bool { panel.isVisible }

    var selectedItem: CompletionItem? {
        let row = tableView.selectedRow
        return row >= 0 && row < items.count ? items[row] : nil
    }

    func show(items: [CompletionItem], below rect: NSRect, parent: NSWindow?) {
        self.items = items
        tableView.reloadData()
        guard !items.isEmpty else {
            hide()
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.scrollRowToVisible(0)
        updateDetail()
        let visibleRows = min(items.count, 10)
        let height = CGFloat(visibleRows) * tableView.rowHeight + 46
        let widest = items.prefix(60).map { CompletionCellView.attributedText(for: $0, emphasized: false).size().width }.max() ?? 300
        let width = min(680, max(320, ceil(widest) + 44))
        var origin = NSPoint(x: rect.minX - 4, y: rect.minY - height - 2)
        if let screen = parent?.screen ?? NSScreen.main {
            if origin.y < screen.visibleFrame.minY { origin.y = rect.maxY + 2 }
            origin.x = min(origin.x, screen.visibleFrame.maxX - width)
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        if panel.parent == nil, let parent { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let row = max(0, min(items.count - 1, tableView.selectedRow + delta))
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        updateDetail()
    }

    func replaceItem(_ item: CompletionItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        // Refresh only this row and the detail text; never re-announce the selection
        // (that would request details again and make the footer flicker).
        tableView.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
        if index == tableView.selectedRow { renderDetail(item) }
    }

    private func updateDetail() {
        guard let item = selectedItem else { return }
        renderDetail(item)
        onSelectionChange?(item)
    }

    private func renderDetail(_ item: CompletionItem) {
        var parts: [String] = []
        if let detail = item.detail, !detail.isEmpty { parts.append(detail) }
        if let documentation = item.documentation?.trimmingCharacters(in: .whitespacesAndNewlines), !documentation.isEmpty {
            parts.append(documentation.replacingOccurrences(of: "\n", with: " "))
        }
        let text = parts.isEmpty ? item.kindName : parts.joined(separator: " — ")
        if detailLabel.stringValue != text { detailLabel.stringValue = text }
    }

    @objc private func doubleClicked() {
        if let item = selectedItem { onAccept?(item) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("completion-cell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? CompletionCellView) ?? CompletionCellView(identifier: identifier)
        cell.item = items[row]
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetail()
    }

    static func symbol(for item: CompletionItem) -> String {
        switch item.kind {
        case 2, 4: "m"
        case 3: "ƒ"
        case 5, 10: "p"
        case 6: "$"
        case 7, 22: "C"
        case 8: "I"
        case 9: "N"
        case 13, 20: "E"
        case 14: "k"
        case 21: "c"
        default: "·"
        }
    }

    static func color(for item: CompletionItem) -> NSColor {
        switch item.kind {
        case 2, 3, 4: .systemPurple
        case 5, 10: .systemBlue
        case 6: .systemTeal
        case 7, 8, 22: .systemOrange
        case 13, 20, 21: .systemPink
        default: .secondaryLabelColor
        }
    }
}

/// A small floating panel for hover documentation, diagnostics, and signature help.
@MainActor
final class InfoPopup {
    private let panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 60))
    private let label = NSTextField(wrappingLabelWithString: "")

    init(identifier: String) {
        let effect = NSVisualEffectView()
        effect.material = .toolTip
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 6
        effect.layer?.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isSelectable = false
        label.maximumNumberOfLines = 18
        label.setAccessibilityIdentifier(identifier)
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: effect.topAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),
            label.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -6),
        ])
        panel.contentView = effect
    }

    var isVisible: Bool { panel.isVisible }
    var text: String { label.attributedStringValue.string }

    /// Shows `content` above (or below) `rect` in screen coordinates.
    func show(_ content: NSAttributedString, near rect: NSRect, above: Bool, parent: NSWindow?) {
        label.attributedStringValue = content
        let maxWidth: CGFloat = 560
        label.preferredMaxLayoutWidth = maxWidth - 16
        let size = label.sizeThatFits(NSSize(width: maxWidth - 16, height: 600))
        let frameSize = NSSize(width: min(maxWidth, ceil(size.width) + 18), height: min(420, ceil(size.height) + 14))
        var origin = NSPoint(x: rect.minX, y: above ? rect.maxY + 4 : rect.minY - frameSize.height - 4)
        if let screen = parent?.screen ?? NSScreen.main {
            if origin.y + frameSize.height > screen.visibleFrame.maxY { origin.y = rect.minY - frameSize.height - 4 }
            if origin.y < screen.visibleFrame.minY { origin.y = rect.maxY + 4 }
            origin.x = min(origin.x, screen.visibleFrame.maxX - frameSize.width)
        }
        panel.setFrame(NSRect(origin: origin, size: frameSize), display: true)
        if panel.parent == nil, let parent { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Lightweight markdown rendering for LSP hover text: code fences and inline code.
    static func render(markdown: String, fontSize: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize - 1), .foregroundColor: NSColor.labelColor]
        let code: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular), .foregroundColor: NSColor.labelColor]
        var inFence = false
        for (index, line) in markdown.components(separatedBy: "\n").enumerated() {
            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if index > 0 && result.length > 0 { result.append(NSAttributedString(string: "\n", attributes: body)) }
            if inFence {
                result.append(NSAttributedString(string: line, attributes: code))
                continue
            }
            let trimmed = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "---", with: "")
            let parts = trimmed.components(separatedBy: "`")
            for (partIndex, part) in parts.enumerated() {
                result.append(NSAttributedString(string: part, attributes: partIndex % 2 == 1 ? code : body))
            }
        }
        while result.string.hasSuffix("\n") { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        return result
    }
}

/// One completion row: always a single truncated line; white text when selected.
final class CompletionCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    var item: CompletionItem? { didSet { render() } }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { render() }
    }

    private func render() {
        guard let item else { return }
        label.attributedStringValue = Self.attributedText(for: item, emphasized: backgroundStyle == .emphasized)
        toolTip = [item.label, item.detail].compactMap { $0 }.joined(separator: "  ")
    }

    static func attributedText(for item: CompletionItem, emphasized: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let primary: NSColor = emphasized ? .white : .labelColor
        let secondary: NSColor = emphasized ? NSColor.white.withAlphaComponent(0.75) : .secondaryLabelColor
        let text = NSMutableAttributedString(string: CompletionPopup.symbol(for: item) + "  ", attributes: [
            .foregroundColor: emphasized ? NSColor.white : CompletionPopup.color(for: item),
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .paragraphStyle: paragraph,
        ])
        text.append(NSAttributedString(string: item.label, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: primary,
            .strikethroughStyle: item.deprecated ? NSUnderlineStyle.single.rawValue : 0,
            .paragraphStyle: paragraph,
        ]))
        if let detail = item.detail?.replacingOccurrences(of: "\n", with: " "), !detail.isEmpty, detail.count < 80 {
            text.append(NSAttributedString(string: "  " + detail, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: secondary,
                .paragraphStyle: paragraph,
            ]))
        }
        return text
    }
}
