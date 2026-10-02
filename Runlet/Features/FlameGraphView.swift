import AppKit
import RunletCore
import SwiftUI

/// The Profile section (#41): a Profile Run's flame graph, drawn natively from the runner's
/// collapsed stacks. Root at the top, callees below; a frame's width is its share of the
/// samples. Hover for details, click to zoom in (or on a dimmed ancestor to zoom out), Reset to
/// see everything, and search to highlight matching frames.
struct ProfileSectionView: View {
    let tab: TabModel

    var body: some View {
        if let record = tab.inspection.records(in: RunInspection.profile).first(where: { $0.profile != nil }), let profile = record.profile {
            ProfileView(profile: profile, tab: tab)
                .id(record.index)
        } else {
            ContentUnavailableView("No profile", systemImage: "flame", description: Text("Run ▸ Profile Run samples the snippet with Excimer and shows a flame graph here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A compact line in the output pointing at the Profile section.
struct ProfileOutputRow: View {
    let summary: ProfileSummary
    let tab: TabModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "flame").foregroundStyle(.orange)
            Text(summary.text).font(.callout).textSelection(.enabled)
            Spacer(minLength: 8)
            Button("Show Flame Graph") { tab.outputSection = RunInspection.profile }
                .buttonStyle(.link)
                .font(.callout)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.07)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("output-profile")
    }
}

struct ProfileView: View {
    @Environment(AppModel.self) private var model
    let profile: ProfileRecord
    let tab: TabModel

    @State private var graph: FlameGraph?
    @State private var hottest: [(name: String, selfSamples: Int, totalSamples: Int)] = []
    @State private var focus = 0
    @State private var query = ""
    @State private var hovered: Int?
    @State private var hoverPoint: CGPoint = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            Divider()
            if let graph {
                if graph.totalSamples == 0 {
                    ContentUnavailableView("No samples", systemImage: "flame",
                                           description: Text("The snippet finished within one sampling period (\(BenchmarkFormat.duration(ns: profile.periodMs * 1_000_000))). Repeat the work in a loop to profile it."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 12) {
                            FlameGraphCanvas(graph: graph, profile: profile, focus: $focus, hovered: $hovered, hoverPoint: $hoverPoint,
                                             matches: matches, onFrameAction: frameAction)
                            legend
                            hottestTable(graph)
                        }
                        .padding(10)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: profile.collapsed.count &+ profile.samples) {
            let collapsed = profile.collapsed
            let built = await Task.detached(priority: .userInitiated) { () -> (FlameGraph, [(name: String, selfSamples: Int, totalSamples: Int)]) in
                let graph = FlameGraph(collapsed: collapsed)
                return (graph, graph.hottestFunctions(limit: 12))
            }.value
            graph = built.0
            hottest = built.1
            focus = 0
        }
        .accessibilityIdentifier("profile-view")
    }

    private var matches: Set<Int> {
        graph?.matches(query) ?? []
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "flame.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(profile.samples.formatted()) sample\(profile.samples == 1 ? "" : "s")" + (profile.durationMs.map { " over " + BenchmarkFormat.duration(ns: $0 * 1_000_000) } ?? ""))
                        .font(.callout.weight(.semibold))
                    Text(profile.engineSummary + " · the snippet only, after the application booted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                searchField
                Button {
                    focus = 0
                } label: {
                    Label("Reset Zoom", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .disabled(focus == 0)
                .help("Show every frame again")
                .accessibilityIdentifier("flame-reset")
                Menu {
                    Button("Copy Collapsed Stacks") { Pasteboard.copy(profile.collapsed + "\n") }
                    Button("Copy Hottest Functions") { Pasteboard.copy(hottestText) }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Copy the samples as collapsed stacks (for FlameGraph, speedscope, or inferno), or the hottest functions")
            }
            ForEach(truncationNotes, id: \.self) { note in
                Label(note, systemImage: "scissors").font(.caption).foregroundStyle(.orange)
            }
            if let graph, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                let matched = graph.matchedSamples(matches)
                Text(matches.isEmpty ? "No frame matches “\(query)”." : "\(matches.count.formatted()) frame\(matches.count == 1 ? "" : "s") match: \(percent(matched, of: graph.totalSamples)) of the samples")
                    .font(.caption)
                    .foregroundStyle(matches.isEmpty ? Color.secondary : Color.purple)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Highlight frames", text: $query)
                .textFieldStyle(.plain)
                .frame(width: 150)
                .accessibilityIdentifier("flame-search")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
    }

    private var truncationNotes: [String] {
        var notes: [String] = []
        if let truncated = profile.truncated, !truncated.isEmpty {
            if let stacks = truncated.stacks, stacks > 0 {
                notes.append("\(stacks.formatted()) rarer stacks (\((truncated.foldedSamples ?? 0).formatted()) samples) are folded into “[other stacks]”: Runlet keeps the \((profile.maxStacks ?? 4000).formatted()) most sampled.")
            }
            if let deep = truncated.deepSamples, deep > 0 {
                notes.append("\(deep.formatted()) samples had stacks deeper than \((profile.maxDepth ?? 200).formatted()) frames; their deepest frames are shown as “[deeper frames]”.")
            }
        }
        if let graph, !graph.truncation.isEmpty {
            notes.append("Some stacks were cut to fit the view (\(graph.truncation.nodeSamples + graph.truncation.depthSamples) samples, \(graph.truncation.malformedLines) unreadable lines).")
        }
        return notes
    }

    // MARK: Legend and hottest functions

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(FrameKind.allCases, id: \.self) { kind in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(kind.color(dark: false, dimmed: false)).frame(width: 12, height: 10)
                    Text(kind.label).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("Click a frame to zoom in · click a dimmed frame above to zoom out")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func hottestTable(_ graph: FlameGraph) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Hottest functions (own samples)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(Array(hottest.enumerated()), id: \.offset) { _, entry in
                    GridRow {
                        Text(entry.name)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 420, alignment: .leading)
                            .help(entry.name)
                            .onTapGesture { query = entry.name }
                        GeometryReader { proxy in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.orange.opacity(0.65))
                                .frame(width: max(2, proxy.size.width * Double(entry.selfSamples) / Double(max(1, graph.totalSamples))))
                        }
                        .frame(width: 120, height: 9)
                        Text(percent(entry.selfSamples, of: graph.totalSamples)).font(.caption.monospacedDigit()).gridColumnAlignment(.trailing)
                        Text("\(percent(entry.totalSamples, of: graph.totalSamples)) incl.").font(.caption.monospacedDigit()).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    }
                }
            }
        }
    }

    private var hottestText: String {
        guard let graph else { return "" }
        return hottest.map { "\($0.name)\t\($0.selfSamples) self (\(percent($0.selfSamples, of: graph.totalSamples)))\t\($0.totalSamples) total" }.joined(separator: "\n")
    }

    // MARK: Frame actions

    private func frameAction(_ action: FlameGraphCanvas.Action) {
        guard let graph else { return }
        switch action {
        case .zoom(let id):
            focus = id
        case .copyName(let id):
            Pasteboard.copy(graph.nodes[id].name)
        case .highlight(let id):
            query = graph.nodes[id].name
        case .goToSnippetLine(let line):
            let editorLine = tab.currentRequestForDisplay?.editorLine(forSnippetLine: line) ?? line
            tab.editor.goTo(line: editorLine)
        case .openFile(let path, let line):
            if let hostPath = model.editorLink(forRuntimePath: path, in: tab).path {
                model.openInExternalEditor(path: hostPath, line: line)
            }
        }
    }
}

/// What a frame belongs to, for its color.
enum FrameKind: CaseIterable {
    case snippet, app, vendor, other

