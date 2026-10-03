import Foundation

/// Why Runlet doesn't send a statement on a read-only saved connection (#139). The database
/// refuses writes in a read-only session, but a session can switch itself back, and a few
/// writes slip past some databases (MySQL's temporary tables, functions with side effects), so
/// Runlet refuses these before anything is sent (and the runner refuses them again).
public enum SQLReadOnlyRefusal: Sendable, Equatable {
    /// The statement changes whether the session is read-only: `SET SESSION TRANSACTION READ
    /// WRITE`, `SET default_transaction_read_only`, `BEGIN … READ WRITE`, `RESET ALL`,
    /// `PRAGMA query_only`, `set_config()`, …
    case sessionChange(String)
    /// It can change data, the schema, or the session's settings (`SQLScript.Effect.write`).
    case write(String)
    /// Runlet can't tell whether it changes data (`SQLScript.Effect.unknown`).
    case unknown(String)

    /// What the statement does, after its subject: "can change data or the schema (INSERT)".
    public var predicate: String {
        switch self {
        case .sessionChange(let phrase):
            "would make the read-only session writable again (\(phrase))"
        case .write(let keyword) where ["SET", "RESET"].contains(keyword):
            "changes the session's settings (\(keyword)), which could make it writable again"
        case .write(let keyword):
            "can change data or the schema (\(keyword))"
        case .unknown(let keyword):
            keyword.isEmpty
                ? "is one Runlet can't classify, so it can't tell whether it changes data"
                : "starts with \(keyword), and Runlet can't tell whether it changes data"
        }
    }

    /// The alert's title for a statement refused on `connection`.
    public static func title(connection: String) -> String {
        "“\(connection)” is read-only"
    }

    /// One statement (Run, Run Selection).
    public func message(connection: String) -> String {
        "This statement \(predicate), so Runlet doesn't send it on the read-only connection “\(connection)”. Nothing ran.\n\n" + Self.advice
    }

    /// Run All Statements: the first refused statement stops the whole script before anything
    /// runs. `others` is how many more statements would be refused.
    public func message(connection: String, index: Int, count: Int, line: Int, others: Int = 0) -> String {
        let more = others == 0 ? "" : others == 1 ? " One more statement would be refused too." : " \(others) more statements would be refused too."
        return "Statement \(index) of \(count) (line \(line)) \(predicate), so Runlet runs none of the script on the read-only connection “\(connection)”. Nothing ran.\(more)\n\n" + Self.advice
    }

    static let advice = "To change data, use a saved connection without Read-only, or turn Read-only off in this connection's settings. For a guarantee, connect as a database user that can only read."
}

extension SQLScript {
    /// Settings whose change switches a session between read-only and read-write: MySQL and
    /// MariaDB (`transaction_read_only`, older `tx_read_only`), PostgreSQL
    /// (`default_transaction_read_only`, `transaction_read_only`), SQLite (`query_only`).
    static let readOnlySettings: Set<String> = ["TRANSACTION_READ_ONLY", "TX_READ_ONLY", "DEFAULT_TRANSACTION_READ_ONLY", "QUERY_ONLY"]

    /// Why `statement` isn't sent on a read-only saved connection (#139); nil when it may run.
    /// Refused: statements that change the session's read-only state, statements `effect`
    /// classifies as writing or unknown, and anything after a `;` in the same text. Allowed:
    /// reads, and transaction control that doesn't ask for READ WRITE (`BEGIN`, `COMMIT`,
    /// `ROLLBACK`, `SAVEPOINT`, …), which can't change data in a read-only session. Keywords
    /// in comments, strings, and quoted names don't count; case doesn't matter.
    ///
    /// Databases read some text differently from the editor's lexer, so the statement is
    /// checked as `driver` reads it, and refused if any reading is: MySQL's backslash escapes
    /// in strings and executable comments (`/*! … */`, MariaDB's `/*M! … */`); PostgreSQL's `#`
    /// operator (a comment in MySQL) and `E'…'` strings with backslash escapes; SQLite's `#`.
    /// Without a driver, every reading counts.
    public static func readOnlyRefusal(of statement: String, driver: DatabaseDriverKind? = nil) -> SQLReadOnlyRefusal? {
        for reading in readings(of: statement, driver: driver) {
            let string = reading.text as NSString
            if let refusal = readOnlyRefusal(tokens: tokenize(string, backslashEscapes: reading.backslashEscapes, hashComments: reading.hashComments), in: string) {
                return refusal
            }
        }
        return nil
    }

