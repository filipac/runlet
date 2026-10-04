import Foundation
@testable import RunletCore
import Testing

/// Redis project and personal snippets (#205): the `#` metadata block (the parser `.mongodb`
/// files share), inputs filled as quoted Redis arguments, `.redis` files that round-trip, and
/// the connection they open on.
struct RedisSnippetsTests {
    static let file = """
    # @title Inspect a user's
    #   session
    # @description The session hash and its TTL
    # @connection Cache (saved)
    # @input string $user "User id" = "42"
    # @input int $count "How many" = 10

    # Look the session up first.
    HGETALL session:$user
    TTL session:$user
    SET '$user' "$user"
    SCAN 0 MATCH ${user}_lock* COUNT $count
    """

    /// The arguments of every command line of `text`, as text.
    private func arguments(_ text: String) -> [[String]] {
        RedisScript.lines(in: text).map { line in
            guard case .success(let arguments) = line.parsed else { return ["<\(line.text)>"] }
            return arguments.map { String(decoding: $0, as: UTF8.self) }
        }
    }

    @Test func headerAndCommandsSplit() throws {
        let (inputs, body, header) = RedisSnippets.parse("\n" + Self.file)
        let parsed = try #require(header)
        #expect(parsed.title == "Inspect a user's session")
        #expect(parsed.description == "The session hash and its TTL")
        #expect(parsed.connection == "Cache (saved)")
        #expect(inputs.inputs.map(\.name) == ["user", "count"] && inputs.problems.isEmpty)
        // The blank line ends the block: later comments stay in the commands.
        #expect(body.hasPrefix("# Look the session up first.\nHGETALL session:$user"))
        #expect(!body.contains("@input"))
        // `@label` is `@title`; a comment block without tags is part of the commands.
        #expect(RedisSnippets.parse("# @label Keys\nDBSIZE").header?.title == "Keys")
        let plain = RedisSnippets.parse("# Count the keys\nDBSIZE\n")
        #expect(plain.header == nil && plain.body == "# Count the keys\nDBSIZE" && plain.inputs.isEmpty)
        // An unreadable declaration is a problem; the snippet still opens.
        #expect(RedisSnippets.parse("# @input text $x\nGET $x").inputs.problems.count == 1)
    }

    @Test func redisAndMongoHeadersShareTheParser() throws {
        let lines = ["@title Orders", "@description Newest", "  first", "@connection reporting", "@input string $id \"Id\" = \"a b\""]
        let redis = DatabaseSnippetHeader.split(Substring(lines.map { "# " + $0 }.joined(separator: "\n") + "\n\nGET x"), marker: "#").header
        let mongo = DatabaseSnippetHeader.split(Substring(lines.map { "// " + $0 }.joined(separator: "\n") + "\n\n{}"), marker: "//").header
        #expect(redis != nil && redis == mongo)
        #expect(RedisSnippets.marker == DatabaseSnippetHeader.marker(for: .redis))
        // Both write the block back the same way, with their own marker.
        let header = try #require(redis)
        #expect(header.lines(marker: "#").map { $0.dropFirst(1) } == header.lines(marker: "//").map { $0.dropFirst(2) })
        #expect(RedisSnippets.parse(RedisSnippets.code(header: header, body: "GET x")).header == header)
    }

