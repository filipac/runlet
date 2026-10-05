import Foundation

/// The Quick Run panel's code and target (#25): kept between openings and saved with the
/// session. Restoring it never runs it.
public struct QuickRunDraft: Sendable, Codable, Equatable {
    public var code: String
    public var target: TargetRef

    public init(code: String = "", target: TargetRef = .sandbox) {
        self.code = code
        self.target = target
    }
}

/// What Open in Tab does with the panel's code (#25): the new tab, and what the panel keeps.
public struct QuickRunHandoff: Sendable, Equatable {
    /// The tab's title, code, and target.
    public var title: String
    public var code: String
    public var target: TargetRef
    /// The panel afterwards: no code (it moved to the tab), the same target.
    public var remaining: QuickRunDraft
}

/// The rules of the Quick Run panel (#25): which targets it offers, when it refuses to run, and
/// what Open in Tab and a restored session give. A production target is never offered and never
/// run: the picker leaves it out, and ⌘R checks again, so a target marked production while the
/// panel is open (or whose application said it runs in production) is refused.
public enum QuickRun {
    /// The title of the tab Open in Tab makes.
    public static let tabTitle = "Quick Run"

    /// The targets the panel's picker offers: the sandbox first, then local projects, Docker
    /// profiles, and SSH hosts, each most recently opened first. Production targets, and targets
    /// whose application reported a production environment (`reportedEnvironments`, by
    /// `TargetRef.stableKey`), are left out.
    public static func offeredTargets(in library: TargetLibrary, reportedEnvironments: [String: String] = [:]) -> [TargetRef] {
        func recent<T>(_ items: [T], _ date: (T) -> Date?) -> [T] {
            items.enumerated().sorted { lhs, rhs in
                let (left, right) = (date(lhs.element) ?? .distantPast, date(rhs.element) ?? .distantPast)
                return left != right ? left > right : lhs.offset < rhs.offset
            }.map(\.element)
        }
        let all: [TargetRef] = [.sandbox]
            + recent(library.localProjects, \.lastOpenedAt).map { .local($0.id) }
            + recent(library.dockerProfiles, \.lastOpenedAt).map { .docker($0.id) }
            + recent(library.sshProfiles, \.lastOpenedAt).map { .ssh($0.id) }
        return all.filter { refusal(for: $0, in: library, reportedEnvironment: reportedEnvironments[$0.stableKey]) == nil }
    }

    /// Why the panel won't run on `target`, or nil when it may. Checked when ⌘R is pressed, not
    /// only when the target was picked. `reportedEnvironment` is what the target's application
    /// said on its last run.
    public static func refusal(for target: TargetRef, in library: TargetLibrary, reportedEnvironment: String? = nil) -> String? {
        if target != .sandbox, name(of: target, in: library) == nil {
            return "This target was removed. Choose another one."
        }
        let name = name(of: target, in: library) ?? "Laravel Sandbox"
        if library.isProduction(target) {
            return "“\(name)” is marked as production, and Quick Run never runs on production. Choose another target, or open the code in a tab, where a run on production asks first."
        }
        if AppEnvironment.isProduction(reportedEnvironment) {
            let reported = AppEnvironment.normalized(reportedEnvironment) ?? "production"
            return "The application on “\(name)” said it runs in “\(reported)” on its last run, and Quick Run never runs on production. Choose another target, or open the code in a tab."
        }
        return nil
    }

    /// The panel's draft after a launch: a removed target falls back to the sandbox. A production
    /// target stays, so the panel can say why it won't run there. Nothing runs.
    public static func restored(_ draft: QuickRunDraft?, in library: TargetLibrary) -> QuickRunDraft {
        guard var draft else { return QuickRunDraft() }
        if draft.target != .sandbox, name(of: draft.target, in: library) == nil { draft.target = .sandbox }
        return draft
    }

    /// Open in Tab: the code and its target move to a new tab, and the panel is left empty on the
    /// same target. Nil when there is no code to move. Opening a tab runs nothing, and a tab on a
    /// production target asks before each run as usual.
    public static func handoff(_ draft: QuickRunDraft, in library: TargetLibrary) -> QuickRunHandoff? {
        guard !draft.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let target = draft.target == .sandbox || name(of: draft.target, in: library) != nil ? draft.target : .sandbox
        return QuickRunHandoff(title: tabTitle, code: draft.code, target: target, remaining: QuickRunDraft(code: "", target: target))
    }

    /// A saved target's name; nil for the sandbox and for targets that no longer exist.
    private static func name(of target: TargetRef, in library: TargetLibrary) -> String? {
        switch target {
        case .sandbox: nil
        case .local(let id): library.localProject(id)?.name
        case .docker(let id): library.dockerProfile(id)?.name
        case .ssh(let id): library.sshProfile(id)?.name
        }
    }
}

// MARK: - Global hotkey

/// A system-wide shortcut (#25): a key by its position on the keyboard (a virtual key code, as
/// Carbon's `RegisterEventHotKey` takes it) and its modifiers, with the combo menus show.
public struct GlobalHotKey: Sendable, Codable, Hashable {
    /// The virtual key code (`kVK_ANSI_R` is 15).
    public var keyCode: Int
    /// The key as typed and the modifiers, for display and for comparing with Runlet's own shortcuts.
    public var combo: KeyCombo

    public init(keyCode: Int, combo: KeyCombo) {
        self.keyCode = keyCode
        self.combo = combo
    }