    /// The ways `driver` could read `statement` (see `readOnlyRefusal(of:driver:)`).
    static func readings(of statement: String, driver: DatabaseDriverKind?) -> [(text: String, backslashEscapes: Bool, hashComments: Bool)] {
        let backslash = statement.contains("\\")
        let executable = statement.range(of: #"/\*M?!"#, options: .regularExpression) != nil
        var readings: [(text: String, backslashEscapes: Bool, hashComments: Bool)] = []
        if driver == nil || driver == .mysql {
            readings.append((statement, false, true))
            if backslash { readings.append((statement, true, true)) }
            if executable {
                let opened = statement.replacingOccurrences(of: #"/\*M?![0-9]*"#, with: " ", options: .regularExpression)
                readings.append((opened, false, true))
                if backslash { readings.append((opened, true, true)) }
            }
        }
        if driver != .mysql {
            readings.append((statement, false, false))
            if backslash, driver != .sqlite { readings.append((statement, true, false)) }
        }
        return readings
    }

    static func readOnlyRefusal(tokens all: [Token], in string: NSString) -> SQLReadOnlyRefusal? {
        let tokens = all.filter { $0.kind != .comment }
        guard !tokens.isEmpty else { return nil }
        // Only the first statement would run: the runner and the databases refuse or ignore the
        // rest, but a read-only connection doesn't send it at all.
        if let semicolon = tokens.firstIndex(where: { $0.kind == .semicolon }), tokens[(semicolon + 1)...].contains(where: { $0.kind != .semicolon }) {
            return .unknown("several statements")
        }
        if let phrase = readOnlySessionChange(tokens: tokens, in: string) {
            return .sessionChange(phrase)
        }
        if transactionControl(words: firstWords(tokens: tokens, in: string, count: 2)) != nil { return nil }
        switch effect(tokens: tokens, in: string) {
        case .read: return nil
        case .write(let keyword): return .write(keyword)
        case .unknown(let keyword): return .unknown(keyword)
        }
    }

    /// The phrase naming how `tokens` (comments removed) would undo a read-only session, if
    /// they would.
    static func readOnlySessionChange(tokens: [Token], in string: NSString) -> String? {
        func word(_ token: Token) -> String? {
            switch token.kind {
            case .keyword, .word:
                // MySQL's system variables: `@@tx_read_only`, `@@session.transaction_read_only`.
                let text = string.substring(with: token.range).uppercased()
                return text.hasPrefix("@@") ? String(text.drop { $0 == "@" }) : text
            case .quotedIdentifier:
                // `transaction_read_only`, "query_only"
                let text = string.substring(with: token.range)
                return text.count >= 2 ? String(text.dropFirst().dropLast()).uppercased() : nil
            default:
                return nil
            }
        }
        let words = tokens.map(word)
        let named = words.compactMap { $0 }
        guard let first = named.first else { return nil }
        // set_config() changes any setting from inside a SELECT (PostgreSQL), including
        // default_transaction_read_only for the session's later transactions.
        if named.contains("SET_CONFIG") { return "set_config()" }
        if let setting = named.first(where: { readOnlySettings.contains($0) }) {
            switch first {
            case "SET": return "SET \(setting.lowercased())"
            case "RESET": return "RESET \(setting.lowercased())"
            case "PRAGMA": return "PRAGMA \(setting.lowercased())"
            case "ALTER": return "ALTER … SET \(setting.lowercased())"
            default: break // Reading it (SHOW, SELECT @@transaction_read_only) is fine.
            }
        }
        let readWrite = words.indices.dropLast().contains { words[$0] == "READ" && words[$0 + 1] == "WRITE" }
        switch first {
        case "SET":
            if named.contains("CHARACTERISTICS") { return readWrite ? "SET SESSION CHARACTERISTICS … READ WRITE" : "SET SESSION CHARACTERISTICS" }
            if readWrite { return "SET TRANSACTION READ WRITE" }
        case "START", "BEGIN":
            if readWrite { return first == "START" ? "START TRANSACTION READ WRITE" : "BEGIN … READ WRITE" }
        case "RESET":
            if named.count > 1, named[1] == "ALL" { return "RESET ALL" }
        case "DISCARD":
            if named.count > 1, named[1] == "ALL" { return "DISCARD ALL" }
        default:
            break
        }
        return nil
    }
}
