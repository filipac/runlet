import Foundation
import RunletCore

/// Runs a driver inspector tab's commands on this Mac: `list` (here, without a terminal) and
/// the command line `run` starts for a row (in a terminal tab, by the app).
public enum DriverInspectorTabCommands {
    public enum Outcome: Sendable, Equatable {
        case listed(DriverInspectorTabListing)
        /// What went wrong, and the end of what the command wrote to stderr (or, when it wrote
        /// nothing there, the start of what it printed).
        case failed(message: String, output: String?)
    }

    /// Runs `tab.listCommand` with `/bin/sh -c` in `directory` (stdin closed), with the user's
    /// shell environment like host command sources, and reads the first JSON object with an
    /// `items` array it prints; anything around it is ignored. Never throws.
    public static func list(_ tab: DriverInspectorTab, directory: String, environment: [String: String], timeout: Duration = .seconds(30)) async -> Outcome {
        guard let command = tab.listCommand else {
            return .failed(message: "\(tab.title) is listed by the project's driver, not by a command.", output: nil)
        }
        let started = ContinuousClock.now
        let spec = ProcessSpec(executable: "/bin/sh", arguments: ["-c", command], environment: environment, workingDirectory: directory)
        let result: (stdout: Data, stderr: Data, exitCode: Int32)
        do {
            result = try await runCommand(spec, timeout: timeout)
        } catch {
            return .failed(message: "Runlet could not run “\(command)”: \(error.localizedDescription)", output: nil)
        }
        if let listing = parse(result.stdout) { return .listed(listing) }
        let reason: String
        if ContinuousClock.now - started >= timeout {
            reason = "took longer than \(timeout.components.seconds) s, so Runlet stopped it."
        } else if result.exitCode != 0 {
            reason = "exited with code \(result.exitCode) without printing a list."
        } else {
            reason = #"printed no list. Runlet expects one JSON object: {"items": [{"id": "…", "title": "…"}]}."#
        }
        return .failed(message: "“\(command)” " + reason, output: excerpt(stderr: result.stderr, stdout: result.stdout))
    }

    /// The first JSON object in `data` that holds a listing.
    public static func parse(_ data: Data) -> DriverInspectorTabListing? {
        for object in HostCommandLister.jsonObjects(in: data) {
            if let listing = DriverInspectorTabListing.decode(object) { return listing }
        }
        return nil
    }

    /// `template` with every `{id}` replaced by `id`, quoted as one shell word.
    public static func runCommandLine(_ template: String, id: String) -> String {
        template.replacingOccurrences(of: "{id}", with: ProjectCommandLauncher.shellQuote(id))
    }

    /// The last lines of stderr, else the first lines of stdout, at most about 2,000 characters.
    static func excerpt(stderr: Data, stdout: Data) -> String? {
        func lines(_ data: Data, last: Bool) -> String {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let all = text.split(whereSeparator: \.isNewline)
            let picked = (last ? Array(all.suffix(12)) : Array(all.prefix(12))).joined(separator: "\n")
            guard picked.count > 2000 else { return picked }
            return last ? "…" + String(picked.suffix(2000)) : String(picked.prefix(2000)) + "…"
        }
        let error = lines(stderr, last: true)
        if !error.isEmpty { return error }
        let output = lines(stdout, last: false)
        return output.isEmpty ? nil : output
    }
}

