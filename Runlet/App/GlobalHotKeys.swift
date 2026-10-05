import AppKit
import Carbon.HIToolbox
import RunletCore

/// 'RNLT', and the number of the one hotkey Runlet registers.
private let quickRunHotKeySignature: OSType = 0x524E_4C54
private let quickRunHotKeyNumber: UInt32 = 1

/// The Quick Run panel's system-wide shortcut through Carbon's `RegisterEventHotKey` (#25). It
/// needs no Accessibility or Input Monitoring permission: macOS sends Runlet only the presses of
/// the one shortcut it registered, never other keys. Registered as exclusive, so a shortcut
/// another app registered first fails with an error instead of firing in both.
@MainActor
final class CarbonHotKeyRegistrar: GlobalHotKeyRegistering {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var onPress: (@MainActor () -> Void)?

    func register(_ hotKey: GlobalHotKey, onPress: @escaping @MainActor () -> Void) -> String? {
        unregister()
        guard installHandler() else { return "Runlet couldn't listen for global shortcuts." }
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: quickRunHotKeySignature, id: quickRunHotKeyNumber)
        let status = RegisterEventHotKey(UInt32(hotKey.keyCode), hotKey.carbonModifiers, identifier, GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else {
            return status == eventHotKeyExistsErr
                ? "Another app already uses \(hotKey.displayString) as a global shortcut. Record another one."
                : "macOS didn't accept \(hotKey.displayString) as a global shortcut (error \(status)). Record another one."
        }
        self.hotKey = reference
        self.onPress = onPress
        return nil
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        onPress = nil
    }

    /// Whether macOS's own shortcuts (System Settings ▸ Keyboard ▸ Keyboard Shortcuts) use the
    /// combo and are turned on: those win over an app's hotkey, which would then never fire.
    func isUsedBySystem(_ hotKey: GlobalHotKey) -> Bool {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let shortcuts = list?.takeRetainedValue() as? [[String: Any]] else { return false }
        return shortcuts.contains { shortcut in
            (shortcut["kHISymbolicHotKeyEnabled"] as? Bool) == true
                && (shortcut["kHISymbolicHotKeyCode"] as? Int) == hotKey.keyCode
                && (shortcut["kHISymbolicHotKeyModifiers"] as? Int).map { UInt32($0) & Self.modifierMask } == hotKey.carbonModifiers
        }
    }

    /// ⌘, ⇧, ⌥, and ⌃ in Carbon's format; other bits (such as the function key's) are ignored.
    private static let modifierMask = UInt32(cmdKey | shiftKey | optionKey | controlKey)

    private func installHandler() -> Bool {
        if handler != nil { return true }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard read == noErr, pressed.signature == quickRunHotKeySignature, pressed.id == quickRunHotKeyNumber else {
                return OSStatus(eventNotHandledErr)
            }
            let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(context).takeUnretainedValue()
            // Carbon calls this on the main thread, from the main run loop.
            MainActor.assumeIsolated { registrar.onPress?() }
            return noErr
        }, 1, &type, context, &handler)
        return status == noErr
    }
}

#if DEBUG
/// Scripted Debug runs (RUNLET_DEBUG_STEPS) never register a global shortcut: it would take the
/// keys from the Mac's other apps while the run lasts. This one registers nothing and says it
/// worked, unless a step asked it to fail (`quick-run:hotkey-conflict`), and `quick-run:hotkey-press`
/// presses it.
@MainActor
final class DebugHotKeyRegistrar: GlobalHotKeyRegistering {
    static let shared = DebugHotKeyRegistrar()
    /// What `register` answers instead of registering (`quick-run:hotkey-conflict`).
    var failure: String?
    /// What macOS would use itself (`quick-run:hotkey-system:<key code>`).
    var systemKeyCodes: Set<Int> = []
    private(set) var registered: GlobalHotKey?
    private(set) var registrations = 0
    private var onPress: (@MainActor () -> Void)?

    func register(_ hotKey: GlobalHotKey, onPress: @escaping @MainActor () -> Void) -> String? {
        if let failure { return failure }
        registered = hotKey
        registrations += 1
        self.onPress = onPress
        return nil
    }

    func unregister() {
        registered = nil
        onPress = nil
    }

    func isUsedBySystem(_ hotKey: GlobalHotKey) -> Bool { systemKeyCodes.contains(hotKey.keyCode) }

    /// A press of the registered shortcut, as Carbon would report it.
    func press() -> Bool {
        guard registered != nil, let onPress else { return false }
        onPress()
        return true
    }
}
#endif
