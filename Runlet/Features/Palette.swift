import AppKit
import RunletCore
import SwiftUI

enum PaletteMode: Equatable {
    /// ⌘P: targets, snippets, recent files (prefixes switch scope).
    case anything
    /// ⇧⌘P: every command with its shortcut.
    case commands
}

/// One palette result.
struct PaletteItem: Identifiable {
    enum Kind: String { case command = "Command", target = "Target", snippet = "Snippet", file = "Recent" }

    var id: String
    var kind: Kind
    var title: String
    var subtitle: String
    var symbol: String
    var badge: String?
    var isCurrent = false
    /// `newTab` is true for ⌘↩.
    var perform: @MainActor (_ newTab: Bool) -> Void
}

/// Open Anything (⌘P) and the Command Palette (⇧⌘P). Fuzzy search, ↑/↓ to move, ↩ to run,
/// ⌘↩ to open in a new tab, esc to close. Choosing a target, snippet, or file never runs code.
///
/// Prefixes in Open Anything: `>` commands · `/` local projects · `@` Docker profiles ·
/// `#` snippets.
struct PaletteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let initialMode: PaletteMode
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var searchFocused: Bool

    init(mode: PaletteMode) {
        initialMode = mode
        _query = State(initialValue: mode == .commands ? ">" : "")
    }

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: isCommandQuery ? "command" : "magnifyingglass").foregroundStyle(.secondary)
                TextField(isCommandQuery ? "Type a command" : "Search targets, snippets, files — > commands, / projects, @ Docker, # snippets", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onSubmit { choose(items, newTab: false) }
                    .onChange(of: query) { selection = 0 }
                    .accessibilityIdentifier("palette-search")
            }
            .padding(12)
            Divider()
            if items.isEmpty {
                Text("No matches").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(item, selected: index == selection)
                                    .id(index)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) {
                                        selection = index
                                        choose(items, newTab: false)
                                    }
                                    .onTapGesture { selection = index }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: min(CGFloat(items.count) * 40 + 8, 380))
                    .onChange(of: selection) { proxy.scrollTo(selection) }
                }
            }
            Divider()
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .frame(width: 620)
        .onAppear { searchFocused = true }
        .onKeyPress(.downArrow) {
            selection = min(selection + 1, max(0, results.count - 1))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selection = max(selection - 1, 0)
            return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            choose(results, newTab: true)
            return .handled
        }
        .onExitCommand { dismiss() }
    }

    private var footer: String {
        isCommandQuery ? "↩ run command · esc close" : "↩ open · ⌘↩ new tab · > commands · / projects · @ Docker · # snippets"
    }

    @ViewBuilder
    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .frame(width: 18)
                .foregroundStyle(selected ? Color.white : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.caption).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            Spacer()
            if item.isCurrent {
                Text("current").font(.caption).foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
            if let badge = item.badge {
                Text(badge)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.white.opacity(0.2) : Color.secondary.opacity(0.12)))
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(minHeight: 36)
        .background(selected ? Color.accentColor : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("palette-row")
    }

    // MARK: Results

    private var isCommandQuery: Bool { query.hasPrefix(">") }

    private var results: [PaletteItem] {
        var text = query
        var pool: [PaletteItem]
        if text.hasPrefix(">") {
            text.removeFirst()
            pool = commandItems
        } else if text.hasPrefix("/") {
            text.removeFirst()
            pool = targetItems.filter { $0.id.hasPrefix("target.local") }
        } else if text.hasPrefix("@") {
            text.removeFirst()
            pool = targetItems.filter { $0.id.hasPrefix("target.docker") }
        } else if text.hasPrefix("#") {
            text.removeFirst()
            pool = snippetItems
        } else {
            pool = targetItems + snippetItems + fileItems
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Array(pool.prefix(60)) }
        return pool
            .compactMap { item in FuzzyMatch.score(trimmed, fields: [item.title, item.subtitle]).map { (item, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(60)
            .map(\.0)
    }

    private var commandItems: [PaletteItem] {
        CommandCatalog.all.filter { $0.isEnabled(model) && $0.id != "library.commandPalette" }.map { command in
            PaletteItem(id: "command.\(command.id)", kind: .command, title: command.title, subtitle: command.category.rawValue + (command.keywords.isEmpty ? "" : " · " + command.keywords),
                        symbol: "command", badge: model.shortcut(for: command.id)?.displayString) { _ in
                model.perform(command.id)
            }
        }
    }

    private var targetItems: [PaletteItem] {
        let current = model.selectedTab?.target
        var items: [PaletteItem] = [
            PaletteItem(id: "target.sandbox", kind: .target, title: model.targetLabel(.sandbox), subtitle: "Bundled Laravel application", symbol: "shippingbox", badge: "Sandbox", isCurrent: current == .sandbox) { newTab in
                useTarget(.sandbox, newTab: newTab)
            },
        ]
        items += model.library.localProjects.sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }.map { project in
            PaletteItem(id: "target.local.\(project.id)", kind: .target, title: project.name, subtitle: (project.path as NSString).abbreviatingWithTildeInPath, symbol: "folder", badge: "Local", isCurrent: current == .local(project.id)) { newTab in
                useTarget(.local(project.id), newTab: newTab)
            }
        }
        items += model.library.dockerProfiles.sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }.map { profile in
            PaletteItem(id: "target.docker.\(profile.id)", kind: .target, title: profile.name, subtitle: "\(profile.identity.displayName) · \(profile.workingDirectory)", symbol: "cube.box", badge: "Docker", isCurrent: current == .docker(profile.id)) { newTab in
                useTarget(.docker(profile.id), newTab: newTab)
            }
        }
        return items
    }

    private var snippetItems: [PaletteItem] {
        model.snippets.map { snippet in
            let firstLine = snippet.code.split(separator: "\n").first.map(String.init) ?? ""
            return PaletteItem(id: "snippet.\(snippet.id)", kind: .snippet, title: snippet.label, subtitle: (snippet.targetLabel.map { $0 + " · " } ?? "") + firstLine, symbol: "bookmark", badge: "Snippet") { newTab in
                model.open(snippet, inNewTab: newTab)
            }
        }
    }

    private var fileItems: [PaletteItem] {
        NSDocumentController.shared.recentDocumentURLs
            .filter { ["php", WorkspaceDocument.fileExtension].contains($0.pathExtension.lowercased()) }
            .prefix(15)
            .map { url in
                PaletteItem(id: "file.\(url.path)", kind: .file, title: url.lastPathComponent, subtitle: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                            symbol: url.pathExtension == WorkspaceDocument.fileExtension ? "rectangle.stack" : "doc.text", badge: url.pathExtension == WorkspaceDocument.fileExtension ? "Workspace" : "File") { _ in
                    model.open(url)
                }
            }
    }

    private func useTarget(_ target: TargetRef, newTab: Bool) {
        if newTab {
            model.newTab(target: target)
        } else if let tab = model.selectedTab {
            model.setTarget(target, for: tab)
        }
    }

    private func choose(_ items: [PaletteItem], newTab: Bool) {
        guard items.indices.contains(selection) else { return }
        let item = items[selection]
        dismiss()
        // Run after the sheet closes so commands that present sheets or panels work.
        DispatchQueue.main.async { item.perform(newTab) }
    }
}
