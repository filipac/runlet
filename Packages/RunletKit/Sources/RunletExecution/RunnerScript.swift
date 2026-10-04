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
    /// Run inspector: SQL statements recorded per run.
    public var maxQueries: Int = 2000
    /// Run inspector: other records (mail, log messages, HTML, driver sections) per run.
    public var maxRecords: Int = 2000
    /// Run inspector: bytes of all records together.
    public var maxRecordBytes: Int = 8 * 1024 * 1024
    /// Each HTML or text body (mail, previews, HTML records).
    public var maxBodyBytes: Int = 2 * 1024 * 1024
    /// Magic comments: hits per probe sent with values (later hits are counted and sampled).
    public var maxInlineHits: Int = 100
    /// Magic comments: bytes of values per run (later hits are sent without values).
    public var maxInlineBytes: Int = 16 * 1024 * 1024

    public init() {}
}

/// A saved database connection as one run hands it to the runner (#138): the definition and
/// the password the engine read from its `CredentialStore` just now (nil: none saved). Only
/// `RunnerBundle.script` reveals the password, into the request that reaches PHP on stdin.
public struct RunnerSQLConnection: Sendable {
    public var definition: DatabaseConnection
    public var password: SensitiveString?
    /// #143: the local forward of a connection through an SSH tunnel, which this Mac's PHP
    /// connects to instead of the definition's host and port.
    public var tunnel: SQLTunnelRoute?

    public init(definition: DatabaseConnection, password: SensitiveString?, tunnel: SQLTunnelRoute? = nil) {
        self.definition = definition
        self.password = password
        self.tunnel = tunnel
    }
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
        /// Report the App Info sections (`panels` events, #19); `code` is ignored.
        case panels
    }

    /// Builds the complete PHP program streamed to `php` on stdin for one run.
    /// `strictTypes` makes the runner declare `strict_types=1` unless the code declares it itself.
    /// `inspector` turns on the run inspector (queries, mail, logs), mail interception, and
    /// previews; without it the runner records nothing.
    /// `profile` samples the snippet with Excimer (Profile Run). `magicComments: false` makes the
    /// runner leave magic comments alone (no probes at all).
    /// `sqlConnection` (#138) makes the run an SQL tab's on a saved connection: the request
    /// carries the definition and password (this request travels only on stdin), the runner
    /// boots no project code (`plain`), and it gets no hints, inspector, or profiler.
    public func script(code: String, nonce: String, runId: UUID, bootstrap: String = "auto", mode: Mode = .run, strictTypes: Bool = false, inspector: RunInspectorOptions? = nil, hints: [String: String] = [:], profile: RunProfileOptions? = nil, magicComments: Bool = true, limits: RunLimits, sqlConnection: RunnerSQLConnection? = nil, sqlBatches: [String]? = nil) -> Data {
        let saved = sqlConnection != nil && mode == .run
        var request: [String: Any] = [
            "protocolVersion": runProtocolVersion,
            "runId": runId.uuidString,
            "nonce": nonce,
            "mode": mode.rawValue,
            "code": code,
            "bootstrap": saved ? "plain" : bootstrap,
            "limits": [
                "maxDepth": limits.maxDepth,
                "maxChildren": limits.maxChildren,
                "maxStringBytes": limits.maxStringBytes,
                "maxNodes": limits.maxNodes,
                "maxValueBytes": limits.maxValueBytes,
                "maxQueries": limits.maxQueries,
                "maxRecords": limits.maxRecords,
                "maxRecordBytes": limits.maxRecordBytes,
                "maxBodyBytes": limits.maxBodyBytes,
                "maxInlineHits": limits.maxInlineHits,
                "maxInlineBytes": limits.maxInlineBytes,
            ],
        ]
        if strictTypes { request["strictTypes"] = true }
        // #152: Import CSV's rows, as data beside the code.
        if let sqlBatches, mode == .run { request["sqlBatches"] = sqlBatches }
        if !magicComments || saved { request["magicComments"] = false }
        if !hints.isEmpty, !saved { request["hints"] = hints }
        if let inspector, mode == .run, !saved {
            request["inspector"] = ["enabled": inspector.enabled, "interceptMail": inspector.interceptMail, "previews": inspector.previews]
        }
        if let profile, mode == .run, !saved {
            request["profile"] = ["engine": profile.engine, "periodMs": profile.periodMs, "eventType": profile.eventType]
        }
        if let sqlConnection, saved {
            let definition = sqlConnection.definition.normalized
            var connection: [String: Any] = [
                "id": definition.id.uuidString,
                "name": definition.name,
                "driver": definition.driver.rawValue,
                "host": definition.host,
                "database": definition.database,
                "user": definition.user,
                "timeout": definition.connectTimeout,
                "summary": definition.summary,
            ]
            if let port = definition.effectivePort { connection["port"] = port }
            // #142: opened from this Mac, so the runner's messages say this Mac, not the target.
            if definition.opensOnThisMac { connection["place"] = "mac" }
            // #143: through an SSH tunnel, PHP connects to the local forward; the host stays the
            // server's name (PostgreSQL verifies TLS against it, with hostaddr=127.0.0.1).
            if let tunnel = sqlConnection.tunnel, definition.usesSSHTunnel {
                connection["tunnel"] = ["port": tunnel.localPort, "via": tunnel.profileName] as [String: Any]
                connection["summary"] = definition.summary + " through SSH “\(tunnel.profileName)”"
            }
            // #139: the runner makes the session read-only right after connecting.
            if definition.readOnly { connection["readOnly"] = true }
            // #140: options, each only when set. None of them is a secret (validation refuses
            // passwords in DSN options and custom DSNs).
            if let socket = definition.socket { connection["socket"] = socket }
            if let charset = definition.charset { connection["charset"] = charset }
            if let tls = definition.tls {
                var fields: [String: String] = ["mode": tls.mode.rawValue]
                fields["ca"] = tls.caFile
                fields["cert"] = tls.certificateFile
                fields["key"] = tls.keyFile
                connection["tls"] = fields
            }
            if !definition.initStatements.isEmpty { connection["init"] = definition.initStatements }
            if !definition.options.isEmpty { connection["options"] = definition.options.map { [$0.key, $0.value] } }
            if let dsn = definition.dsn { connection["dsn"] = dsn }
            if let password = sqlConnection.password { connection["password"] = password.revealed() }
            request["sqlConnection"] = connection
        }
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