    @Test func inputsBecomeQuotedArguments() {
        let (_, body, _) = RedisSnippets.parse(Self.file)
        let filled = RedisSnippets.substitute(body, values: ["user": .string("ada lovelace"), "count": .int(100)])
        #expect(filled == """
        # Look the session up first.
        HGETALL "session:ada lovelace"
        TTL "session:ada lovelace"
        SET '$user' "$user"
        SCAN 0 MATCH "ada lovelace_lock*" COUNT 100
        """, "\(filled)")
        #expect(arguments(filled) == [
            ["HGETALL", "session:ada lovelace"], ["TTL", "session:ada lovelace"], ["SET", "$user", "$user"],
            ["SCAN", "0", "MATCH", "ada lovelace_lock*", "COUNT", "100"],
        ])
    }

    @Test func valuesAreNeverSplicedAsText() {
        let values: [String] = [
            "two words", #"say "hi""#, "it's", "line\nFLUSHALL", "tab\there", #"back\slash"#, "\r\n", "", "ünïcödé ✓", "#not a comment",
            "\"; FLUSHALL; \"", "x\" y", "\\x41", "$user", "\u{0}", "a\u{7f}b",
        ]
        for value in values {
            let lines: [(String, String)] = [
                ("SET $v 1", value), ("SET key:$v 1", "key:" + value), ("SET ${v}:tail 1", value + ":tail"), ("SET $v\"quoted \" 1", value + "quoted "),
            ]
            for (line, expected) in lines {
                let filled = RedisSnippets.substitute(line, values: ["v": .string(value)])
                let commands = RedisScript.lines(in: filled)
                // Still one command line with three arguments, whatever the value holds.
                #expect(commands.count == 1, "\(value.debugDescription) in \(line): \(filled)")
                guard case .success(let parsed) = commands.first?.parsed else {
                    Issue.record("\(filled) doesn't parse")
                    continue
                }
                #expect(parsed.count == 3 && String(decoding: parsed[1], as: UTF8.self) == expected, "\(filled)")
                #expect(Array(expected.utf8) == parsed[1], "bytes of \(filled)")
            }
            // As the command's name, too: a value starting with `#` doesn't make the line a comment.
            let named = RedisSnippets.substitute("$v key", values: ["v": .string(value)])
            #expect(RedisScript.lines(in: named).first?.command?.arguments == [Array(value.utf8), Array("key".utf8)], "\(named)")
        }
    }

    @Test func placeholdersFollowTheRules() {
        func fill(_ text: String, _ values: [String: SnippetInputValue] = ["id": .int(7), "user": .string("ada")]) -> String {
            RedisSnippets.substitute(text, values: values)
        }
        // Whole arguments and parts of them; `${name}` when a name character follows.
        #expect(fill("GET user:$id:name") == "GET user:7:name")
        #expect(fill("GET ${user}_lock $user_lock") == "GET ada_lock $user_lock", "the longest name, which isn't an input")
        // Inside quotes, undeclared, malformed, or a lone `$`: text.
        #expect(fill("ECHO '$id' \"${user}\" $other ${id $ $1 ${} ${1x}") == "ECHO '$id' \"${user}\" $other ${id $ $1 ${} ${1x}")
        // A quoted part after a placeholder joins its argument.
        #expect(fill("SET $user\" x\" 1") == "SET \"ada x\" 1")
        // Comment lines, and lines Runlet can't read, stay as written.
        #expect(fill("  # GET $id\nGET \"$id\nGET $id") == "  # GET $id\nGET \"$id\nGET 7")
        #expect(fill("GET \"a\"$id") == "GET \"a\"$id")
        // Line breaks and spacing stay; only filled arguments change.
        #expect(fill("GET   'x y'\t$id\r\nDEL $id\rTTL $id\n") == "GET   'x y'\t7\r\nDEL 7\rTTL 7\n")
        #expect(fill("GET $id", [:]) == "GET $id")
        // Every kind of value.
        #expect(RedisSnippets.quotedArgument(.int(-3)) == "-3")
        #expect(RedisSnippets.quotedArgument(.float(2.5)) == "2.5" && RedisSnippets.quotedArgument(.float(3)) == "3.0")
        #expect(RedisSnippets.quotedArgument(.float(-.infinity)) == "-inf")
        #expect(RedisSnippets.quotedArgument(.bool(true)) == "1" && RedisSnippets.quotedArgument(.bool(false)) == "0")
        #expect(RedisSnippets.quotedArgument(.string("")) == "\"\"")
        #expect(RedisSnippets.quotedArgument(.string("a\nb")) == "\"a\\nb\"")
        #expect(RedisSnippets.quotedArgument(.string("O'Neil")) == "\"O'Neil\"")
        // Unicode names, as PHP variables may have.
        #expect(fill("GET k:$ñame", ["ñame": .string("x")]) == "GET k:x")
    }

    @Test func projectFilesLoadAndRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("p205-snippets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = ProjectSnippets.directory(projectRoot: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(Self.file.utf8).write(to: folder.appendingPathComponent("user-session.redis"))
        try Data("DBSIZE\n".utf8).write(to: folder.appendingPathComponent("count-keys.REDIS"))
        let loaded = ProjectSnippets.load(projectRoot: root)
        #expect(loaded.map(\.label) == ["count-keys", "Inspect a user's session"])
        let snippet = try #require(loaded.last)
        #expect(snippet.language == .redis && snippet.description == "The session hash and its TTL")
        #expect(snippet.connection == .saved(name: "Cache"))
        #expect(snippet.inputs.inputs.map(\.name) == ["user", "count"])
        #expect(snippet.code.hasPrefix("# Look the session up first.\nHGETALL session:$user") && !snippet.code.contains("@title"))
        #expect(loaded.first?.language == .redis && loaded.first?.code == "DBSIZE" && loaded.first?.connection == nil)

        // A personal copy keeps the inputs as `# @input` lines, and opens with the same commands.
        #expect(snippet.personalCode.hasPrefix("# @input string $user \"User id\" = \"42\"\n# @input int $count \"How many\" = 10\n\n# Look the session up first.\n"))
        let personal = Snippet(label: snippet.label, code: snippet.personalCode, language: .redis, connection: snippet.connection)
        #expect(personal.inputs.inputs.map(\.name) == ["user", "count"] && personal.openingCode == snippet.code)
        #expect(personal.connection == .saved(name: "Cache"))
        // A personal Redis snippet without a header opens as saved.
        #expect(Snippet(label: "Keys", code: "DBSIZE", language: .redis).openingCode == "DBSIZE")

        // Saving a Redis tab writes `# @title`, `# @description`, `# @connection`, and the commands.
        #expect(ProjectSnippets.fileName(forLabel: "Clear a stuck lock!", language: .redis) == "clear-a-stuck-lock.redis")
        let url = try ProjectSnippets.save(label: "Rate limits", description: "Counters\nper user", code: "\nSCAN 0 MATCH rate:* COUNT 100\nTTL 'rate:a b'\n\n",
                                           projectRoot: root, language: .redis, connection: .application("cache"))
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(url.lastPathComponent == "rate-limits.redis")
        #expect(written == "# @title Rate limits\n# @description Counters per user\n# @connection cache\n\nSCAN 0 MATCH rate:* COUNT 100\nTTL 'rate:a b'\n", "\(written)")
        let reread = ProjectSnippets.parse(written, fileURL: url)
        #expect(reread.label == "Rate limits" && reread.description == "Counters per user" && reread.connection == .named("cache") && reread.language == .redis)
        #expect(reread.code == "SCAN 0 MATCH rate:* COUNT 100\nTTL 'rate:a b'")
        // A saved connection keeps the marker; the default connection writes nothing.
        let saved = ProjectSnippets.fileContents(label: "x", description: nil, code: "PING", language: .redis, connection: .saved(name: "Cache", id: UUID()))
        #expect(saved == "# @title x\n# @connection Cache (saved)\n\nPING\n")
        #expect(ProjectSnippets.fileContents(label: "x", description: nil, code: "PING", language: .redis, connection: .application(nil)) == "# @title x\n\nPING\n")
        // Saving the reread snippet again writes the same file.
        #expect(ProjectSnippets.fileContents(label: reread.label, description: reread.description, code: reread.code, language: .redis, connection: reread.connection) == written)
        // A tab whose text already has inputs keeps them; its other comments stay in the commands.
        let withInputs = ProjectSnippets.fileContents(label: "Unlock", description: nil, code: "# @input string $job \"Job\"\n\n# Careful\nDEL lock:$job", language: .redis)
        #expect(withInputs == "# @title Unlock\n# @input string $job \"Job\"\n\n# Careful\nDEL lock:$job\n")
        #expect(throws: ProjectSnippets.SaveError.self) { try ProjectSnippets.save(label: "x", description: nil, code: "PING", projectRoot: root, fileName: "x.php", language: .redis) }
    }

    @Test func connectionsResolveByFamily() {
        let target = TargetRef.local(UUID())
        var library = TargetLibrary()
        let redis = library.saveDatabaseConnection(DatabaseConnection(name: "Cache", scope: target, driver: .redis, host: "cache"))
        _ = library.saveDatabaseConnection(DatabaseConnection(name: "Reporting", scope: target, driver: .pgsql, host: "db"))
        let shared = library.saveDatabaseConnection(DatabaseConnection(name: "Sessions", scope: nil, driver: .redis, host: "cache"))
        func connection(_ line: String) -> SQLConnectionReference? {
            ProjectSnippets.parse("# @connection \(line)\nPING", fileURL: URL(fileURLWithPath: "/p/.runlet/snippets/a.redis")).connection
        }
        // A bare name: the target's saved Redis connection (names ignore case), then one of all targets…
        #expect(library.resolve(connection("cache")!, on: target, family: .redis) == .saved(redis))
        #expect(library.resolve(connection("Sessions")!, on: target, family: .redis) == .saved(shared))
        // …else the application's Redis connection with that name, never an SQL connection.
        #expect(library.resolve(connection("Reporting")!, on: target, family: .redis) == .application("Reporting"))
        #expect(library.resolve(connection("default")!, on: target, family: .redis) == .application("default"))
        // `(saved)`: only a saved connection; missing, the tab gets the default and a note.
        #expect(library.resolve(connection("Cache (saved)")!, on: target, family: .redis) == .saved(redis))
        #expect(library.resolve(connection("Reporting (saved)")!, on: target, family: .redis) == .missing("Reporting"))
        #expect(connection("") == nil)
        #expect(SQLConnectionReference.missingNote("Reporting", source: "snippet").contains("Reporting"))
    }
}
