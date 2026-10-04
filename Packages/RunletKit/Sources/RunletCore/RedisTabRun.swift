import Foundation

/// Builds the PHP that runs a Redis tab's commands (#190). Each command is a list of byte-exact
/// PHP string literals, never the line's text; the runner's `RedisTab` opens the run's saved
/// connection (which this code never contains) or the application's connection by name, and
/// reports a `redis` event per command.
public enum RedisTabRun {
    /// Elements a reply keeps at most (each level); the rest are counted.
    public static let defaultMaxElements = 1000

    /// A PHP string literal holding exactly `bytes`: printable ASCII as is, everything else as
    /// `\xHH`, so binary arguments survive and nothing interpolates.
    public static func phpBytes(_ bytes: [UInt8]) -> String {
        var result = "\""
        for byte in bytes {
            switch byte {
            case 0x5C: result += "\\\\"
            case 0x22: result += "\\\""
            case 0x24: result += "\\$"
            case 0x20..<0x7F: result.append(Character(UnicodeScalar(byte)))
            default: result += String(format: "\\x%02X", byte)
            }
        }
        return result + "\""
    }

    public static func phpBytes(_ text: String) -> String { phpBytes(Array(text.utf8)) }

    static func phpString(_ text: String?) -> String { text.map(phpBytes) ?? "null" }

    /// How many elements of `arguments`' reply the runner keeps: twice the cap for replies of
    /// pairs (field/value, member/score), so a page holds `maxElements` rows.
    public static func cap(for arguments: [String], maxElements: Int) -> Int {
        let key = RedisCommands.key(arguments)
        let upper = arguments.map { $0.uppercased() }
        let pairs = ["HGETALL", "CONFIG|GET", "HSCAN", "ZSCAN", "ZPOPMIN", "ZPOPMAX"].contains(key)
            || (key == "HRANDFIELD" && upper.contains("WITHVALUES")) || upper.contains("WITHSCORES")
        return max(1, maxElements) * (pairs ? 2 : 1)
    }

    /// One command, or Run All's commands (`all`), in order on one connection, optionally in
    /// MULTI/EXEC (`transaction`). Each command carries its line and which arguments are
    /// passwords (the runner echoes them as `•••` and scrubs them from its events).
    public static func code(commands: [RedisScript.Command], connection: String?, maxElements: Int = defaultMaxElements, all: Bool = false, transaction: Bool = false) -> String {
        let items = commands.map { command -> String in
            let secrets = RedisScript.secretArguments(command.strings).sorted()
            let secret = secrets.isEmpty ? "" : ", 'secret' => [\(secrets.map(String.init).joined(separator: ", "))]"
            return "    ['argv' => [\(command.arguments.map(phpBytes).joined(separator: ", "))], 'line' => \(command.line), 'cap' => \(cap(for: command.strings, maxElements: maxElements))\(secret)],"
        }
        return """
        <?php
        // Runlet Redis tab (#190): \(all ? "every command in order, stopping at the first error" : "one command on the tab's connection").
        return \\RunletRunner\\RedisTab::run([
        \(items.joined(separator: "\n"))
        ], \(phpString(connection)), \(max(1, maxElements)), \(all ? "true" : "false"), \(transaction ? "true" : "false"));
        """
    }

    /// Load More: `arguments` (a SCAN with the next cursor, the next LRANGE or ZRANGE range),
    /// as one command.
    public static func pageCode(arguments: [[UInt8]], line: Int, connection: String?, maxElements: Int = defaultMaxElements) -> String {
        let command = RedisScript.Command(arguments: arguments, text: "", range: NSRange(location: 0, length: 0), line: line)
        return code(commands: [command], connection: connection, maxElements: maxElements)
    }

    /// Test Connection for a saved Redis connection: PING, the server's version, the database,
    /// the ACL user, and TLS.
    public static let testCode = """
        <?php
        // Runlet Redis tab (#190): Test Connection for a saved connection.
        return \\RunletRunner\\RedisTab::test();
        """

