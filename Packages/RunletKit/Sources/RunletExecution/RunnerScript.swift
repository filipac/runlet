import Foundation
import RunletCore

/// Output and value limits for one run. Proposed defaults from the plan; tune with fixtures.
public struct RunLimits: Sendable, Codable, Equatable {
    public var maxRawOutputBytes: Int = 8 * 1024 * 1024
    public var maxValueBytes: Int = 2 * 1024 * 1024
    public var maxDepth: Int = 8
    public var maxChildren: Int = 200
    public var maxStringBytes: Int = 64 * 1024
    public var maxNodes: Int = 20_000

    public init() {}
}

/// The app-owned PHP runner bundle (Resources/Runner/dist/runlet-runner.php).
public struct RunnerBundle: Sendable {
    public let source: Data

    public init(source: Data) {
        self.source = source
    }

    public init(contentsOf url: URL) throws {
        self.source = try Data(contentsOf: url)
    }

    /// What the runner does after booting the project.
    public enum Mode: String, Sendable {
        /// Run the snippet (`code`).
        case run
        /// List the driver's commands and Composer scripts (`commands` events); `code` is ignored.
        case commands
    }

    /// Builds the complete PHP program streamed to `php` on stdin for one run.
    public func script(code: String, nonce: String, runId: UUID, bootstrap: String = "auto", mode: Mode = .run, limits: RunLimits) -> Data {
        let request: [String: Any] = [
            "protocolVersion": runProtocolVersion,
            "runId": runId.uuidString,
            "nonce": nonce,
            "mode": mode.rawValue,
            "code": code,
            "bootstrap": bootstrap,
            "limits": [
                "maxDepth": limits.maxDepth,
                "maxChildren": limits.maxChildren,
                "maxStringBytes": limits.maxStringBytes,
                "maxNodes": limits.maxNodes,
                "maxValueBytes": limits.maxValueBytes,
            ],
        ]
        let json = (try? JSONSerialization.data(withJSONObject: request)) ?? Data("{}".utf8)
        var script = source
        script.append(Data("namespace {\n\\RunletRunner\\Runner::main('".utf8))
        script.append(Data(json.base64EncodedString().utf8))
        script.append(Data("');\n}\n".utf8))
        return script
    }

    public static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// `php` arguments used for every run (the program itself arrives on stdin).
    public static let phpArguments = ["-d", "display_errors=stderr", "-d", "html_errors=0", "-d", "log_errors=0"]
}