extension ExecutionEngine {
    /// Lists a driver inspector tab whose `list` is a PHP callable: the runner boots the
    /// project exactly like App Info (the same adapters: local PHP, `docker exec`, the sandbox,
    /// SSH), runs no snippet, calls the callable, and reports the rows it returned (strings and
    /// numbers only). This executes project code: call it only when the tab appears or on
    /// Refresh.
    ///
    /// A failing boot or callable, exit(), a fatal error, or a timeout don't throw: they come
    /// back as `.failed` with the error's first line and where it happened. Throws when the run
    /// cannot be admitted (e.g. no Docker CLI) or the calling task is cancelled.
    public func listDriverInspectorTab(_ tabId: String, title: String, target: TargetSnapshot, timeout: Duration = .seconds(120)) async throws -> DriverInspectorTabCommands.Outcome {
        let runId = UUID()
        let collector = DriverTabFrameCollector()
        let session = RunSession(runId: runId, limits: limits) { type, payload in
            collector.receive(type: type, payload: payload)
        }
        // A fresh pseudo tab id: listing never conflicts with (or blocks) a tab's run.
        try launch(session, tabId: runId, target: target) { bundle, nonce, limits in
            bundle.script(code: "", nonce: nonce, runId: runId, mode: .driverTab, limits: limits, driverTab: tabId)
        }

        let watchdog = Task { [weak self] in
            try await Task.sleep(for: timeout)
            collector.markTimedOut()
            _ = await self?.cancel(runId: runId)
        }
        defer { watchdog.cancel() }

        var errors: [RunErrorInfo] = []
        var notices: [String] = []
        var booted = false
        var finished: FinishedInfo?
        await withTaskCancellationHandler {
            for await event in session.events {
                switch event.kind {
                case .bootstrapped: booted = true
                case .error(let error): errors.append(error)
                // Only what the list's callable caused, not the boot's own notes.
                case .notice(let message) where booted: notices.append(message)
                case .snippetMessage(let message) where booted: notices.append(message.summary(line: nil))
                case .finished(let info): finished = info
                default: break
                }
            }
        } onCancel: {
            Task { await self.cancel(runId: runId) }
        }
        try Task.checkCancellation()

        let collected = collector.result()
        if let error = errors.first {
            return DriverInspectorTabCommands.failure(error, title: title, booted: booted, projectDirectory: target.workingDirectory)
        }
        if collected.timedOut {
            return .failed(message: "Listing \(title) took longer than \(timeout.components.seconds) s, so Runlet stopped it. The application may be waiting on a service (database, cache) while it boots.", output: nil)
        }
        guard let payload = collected.payload, var listing = DriverInspectorTabListing.decode(payload) else {
            return .failed(message: "Runlet got no list for \(title) from the driver" + (finished.map { " (the runner ended: \($0.reason))." } ?? "."), output: nil)
        }
        listing.notices = notices
        return .listed(listing)
    }
}

extension DriverInspectorTabCommands {
    /// A boot or callable error, for the tab: its first line, and where it happened.
    static func failure(_ error: RunErrorInfo, title: String, booted: Bool, projectDirectory: String? = nil) -> Outcome {
        let firstLine = error.message.split(whereSeparator: \.isNewline).first.map(String.init) ?? error.message
        let prefix = booted ? "Could not list \(title): " : "Could not boot the application to list \(title): "
        var details: [String] = []
        let className = error.className.flatMap { ["InspectorTab", "Exit", "FatalError"].contains($0) ? nil : $0 }
        if let file = error.file {
            // Inside the project: relative to it.
            var path = file
            if let projectDirectory, !projectDirectory.isEmpty {
                // PHP reports real paths (/private/var/… for /var/…).
                let real = URL(fileURLWithPath: projectDirectory).resolvingSymlinksInPath().path
                if let base = [projectDirectory, real, "/private" + real].first(where: { path.hasPrefix($0 + "/") }) { path.removeFirst(base.count + 1) }
            }
            details.append((className.map { $0 + " " } ?? "") + "at " + path + (error.line.map { ":\($0)" } ?? ""))
        } else if let className {
            details.append(className)
        }
        if let previous = error.previous { details.append("caused by \(previous.className): \(previous.message)") }
        return .failed(message: prefix + firstLine, output: details.isEmpty ? nil : details.joined(separator: "\n"))
    }
}

/// Collects the `driverTabList` frame on the session's pump thread.
final class DriverTabFrameCollector: @unchecked Sendable {
    struct Result {
        var payload: Data?
        var timedOut = false
    }

    private let lock = NSLock()
    private var state = Result()

    func receive(type: String, payload: Data) {
        guard type == "driverTabList" else { return }
        lock.lock()
        state.payload = payload
        lock.unlock()
    }

    func markTimedOut() {
        lock.lock()
        state.timedOut = true
        lock.unlock()
    }

    func result() -> Result {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}
