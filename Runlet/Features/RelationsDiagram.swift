import AppKit
import RunletCore
import SwiftUI
import UniformTypeIdentifiers

/// The relations diagram window (#153): a table of the explorer's schema in the middle, the tables
/// it references on the left, the tables that reference it on the right, one or two hops out, with
/// a line per foreign key labelled with its column pairs. Built only from the schema already
/// loaded; nothing in it reads or runs anything. Clicking a table centres on it (Back and
/// Forward go through them); a line's Copy Join or Insert Join prepares its `JOIN … ON …`.
struct RelationsWindowView: View {
    let id: UUID?

    var body: some View {
        if let id, let document = RelationsWindows.documents[id] {
            RelationsBrowser(document: document)
                .navigationTitle(document.title)
                .navigationSubtitle(document.subtitle)
                .onDisappear { RelationsWindows.documents[id] = nil }
        } else {
            ContentUnavailableView("Diagram Closed", systemImage: "point.3.connected.trianglepath.dotted",
                                   description: Text("This diagram is no longer available. Choose Show Relations on a table in the Database pane."))
                .frame(minWidth: 420, minHeight: 240)
        }
    }
}

/// The toolbar, the canvas (or why there is none), and the footer.
private struct RelationsBrowser: View {
    @Environment(AppModel.self) private var model
    @Bindable var document: RelationsDocument

