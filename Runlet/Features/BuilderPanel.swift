import SwiftUI

/// What a builder last read or wrote, under its header (#217, #218).
struct BuilderNote: Equatable {
    var text: String
    var isWarning = false
}

/// The builders' panel beside a database tab's editor: Redis's Command Builder (#218) and
/// MongoDB's Query Builder (#217). Between the editor and the output; its leading edge
/// resizes it. A header, the last note, the form, then the builder's preview area.
struct BuilderPanel<Header: View, Content: View>: View {
    /// The panel's accessibility identifier; the edge is `<identifier>-resize`, the note `<identifier>-note`.
    var identifier: String
    var width: Double
    var range: ClosedRange<Double>
    var note: BuilderNote?
    var commitWidth: (Double) -> Void
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content
    @State private var liveWidth: Double?

    var body: some View {
        HStack(spacing: 0) {
            SidebarResizeHandle(width: $liveWidth, committed: width, range: range, edge: .trailing, identifier: identifier + "-resize", onCommit: commitWidth)
            VStack(spacing: 0) {
                header()
                if let note {
                    Label(note.text, systemImage: note.isWarning ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(note.isWarning ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                        .accessibilityIdentifier(identifier + "-note")
                }
                Divider()
                content()
            }
            .frame(width: liveWidth ?? width)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// A builder's header: its icon and name, then its buttons (borderless).
struct BuilderHeader<Buttons: View>: View {
    var systemImage: String
    var color: Color
    var title: String
    @ViewBuilder var buttons: () -> Buttons

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(color)
            Text(title).fontWeight(.semibold)
            Spacer(minLength: 4)
            buttons()
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

/// The text a builder writes, in its preview area: monospaced and selectable, in a box whose
/// border says how Runlet treats it (orange: writes; red: dangerous or destructive).
struct BuilderPreviewBox: View {
    enum Emphasis { case read, write, danger }
    var text: String
    var emphasis: Emphasis
    var identifier: String

    var body: some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(emphasis == .danger ? Color.red.opacity(0.6) : emphasis == .read ? Color.clear : Color.orange.opacity(0.45)))
            .accessibilityIdentifier(identifier)
    }
}

/// A small capsule for how Runlet treats what a builder writes: WRITE, DANGEROUS, READ, ….
struct BuilderBadge: View {
    var text: String
    var color: Color
    var help: String

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.14)))
            .help(help)
            .accessibilityLabel(text.lowercased())
    }
}

extension AppModel {
    /// Show Builder (⌥⌘B, View ▸ Show Builder): the builder of the current tab's language,
    /// Redis's Command Builder (#218) or MongoDB's Query Builder (#217).
    func hasBuilder(_ tab: TabModel) -> Bool {
        tab.language == .redis || tab.language == .mongodb
    }

    func isBuilderOpen(_ tab: TabModel) -> Bool {
        switch tab.language {
        case .redis: redisBuilder(for: tab).isOpen
        case .mongodb: mongoBuilder(for: tab).isOpen
        default: false
        }
    }

    func toggleBuilder(_ tab: TabModel) {
        switch tab.language {
        case .redis: toggleRedisBuilder(tab)
        case .mongodb: toggleMongoBuilder(tab)
        default: break
        }
    }
}
