import AppKit
import RunletCore
import SwiftUI

/// Show Definition's sheet (#148) on the window that asked: a spinner while the catalog is
/// read, then the definition read-only (selectable, in the editor's font and SQL colours), or
/// the reason there is none. Copy, Open in SQL Tab, and Done; nothing in it runs.
struct SchemaDefinitionSheetModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let windowId: UUID

    func body(content: Content) -> some View {
        content.sheet(item: presented) { sheet in
            SchemaDefinitionSheetView(sheet: sheet)
        }
    }

    private var presented: Binding<SchemaDefinitionSheet?> {
        Binding(
            get: {
                guard let sheet = model.schemaExplorer.definitionSheet, sheet.windowId == nil || sheet.windowId == windowId else { return nil }
                return sheet
            },
            set: { value in
                if value == nil, let sheet = model.schemaExplorer.definitionSheet, sheet.windowId == nil || sheet.windowId == windowId {
                    model.closeSchemaDefinition()
                }
            }
        )
    }
}

struct SchemaDefinitionSheetView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let sheet: SchemaDefinitionSheet
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            buttons
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 720, idealWidth: 880, maxWidth: .infinity, minHeight: 480, idealHeight: 620, maxHeight: .infinity)
        .background(ResizableSheet(minSize: NSSize(width: 720, height: 480), initialSize: NSSize(width: 880, height: 620)))
        .onExitCommand { model.closeSchemaDefinition() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("schema-definition-sheet")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: sheet.isView ? "eye" : "tablecells")
                .font(.title2)
                .foregroundStyle(sheet.isView ? .purple : .teal)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(sheet.title)
                    .font(.headline)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("schema-definition-title")
                Text(sheet.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if case .loaded(let info, _) = sheet.state {
                Text(info.reconstructed == true ? "Reconstructed from \(info.how ?? "the catalog")" : "Read with \(info.how ?? "the catalog")")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(info.reconstructed == true ? Color.orange : Color.secondary)
                    .background(Capsule().fill((info.reconstructed == true ? Color.orange : Color.secondary).opacity(0.12)))
                    .help(info.reconstructed == true ? "PostgreSQL has no SHOW CREATE TABLE: Runlet rebuilt this from the catalog. The header says what is left out." : "The database's own text.")
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch sheet.state {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading the definition of \(sheet.table)…")
                    .foregroundStyle(.secondary)
                Text("Only the catalog is read. Nothing runs.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .accessibilityIdentifier("schema-definition-loading")
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Runlet could not show this definition")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 560)
                    .accessibilityIdentifier("schema-definition-error")
            }
            .padding(24)
        case .loaded(_, let text):
            DefinitionTextView(text: text, preferences: EditorPreferences(settings: model.settings, dark: colorScheme == .dark))
                .accessibilityIdentifier("schema-definition-text")
        }
    }

    private var buttons: some View {
        HStack {
            Button(copied ? "Copied" : "Copy") {
                model.copySchemaDefinition()
                copied = true
            }
            .disabled(sheet.text == nil)
            .help("Copy the whole definition, with its header")
            .accessibilityIdentifier("schema-definition-copy")
            Button("Open in SQL Tab") { model.openSchemaDefinitionInTab() }
                .disabled(sheet.text == nil)
                .help("Open the definition in a new SQL tab on the same target and connection. It doesn't run.")
                .accessibilityIdentifier("schema-definition-open")
            Spacer()
            Text("Not run")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Done") { model.closeSchemaDefinition() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("schema-definition-done")
        }
    }
}

/// Makes the sheet's window resizable from `minSize` up, starting at `initialSize` (or the
/// parent window's size less a margin, when that is smaller). SwiftUI sizes a sheet to its
/// content and doesn't let it be resized, and it resets the window's minimum as it lays out,
/// so the minimum is applied again after every resize.
private struct ResizableSheet: NSViewRepresentable {
    let minSize: NSSize
    let initialSize: NSSize

    func makeNSView(context: Context) -> NSView { Probe(minSize: minSize, initialSize: initialSize) }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        let minSize: NSSize
        let initialSize: NSSize
        private var configured = false

        init(minSize: NSSize, initialSize: NSSize) {
            self.minSize = minSize
            self.initialSize = initialSize
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func didResize(_ notification: Notification) {
            guard let window else { return }
            applyMinimum(window)
            let content = window.contentRect(forFrameRect: window.frame).size
            if content.width < minSize.width || content.height < minSize.height {
                window.setContentSize(NSSize(width: max(content.width, minSize.width), height: max(content.height, minSize.height)))
            }
        }

        private func applyMinimum(_ window: NSWindow) {
            window.contentMinSize = minSize
            window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: minSize)).size
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !configured else { return }
            configured = true
            window?.styleMask.insert(.resizable)
            NotificationCenter.default.addObserver(self, selector: #selector(didResize(_:)), name: NSWindow.didResizeNotification, object: window)
            // After SwiftUI has sized the sheet to its content.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.applyMinimum(window)
                let parent = window.sheetParent?.frame.size ?? self.initialSize
                let size = NSSize(width: max(self.minSize.width, min(self.initialSize.width, parent.width - 80)),
                                  height: max(self.minSize.height, min(self.initialSize.height, parent.height - 80)))
                window.setContentSize(size)
            }
        }
    }
}

/// The definition read-only and selectable, in the editor's font, line height, and SQL colours
/// (`SQLHighlighter`, `EditorTheme`), scrolling both ways without wrapping, like the editor.
private struct DefinitionTextView: NSViewRepresentable {
    let text: String
    let preferences: EditorPreferences

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityIdentifier("schema-definition-textview")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        let theme = EditorTheme.resolve(dark: preferences.dark)
        let rendered = Self.render(text, preferences: preferences, theme: theme)
        if textView.textStorage?.isEqual(to: rendered) != true {
            textView.textStorage?.setAttributedString(rendered)
        }
        textView.backgroundColor = theme.background
        scroll.backgroundColor = theme.background
    }

    static func render(_ text: String, preferences: EditorPreferences, theme: EditorTheme) -> NSAttributedString {
        let font = EditorFonts.font(family: preferences.fontName, size: preferences.fontSize, ligatures: preferences.ligatures)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = preferences.lineHeight
        paragraph.lineBreakMode = .byClipping
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .paragraphStyle: paragraph,
            .foregroundColor: theme.text,
            .ligature: preferences.ligatures ? 1 : 0,
        ])
        for token in SQLHighlighter.tokenize(text as NSString) where NSMaxRange(token.range) <= result.length {
            result.addAttribute(.foregroundColor, value: theme.color(for: token.kind), range: token.range)
        }
        return result
    }
}
