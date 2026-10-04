import AppKit
import RunletCore

/// Feature flags (#187) and the hidden Settings ▸ Advanced tab that lists them.
extension AppModel {
    /// Flags `RUNLET_FEATURE_FLAGS=a,b` turns on, for screenshots and scripted checks. Debug
    /// builds only: release builds ignore the variable.
    static let forcedFeatureFlags: Set<String> = {
        #if DEBUG
        return FeatureFlag.ids(in: ProcessInfo.processInfo.environment["RUNLET_FEATURE_FLAGS"])
        #else
        return []
        #endif
    }()

    /// The one place code asks whether a feature flag is on.
    func isEnabled(_ flag: FeatureFlag) -> Bool {
        settings.isEnabled(flag, forcedOn: Self.forcedFeatureFlags)
    }

    /// Whether `RUNLET_FEATURE_FLAGS` keeps the flag on (its toggle can't turn it off).
    func isForcedOn(_ flag: FeatureFlag) -> Bool {
        Self.forcedFeatureFlags.contains(flag.id)
    }

    /// Settings ▸ Advanced's toggle. Turning a flag off hides its UI; nothing it created goes.
    func setFeatureFlag(_ flag: FeatureFlag, enabled: Bool) {
        settings.setEnabled(flag, enabled)
    }

    /// Shows Settings ▸ Advanced from now on (⌥⌘, or ⌥ while choosing Settings…), and with
    /// `open`, opens Settings on it.
    func revealAdvancedSettings(open: Bool) {
        settings.showAdvancedSettings = true
        guard open else { return }
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        // The tab's toolbar item exists once SwiftUI has redrawn the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            SettingsTabSelection.select("Advanced")
        }
    }

    /// Hide Advanced Settings: the tab goes until it is revealed again. Flags keep their values.
    func hideAdvancedSettings() {
        settings.showAdvancedSettings = false
        DispatchQueue.main.async {
            SettingsTabSelection.select("General")
        }
    }
}

/// How Settings ▸ Advanced is revealed (#187): ⌥⌘, anywhere in Runlet, or holding ⌥ while
/// Settings opens (⌥-clicking Settings… in the app menu). Nothing in the menus shows it.
@MainActor
enum AdvancedSettingsTrigger {
    private static var keyMonitor: Any?
    private static var windowObserver: NSObjectProtocol?

    static func install(model: @escaping @MainActor () -> AppModel?) {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isRevealShortcut(event) else { return event }
            MainActor.assumeIsolated { model()?.revealAdvancedSettings(open: true) }
            return nil
        }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard isSettingsWindow(window), NSEvent.modifierFlags.contains(.option),
                      let model = model(), !model.settings.showAdvancedSettings else { return }
                model.revealAdvancedSettings(open: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { SettingsTabSelection.select("Advanced") }
            }
        }
    }

    /// ⌥⌘, (the comma, whatever ⌥ types with it on this keyboard layout).
    static func isRevealShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        return flags == [.command, .option] && event.charactersIgnoringModifiers == ","
    }

    /// SwiftUI's Settings window (`com_apple_SwiftUI_Settings_window`).
    static func isSettingsWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true
    }
}
