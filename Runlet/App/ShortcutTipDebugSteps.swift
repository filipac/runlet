#if DEBUG
import AppKit
import RunletCore

/// RUNLET_DEBUG_STEPS for shortcut tips (#345), with scratch data. They need no key window, so
/// Runlet can stay in the background (`ghost`). A scripted run shows no tip for clicks (`click:`
/// and `press:` steps) until one of these steps turns tips on, so other features' checks and
/// screenshots never catch one; `perform:` is a script and never shows one.
///
/// - `shortcut-tip:<command id>[|menu|toolbar|button|palette]` counts a click on the command
///   (a button, unless a source follows), without running it, and shows its tip in the active
///   window when `ShortcutTipRule` says so, as the click would. It prints the rule's decision,
///   and turns tips on for the rest of the run. `shortcut-tip:off` hides the tip on screen.
/// - `shortcut-tips:on|off` turns tips from clicks on or off for the rest of the run.
/// - `shortcut-tip-key:<command id>` counts a use of the command's shortcut, as pressing it does.
/// - `shortcut-tip-dont-show` presses the tip's Don't Show Again.
/// - `shortcut-tip-state` prints the setting, the tip on screen and where it is, the caret's
///   line, and what was counted for each command.
@MainActor
enum ShortcutTipDebugSteps {
    /// A scripted Debug run, as `LoggingRunNotifier` tells one.
    nonisolated static let isScriptedRun = ["RUNLET_DEBUG_STEPS", "RUNLET_DEBUG_INSPECTOR", "RUNLET_SNAPSHOT_DIR"]
        .contains { ProcessInfo.processInfo.environment[$0] != nil }
    /// Whether a step turned tips on for this scripted run.
    static var tipsAllowed = false

    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        switch name {
        case "shortcut-tip":
            if argument == "off" {
                model.shortcutTips.hide()
                return true
            }
            let parts = argument.split(separator: "|", maxSplits: 1).map(String.init)
            guard let id = parts.first, CommandCatalog.byId[id] != nil else {
                log("shortcut-tip: no command \(argument)")
                return true
            }
            guard let source = parts.count > 1 ? CommandSource(rawValue: parts[1]) : .button else {
                log("shortcut-tip: no source \(parts[1])")
                return true
            }
            tipsAllowed = true
            model.shortcutTips.hide()
            let decision = model.noteCommandUse(id, source: source, in: model.activeWindow)
            log("shortcut-tip \(id) from \(source.rawValue): \(decision?.rawValue ?? "not counted") · " + state(model))
        case "shortcut-tips":
            tipsAllowed = argument != "off"
            log("shortcut-tips: \(tipsAllowed ? "on" : "off") for this run")
        case "shortcut-tip-key":
            guard CommandCatalog.byId[argument] != nil else {
                log("shortcut-tip-key: no command \(argument)")
                return true
            }
            model.noteCommandUse(argument, source: .keyboard, in: nil)
            log("shortcut-tip-key \(argument): " + counts(model, argument))
        case "shortcut-tip-dont-show":
            guard let tip = model.shortcutTips.current else {
                log("shortcut-tip-dont-show: no tip")
                return true
            }
            model.dontShowShortcutTip(tip)
            log("shortcut-tip-dont-show \(tip.commandId): " + counts(model, tip.commandId))
        case "shortcut-tip-state":
            log("shortcut-tip-state: " + state(model))
        default:
            return false
        }
        return true
    }

    private static func state(_ model: AppModel) -> String {
        var parts = ["setting=\(model.settings.shortcutTips ? "on" : "off")", "enabled=\(model.shortcutTipsEnabled)"]
        if let tip = model.shortcutTips.current {
            let here = tip.windowId == model.activeWindow?.id ? "active window" : "another window"
            parts.append("tip=\(tip.commandId) edge=\(tip.edge == .top ? "top" : "bottom") in \(here) keys=\(tip.keys.joined(separator: " ")) text=\"\(tip.text)\"")
        } else {
            parts.append("tip=none")
        }
        if let window = model.activeWindow { parts.append(model.shortcutTips.debugGeometry(in: window)) }
        let counted = model.shortcutTipRecord.entries.keys.sorted().map { counts(model, $0) }
        parts.append("record=[" + counted.joined(separator: "; ") + "]")
        return parts.joined(separator: " · ")
    }

    private static func counts(_ model: AppModel, _ id: String) -> String {
        let entry = model.shortcutTipRecord.entry(id)
        let uses = entry.uses.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let last = entry.lastTip.map { ISO8601DateFormatter().string(from: $0) } ?? "never"
        return "\(id) uses{\(uses)} lastTip=\(last)\(entry.tipDismissed ? " dismissed" : "")"
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(message)\n".utf8))
    }
}
#endif
