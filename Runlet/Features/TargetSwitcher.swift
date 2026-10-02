import RunletCore
import SwiftUI

/// ⌘P palette: fuzzy-search the sandbox, local projects, and Docker profiles and switch the
/// current tab's target (or open it in a new tab with ⌘↩). Never runs code.
struct TargetSwitcher: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var searchFocused: Bool

    struct Entry: Identifiable {
        var target: TargetRef
        var title: String
        var detail: String
        var symbol: String
        var lastUsed: Date?
        var id: String { target.stableKey }
    }

    private var entries: [Entry] {
        var all: [Entry] = [Entry(target: .sandbox, title: model.targetLabel(.sandbox), detail: "Bundled Laravel application", symbol: "shippingbox", lastUsed: nil)]
        all += model.library.localProjects.map {
            Entry(target: .local($0.id), title: $0.name, detail: $0.path, symbol: "folder", lastUsed: $0.lastOpenedAt)
        }
        all += model.library.dockerProfiles.map {
            Entry(target: .docker($0.id), title: $0.name, detail: "\($0.identity.displayName) · \($0.workingDirectory)", symbol: "cube.box", lastUsed: $0.lastOpenedAt)
        }
        let filtered = all.filter { matchesSearch(query, in: $0.title, $0.detail) }
        return filtered.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
    }

    var body: some View {
        let entries = entries
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Switch target — sandbox, projects, Docker apps", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onSubmit { choose(entries, newTab: false) }
                    .onChange(of: query) { selection = 0 }
                    .accessibilityIdentifier("target-switcher-search")
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                List(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.symbol).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title).font(.body.weight(.medium))
                            Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if model.selectedTab?.target == entry.target {
                            Text("current").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .listRowBackground(index == selection ? Color.accentColor.opacity(0.2) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { selection = index; choose(entries, newTab: false) }
                    .onTapGesture { selection = index }
                    .id(index)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("target-switcher-row")
                }
                .listStyle(.plain)
                .onChange(of: selection) { proxy.scrollTo(selection) }
            }
            .frame(height: 300)
            Divider()
            Text("↩ use in this tab · ⌘↩ open in a new tab · esc close")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .frame(width: 560)
        .onAppear { searchFocused = true }
        .onKeyPress(.downArrow) {
            selection = min(selection + 1, max(0, entries.count - 1))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selection = max(selection - 1, 0)
            return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            choose(entries, newTab: true)
            return .handled
        }
        .onExitCommand { dismiss() }
    }

    private func choose(_ entries: [Entry], newTab: Bool) {
        guard entries.indices.contains(selection) else { return }
        let target = entries[selection].target
        if newTab {
            model.newTab(target: target)
        } else if let tab = model.selectedTab {
            model.setTarget(target, for: tab)
        }
        dismiss()
    }
}
