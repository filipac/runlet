import RunletCore
import SwiftUI

/// Pinned tabs (#279) show the tab's kind instead of its target: an icon per language, in the
/// colour of its badge (PHP, SQL, Redis, MongoDB). The tooltip names the tab and its target.
extension TabLanguage {
    var pinnedSymbol: String {
        switch self {
        case .php: "chevron.left.forwardslash.chevron.right"
        case .sql: "cylinder.split.1x2"
        case .redis: "square.stack.3d.up.fill"
        case .mongodb: "leaf.fill"
        }
    }

    var pinnedTint: Color {
        switch self {
        case .php: .indigo
        case .sql: .teal
        case .redis: .red
        case .mongodb: .mongoDB
        }
    }
}

/// A pinned tab's icon: its kind's symbol, a spinner while it runs, and a red dot on a
/// production target.
struct PinnedTabIcon: View {
    @Environment(AppModel.self) private var model
    let tab: TabModel

    var body: some View {
        ZStack {
            if tab.isRunning {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: tab.language.pinnedSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tab.language.pinnedTint)
            }
        }
        .frame(width: 16, height: 14)
        .overlay(alignment: .topTrailing) {
            if model.isProduction(tab.target) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                    .offset(x: 3, y: -2)
                    .help("Production")
                    .accessibilityLabel("Production")
            }
        }
        .accessibilityLabel(tab.isRunning ? "\(tab.language.displayName) tab, running" : "\(tab.language.displayName) tab")
    }
}

/// The vertical tabs' "Pinned" heading (#279).
struct PinnedTabsHeader: View {
    var body: some View {
        Label("Pinned", systemImage: "pin.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .accessibilityIdentifier("pinned-tabs-header")
    }
}

extension TabModel {
    /// The tooltip of a pinned tab, which shows a short title (#279): the full title, the
    /// target, and that it is pinned.
    @MainActor func pinnedHelp(target: String) -> String {
        "\(title)\(isFileDirty ? " (edited)" : "") — \(target) · Pinned"
    }
}
