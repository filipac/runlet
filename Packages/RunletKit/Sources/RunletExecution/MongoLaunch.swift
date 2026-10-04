import Foundation
import RunletCore

/// The PHP that opens MongoDB connections from this Mac (#191): the first one with ext-mongodb
/// (since #184, `LocalConnectionLaunch.choosePHP(for:candidates:drivers:)` picks it, as for
/// every driver).
public enum MongoLaunch {
    /// The PHPs that may open a MongoDB connection, in order: `LocalConnectionLaunch.candidates`
    /// (one list for every driver since #184): Runlet's own PHP (build php-8.5.8-r3 and later
    /// have ext-mongodb, #212), the default PHP from Settings, the PHP Runlet would pick
    /// automatically, then every other discovered PHP. Each path once.
    public static func candidates(runlet: PHPInstallation?, defaultPath: String?, installations: [PHPInstallation]) -> [LocalConnectionLaunch.PHP] {
        LocalConnectionLaunch.candidates(runlet: runlet, defaultPath: defaultPath, installations: installations)
    }

    /// The first of `candidates` whose PHP loads ext-mongodb, probing each now, or nil. The app
    /// picks with `LocalConnectionLaunch.choosePHP(for:candidates:drivers:)` and the drivers
    /// discovery read (#184), so it never probes on a run; this is for tests and checks.
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
