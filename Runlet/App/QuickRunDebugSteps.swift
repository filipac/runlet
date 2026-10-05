#if DEBUG
import AppKit
import RunletCore

/// RUNLET_DEBUG_STEPS for the Quick Run panel (#25), for scripted checks and screenshots with
/// scratch data (see `DebugSteps`). The panel opens without the keyboard in these runs, and the
/// global shortcut is never registered (`DebugHotKeyRegistrar`):
/// `quick-run:open` / `quick-run:close` · `quick-run:type:<code>` (inserts the code at the caret in
/// one edit, as typing would; `\n` is a newline, `\c` a comma) · `quick-run:clear` (empties the
/// editor) · `quick-run:key:<key>` (one press handed to the panel as if it had the keyboard:
/// `cmd+r`, `cmd+return`, `cmd+.`, `cmd+w`, `escape`, or any `key:` name; keys the panel doesn't
/// take go to its editor) · `quick-run:run` (Run, as ⌘R) · `quick-run:target:<saved target
/// name>|sandbox` (the picker: only targets it offers) · `quick-run:mark:<saved target
/// name>=production|staging|development` (changes that target's marking, as its settings would) ·
/// `quick-run:open-in-tab` · `quick-run:state` (the panel, the keyboard and the active app, the
/// target and what the picker offers, the code, the run, its output, and History's newest entry) ·
/// `quick-run:hotkey:on|off` · `quick-run:hotkey-conflict[:off]` (the next registration fails as if
/// another app used the shortcut) · `quick-run:hotkey-system:<key code>|off` (macOS uses that key) ·
/// `quick-run:hotkey-press` (presses the registered shortcut) · `quick-run:hotkey-state`.
/// `quick-run-wait[:<seconds>]` (in `AppDelegate.runDebugInspectorCheck`) waits for the panel's run.
@MainActor
enum QuickRunDebugSteps {
    /// Runs one step; false when `name` isn't one of these.
    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        guard name == "quick-run" else { return false }
        let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
        let value = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "open":
            model.showQuickRun()
        case "close":
            model.closeQuickRun()
        case "type":
            let editor = model.quickRunTab().editor
            let text = value.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\c", with: ",")
            editor.textView.insertText(text, replacementRange: editor.textView.selectedRange())
        case "clear":
            model.quickRunTab().editor.replaceAll(with: "")
        case "key":
            key(value, model: model)
        case "run":
            model.runQuickRun()
        case "target":
            let target = value == "sandbox" ? TargetRef.sandbox : savedTarget(named: value, model: model)
            guard let target else {
                log("target: no saved target \(value)")
                return true
            }
            let offered = model.quickRunTargets.contains(target)
            model.setQuickRunTarget(target)
            log("target \(value): \(offered ? "chosen" : "not offered, unchanged")")
        case "mark":
            let pieces = value.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2, let environment = TargetEnvironment(rawValue: pieces[1]), let target = savedTarget(named: pieces[0], model: model) else {
                log("mark: \(value)?")
                return true
            }
            mark(target, environment, model: model)
            log("mark \(pieces[0]): \(model.library.environment(for: target).rawValue)")
        case "open-in-tab":
            model.openQuickRunInTab()
            let tab = model.activeWindow?.selectedTab
            log("open-in-tab: window tabs=\(model.activeWindow?.tabs.map(\.title) ?? []) selected=\(tab?.title ?? "none") target=\(tab.map { model.targetLabel($0.target) } ?? "-") code=\(quoted(tab?.editorIfLoaded?.text ?? tab?.code ?? "")) output=\(tab.map { summary(of: $0) } ?? "-") panel=\(panelState(model))")
        case "state":
            log("state: \(state(model))")
        case "hotkey":
            model.settings.quickRunHotKeyEnabled = value == "on"
            log("hotkey: \(hotKeyState(model))")
        case "hotkey-conflict":
            DebugHotKeyRegistrar.shared.failure = value == "off" ? nil : "Another app already uses \(model.settings.quickRunHotKey.displayString) as a global shortcut. Record another one."
            model.applyQuickRunHotKey()
            log("hotkey-conflict: \(hotKeyState(model))")
        case "hotkey-system":
            DebugHotKeyRegistrar.shared.systemKeyCodes = Int(value).map { [$0] } ?? []
            model.applyQuickRunHotKey()
            log("hotkey-system: \(hotKeyState(model))")
        case "hotkey-press":
            let pressed = DebugHotKeyRegistrar.shared.press()
            log("hotkey-press: \(pressed ? "pressed" : "nothing registered") panel=\(panelState(model))")
        case "hotkey-state":
            log("hotkey-state: \(hotKeyState(model))")
        default:
            log("unknown step quick-run:\(argument)")
        }
        return true
    }

    /// Whether the panel's run is still going (`quick-run-wait`).
    static func isRunning(_ model: AppModel) -> Bool {
        model.quickRun.tab?.isRunning ?? false
    }

    static var waited = 0.0

    /// One press, as the panel gets it with the keyboard: its own keys first, then its editor's.
    private static func key(_ spec: String, model: AppModel) {
        guard let panel = QuickRunPanelController.current?.panel, let (code, flags) = DebugSteps.keySpec(spec),
              let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: true) else {
            return log("key \(spec): no panel")
        }
        event.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
        guard let press = NSEvent(cgEvent: event) else { return }
        if panel.performKeyEquivalent(with: press) {
            log("key \(spec): taken by the panel; panel=\(panelState(model))")
            return
        }
        let textView = model.quickRunTab().editor.textView
        textView.inputContext?.activate()
        textView.keyDown(with: press)
        log("key \(spec): sent to the editor; panel=\(panelState(model))")
    }

    private static func savedTarget(named name: String, model: AppModel) -> TargetRef? {
        if let project = model.library.localProjects.first(where: { $0.name == name }) { return .local(project.id) }
        if let profile = model.library.dockerProfiles.first(where: { $0.name == name }) { return .docker(profile.id) }
        if let profile = model.library.sshProfiles.first(where: { $0.name == name }) { return .ssh(profile.id) }
        return nil
    }

    /// Changes a saved target's marking the way its settings would (they save it).
    private static func mark(_ target: TargetRef, _ environment: TargetEnvironment, model: AppModel) {
        switch target {
        case .local(let id):
            if var project = model.library.localProject(id) {
                project.environment = environment
                model.saveProject(project)
            }
        case .docker(let id):
            if var profile = model.library.dockerProfile(id) {
                profile.environment = environment
                model.saveDockerProfile(profile)
            }
        case .ssh(let id):
            if var profile = model.library.sshProfile(id) {
                profile.environment = environment
                model.saveSSHProfile(profile)
            }
        case .sandbox:
            break
        }
    }

    private static func panelState(_ model: AppModel) -> String {
        let panel = QuickRunPanelController.current?.panel
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        return "open=\(model.quickRun.isOpen) visible=\(panel?.isVisible ?? false) key=\(panel?.isKeyWindow ?? false) appActive=\(NSApp.isActive) frontmostIsRunlet=\(front == Bundle.main.bundleIdentifier)"
    }

    private static func state(_ model: AppModel) -> String {
        guard let tab = model.quickRun.tab else { return "no panel tab yet; draft=\(quoted(model.quickRun.draft.code)) target=\(model.targetLabel(model.quickRun.draft.target)) \(panelState(model))" }
        let offered = model.quickRunTargets.map { model.targetLabel($0) }
        let refusal = model.quickRun.refusal ?? model.quickRunRefusal(for: tab.target)
        let newest = model.history.first.map { "\(quoted(String($0.code.prefix(60)))) \($0.status.rawValue) quickRun=\($0.isQuickRun) target=\($0.targetLabel)" } ?? "none"
        return "\(panelState(model)) target=\(model.targetLabel(tab.target)) offered=\(offered) code=\(quoted(tab.editor.text)) run=\(runState(tab)) output=\(summary(of: tab)) refusal=\(refusal.map(quoted) ?? "none") history=\(newest) saved=\(model.quickRunDraftForSaving.map { quoted($0.code) } ?? "nil")"
    }

    private static func runState(_ tab: TabModel) -> String {
        switch tab.runState {
        case .idle: "idle"
        case .preparing: "preparing"
        case .running: "running"
        case .stopping: "stopping"
        case .finished(let info): "\(info.status.rawValue) (\(info.reason))"
        }
    }

    /// The output the panel shows: the result, errors with their line, printed output, and more.
    private static func summary(of tab: TabModel) -> String {
        let display = tab.shownModelDisplay
        let parts: [String] = tab.output.compactMap { item in
            switch item {
            case .result(_, let result): "result=\(quoted(result.hasValue ? result.node(for: display)?.plainText() ?? "" : "(none)"))"
            case .error(_, let error, let line): "error=\(quoted("\(error.className ?? "Error"): \(error.message)")) line=\(line.map(String.init) ?? "-")"
            case .text(_, let stream, let text): "\(stream.rawValue)=\(quoted(text.string))"
            case .dump(_, let dump, _): "dump=\(quoted(dump.node(for: display).plainText()))"
            case .notice(_, let text): "notice=\(quoted(text))"
            case .warning(_, let text): "warning=\(quoted(text))"
            default: nil
            }
        }
        return parts.isEmpty ? "none" : parts.joined(separator: " ")
    }

    private static func hotKeyState(_ model: AppModel) -> String {
        let registrar = DebugHotKeyRegistrar.shared
        let status: String = switch model.quickRun.hotKeyStatus {
        case .off: "off"
        case .noShortcut: "no shortcut"
        case .active(let hotKey): "active \(hotKey.displayString)"
        case .unavailable(let hotKey, let reason): "unavailable \(hotKey.displayString): \(reason)"
        }
        return "enabled=\(model.settings.quickRunHotKeyEnabled) status=\(status) registered=\(registrar.registered?.displayString ?? "none") registrations=\(registrar.registrations)"
    }

    private static func quoted(_ text: String) -> String {
        "\"" + String(text.prefix(300)).replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: quick-run \(message)\n".utf8))
    }
}
#endif
