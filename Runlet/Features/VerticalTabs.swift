import Combine
import RunletCore
import SwiftUI

/// Sidebar of tab cards: title, target, runtime (Docker/SSH/Local/Sandbox), PHP version, and the
/// framework or `.runlet` driver from the last run. Drag to reorder; double-click to rename
/// (the shared rename field, #285).
/// Pinned tabs (#279) sit in their own section at the top, as compact rows; a drag stays in
/// its section.
struct VerticalTabList: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window

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
                .tourAnchor(.newTabButton) // #232
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            List {
                let pinned = window.tabs.filter(\.isPinned)
                let others = window.tabs.filter { !$0.isPinned }
                if pinned.isEmpty {
                    cards(others)
                } else {
                    Section {
                        ForEach(pinned) { tab in
                            pinnedRow(tab)
                                .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                                .listRowSeparator(.hidden)
                        }
                        .onMove { source, destination in move(source, destination, in: pinned, offset: 0) }
                    } header: {
                        PinnedTabsHeader()
                    }
                    if !others.isEmpty {
                        Section {
                            cards(others, offset: pinned.count)
                        } header: {
                            // A line between the pinned tabs and the others.
                            Rectangle()
                                .fill(Color.secondary.opacity(0.25))
                                .frame(height: 1)
                                .padding(.leading, 6)
                                .padding(.trailing, 18)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vertical-tabs")
    }

    /// The unpinned tabs' cards; `offset` is where they start in the window's tabs.
    private func cards(_ tabs: [TabModel], offset: Int = 0) -> some View {
        ForEach(tabs) { tab in
            card(tab)
                .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                .listRowSeparator(.hidden)
        }
        .onMove { source, destination in move(source, destination, in: tabs, offset: offset) }
    }

    /// A drag inside one section: SwiftUI's destination is an index before the move.
    private func move(_ source: IndexSet, _ destination: Int, in tabs: [TabModel], offset: Int) {
        guard let first = source.first, tabs.indices.contains(first) else { return }
        model.moveTab(tabs[first].id, to: offset + (destination > first ? destination - 1 : destination))
    }

    /// A pinned tab (#279): one line with the kind's icon, the title, and the run state, in the
    /// target's colour stripe, as selectable as a card. No close button (⌘W and the context menu
    /// still close it).
    @ViewBuilder
    private func pinnedRow(_ tab: TabModel) -> some View {
        let selected = tab.id == window.selectedTab?.id
        HStack(spacing: 5) {
            // The run state is on the right, as on the cards.
            PinnedTabIcon(tab: tab, showsProgress: false)
            if let rename = window.rename, rename.tabId == tab.id {
                TabRenameField(session: rename, font: TabRenameField.font(weight: selected ? .semibold : .regular)) // #285
            } else {
                Text(tab.title + (tab.isFileDirty ? " •" : ""))
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            statusIndicator(tab)
        }
        .padding(.vertical, 4)
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.05))
        )
        .overlay(alignment: .leading) {
            if let tint = model.library.color(for: tab.target)?.color ?? (model.isProduction(tab.target) ? Color.red : nil) {
                UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 7)
                    .fill(tint)
                    .frame(width: 3)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(selected ? Color.accentColor.opacity(0.45) : Color.clear)
        )
        .contentShape(Rectangle())
        .tabClicks(renaming: window.rename?.tabId == tab.id, rename: { model.beginRename(tab.id) }, select: { window.selectedTabId = tab.id })
        .help(tab.pinnedHelp(target: model.targetLabel(tab.target)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tab-\(tab.title)")
        .accessibilityValue("Pinned")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .tabContextMenu(tab, model: model) { model.beginRename(tab.id) }
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
                if let rename = window.rename, rename.tabId == tab.id {
                    TabRenameField(session: rename, font: TabRenameField.font(weight: selected ? .semibold : .regular)) // #285
                } else {
                    Text(tab.title + (tab.isFileDirty ? " •" : ""))
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .lineLimit(1)
                }
                if tab.language == .sql {
                    SQLBadge()
                } else if tab.language == .redis {
                    RedisBadge()
                } else if tab.language == .mongodb {
                    MongoDBBadge() // #214: as in the tab bar
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
                .help(targetDetail(tab.target))
            FlowChips(chips: chips(for: tab, facts: facts), tab: tab)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.05))
        )
        // The target's colour (or red for production) as a stripe along the card's edge.
        .overlay(alignment: .leading) {
            if let tint = model.library.color(for: tab.target)?.color ?? (model.isProduction(tab.target) ? Color.red : nil) {
                UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                    .fill(tint)
                    .frame(width: 3)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor.opacity(0.45) : Color.clear)
        )
        .contentShape(Rectangle())
        .tabClicks(renaming: window.rename?.tabId == tab.id, rename: { model.beginRename(tab.id) }, select: { window.selectedTabId = tab.id })
        .help("\(tab.title) — \(model.targetLabel(tab.target))")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tab-\(tab.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        // The same menu as the tab bar's (#214).
        .tabContextMenu(tab, model: model) { model.beginRename(tab.id) }
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
            return TabCardText.dockerSubtitle(profileName: profile.name, identity: profile.identity)
        case .ssh(let id):
            guard let profile = model.library.sshProfile(id) else { return "Missing SSH profile" }
            return TabCardText.sshSubtitle(profile)
        }
    }

    /// Tooltip for the second line: the untruncated target, including the container identity
    /// that `targetName` leaves out when it repeats the profile name.
    private func targetDetail(_ target: TargetRef) -> String {
        if case .docker(let id) = target, let profile = model.library.dockerProfile(id) {
            return "\(profile.name) · \(profile.identity.displayName)"
        }
        if case .ssh(let id) = target, let profile = model.library.sshProfile(id) {
            if let step = profile.container { return "\(profile.name) · \(step.summary) on \(profile.destinationLabel)" }
            return "\(profile.name) · \(profile.destinationLabel):\(profile.remoteDirectory)"
        }
        return targetName(target)
    }

    /// Two compact chips: runtime + PHP (icon/color = Docker, Local, or Sandbox), and the
    /// framework or `.runlet` driver. Versions are shortened; tooltips show the full values.
    private func chips(for tab: TabModel, facts: AppModel.TargetFacts?) -> [Chip] {
        var chips: [Chip] = []
        switch model.library.environment(for: tab.target) {
        case .production:
            chips.append(Chip(text: "PRODUCTION", symbol: "exclamationmark.triangle.fill", tint: .red, help: "Production: every run asks first (⌘↩ confirms), and nothing loads or connects by itself."))
        case .staging:
            chips.append(Chip(text: "Staging", symbol: nil, tint: .orange, help: "Staging environment"))
        case .development:
            break
        }
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
        case .ssh(let id):
            let profile = model.library.sshProfile(id)
            let host = profile?.destinationLabel ?? "a server"
            if let step = profile?.container {
                chips.append(Chip(text: phpText.map { "SSH · Docker · \($0)" } ?? "SSH · Docker", symbol: "server.rack", tint: .purple,
                                  help: "Runs in \(step.identity.displayName) on \(host) (docker exec over SSH)" + (php.map { " · PHP \($0)" } ?? " · PHP version known after Test Connection or the first run")))
            } else {
                chips.append(Chip(text: phpText ?? "SSH", symbol: "server.rack", tint: .purple,
                                  help: "Runs on \(host) over SSH" + (php.map { " · PHP \($0)" } ?? " · PHP version known after Test Connection or the first run")))
            }
        }
        if let facts, let framework = facts.framework, framework != "plain" {
            let custom = framework.hasPrefix("custom:")
            let name = facts.driverName ?? (custom ? String(framework.dropFirst(7)) : framework.capitalized)
            let version = facts.frameworkVersion.map { custom ? $0 : Self.shortVersion($0) }
            chips.append(Chip(text: TabCardText.frameworkChip(name: name, version: version), symbol: custom ? "gearshape" : nil, tint: .orange,
                              help: TabCardText.frameworkHelp(name: name, version: facts.frameworkVersion, custom: custom) + " · Click for App Info", opensAppInfo: true))
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

// MARK: - Card text

/// Wording for the card's second line and framework chip, without repeating the same name.
enum TabCardText {
    /// "Laravel 13.34", or just the driver name when the reported "version" is really a name
    /// that repeats it (a `.runlet` driver "Hellorider Lease API" reporting "Hellorider Lease-API").
    static func frameworkChip(name: String, version: String?) -> String {
        guard let version, !version.isEmpty else { return name }
        return repeatsName(version, name) ? name : "\(name) \(version)"
    }

    /// Full, unshortened driver details for the chip's tooltip.
    static func frameworkHelp(name: String, version: String?, custom: Bool) -> String {
        var text = (custom ? "Project driver " : "") + name
        if let version, !version.isEmpty { text += (isVersionNumber(version) ? " " : " · ") + version }
        return text
    }

    /// The profile name, plus "project/service" (Compose) or the container name only when it
    /// adds something: "microservice", not "microservice · hellorider/microservice".
    static func dockerSubtitle(profileName: String, identity: ContainerIdentity) -> String {
        let detail: String?
        if let project = identity.composeProject, let service = identity.composeService {
            detail = sameName(project, profileName) || sameName(service, profileName) ? nil : "\(project)/\(service)"
        } else {
            let container = identity.containerName ?? identity.lastContainerId.map { String($0.prefix(12)) }
            detail = container.flatMap { sameName($0, profileName) ? nil : $0 }
        }
        return detail.map { "\(profileName) · \($0)" } ?? profileName
    }

    /// "deploy@app-prod:/home/forge/app/current", or "deploy@app-prod · shop/app" for a
    /// container on the host: where an SSH tab runs.
    static func sshSubtitle(_ profile: SSHProfile) -> String {
        if let step = profile.container { return "\(profile.destinationLabel) · \(step.identity.displayName)" }
        return "\(profile.destinationLabel):\(profile.remoteDirectory)"
    }

    /// "13.34.0", "8.4", "v2.1", "1.0-beta" are version numbers; "Hellorider Lease-API" is not.
    static func isVersionNumber(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.first == "v" || trimmed.first == "V" ? trimmed.dropFirst() : Substring(trimmed)
        return digits.first?.isNumber == true
    }

    /// A non-numeric version equal to, containing, or contained in the name (ignoring case,
    /// punctuation, and whitespace).
    static func repeatsName(_ version: String, _ name: String) -> Bool {
        guard !isVersionNumber(version) else { return false }
        let version = normalized(version), name = normalized(name)
        guard !version.isEmpty, !name.isEmpty else { return false }
        return version.contains(name) || name.contains(version)
    }

    static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = normalized(lhs)
        return !lhs.isEmpty && lhs == normalized(rhs)
    }

    /// Lowercased letters and digits only: "Hellorider Lease-API" → "helloriderleaseapi".
    static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

// MARK: - Chips

struct Chip: Hashable {
    var text: String
    var symbol: String?
    var tint: Color
    var help: String = ""
    /// The framework chip: a click opens App Info (#19) for the card's tab.
    var opensAppInfo = false
}

/// Small capsules that wrap onto multiple lines.
struct FlowChips: View {
    let chips: [Chip]
    /// The tab whose App Info the framework chip opens.
    var tab: TabModel?

    var body: some View {
        FlowLayout(spacing: 3) {
            ForEach(chips, id: \.self) { chip in
                if chip.opensAppInfo, let tab {
                    AppInfoButton(tab: tab, anchor: "card", arrowEdge: .trailing, inset: false) { ChipView(chip: chip) }
                        .accessibilityIdentifier("app-info-card-chip")
                } else {
                    ChipView(chip: chip)
                }
            }
        }
    }
}

/// One capsule. Narrower than its text, the text truncates with an ellipsis and the icon stays.
struct ChipView: View {
    let chip: Chip

    var body: some View {
        HStack(spacing: 3) {
            if let symbol = chip.symbol { Image(systemName: symbol).font(.system(size: 9)) }
            Text(chip.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
        }
        .font(.system(size: 9.5, weight: .medium))
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .foregroundStyle(chip.tint)
        .background(Capsule().fill(chip.tint.opacity(0.13)))
        .help(chip.help)
    }
}

/// Left-aligned wrapping layout. A subview wider than a row is proposed the row width (so its
/// text truncates) and never placed wider than the row.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rowWidth = Self.rowWidth(proposal.width)
        let frames = arrange(subviews, rowWidth: rowWidth)
        let width = frames.map(\.maxX).max() ?? 0
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: min(width, rowWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(subviews, rowWidth: Self.rowWidth(bounds.width))
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    /// The available row width; nil or infinite means unconstrained (ideal sizes, one row).
    static func rowWidth(_ width: CGFloat?) -> CGFloat {
        guard let width, width.isFinite else { return .infinity }
        return max(width, 0)
    }

    /// Frames relative to the layout's origin, filling rows left to right.
    private func arrange(_ subviews: Subviews, rowWidth: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > rowWidth {
                size = subview.sizeThatFits(ProposedViewSize(width: rowWidth, height: nil))
                size.width = min(size.width, rowWidth)
            }
            if x > 0 && x + size.width > rowWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}