    /// The key browser: one SCAN page of database `db` (`MATCH pattern`, `COUNT count`,
    /// optionally `TYPE type`), with each key's type and TTL. Never KEYS. Without `details`
    /// (Load Keys for Completion, #206), the SCAN only: key names, no TYPE, PTTL, or INFO.
    public static func keysCode(db: Int, pattern: String, cursor: String, count: Int, type: String?, connection: String?, details: Bool = true) -> String {
        """
        <?php
        // Runlet Redis key browser (#190): one SCAN page, with each key's type and TTL.
        return \\RunletRunner\\RedisTab::keys(\(max(0, db)), \(phpBytes(pattern)), \(phpBytes(cursor)), \(max(1, count)), \(phpString(type)), \(phpString(connection))\(details ? "" : ", false"));
        """
    }

    /// The key browser's Open Value: the key's value read by its type (GET, HSCAN, LRANGE,
    /// SSCAN, ZRANGE … WITHSCORES, XRANGE), at most `maxElements` elements.
    public static func valueCode(db: Int, key: [UInt8], maxElements: Int, connection: String?) -> String {
        """
        <?php
        // Runlet Redis key browser (#190): one key's value, read by its type.
        return \\RunletRunner\\RedisTab::value(\(max(0, db)), \(phpBytes(key)), \(max(1, maxElements)), \(phpString(connection)));
        """
    }

    /// The key browser's Memory Usage: type, TTL, encoding, length, and MEMORY USAGE of one key.
    public static func keyInfoCode(db: Int, key: [UInt8], connection: String?) -> String {
        """
        <?php
        // Runlet Redis key browser (#190): one key's type, TTL, encoding, length, and memory.
        return \\RunletRunner\\RedisTab::keyInfo(\(max(0, db)), \(phpBytes(key)), \(phpString(connection)));
        """
    }

    /// The server panel: INFO and CLIENT LIST.
    public static func serverCode(connection: String?) -> String {
        """
        <?php
        // Runlet Redis server panel (#190): INFO and CLIENT LIST, nothing else.
        return \\RunletRunner\\RedisTab::server(\(phpString(connection)));
        """
    }

    /// The server panel's Kill Client, confirmed: CLIENT KILL ID on the same server (`runId`),
    /// never the panel's own client (`listedBy`) or this runner's, and only while the client is
    /// still the one listed (`address`).
    public static func killCode(clientId: Int64, address: String, runId: String, listedBy: Int64, connection: String?) -> String {
        """
        <?php
        // Runlet Redis server panel (#190): CLIENT KILL ID, confirmed by the user.
        return \\RunletRunner\\RedisTab::kill(\(clientId), \(phpBytes(address)), \(phpBytes(runId)), \(listedBy), \(phpString(connection)));
        """
    }
}

/// Load More for a Redis reply (#190): the command that reads the next page, or nil.
public enum RedisPaging {
    /// SCAN/HSCAN/SSCAN/ZSCAN with the reply's cursor; LRANGE/ZRANGE/ZREVRANGE (by index) for
    /// the elements after the ones shown. `shown` is how many rows the reply holds so far.
    public static func next(arguments: [[UInt8]], view: RedisReplyView, shown: Int) -> [[UInt8]]? {
        let strings = arguments.map { String(decoding: $0, as: UTF8.self) }
        let key = RedisCommands.key(strings)
        var next = arguments
        switch key {
        case "SCAN":
            guard let cursor = view.cursor, cursor != "0", arguments.count >= 2 else { return nil }
            next[1] = Array(cursor.utf8)
            return next
        case "HSCAN", "SSCAN", "ZSCAN":
            guard let cursor = view.cursor, cursor != "0", arguments.count >= 3 else { return nil }
            next[2] = Array(cursor.utf8)
            return next
        case "LRANGE", "ZRANGE", "ZREVRANGE":
            let upper = strings.map { $0.uppercased() }
            guard view.omitted > 0, arguments.count >= 4, !upper.contains("BYSCORE"), !upper.contains("BYLEX"), !upper.contains("REV") || key == "ZREVRANGE",
                  let start = Int(strings[2]), start >= 0, let stop = Int(strings[3]) else { return nil }
            let first = start + shown
            if stop >= 0, first > stop { return nil }
            next[2] = Array(String(first).utf8)
            return next
        default:
            return nil
        }
    }
}
