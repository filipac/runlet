import Foundation
import RunletCore

public enum MongoLaunch {
    public static func choosePHP(candidates: [LocalConnectionLaunch.PHP]) async -> LocalConnectionLaunch.PHP? {
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.path).inserted {
            var environment = ExecutableLocator.toolEnvironment()
            environment["SSH_AUTH_SOCK"] = ""
            let spec = ProcessSpec(executable: candidate.path,
                                   arguments: ["-d", "auto_prepend_file=", "-d", "auto_append_file=", "-r", "exit(extension_loaded('mongodb') ? 0 : 1);"],
                                   environment: environment, newProcessGroup: true)
            if let output = try? await runCommand(spec, timeout: .seconds(3)), output.exitCode == 0 { return candidate }
        }
        return nil
    }
}
