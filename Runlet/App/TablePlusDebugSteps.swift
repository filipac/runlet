#if DEBUG
import AppKit
import RunletCore

/// RUNLET_DEBUG_STEPS for feature flags (#187) and Import from TablePlus… (#188), for
/// screenshots and scripted checks with scratch data and the fixture folder only
/// (`RUNLET_TABLEPLUS_DIR=Tests/Fixtures/tableplus`, which also swaps the Keychain for
/// `keychain-fixture.json`; see `DebugSteps`):
/// `advanced:on|off` shows or hides Settings ▸ Advanced, as ⌥⌘, and Hide Advanced Settings
/// do (`advanced:reveal` also opens Settings on it) · `flag:<id>=on|off` sets a feature flag ·
/// `tableplus-open` opens the sheet from the visible Import from TablePlus… button (Settings ▸
/// Databases or Edit Connections) · `tableplus-select:all|none|<name>` (`\c` is a comma) ·
/// `tableplus-ssh:<name>=new|direct|<SSH profile name>` · `tableplus-scope:all|<target name>` ·
/// `tableplus-scroll:<name>` (the list scrolls to that row) ·
/// `tableplus-duplicates:skip|update` · `tableplus-passwords:on|off` · `tableplus-import`
/// presses Import · `tableplus-wait[:<seconds>]` waits for the summary · `tableplus-state`
/// prints the rows, choices, and summary (never a password).
@MainActor
enum TablePlusDebugSteps {
    static var waited = 0.0

    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        let argument = argument.replacingOccurrences(of: "\\c", with: ",")
        switch name {
        case "advanced":
            switch argument {
            case "off": model.hideAdvancedSettings()
            case "reveal": model.revealAdvancedSettings(open: true)
            default: model.revealAdvancedSettings(open: false)
            }
        case "flag":
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard let flag = parts.first.flatMap(FeatureFlag.named) else {
                log("flag: no flag \(argument)")
                return true
            }
            model.setFeatureFlag(flag, enabled: parts.count < 2 || parts[1] != "off")
        case "advanced-state":
            // How the ⌥ trigger sees the open windows (#187).
            let windows = NSApp.windows.filter(\.isVisible).map { "\($0.title)[id=\($0.identifier?.rawValue ?? "none") settings=\(AdvancedSettingsTrigger.isSettingsWindow($0))]" }
            func key(_ flags: NSEvent.ModifierFlags, _ characters: String) -> Bool {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43).map(AdvancedSettingsTrigger.isRevealShortcut) ?? false
            }
            let shortcut = "optCmdComma=\(key([.command, .option], "≤")) cmdComma=\(key([.command], ",")) optCmdShiftComma=\(key([.command, .option, .shift], "¯"))"
            log("advanced-state: shown=\(model.settings.showAdvancedSettings) flags=\(model.settings.featureFlags) forced=\(AppModel.forcedFeatureFlags.sorted()) \(shortcut) windows=\(windows)")
        case "tableplus-open":
            NotificationCenter.default.post(name: .debugOpenTablePlusImport, object: nil)
        case "tableplus-select":
            guard let session = TablePlusImportSession.current else { return noSheet(name) }
            switch argument {
            case "all": session.selectAll(true)
            case "none": session.selectAll(false)
            default:
                let rows = session.plan.rows.filter { $0.source.name == argument }
                if rows.isEmpty { log("tableplus-select: no row \(argument)") }
                rows.forEach { session.setSelected($0, true) }
            }
        case "tableplus-ssh":
            guard let session = TablePlusImportSession.current else { return noSheet(name) }
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let row = session.plan.rows.first(where: { $0.source.name == parts[0] }) else {
                log("tableplus-ssh: \(argument)?")
                return true
            }
            switch parts[1] {
            case "new": session.options.sshChoices[row.id] = .newProfile
            case "direct": session.options.sshChoices[row.id] = .direct
            default:
                if let profile = model.library.sshProfiles.first(where: { $0.name == parts[1] }) {
                    session.options.sshChoices[row.id] = .existing(profile.id)
                } else {
                    log("tableplus-ssh: no SSH profile \(parts[1])")
                }
            }
        case "tableplus-scope":
            guard let session = TablePlusImportSession.current else { return noSheet(name) }
            if argument == "all" {
                session.options.scope = nil
            } else if let project = model.library.localProjects.first(where: { $0.name == argument }) {
                session.options.scope = .local(project.id)
            } else if let profile = model.library.dockerProfiles.first(where: { $0.name == argument }) {
                session.options.scope = .docker(profile.id)
            } else if let profile = model.library.sshProfiles.first(where: { $0.name == argument }) {
                session.options.scope = .ssh(profile.id)
            } else {
                log("tableplus-scope: no target \(argument)")
            }
        case "tableplus-scroll":
            guard let session = TablePlusImportSession.current else { return noSheet(name) }
            session.scrollTarget = session.plan.rows.first { $0.source.name == argument }?.id
        case "tableplus-duplicates":
            TablePlusImportSession.current?.options.duplicates = argument == "update" ? .update : .skip
        case "tableplus-passwords":
            TablePlusImportSession.current?.options.copyPasswords = argument != "off"
        case "tableplus-import":
            guard let session = TablePlusImportSession.current else { return noSheet(name) }
            model.performTablePlusImport(session)
        case "tableplus-state":
            guard let session = TablePlusImportSession.current else { return noSheet(name) }
            let rows = session.plan.rows.map { row -> String in
                var text = "\(row.source.name)[\(row.canImport ? "ok" : "unsupported")\(session.isSelected(row) ? ",selected" : "")\(row.isProduction ? ",production" : "")"
                if let choice = session.plan.sshChoice(for: row, options: session.options, in: model.library) { text += ",ssh=\(choice)" }
                if session.plan.duplicate(of: row, scope: session.options.scope, in: model.library) != nil { text += ",duplicate" }
                return text + "]"
            }
            let profiles = session.plan.newProfiles(options: session.options, library: model.library).map { "\($0.profile.name)(\($0.rowIDs.count))" }
            var line = "tableplus-state: source=\(session.source ?? "none") error=\(session.readError ?? "none") rows=\(rows) newProfiles=\(profiles) scope=\(session.options.scope.map(model.targetLabel) ?? "all") duplicates=\(session.options.duplicates.rawValue) passwords=\(session.options.copyPasswords) phase=\(session.summary == nil ? "\(session.phase)" : "done")"
            if let summary = session.summary {
                line += " imported=\(summary.imported.map(\.name)) updated=\(summary.updated.map(\.name)) skipped=\(summary.skipped.map(\.name)) attention=\(summary.needsAttention.map(\.name)) profiles=\(summary.createdProfiles.map(\.name)) passwordsCopied=\(summary.passwordsCopied)"
            }
            log(line)
        default:
            return false
        }
        return true
    }

    private static func noSheet(_ step: String) -> Bool {
        log("\(step): no Import from TablePlus sheet")
        return true
    }

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STEPS: \(text)\n".utf8))
    }
}
#endif