    var label: String {
        switch self {
        case .snippet: "Snippet"
        case .app: "Project code"
        case .vendor: "vendor/"
        case .other: "Runlet and folded"
        }
    }

    static func of(_ name: String, frame: ProfileRecord.Frame?) -> FrameKind {
        if name.hasPrefix("[") || name.hasPrefix("RunletRunner\\") || name.hasPrefix("Runlet\\") { return .other }
        if frame?.inSnippet == true || name.hasPrefix("snippet:") || name.hasPrefix("{closure:snippet:") { return .snippet }
        if let file = frame?.file { return file.contains("/vendor/") ? .vendor : .app }
        return name.contains("/vendor/") ? .vendor : .app
    }

    /// A stable hue jitter per name keeps neighbouring frames apart.
    func color(dark: Bool, dimmed: Bool, jitter: Double = 0.5) -> Color {
        let (hue, saturation): (Double, Double) = switch self {
        case .snippet: (0.36 + jitter * 0.05, 0.55)
        case .app: (0.12 + jitter * 0.04, 0.62)
        case .vendor: (0.03 + jitter * 0.06, 0.58)
        case .other: (0.6, 0.08)
        }
        let brightness = dark ? 0.78 : 0.97
        return Color(hue: hue, saturation: dimmed ? saturation * 0.35 : saturation, brightness: dimmed ? brightness * (dark ? 0.55 : 0.92) : brightness)
    }
}

/// The flame graph itself, drawn with Canvas. Rows are 18 pt; frames narrower than a pixel
/// are skipped with their callees.
struct FlameGraphCanvas: View {
    enum Action {
        case zoom(Int), copyName(Int), highlight(Int), goToSnippetLine(Int), openFile(String, Int?)
    }

