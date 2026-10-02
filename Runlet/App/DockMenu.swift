import AppKit
import RunletCore

/// The Dock icon's menu: recently used projects (local projects and Docker profiles), each
/// opening a tab on that target. macOS adds the recent documents above it on its own.
@MainActor
enum DockMenu {
    static let limit = 8
    private static let handler = Handler()

    static func make(model: AppModel?) -> NSMenu? {
        guard let model else { return nil }
        let targets = recentTargets(in: model.library)
        guard !targets.isEmpty else { return nil }
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: "Recent Projects"))
        for target in targets {
            let item = NSMenuItem(title: model.targetLabel(target), action: #selector(Handler.open(_:)), keyEquivalent: "")
            item.target = handler
            item.representedObject = target.stableKey
            item.image = NSImage(systemSymbolName: model.targetSymbol(target), accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }

    /// Saved projects and profiles that were used, most recent first.
    static func recentTargets(in library: TargetLibrary) -> [TargetRef] {
        let projects = library.localProjects.compactMap { project in project.lastOpenedAt.map { (TargetRef.local(project.id), $0) } }
        let profiles = library.dockerProfiles.compactMap { profile in profile.lastOpenedAt.map { (TargetRef.docker(profile.id), $0) } }
        return (projects + profiles).sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    private final class Handler: NSObject {
        @objc func open(_ sender: NSMenuItem) {
            guard let key = sender.representedObject as? String, let model = AppDelegate.model,
                  let target = recentTargets(in: model.library).first(where: { $0.stableKey == key }) else { return }
            NSApp.activate()
            model.openTargetInTab(target)
        }
    }
}

extension AppModel {
    /// Opens `target` in `window` (default: the active one, or a new window): in the current
    /// tab when it holds nothing worth keeping, else in a new tab. Never runs code.
    func openTargetInTab(_ target: TargetRef, in window: WindowModel? = nil) {
        let window = window ?? activeWindow ?? makeWindow()
        if let tab = window.selectedTab, tab.isBlankScratch {
            setTarget(target, for: tab)
        } else {
            newTab(target: target, in: window)
        }
        activeWindowId = window.id
        openWindowAction?(window.id)
    }
}
