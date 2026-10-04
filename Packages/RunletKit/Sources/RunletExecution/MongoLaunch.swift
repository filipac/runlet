import Foundation
import RunletCore

/// The PHP that opens MongoDB connections from this Mac (#191): the first one with ext-mongodb.
public enum MongoLaunch {
    /// The PHPs to probe for ext-mongodb, in order: Runlet's own PHP (build php-8.5.8-r3 and
    /// later have it, #212), the default PHP from Settings, the PHP Runlet would pick
    /// automatically, then every other discovered PHP (Herd, Homebrew, …). Each path once.
    public static func candidates(runlet: PHPInstallation?, defaultPath: String?, installations: [PHPInstallation]) -> [LocalConnectionLaunch.PHP] {
        var ordered: [LocalConnectionLaunch.PHP] = []
        if let runlet { ordered.append(.init(path: runlet.path, label: "Runlet's PHP \(runlet.version)", isRunletPHP: true)) }
        if let defaultPath, !defaultPath.isEmpty {
            let known = installations.first { $0.path == defaultPath }
            ordered.append(.init(path: defaultPath, label: known.map(LocalConnectionLaunch.label(of:)) ?? "the default PHP", isRunletPHP: known?.source == RunletPHPStore.sourceName))
        }
        // Runlet's PHP is listed with the discovered ones; it was probed first already (an older
        // build without ext-mongodb is skipped by the probe, not here).
        let others = installations.filter { $0.source != RunletPHPStore.sourceName }
        let preferred = PHPDiscovery.preferred(others)
        for php in (preferred.map { [$0] } ?? []) + others {
            ordered.append(.init(path: php.path, label: LocalConnectionLaunch.label(of: php), isRunletPHP: false))
        }
        var seen = Set<String>()
        return ordered.filter { seen.insert($0.path).inserted }
    }

    /// The first of `candidates` whose PHP loads ext-mongodb, or nil.
    public static func choosePHP(candidates: [LocalConnectionLaunch.PHP]) async -> LocalConnectionLaunch.PHP? {
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.path).inserted {
            if await hasMongoDB(candidate.path) { return candidate }
        }
        return nil
    }

    /// Whether the PHP at `path` loads ext-mongodb (no ini prepend/append, 3 seconds at most).
    public static func hasMongoDB(_ path: String) async -> Bool {
        var environment = ExecutableLocator.toolEnvironment()
        environment["SSH_AUTH_SOCK"] = ""
        let spec = ProcessSpec(executable: path,
                               arguments: ["-d", "auto_prepend_file=", "-d", "auto_append_file=", "-r", "exit(extension_loaded('mongodb') ? 0 : 1);"],
                               environment: environment, newProcessGroup: true)
        guard let output = try? await runCommand(spec, timeout: .seconds(3)) else { return false }
        return output.exitCode == 0
    }

    /// Why no PHP on this Mac can open a MongoDB connection, and what to do.
    public static let noPHPMessage = "No PHP on this Mac has ext-mongodb, so nothing ran. Download or update Runlet's PHP in Settings ▸ PHP (it has ext-mongodb from build r3), or install ext-mongodb in a PHP listed there."
}
