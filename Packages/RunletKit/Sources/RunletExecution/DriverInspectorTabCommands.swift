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
        let started = ContinuousClock.now
        let spec = ProcessSpec(executable: "/bin/sh", arguments: ["-c", tab.listCommand], environment: environment, workingDirectory: directory)
        let result: (stdout: Data, stderr: Data, exitCode: Int32)
        do {
            result = try await runCommand(spec, timeout: timeout)
        } catch {
            return .failed(message: "Runlet could not run “\(tab.listCommand)”: \(error.localizedDescription)", output: nil)
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
        return .failed(message: "“\(tab.listCommand)” " + reason, output: excerpt(stderr: result.stderr, stdout: result.stdout))
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