    /// The shortcut Settings offers before one is recorded: ⌃⌥R.
    public static let quickRunDefault = GlobalHotKey(keyCode: 15, combo: KeyCombo("r", [.control, .option]))

    public var displayString: String { combo.displayString }

    /// A global shortcut needs ⌘, ⌃, or ⌥: a plain key, or one with only ⇧, would stop typing it
    /// in every app.
    public var isValid: Bool {
        keyCode >= 0 && !combo.key.isEmpty && !combo.modifiers.isDisjoint(with: [.command, .control, .option])
    }

    /// The modifiers in Carbon's format (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`), as
    /// `RegisterEventHotKey` and the system's symbolic hotkeys use them.
    public var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if combo.modifiers.contains(.command) { flags |= 1 << 8 }
        if combo.modifiers.contains(.shift) { flags |= 1 << 9 }
        if combo.modifiers.contains(.option) { flags |= 1 << 11 }
        if combo.modifiers.contains(.control) { flags |= 1 << 12 }
        return flags
    }
}

/// Where the Quick Run hotkey stands, for Settings.
public enum GlobalHotKeyStatus: Sendable, Equatable {
    /// Turned off in Settings: nothing is registered.
    case off
    /// Turned on, but no shortcut is recorded.
    case noShortcut
    /// Registered: the shortcut opens the panel from any app.
    case active(GlobalHotKey)
    /// Turned on, but not registered, and why: another app or macOS uses the shortcut, Runlet
    /// uses it for a command, or it has no ⌘, ⌃, or ⌥.
    case unavailable(GlobalHotKey, reason: String)

    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

/// Registers one system-wide hotkey. The app's is Carbon's `RegisterEventHotKey`, which needs no
/// Accessibility permission; tests and scripted Debug runs use one that registers nothing, so
/// they never take a shortcut from the Mac they run on.
@MainActor
public protocol GlobalHotKeyRegistering: AnyObject {
    /// Registers `hotKey` in place of any earlier one, calling `onPress` each time it's pressed.
    /// Returns nil when it worked, else why not, in a sentence.
    func register(_ hotKey: GlobalHotKey, onPress: @escaping @MainActor () -> Void) -> String?
    /// Unregisters the hotkey, if one is registered.
    func unregister()
    /// Whether macOS itself uses the shortcut (System Settings ▸ Keyboard ▸ Keyboard Shortcuts:
    /// Spotlight, input sources, Mission Control, …), when it's turned on there.
    func isUsedBySystem(_ hotKey: GlobalHotKey) -> Bool
}

/// Keeps the Quick Run hotkey registered as Settings say (#25): registers it when turned on,
/// again when the shortcut changes, and unregisters it when turned off. A shortcut that macOS or
/// one of Runlet's commands uses isn't registered, and the status says why; so is one another
/// app registered first (the registrar's error).
@MainActor
public final class GlobalHotKeyController {
    public private(set) var status: GlobalHotKeyStatus = .off
    private let registrar: any GlobalHotKeyRegistering
    private let onPress: @MainActor () -> Void
    /// What is registered now.
    private var registered: GlobalHotKey?

    public init(registrar: any GlobalHotKeyRegistering, onPress: @escaping @MainActor () -> Void) {
        self.registrar = registrar
        self.onPress = onPress
    }

    /// Applies the settings. `appShortcuts` are Runlet's own commands' shortcuts (command title →
    /// combo): a global hotkey would take the keys from them, even in Runlet. Applying the same
    /// settings again changes nothing.
    @discardableResult
    public func apply(enabled: Bool, hotKey: GlobalHotKey?, appShortcuts: [String: KeyCombo] = [:]) -> GlobalHotKeyStatus {
        guard enabled else {
            release()
            status = .off
            return status
        }
        guard let hotKey else {
            release()
            status = .noShortcut
            return status
        }
        // Checked every time: a command may have taken the shortcut since it was registered.
        if let reason = Self.problem(with: hotKey, appShortcuts: appShortcuts, registrar: registrar) {
            release()
            status = .unavailable(hotKey, reason: reason)
            return status
        }
        if registered == hotKey, status == .active(hotKey) { return status }
        release()
        if let failure = registrar.register(hotKey, onPress: onPress) {
            status = .unavailable(hotKey, reason: failure)
            return status
        }
        registered = hotKey
        status = .active(hotKey)
        return status
    }

    /// Unregisters whatever is registered (quitting, or turning it off).
    public func release() {
        guard registered != nil else { return }
        registrar.unregister()
        registered = nil
    }

    /// Why `hotKey` can't be a global shortcut before asking macOS: no ⌘, ⌃, or ⌥; one of Runlet's
    /// commands; or a shortcut of macOS's own.
    private static func problem(with hotKey: GlobalHotKey, appShortcuts: [String: KeyCombo], registrar: any GlobalHotKeyRegistering) -> String? {
        guard hotKey.isValid else {
            return "\(hotKey.displayString) can't open Quick Run from every app: a global shortcut needs ⌘, ⌃, or ⌥. Record another one."
        }
        if let command = appShortcuts.filter({ $0.value == hotKey.combo }).keys.sorted().first {
            return "Runlet's \(command) command uses \(hotKey.displayString). Record another shortcut, or change that command's in the list below."
        }
        if registrar.isUsedBySystem(hotKey) {
            return "macOS uses \(hotKey.displayString) for one of its own shortcuts (System Settings ▸ Keyboard ▸ Keyboard Shortcuts). Record another one."
        }
        return nil
    }
}
