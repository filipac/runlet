import RunletCore
import SwiftUI

/// Sidebar of tab cards: title, target, runtime (Docker/Local/Sandbox), PHP version, and the
/// framework or `.runlet` driver from the last run. Drag to reorder; double-click to rename.
struct VerticalTabList: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window
    @State private var renaming: UUID?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tabs").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.newTab(in: window)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Tab (⌘T)")
                .accessibilityIdentifier("new-tab-button")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            List {
                ForEach(window.tabs) { tab in
                    card(tab)
                        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                        .listRowSeparator(.hidden)
                }
                .onMove { source, destination in
                    guard let first = source.first else { return }
                    let id = window.tabs[first].id
                    model.moveTab(id, to: destination > first ? destination - 1 : destination)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vertical-tabs")
    }

    @ViewBuilder
    private func card(_ tab: TabModel) -> some View {
        let selected = tab.id == window.selectedTab?.id
        let facts = model.targetFacts[tab.target.stableKey]
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: model.targetSymbol(tab.target))
                    .font(.caption)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 14)
                if renaming == tab.id {
                    TextField("Name", text: $renameText)
                        .textFieldStyle(.plain)
                        .onSubmit {
                            model.renameTab(tab.id, to: renameText)
                            renaming = nil
                        }
                        .onExitCommand { renaming = nil }
                } else {
                    Text(tab.title + (tab.isFileDirty ? " •" : ""))
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                statusIndicator(tab)
                Button {
                    model.closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.bold))
                }
                .buttonStyle(.borderless)
                .opacity(selected ? 0.9 : 0.35)
                .help("Close Tab (⌘W)")
            }
            Text(targetName(tab.target))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 2)
            FlowChips(chips: chips(for: tab, facts: facts))
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor.opacity(0.45) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            renameText = tab.title
            renaming = tab.id
        }
        .onTapGesture { window.selectedTabId = tab.id }
        .help("\(tab.title) — \(model.targetLabel(tab.target))")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tab-\(tab.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Rename…") {
                renameText = tab.title
                renaming = tab.id
            }
            Button("Duplicate") { model.duplicateTab(tab.id) }
            Divider()
            Button("Close") { model.closeTab(tab.id) }
            Button("Close Other Tabs") { model.closeOtherTabs(tab.id) }
        }
    }

    @ViewBuilder
    private func statusIndicator(_ tab: TabModel) -> some View {
        switch tab.runState {
        case .preparing, .running, .stopping:
            ProgressView().controlSize(.mini)
        case .finished(let info):
            Circle().fill(info.status.color).frame(width: 7, height: 7).help("Last run: \(info.status.label)")
        case .idle:
            EmptyView()
        }
    }

    private func targetName(_ target: TargetRef) -> String {
        switch target {
        case .sandbox: return "Laravel Sandbox"
        case .local(let id): return model.library.localProject(id).map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Missing project"
        case .docker(let id):
            guard let profile = model.library.dockerProfile(id) else { return "Missing Docker profile" }
            return "\(profile.name) · \(profile.identity.displayName)"
        }
    }

    /// Two compact chips: runtime + PHP (icon/color = Docker, Local, or Sandbox), and the
    /// framework or `.runlet` driver. Versions are shortened; tooltips show the full values.
    private func chips(for tab: TabModel, facts: AppModel.TargetFacts?) -> [Chip] {
        var chips: [Chip] = []
        let php = model.phpVersionHint(for: tab.target)
        let phpText = php.map { "PHP " + Self.shortVersion($0) }
        switch tab.target {
        case .sandbox:
            let docker: Bool
            if case .ready(.docker) = model.sandboxStatus { docker = true } else { docker = false }
            chips.append(Chip(text: phpText ?? "Sandbox", symbol: docker ? "cube.box" : "shippingbox", tint: docker ? .blue : .teal,
                              help: "Sandbox \(docker ? "in Docker" : "with local PHP")" + (php.map { " · PHP \($0)" } ?? "")))
        case .local:
            chips.append(Chip(text: phpText ?? "Local", symbol: "laptopcomputer", tint: .green,
                              help: "Local PHP" + (php.map { " \($0)" } ?? "")))
        case .docker:
            chips.append(Chip(text: phpText ?? "Docker", symbol: "cube.box", tint: .blue,
                              help: "Runs in Docker" + (php.map { " · PHP \($0)" } ?? " · PHP version known after the first run")))
        }
        if let facts, let framework = facts.framework, framework != "plain" {
            let custom = framework.hasPrefix("custom:")
            let name = facts.driverName ?? (custom ? String(framework.dropFirst(7)) : framework.capitalized)
            let version = facts.frameworkVersion.map { custom ? $0 : Self.shortVersion($0) }
            chips.append(Chip(text: name + (version.map { " \($0)" } ?? ""), symbol: custom ? "gearshape" : nil, tint: .orange,
                              help: (custom ? "Project driver " : "") + name + (facts.frameworkVersion.map { " \($0)" } ?? "")))
        }
        return chips
    }

    /// "8.4.25" → "8.4", "13.34.0" → "13.34"; other strings unchanged.
    static func shortVersion(_ version: String) -> String {
        let parts = version.split(separator: ".")
        guard parts.count >= 2, parts.prefix(2).allSatisfy({ Int($0) != nil }) else { return version }
        return parts.prefix(2).joined(separator: ".")
    }
}

struct Chip: Hashable {
    var text: String
    var symbol: String?
    var tint: Color
    var help: String = ""
}

/// Small capsules that wrap onto multiple lines.
struct FlowChips: View {
    let chips: [Chip]

    var body: some View {
        FlowLayout(spacing: 3) {
            ForEach(chips, id: \.self) { chip in
                HStack(spacing: 3) {
                    if let symbol = chip.symbol { Image(systemName: symbol).font(.system(size: 9)) }
                    Text(chip.text).lineLimit(1)
                }
                .font(.system(size: 9.5, weight: .medium))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .foregroundStyle(chip.tint)
                .background(Capsule().fill(chip.tint.opacity(0.13)))
                .help(chip.help)
            }
        }
    }
}

/// Left-aligned wrapping layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = (proposal.width ?? .infinity).isFinite && (proposal.width ?? 0) > 0 ? proposal.width! : .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