    var body: some View {
        let loaded = model.relationsSchema(document)
        let layout = loaded.flatMap { document.layout(for: $0.schema, token: $0.token) }
        VStack(spacing: 0) {
            RelationsToolbar(document: document, layout: layout)
            Divider()
            if let layout {
                RelationsScrollView(document: document, layout: layout)
                Divider()
                RelationsFooter(document: document, layout: layout)
            } else if loaded != nil {
                ContentUnavailableView {
                    Label("No Table \(document.focus)", systemImage: "questionmark.square.dashed")
                } description: {
                    Text("The loaded schema has no table named \(document.focus). Reload the schema in the Database pane, or go back.")
                } actions: {
                    if document.canGoBack { Button("Back") { document.back() } }
                }
            } else {
                RelationsSchemaPlaceholder(document: document)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("relations-window")
    }
}

/// Back/Forward, the focus, hops, all columns, zoom, and export.
private struct RelationsToolbar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var document: RelationsDocument
    let layout: SQLRelationsLayout?

    var body: some View {
        HStack(spacing: 10) {
            ControlGroup {
                Button { document.back() } label: { Image(systemName: "chevron.left") }
                    .disabled(!document.canGoBack)
                    .help("Back: the table the diagram was centred on before")
                    .accessibilityIdentifier("relations-back")
                Button { document.forward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!document.canGoForward)
                    .help("Forward")
                    .accessibilityIdentifier("relations-forward")
            }
            .fixedSize()
            Label {
                Text(document.focus).font(.system(.callout, design: .monospaced).weight(.semibold)).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.teal)
            }
            Spacer(minLength: 8)
            Picker("Hops", selection: $document.hops) {
                Text("1 Hop").tag(1)
                Text("2 Hops").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Tables one hop away (they reference the table, or it references them), or two")
            .accessibilityIdentifier("relations-hops")
            Toggle("All Columns", isOn: $document.allColumns)
                .toggleStyle(.checkbox)
                .help("Show every column, not only primary, foreign, and referenced keys")
                .accessibilityIdentifier("relations-all-columns")
            ControlGroup {
                Button { zoom(by: 1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom Out")
                Button { document.zoom = 1; document.scrollRequest += 1 } label: { Text("\(Int((document.zoom * 100).rounded()))%").monospacedDigit().frame(minWidth: 38) }
                    .help("Actual Size")
                Button { zoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom In")
                Button { document.fitRequest += 1 } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .help("Zoom to Fit: the whole diagram in the window")
                    .accessibilityIdentifier("relations-fit")
            }
            .fixedSize()
            Menu {
                Button("Export as PNG…") { export(.png) }
                Button("Export as SVG…") { export(.svg) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
            .disabled(layout == nil)
            .help("Save the diagram as a PNG image or an SVG drawing")
            .accessibilityIdentifier("relations-export")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func zoom(by factor: CGFloat) {
        document.zoom = min(max(document.zoom * factor, 0.3), 2.5)
        document.scrollRequest += 1
    }

    private func export(_ format: RelationsExport.Format) {
        guard let layout else { return }
        RelationsExport.save(layout, format: format, colorScheme: colorScheme, to: nil)
    }
}

/// The schema isn't loaded (never read, or forgotten): Load Schema, as the explorer offers it.
private struct RelationsSchemaPlaceholder: View {
    @Environment(AppModel.self) private var model
    let document: RelationsDocument

    var body: some View {
        let tab = model.relationsTab(document)
        VStack(spacing: 10) {
            Spacer()
            if model.relationsSchemaLoading(document) {
                ProgressView()
                Text("Reading the tables and columns…").foregroundStyle(.secondary)
            } else {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.largeTitle).foregroundStyle(.teal)
                Text("The schema isn't loaded").font(.headline)
                Text(tab == nil
                     ? "The diagram is drawn from the schema the Database pane loads. Open a tab on this target and load its schema there."
                     : "The diagram is drawn from the schema the Database pane loads. Load it to see \(document.focus)'s relations. Runlet reads only names and types, never rows\(model.isProduction(document.target, connection: document.connection.savedConnection) ? "; this is production, so it asks first" : "").")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Load Schema") { model.loadRelationsSchema(document) }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)
                    .disabled(tab == nil)
                    .accessibilityIdentifier("relations-load-schema")
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The canvas in a scroll view that scrolls both ways, centred on the focus when it opens or
/// re-centres, zoomed by the toolbar or a pinch.
private struct RelationsScrollView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var document: RelationsDocument
    let layout: SQLRelationsLayout
    @State private var position = ScrollPosition()
    @State private var viewport: CGSize = .zero
    @State private var pinchStart: CGFloat?

    var body: some View {
        let zoom = document.zoom
        ScrollView([.horizontal, .vertical]) {
            RelationsCanvas(layout: layout, document: document)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: layout.size.width * zoom, height: layout.size.height * zoom, alignment: .topLeading)
                .frame(minWidth: viewport.width, minHeight: viewport.height)
        }
        .scrollPosition($position)
        .background(RelationsPalette(colorScheme).canvas)
        .onScrollGeometryChange(for: CGSize.self, of: { $0.containerSize }) { _, size in viewport = size }
        .onChange(of: document.scrollRequest) { scrollToFocus() }
        .onChange(of: document.fitRequest) {
            guard viewport.width > 0, viewport.height > 0 else { return }
            document.zoom = min(max(min(viewport.width / layout.size.width, viewport.height / layout.size.height), 0.3), 1)
            scrollToFocus()
        }
        .onChange(of: viewport) { old, _ in if old == .zero { scrollToFocus() } }
        .simultaneousGesture(MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? document.zoom
                pinchStart = start
                document.zoom = min(max(start * value.magnification, 0.3), 2.5)
            }
            .onEnded { _ in pinchStart = nil })
        .accessibilityIdentifier("relations-canvas")
    }

    /// Scrolls so the focus table is in the middle (as far as the canvas allows).
    private func scrollToFocus() {
        DispatchQueue.main.async {
            guard let box = layout.box(layout.focus) else { return }
            let zoom = document.zoom
            let x = min(max(box.frame.midX * zoom - viewport.width / 2, 0), max(layout.size.width * zoom - viewport.width, 0))
            let y = min(max(box.frame.midY * zoom - viewport.height / 2, 0), max(layout.size.height * zoom - viewport.height, 0))
            position.scrollTo(point: CGPoint(x: x, y: y))
        }
    }
}

/// Colours, explicit per appearance so the PNG export draws as the window does.
struct RelationsPalette {
    let canvas, box, header, focusHeader, border, focusBorder, text, secondary, edge, selected, primaryKey, foreignKey: Color

    init(_ scheme: ColorScheme) {
        let dark = scheme == .dark
        func rgb(_ hex: UInt32) -> Color {
            Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        }
        canvas = rgb(dark ? 0x1C1C1E : 0xF4F4F6)
        box = rgb(dark ? 0x2C2C2E : 0xFFFFFF)
        header = rgb(dark ? 0x3A3A3C : 0xEEEEF1)
        focusHeader = rgb(dark ? 0x153A36 : 0xDDF2EF)
        border = rgb(dark ? 0x545458 : 0xC7C7CC)
        focusBorder = rgb(dark ? 0x2EC4B6 : 0x0F9B8E)
        text = rgb(dark ? 0xF2F2F7 : 0x1C1C1E)
        secondary = rgb(dark ? 0x98989D : 0x86868B)
        edge = rgb(dark ? 0x8E8E93 : 0x9A9AA0)
        selected = rgb(dark ? 0x2EC4B6 : 0x0F9B8E)
        primaryKey = rgb(dark ? 0xFFD60A : 0xC99700)
        foreignKey = rgb(dark ? 0x64A0FF : 0x2F6FDB)
    }
}

/// The drawing: lines under the tables, labels on top. `document` is nil for the PNG export,
/// which draws without interaction.
struct RelationsCanvas: View {
    @Environment(\.colorScheme) private var colorScheme
    let layout: SQLRelationsLayout
    var document: RelationsDocument?

    var body: some View {
        let palette = RelationsPalette(colorScheme)
        let selected = document?.selectedEdge
        ZStack(alignment: .topLeading) {
            ForEach(layout.edges) { edge in
                let isSelected = edge.id == selected
                let color = isSelected ? palette.selected : palette.edge
                RelationsEdgeShape(edge: edge)
                    .stroke(color, style: StrokeStyle(lineWidth: isSelected ? 2.4 : 1.3, lineCap: .round, dash: edge.relation == nil ? [4, 4] : []))
                RelationsArrowShape(edge: edge).fill(color)
                if let document, let relation = edge.relation {
                    // A wider, invisible stroke to click on.
                    RelationsEdgeShape(edge: edge)
                        .stroke(Color.clear, lineWidth: 1)
                        .contentShape(RelationsEdgeShape(edge: edge).stroke(style: StrokeStyle(lineWidth: 10)))
                        .onTapGesture { document.selectedEdge = edge.id }
                        .contextMenu { RelationsEdgeMenu(document: document, relation: relation) }
                        .help(relation.summary)
                }
            }
            ForEach(layout.boxes) { box in
                RelationsTableBox(box: box, palette: palette, document: document)
                    .frame(width: box.frame.width, height: box.frame.height)
                    .position(x: box.frame.midX, y: box.frame.midY)
            }
            ForEach(layout.groups) { group in
                RelationsGroupBox(group: group, palette: palette, document: document)
                    .frame(width: group.frame.width, height: group.frame.height)
                    .position(x: group.frame.midX, y: group.frame.midY)
            }
            ForEach(layout.edges.filter { $0.label != nil }) { edge in
                RelationsEdgeLabel(edge: edge, palette: palette, isSelected: edge.id == selected, document: document)
                    .frame(width: edge.labelFrame.width, height: edge.labelFrame.height)
                    .position(x: edge.labelFrame.midX, y: edge.labelFrame.midY)
            }
            #if DEBUG
            // DEBUG step `relations-key-menu`: a line's context menu items on a card under its
            // label, for a screenshot (a menu can't be drawn).
            if let document, let edge = layout.edges.first(where: { $0.id == document.debugMenuEdge }), let relation = edge.relation {
                VStack(alignment: .leading, spacing: 7) { RelationsEdgeMenu(document: document, relation: relation) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .padding(12)
                    .fixedSize()
                    .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial).shadow(radius: 8, y: 3))
                    .alignmentGuide(.leading) { _ in -edge.labelFrame.minX }
                    .alignmentGuide(.top) { _ in -(edge.labelFrame.maxY + 6) }
            }
            #endif
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .background(palette.canvas)
        .contentShape(Rectangle())
        .onTapGesture { document?.selectedEdge = nil }
    }
}

/// A foreign key's curve, in the canvas's coordinates.
nonisolated struct RelationsEdgeShape: Shape {
    let edge: SQLRelationsLayout.Edge

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: edge.start)
            path.addCurve(to: edge.end, control1: edge.control1, control2: edge.control2)
        }
    }
}

/// The arrowhead at the referenced table.
nonisolated struct RelationsArrowShape: Shape {
    let edge: SQLRelationsLayout.Edge

    func path(in rect: CGRect) -> Path {
        Path { path in path.addLines(edge.arrowhead); path.closeSubpath() }
    }
}

/// A table: its name, then its key columns (or all), each marked as a primary or foreign key.
private struct RelationsTableBox: View {
    let box: SQLRelationsLayout.Box
    let palette: RelationsPalette
    let document: RelationsDocument?

    var body: some View {
        let node = box.node
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: node.isMissing ? "questionmark.square.dashed" : node.table?.isView == true ? "eye" : "tablecells")
                    .font(.system(size: 11))
                    .foregroundStyle(node.isFocus ? palette.focusBorder : node.table?.isView == true ? Color.purple : palette.secondary)
                    .frame(width: 16)
                Text(node.name)
                    .font(.system(size: SQLRelationsLayout.Metrics.titleFontSize, weight: .semibold, design: .monospaced))
                    .foregroundStyle(node.isMissing ? palette.secondary : palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if node.table?.isView == true {
                    Text("VIEW")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .foregroundStyle(.white)
                        .background(Capsule().fill(Color.purple.opacity(0.8)))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: SQLRelationsLayout.Metrics.headerHeight)
            .background(node.isFocus ? palette.focusHeader : palette.header)
            ForEach(Array(box.rows.enumerated()), id: \.offset) { _, row in
                RelationsRow(row: row, palette: palette)
                    .frame(height: SQLRelationsLayout.Metrics.rowHeight)
            }
            Spacer(minLength: 0)
        }
        .background(shape.fill(node.isMissing ? palette.canvas : palette.box))
        .clipShape(shape)
        .overlay(shape.strokeBorder(node.isFocus ? palette.focusBorder : palette.border,
                                    style: StrokeStyle(lineWidth: node.isFocus ? 2.5 : 1, dash: node.isMissing ? [5, 4] : [])))
        .contentShape(shape)
        .modifier(RelationsTableActions(node: node, document: document))
    }
}

/// A table's click (centre on it) and context menu, only in the window.
private struct RelationsTableActions: ViewModifier {
    let node: SQLRelations.Node
    let document: RelationsDocument?

    func body(content: Content) -> some View {
        if let document {
            content
                .onTapGesture { if !node.isMissing { document.recentre(on: node.name) } }
                .contextMenu { RelationsTableMenu(document: document, node: node) }
                .help(node.isMissing
                      ? "\(node.name) isn't in the loaded schema (another schema or database, or more tables than Runlet reads)"
                      : node.isFocus ? "\(node.name)\nRight-click for Open in SQL Tab and Show Definition." : "\(node.name)\nClick to centre the diagram on it.")
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("relations-table")
        } else {
            content
        }
    }
}

/// A table's context menu (also drawn by the DEBUG step `relations-menu:<table>`).
struct RelationsTableMenu: View {
    @Environment(AppModel.self) private var model
    let document: RelationsDocument
    let node: SQLRelations.Node

    var body: some View {
        if !node.isMissing {
            Button("Centre on \(node.name)") { document.recentre(on: node.name) }
                .disabled(node.isFocus)
            Button("Open in SQL Tab") { model.openRelationsTable(node.name, in: document) }
            Button("Show Definition") { model.showRelationsDefinition(node.name, in: document) }
                .disabled(model.relationsTab(document) == nil)
            Divider()
        }
        Button("Copy Name") { Pasteboard.copy(node.name) }
    }
}

private struct RelationsRow: View {
    let row: SQLRelationsLayout.Row
    let palette: RelationsPalette

    var body: some View {
        HStack(spacing: 5) {
            if let note = row.note {
                Text(note)
                    .font(.system(size: SQLRelationsLayout.Metrics.typeFontSize))
                    .italic()
                    .foregroundStyle(palette.secondary)
            } else {
                Group {
                    if row.isPrimaryKey {
                        Image(systemName: "key.fill").foregroundStyle(palette.primaryKey)
                    } else if row.isForeignKey {
                        Image(systemName: "arrow.turn.down.right").foregroundStyle(palette.foreignKey)
                    } else {
                        Image(systemName: "circle.fill").font(.system(size: 3.5)).foregroundStyle(palette.secondary.opacity(0.6))
                    }
                }
                .font(.system(size: 9))
                .frame(width: 14)
                Text(row.name)
                    .font(.system(size: SQLRelationsLayout.Metrics.columnFontSize, design: .monospaced))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let type = row.type {
                    Text(type)
                        .font(.system(size: SQLRelationsLayout.Metrics.typeFontSize, design: .monospaced))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
    }
}

/// "+12 more": tables collapsed past the limit; a click shows them.
private struct RelationsGroupBox: View {
    let group: SQLRelationsLayout.Group
    let palette: RelationsPalette
    let document: RelationsDocument?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        VStack(spacing: 2) {
            Text(group.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.text)
            Text(group.subtitle).font(.system(size: 10)).foregroundStyle(palette.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(palette.header))
        .overlay(shape.strokeBorder(palette.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .contentShape(shape)
        .onTapGesture { document?.expanded.insert(group.id) }
        .help("Show \(group.tables.count) more: " + group.tables.prefix(12).joined(separator: ", ") + (group.tables.count > 12 ? ", …" : ""))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("relations-group")
    }
}

/// A line's column pairs; click to select it, right-click for Copy Join.
private struct RelationsEdgeLabel: View {
    let edge: SQLRelationsLayout.Edge
    let palette: RelationsPalette
    let isSelected: Bool
    let document: RelationsDocument?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        Text(edge.label ?? "")
            .font(.system(size: SQLRelationsLayout.Metrics.labelFontSize, design: .monospaced))
            .foregroundStyle(isSelected ? palette.text : palette.secondary)
            .fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(palette.box))
            .overlay(shape.strokeBorder(isSelected ? palette.selected : palette.border, lineWidth: isSelected ? 1.5 : 0.8))
            .contentShape(shape)
            .modifier(RelationsEdgeActions(edge: edge, document: document))
    }
}

private struct RelationsEdgeActions: ViewModifier {
    let edge: SQLRelationsLayout.Edge
    let document: RelationsDocument?

    func body(content: Content) -> some View {
        if let document, let relation = edge.relation {
            content
                .onTapGesture { document.selectedEdge = edge.id }
                .contextMenu { RelationsEdgeMenu(document: document, relation: relation) }

                .help(relation.summary + (relation.displayName.map { "\nConstraint \($0)" } ?? "") + "\nClick to select it; right-click to copy its JOIN.")
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("relations-key")
        } else {
            content
        }
    }
}

/// A line's context menu: Copy Join, Insert Join, and the reverse join.
struct RelationsEdgeMenu: View {
    @Environment(AppModel.self) private var model
    let document: RelationsDocument
    let relation: SQLRelations.Relation

    var body: some View {
        let join = model.relationJoin(relation, in: document)
        Button("Copy Join") { model.copyRelationJoin(relation, in: document) }
            .disabled(join == nil)
        Button("Insert Join") { model.insertRelationJoin(relation, in: document) }
            .disabled(join == nil || model.relationsInsertTab(document) == nil)
        if !relation.isSelfReference {
            Button("Copy Reverse Join") { model.copyRelationJoin(relation, in: document, reverse: true) }
                .disabled(join == nil)
        }
        Divider()
        Button("Copy \(relation.summary)") { Pasteboard.copy(relation.summary) }
    }
}

/// What the diagram shows, and the selected line's JOIN with Copy Join and Insert Join.
private struct RelationsFooter: View {
    @Environment(AppModel.self) private var model
    @Bindable var document: RelationsDocument
    let layout: SQLRelationsLayout

    var body: some View {
        let relation = document.selectedEdge.flatMap { id in layout.edges.first { $0.id == id }?.relation }
        HStack(spacing: 10) {
            if let relation {
                Image(systemName: "link").foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text(relation.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Text(model.relationJoin(relation, in: document) ?? "The referenced columns aren't known, so there is no JOIN to copy.")
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("relations-join")
                }
                Spacer(minLength: 8)
                Button("Copy Join") { model.copyRelationJoin(relation, in: document) }
                    .disabled(model.relationJoin(relation, in: document) == nil)
                    .accessibilityIdentifier("relations-copy-join")
                Button("Insert Join") { model.insertRelationJoin(relation, in: document) }
                    .disabled(model.relationJoin(relation, in: document) == nil || model.relationsInsertTab(document) == nil)
                    .help(model.relationsInsertTab(document).map { "Insert the JOIN at the cursor of \($0.title) (it doesn't run)" } ?? "Open an SQL tab to insert the JOIN into")
                    .accessibilityIdentifier("relations-insert-join")
            } else {
                Text(layout.summary).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("Click a table to centre on it · click a key to copy its JOIN" + (layout.hiddenCount > 0 ? " · click “+N more” to show collapsed tables" : ""))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .accessibilityIdentifier("relations-footer")
    }
}

/// Export as PNG (drawn by `ImageRenderer` as the window draws, at 2x) or SVG (from the layout
/// model, `SQLRelationsSVG`). Saved where the user chooses; nothing else is written.
@MainActor
enum RelationsExport {
    enum Format {
        case png, svg

        var type: UTType { self == .png ? .png : .svg }
        var fileExtension: String { self == .png ? "png" : "svg" }
    }

    /// The file's data, or nil when drawing failed.
    static func data(_ layout: SQLRelationsLayout, format: Format, colorScheme: ColorScheme) -> Data? {
        switch format {
        case .svg:
            return Data(SQLRelationsSVG.render(layout).utf8)
        case .png:
            let renderer = ImageRenderer(content: RelationsCanvas(layout: layout).environment(\.colorScheme, colorScheme).environment(AppDelegate.model))
            renderer.scale = 2
            guard let image = renderer.cgImage else { return nil }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }
    }

    /// Asks where to save (or writes `url`, for DEBUG steps). Returns where it wrote.
    @discardableResult
    static func save(_ layout: SQLRelationsLayout, format: Format, colorScheme: ColorScheme, to url: URL?) -> URL? {
        var destination = url
        if destination == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format.type]
            let base = layout.focus.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            panel.nameFieldStringValue = "\(base) relations.\(format.fileExtension)"
            panel.message = "Save the relations of \(layout.focus) as \(format == .png ? "a PNG image" : "an SVG drawing")."
            guard panel.runModal() == .OK else { return nil }
            destination = panel.url
        }
        guard let destination, let data = data(layout, format: format, colorScheme: colorScheme) else { return nil }
        do {
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }
}