    let graph: FlameGraph
    let profile: ProfileRecord
    @Binding var focus: Int
    @Binding var hovered: Int?
    @Binding var hoverPoint: CGPoint
    let matches: Set<Int>
    let onFrameAction: (Action) -> Void
    @Environment(\.colorScheme) private var colorScheme

    static let rowHeight: CGFloat = 18

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let placements = graph.placements(focus: focus, minimumWidth: 0.5 / max(width, 1))
            let byDepth = Dictionary(grouping: placements, by: \.depth)
            Canvas { context, size in
                draw(placements, in: &context, width: size.width)
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    hoverPoint = point
                    hovered = hit(point, in: byDepth, width: width)
                case .ended:
                    hovered = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { point in
                if let id = hit(point, in: byDepth, width: width), id != focus { focus = id }
            }
            .contextMenu { contextMenu }
            .overlay(alignment: .topLeading) {
                if let hovered, graph.nodes.indices.contains(hovered) {
                    tooltip(for: hovered)
                        .fixedSize()
                        .offset(tooltipOffset(width: width))
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: CGFloat(graph.depth + 1) * Self.rowHeight)
        .accessibilityElement()
        .accessibilityLabel("Flame graph, \(graph.totalSamples) samples")
        .accessibilityIdentifier("flame-graph")
    }

    private func draw(_ placements: [FlameGraph.Placement], in context: inout GraphicsContext, width: CGFloat) {
        let dark = colorScheme == .dark
        let searching = !matches.isEmpty
        let focusDepth = graph.nodes[focus].depth
        for placement in placements {
            let node = graph.nodes[placement.node]
            let rect = CGRect(x: placement.x * width, y: CGFloat(placement.depth) * Self.rowHeight,
                              width: max(0.5, placement.width * width - 1), height: Self.rowHeight - 1)
            let isAncestor = placement.depth < focusDepth
            let frame = profile.frames[node.name]
            let kind = placement.node == 0 ? FrameKind.other : FrameKind.of(node.name, frame: frame)
            var fill = kind.color(dark: dark, dimmed: isAncestor || (searching && !matches.contains(node.id)), jitter: Self.jitter(node.name))
            if searching, matches.contains(node.id) {
                fill = Color(hue: 0.82, saturation: 0.55, brightness: dark ? 0.85 : 0.95)
            }
            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(fill))
            if placement.node == hovered {
                context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2), with: .color(dark ? .white : .black), lineWidth: 1)
            }
            guard rect.width > 26 else { continue }
            let label = placement.node == 0 ? "all (\(graph.totalSamples.formatted()) samples)" : node.name
            let fits = Int((rect.width - 8) / 6.4)
            guard fits >= 2 else { continue }
            let text = label.count > fits ? String(label.prefix(max(1, fits - 1))) + "…" : label
            let textColor: Color = isAncestor ? Color.black.opacity(0.55) : Color.black.opacity(0.85)
            context.draw(Text(text).font(.system(size: 11)).foregroundStyle(textColor),
                         at: CGPoint(x: rect.minX + 4, y: rect.midY), anchor: .leading)
        }
    }

    private func hit(_ point: CGPoint, in byDepth: [Int: [FlameGraph.Placement]], width: CGFloat) -> Int? {
        let depth = Int(point.y / Self.rowHeight)
        guard let row = byDepth[depth], width > 0 else { return nil }
        let x = point.x / width
        return row.first { x >= $0.x && x < $0.x + $0.width }?.node
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let id = hovered, graph.nodes.indices.contains(id) {
            let node = graph.nodes[id]
            let frame = profile.frames[node.name]
            Button("Zoom to \(Self.short(node.name))") { onFrameAction(.zoom(id)) }
            Button("Highlight Matching Frames") { onFrameAction(.highlight(id)) }
            Button("Copy Name") { onFrameAction(.copyName(id)) }
            if frame?.inSnippet == true, let line = frame?.line, line > 0 {
                Divider()
                Button("Go to Line \(line)") { onFrameAction(.goToSnippetLine(line)) }
            } else if let file = frame?.file {
                Divider()
                Button("Open \((file as NSString).lastPathComponent)\(frame?.line.map { ":\($0)" } ?? "")") { onFrameAction(.openFile(file, frame?.line)) }
            }
        }
    }

    private func tooltip(for id: Int) -> some View {
        let node = graph.nodes[id]
        let frame = profile.frames[node.name]
        let total = graph.totalSamples
        let zoomed = focus != 0 && graph.isAncestor(focus, of: id) || id == focus && focus != 0
        return VStack(alignment: .leading, spacing: 3) {
            Text(id == 0 ? "all samples" : node.name)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .lineLimit(3)
                .frame(maxWidth: 420, alignment: .leading)
            if let location = location(of: frame) {
                Text(location).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 420, alignment: .leading)
            }
            Text("\(node.value.formatted()) sample\(node.value == 1 ? "" : "s") · \(Self.percent(node.value, total)) of all" + (zoomed ? " · \(Self.percent(node.value, graph.nodes[focus].value)) of the zoomed frame" : ""))
                .font(.caption.monospacedDigit())
            if node.selfValue > 0, id != 0 {
                Text("Own samples: \(node.selfValue.formatted()) (\(Self.percent(node.selfValue, total)))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let duration = approximateDuration(node.value) {
                Text("≈ \(duration) of \(profile.eventType == "cpu" ? "CPU" : "wall") time").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .accessibilityIdentifier("flame-tooltip")
    }

    private func tooltipOffset(width: CGFloat) -> CGSize {
        let x = hoverPoint.x + 280 > width ? max(0, hoverPoint.x - 300) : hoverPoint.x + 14
        return CGSize(width: x, height: hoverPoint.y + 16)
    }

    private func location(of frame: ProfileRecord.Frame?) -> String? {
        guard let frame else { return nil }
        if frame.inSnippet == true { return "snippet" + (frame.line.map { ", line \($0)" } ?? "") }
        guard let file = frame.file else { return nil }
        return file + (frame.line.map { ":\($0)" } ?? "")
    }

    private func approximateDuration(_ samples: Int) -> String? {
        guard let duration = profile.durationMs, profile.samples > 0 else { return nil }
        return BenchmarkFormat.duration(ns: duration * 1_000_000 * Double(samples) / Double(profile.samples))
    }

    static func percent(_ part: Int, _ whole: Int) -> String {
        guard whole > 0 else { return "0%" }
        let value = Double(part) / Double(whole) * 100
        return value >= 10 ? String(format: "%.0f%%", value) : String(format: "%.1f%%", value)
    }

    static func short(_ name: String) -> String {
        name.count > 48 ? String(name.prefix(47)) + "…" : name
    }

    /// 0…1 from the name, stable across runs (FNV-1a).
    static func jitter(_ name: String) -> Double {
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Double(hash % 1000) / 1000
    }
}

private func percent(_ part: Int, of whole: Int) -> String {
    FlameGraphCanvas.percent(part, whole)
}
