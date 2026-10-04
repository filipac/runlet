#if DEBUG
import AppKit
import RunletCore

/// RUNLET_DEBUG_STEPS for the Logs window (#20), for screenshots and scripted checks with
/// scratch data only (see `DebugSteps`):
/// `logs[:<target name>]` (opens the window for the current tab's target, or the sandbox, a
/// local project, or a Docker or SSH profile by name; `logs:off` closes it) ·
/// `logs-source:<text>` (opens the first source whose title starts with, or contains, the text) ·
/// `logs-other:<path>` (Other Path…) · `logs-follow`, `logs-stop`, `logs-pause`, `logs-clear`,
/// `logs-reload`, `logs-find` (the toolbar's buttons) · `logs-level:<level>|all` ·
/// `logs-search:<text>` · `logs-last-run:on|off` · `logs-expand:<n>|<text>` (opens the nth
/// shown entry, 1-based, or the first whose text contains the text) · `logs-collapse` ·
/// `logs-frames:log` (frame links log where they would open instead of opening an editor) ·
/// `logs-frame:<n>` (the nth frame of the first open entry) · `logs-state` (prints the source,
/// state, counts, levels, and frames, never log text) · `logs-wait:<entries>|following|idle[:<seconds>]`
/// (in `LogDebugSteps.reached`: holds the steps until that many entries are shown, or the state).
@MainActor
enum LogDebugSteps {
    static var waited: Double = 0
    /// `logs-frames:log`: frame links only log.
    static var logsFrames = false

    static func run(_ name: String, _ argument: String, model: AppModel) -> Bool {
        guard name == "logs" || name.hasPrefix("logs-") else { return false }
        let store = model.logViewer
        switch name {
        case "logs":
            if argument == "off" {
                NSApp.windows.first { $0.title == "Logs" }?.close()
            } else if argument.isEmpty {
                model.showLogs()
            } else if let target = target(named: argument, model: model) {
                model.showLogs(target: target)
            } else {
                log("logs: no target \(argument)")
            }
        case "logs-source":
            let sources = store.target.map(model.logSources(for:)) ?? []
            if let source = sources.first(where: { $0.title.hasPrefix(argument) }) ?? sources.first(where: { $0.title.contains(argument) }) {
                model.openLogSource(source)
            } else {
                log("logs-source: none like \(argument) in \(sources.map(\.title))")
            }
        case "logs-other": model.addOtherLogPath(argument)
        case "logs-follow": model.followLog()
        case "logs-stop": model.stopFollowingLog()
        case "logs-pause": model.toggleLogPause()
        case "logs-clear": model.clearLog()
        case "logs-reload": model.reloadLog()
        case "logs-find": model.findRemoteLogs()
        case "logs-level":
            store.minimumLevel = argument == "all" ? nil : LogLevel(name: argument)
        case "logs-search":
            store.search = argument
        case "logs-last-run":
            store.showsLastRun = argument != "off"
            model.refreshLastRun()
        case "logs-expand":
            guard let session = store.session else { return true }
            let shown = model.visibleLogEntries(session)
            if let index = Int(argument), shown.indices.contains(index - 1) {
                session.expanded.insert(shown[index - 1].id)
            } else if let entry = shown.first(where: { $0.text.contains(argument) }) {
                session.expanded.insert(entry.id)
            }
        case "logs-collapse":
            store.session?.expanded = []
        case "logs-frames":
            logsFrames = argument == "log"
        case "logs-frame":
            guard let session = store.session, let entry = model.visibleLogEntries(session).first(where: { session.expanded.contains($0.id) }) else {
                log("logs-frame: no open entry")
                return true
            }
            let frames = entry.frames
            guard let index = Int(argument), frames.indices.contains(index - 1) else {
                log("logs-frame: \(frames.count) frames")
                return true
            }
            model.openLogFrame(frames[index - 1], target: session.target)
            log("logs-frame \(index): \(store.lastEvent ?? "-")")
        case "logs-state":
            log(state(model))
        default:
            return false
        }
        return true
    }

    static func target(named name: String, model: AppModel) -> TargetRef? {
        if name == "sandbox" { return .sandbox }
        if let project = model.library.localProjects.first(where: { $0.name == name }) { return .local(project.id) }
        if let profile = model.library.dockerProfiles.first(where: { $0.name == name }) { return .docker(profile.id) }
        if let profile = model.library.sshProfiles.first(where: { $0.name == name }) { return .ssh(profile.id) }
        return nil
    }

    /// Whether `logs-wait:<argument>` is satisfied.
    static func reached(_ argument: String, model: AppModel) -> Bool {
        let what = argument.split(separator: ":").first.map(String.init) ?? argument
        guard let session = model.logViewer.session else { return false }
        switch what {
        case "following": return session.isFollowing
        case "idle": return !session.isFollowing && session.state != .starting && session.state != .loading
        case "found": return model.logViewer.target.map { !model.logViewer.finding.contains($0.stableKey) } ?? true
        default:
            guard let count = Int(what) else { return true }
            return model.visibleLogEntries(session).count >= count
        }
    }

    /// Source, state, counts, levels, open entries' frames: never a log line's text.
    static func state(_ model: AppModel) -> String {
        let store = model.logViewer
        guard let session = store.session else {
            return "logs: target=\(store.target.map(model.targetLabel) ?? "none") no source; sources=\(store.target.map { model.logSources(for: $0).map(\.title) } ?? [])"
        }
        let shown = model.visibleLogEntries(session)
        let levels = Dictionary(grouping: shown, by: { $0.level?.label ?? "NONE" }).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " ")
        let formats = Set(shown.map(\.format.rawValue)).sorted().joined(separator: ",")
        let open = shown.filter { session.expanded.contains($0.id) }.map { entry in
            "#\(entry.id)[lines=\(entry.lines.count) frames=\(entry.frames.map(\.shortLabel).joined(separator: ";"))]"
        }
        let sources = store.target.map { model.logSources(for: $0).map { "\($0.group.rawValue)/\($0.title)" } } ?? []
        return "logs: target=\(store.target.map(model.targetLabel) ?? "none") source=\(session.source.id) state=\(session.state) paused=\(session.isPaused) "
            + "entries=\(session.buffer.entries.count) shown=\(shown.count) dropped=\(session.buffer.dropped) levels=[\(levels)] formats=\(formats) "
            + "open=\(open) lastRun=\(store.showsLastRun) runEntries=\(session.runEntries?.count ?? -1) notices=\(session.notices.count) lastNotice=\(session.notices.last ?? "-") "
            + "event=\(store.lastEvent ?? "-") connections=\(model.activeConnections.count(of: .logFollow)) sources=\(sources)"
    }

    static func log(_ text: String) {
        FileHandle.standardError.write(Data("RUNLET_DEBUG_STATE: \(text)\n".utf8))
    }
}
#endif
