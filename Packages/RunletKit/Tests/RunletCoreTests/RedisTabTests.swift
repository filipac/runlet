import Foundation
import Testing
@testable import RunletCore

/// Redis tabs (#190): parsing commands the way redis-cli does, what Run and Run All send,
/// passwords in typed commands, the command table (reads, writes, dangerous, unknown), reply
/// mapping, Load More, the generated PHP, and the `redis` connection kind.
struct RedisTabTests {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    // MARK: Parsing

    @Test func parsesLikeRedisCli() throws {
        #expect(try RedisScript.parse("SET key value").get() == [bytes("SET"), bytes("key"), bytes("value")])
        #expect(try RedisScript.parse("  GET   spaced  ").get() == [bytes("GET"), bytes("spaced")])
        #expect(try RedisScript.parse(#"SET "a b" 'c d'"#).get() == [bytes("SET"), bytes("a b"), bytes("c d")])
        #expect(try RedisScript.parse(#"SET k "line\nnext\t\"q\" \\""#).get()[2] == bytes("line\nnext\t\"q\" \\"))
        #expect(try RedisScript.parse(#"SET k "\xff\x00A""#).get()[2] == [0xFF, 0x00, 0x41])
        #expect(try RedisScript.parse(#"SET k 'it\'s'"#).get()[2] == bytes("it's"))
        // \x without two hex digits keeps the x; single quotes keep backslashes.
        #expect(try RedisScript.parse(#"SET k "\xZ""#).get()[2] == bytes("xZ"))
        #expect(try RedisScript.parse(#"SET k 'a\nb'"#).get()[2] == bytes(#"a\nb"#))
        #expect(try RedisScript.parse(#"SET k """#).get()[2] == [])
        #expect(try RedisScript.parse("HSET user:1 name Ada").get().count == 4)
        #expect(RedisScript.parse(#"SET k "open"#) == .failure(.unbalancedQuotes))
        #expect(RedisScript.parse(#"SET k 'open"#) == .failure(.unbalancedQuotes))
        #expect(RedisScript.parse(#"SET k "a"b"#) == .failure(.quoteNotFollowedBySpace))
        // Unicode passes through as UTF-8.
        #expect(try RedisScript.parse("SET k café").get()[2] == bytes("café"))
    }

    @Test func linesSkipBlanksAndComments() {
        let text = "# a comment\nPING\n\n   # indented comment\n  GET a  \nSET \"broken\n"
        let lines = RedisScript.lines(in: text)
        #expect(lines.map(\.line) == [2, 5, 6])
        #expect(lines[1].text == "GET a")
        #expect((text as NSString).substring(with: lines[1].range) == "GET a")
        #expect(lines[2].parsed == .failure(.unbalancedQuotes))
    }

    @Test func runPicksTheCaretsLine() throws {
        let text = "PING\n\nGET a\nGET b\n"
        func command(at caret: Int) throws -> RedisScript.Command {
            try RedisScript.commandToRun(in: text, selection: NSRange(location: caret, length: 0)).get()
        }
        #expect(try command(at: 0).name == "PING")
        #expect(try command(at: 3).text == "PING")
        // A blank line: the next command.
        #expect(try command(at: 5).text == "GET a")
        #expect(try command(at: 8).text == "GET a")
        #expect(try command(at: 12).text == "GET b")
        // After the last line: the last command.
        #expect(try command(at: (text as NSString).length).text == "GET b")
        #expect(try command(at: 12).line == 4)
        #expect(RedisScript.commandToRun(in: "# only\n\n", selection: NSRange(location: 0, length: 0)) == .failure(.empty))
        #expect(RedisScript.commandToRun(in: text, selection: NSRange(location: 0, length: 0), selectionOnly: true) == .failure(.nothingSelected))
    }

    @Test func selectionHoldsOneCommandForRunAndAnyForRunAll() throws {
        let text = "PING\nGET a\nGET b"
        let both = (text as NSString).range(of: "GET a\nGET b")
        #expect(RedisScript.commandToRun(in: text, selection: both) == .failure(.multipleCommands(count: 2)))
        let all = try RedisScript.commandsToRunAll(in: text, selection: both).get()
        #expect(all.map(\.line) == [2, 3])
        #expect(all.map { (text as NSString).substring(with: $0.range) } == ["GET a", "GET b"])
        let one = try RedisScript.commandToRun(in: text, selection: (text as NSString).range(of: "GET b")).get()
        #expect(one.line == 3 && one.strings == ["GET", "b"])
        #expect(try RedisScript.commandsToRunAll(in: text, selection: NSRange(location: 0, length: 0)).get().count == 3)
        if case .failure(.parse(let line, _)) = RedisScript.commandsToRunAll(in: "PING\nGET \"x", selection: NSRange(location: 0, length: 0)) {
            #expect(line == 2)
        } else {
            Issue.record("a broken line refuses Run All")
        }
    }

    @Test func passwordsAreRedacted() {
        func shown(_ line: String) -> String { RedisScript.redacted(line) }
        #expect(shown("AUTH s3cret") == "AUTH •••")
        #expect(shown("AUTH reader s3cret") == "AUTH reader •••")
        #expect(shown("HELLO 3 AUTH reader s3cret SETNAME me") == "HELLO 3 AUTH reader ••• SETNAME me")
        #expect(shown("MIGRATE host 6379 key 0 5000 AUTH s3cret") == "MIGRATE host 6379 key 0 5000 AUTH •••")
        #expect(shown("MIGRATE host 6379 key 0 5000 AUTH2 user s3cret") == "MIGRATE host 6379 key 0 5000 AUTH2 user •••")
        #expect(shown("ACL SETUSER bob on >s3cret ~* +@read") == "ACL SETUSER bob on ••• \"~*\" +@read" || shown("ACL SETUSER bob on >s3cret ~* +@read") == "ACL SETUSER bob on ••• ~* +@read")
        #expect(shown("CONFIG SET requirepass s3cret") == "CONFIG SET requirepass •••")
        #expect(shown("CONFIG SET maxmemory 1gb masterauth s3cret") == "CONFIG SET maxmemory 1gb masterauth •••")
        #expect(shown("GET plain") == "GET plain")
        // A whole tab: only the secret lines change.
        #expect(shown("PING\nAUTH s3cret\nGET a") == "PING\nAUTH •••\nGET a")
        // A line Runlet can't read keeps only the command.
        #expect(shown("AUTH \"s3cret") == "AUTH •••")
        #expect(!shown("auth Secret-Pa55").contains("Secret-Pa55"))
    }

    @Test func quotingRoundTrips() throws {
        for value in ["plain", "with space", "quote\"inside", "tab\tand\nnewline", "back\\slash", "café", ""] {
            let quoted = RedisScript.quoted(value)
            #expect(try RedisScript.parse("SET k \(quoted)").get()[2] == bytes(value), "\(value) → \(quoted)")
        }
        let binary: [UInt8] = [0xFF, 0x00, 0x41]
        #expect(try RedisScript.parse("GET \(RedisScript.quoted(binary))").get()[1] == binary)
    }

    // MARK: Classification

    @Test func classifiesReadsWritesAndUnknown() {
        func access(_ line: String) -> RedisCommands.Access { RedisCommands.classify(line.split(separator: " ").map(String.init)).access }
        #expect(access("GET a") == .read)
        #expect(access("hgetall user:1") == .read)
        #expect(access("ZRANGE z 0 -1 WITHSCORES") == .read)
        #expect(access("SCAN 0 MATCH p190:* COUNT 100") == .read)
        #expect(access("CONFIG GET maxmemory") == .read)
        #expect(access("CLIENT LIST") == .read)
        #expect(access("INFO keyspace") == .read)
        #expect(access("XRANGE s - +") == .read)
        #expect(access("EVAL_RO return 1 0") == .read)
        #expect(access("SET a 1") == .write)
        #expect(access("DEL a") == .write)
        #expect(access("BLPOP q 0") == .write)
        #expect(access("XREADGROUP GROUP g c STREAMS s >") == .write)
        #expect(access("EVAL return 1 0") == .write)
        #expect(access("CONFIG SET maxmemory 1gb") == .write)
        #expect(access("ACL LOG") == .read)
        #expect(access("ACL LOG RESET") == .write)
        #expect(access("SELECT 2") == .connection)
        #expect(access("AUTH pw") == .connection)
        #expect(access("MULTI") == .transaction)
        #expect(access("SUBSCRIBE news") == .streaming)
        #expect(access("MONITOR") == .streaming)
        #expect(access("CLIENT REPLY OFF") == .streaming)
        #expect(access("FT.SEARCH idx hello") == .unknown)
        #expect(access("CONFIG FROBNICATE") == .unknown)
        #expect(RedisCommands.classify(["BLPOP", "q", "0"]).blocking)
        #expect(RedisCommands.classify(["XREAD", "BLOCK", "0", "STREAMS", "s", "$"]).blocking)
        #expect(!RedisCommands.classify(["XREAD", "STREAMS", "s", "0"]).blocking)
    }

    @Test func dangerousCommandsAreNamed() {
        for line in ["FLUSHALL", "FLUSHDB ASYNC", "KEYS *", "DEBUG SLEEP 0", "SHUTDOWN NOSAVE", "CONFIG SET maxmemory 1", "CONFIG REWRITE", "SCRIPT FLUSH", "CLIENT KILL ID 5", "MIGRATE h 1 k 0 1", "SWAPDB 0 1", "REPLICAOF NO ONE", "SLAVEOF h 1", "MODULE LOAD /x.so", "ACL SETUSER bob on", "ACL DELUSER bob", "FUNCTION FLUSH", "FUNCTION DELETE lib"] {
            let info = RedisCommands.classify(line.split(separator: " ").map(String.init))
            #expect(info.dangerous, "\(line)")
            #expect(info.danger?.isEmpty == false, "\(line)")
        }
        #expect(RedisCommands.classify(["KEYS", "*"]).danger?.contains("SCAN") == true)
        #expect(RedisCommands.classify(["CONFIG", "SET", "x", "y"]).name == "CONFIG SET")
        for line in ["GET a", "SCAN 0", "CONFIG GET x", "CLIENT LIST", "DEL a", "FLUSHX"] {
            #expect(!RedisCommands.classify(line.split(separator: " ").map(String.init)).dangerous, "\(line)")
        }
    }

    @Test func readOnlyRefusesWritesAndUnknown() {
        #expect(RedisCommands.readOnlyRefusal(["GET", "a"]) == nil)
        #expect(RedisCommands.readOnlyRefusal(["MULTI"]) == nil)
        #expect(RedisCommands.readOnlyRefusal(["SELECT", "3"]) == nil)
        #expect(RedisCommands.readOnlyRefusal(["KEYS", "*"]) == nil, "KEYS reads; it is dangerous, which confirms")
        #expect(RedisCommands.readOnlyRefusal(["SET", "a", "1"]) == "can change data or the server (SET)")
        #expect(RedisCommands.readOnlyRefusal(["FLUSHALL"]) == "can change data or the server (FLUSHALL)")
        #expect(RedisCommands.readOnlyRefusal(["config", "set", "a", "b"]) == "can change data or the server (CONFIG SET)")
        #expect(RedisCommands.readOnlyRefusal(["FT.CREATE", "idx"])?.contains("doesn't know") == true)
        #expect(RedisCommands.refusal(["SUBSCRIBE", "news"])?.contains("redis-cli") == true)
        #expect(RedisCommands.refusal(["GET", "a"]) == nil)
    }

    @Test func tableHasNoOverlaps() {
        let sets: [(String, Set<String>)] = [("reads", RedisCommands.reads), ("connection", RedisCommands.connection), ("transaction", RedisCommands.transaction), ("streaming", RedisCommands.streaming), ("writes", RedisCommands.writes)]
        for (index, (name, set)) in sets.enumerated() {
            for (other, otherSet) in sets[(index + 1)...] {
                #expect(set.isDisjoint(with: otherSet), "\(name) and \(other): \(set.intersection(otherSet))")
            }
        }
        // Dangerous commands are writes, except KEYS (a read that blocks the server).
        for name in RedisCommands.dangerous.keys where name != "KEYS" {
            #expect(!RedisCommands.reads.contains(name), "\(name)")
        }
    }

    // MARK: Replies

    private func decode(_ json: String) throws -> RedisReplyInfo {
        try JSONDecoder().decode(RedisReplyInfo.self, from: Data(json.utf8))
    }

    @Test func decodesEveryReplyType() throws {
        let tree = #"{"t":"*","v":[{"t":"s","v":"text"},{"t":"s","v":"cut","o":10},{"t":"x","n":3,"h":"FF00FE"},{"t":"+","v":"OK"},{"t":"-","v":"ERR no"},{"t":"i","v":42},{"t":"d","v":"1.5"},{"t":"b","v":true},{"t":"n"},{"t":"~","v":[{"t":"s","v":"m"}]},{"t":"%","v":[[{"t":"s","v":"k"},{"t":"i","v":1}]],"o":2}],"o":7}"#
        let value = try JSONDecoder().decode(RedisValue.self, from: Data(tree.utf8))
        guard case .array(let items, let omitted) = value else { Issue.record("array"); return }
        #expect(omitted == 7)
        #expect(items[0] == .string("text"))
        #expect(items[1] == .clipped("cut", omittedBytes: 10))
        #expect(items[2] == .binary(bytes: 3, hexPrefix: "FF00FE"))
        #expect(items[3] == .status("OK"))
        #expect(items[4] == .error("ERR no"))
        #expect(items[5] == .integer(42))
        #expect(items[6] == .double("1.5"))
        #expect(items[7] == .bool(true))
        #expect(items[8] == .null)
        #expect(items[9] == .set([.string("m")], omitted: 0))
        #expect(items[10] == .map([RedisPair(key: .string("k"), value: .integer(1))], omitted: 2))
        // Round trip.
        #expect(try JSONDecoder().decode(RedisValue.self, from: JSONEncoder().encode(value)) == value)
        #expect(value.cliText().hasPrefix(" 1) \"text\"\n 2) \"cut\" (truncated)"))
    }

    @Test func repliesBecomeTablesByCommand() throws {
        let hash = try decode(#"{"argv":["HGETALL","user:1"],"reply":{"t":"*","v":[{"t":"s","v":"name"},{"t":"s","v":"Ada"},{"t":"s","v":"role"},{"t":"s","v":"admin"}]}}"#)
        #expect(hash.view.kind == .hash)
        #expect(hash.view.table.columns == ["field", "value"])
        #expect(hash.view.table.rows.map { $0.map(\.text) } == [["name", "Ada"], ["role", "admin"]])
        #expect(hash.summary == "2 fields")

        let zset = try decode(#"{"argv":["ZRANGE","board","0","-1","WITHSCORES"],"reply":{"t":"*","v":[{"t":"s","v":"ada"},{"t":"s","v":"12"},{"t":"s","v":"bob"},{"t":"s","v":"7.5"}]}}"#)
        #expect(zset.view.kind == .zset)
        #expect(zset.view.table.columns == ["member", "score"])
        #expect(zset.view.table.rows[1][1].number == 7.5)

        let resp3 = try decode(#"{"argv":["ZRANGE","board","0","-1","WITHSCORES"],"reply":{"t":"*","v":[{"t":"*","v":[{"t":"s","v":"ada"},{"t":"d","v":"12"}]}]}}"#)
        #expect(resp3.view.kind == .zset && resp3.view.table.rows.count == 1)

        let set = try decode(#"{"argv":["SMEMBERS","tags"],"reply":{"t":"*","v":[{"t":"s","v":"a"},{"t":"s","v":"b"}]}}"#)
        #expect(set.view.kind == .set && set.summary == "2 members")

        let list = try decode(#"{"argv":["LRANGE","q","10","11"],"reply":{"t":"*","v":[{"t":"s","v":"x"},{"t":"s","v":"y"}],"o":5}}"#)
        #expect(list.view.kind == .list)
        #expect(list.view.table.rowKeys == ["10", "11"])
        #expect(list.summary == "First 2 of 7 elements")

        let scan = try decode(#"{"argv":["SCAN","0","MATCH","p190:*"],"reply":{"t":"*","v":[{"t":"s","v":"17"},{"t":"*","v":[{"t":"s","v":"p190:a"},{"t":"s","v":"p190:b"}]}]}}"#)
        #expect(scan.view.kind == .keys && scan.view.cursor == "17")
        #expect(scan.view.table.rows.map { $0[0].text } == ["p190:a", "p190:b"])

        let hscan = try decode(#"{"argv":["HSCAN","h","0"],"reply":{"t":"*","v":[{"t":"s","v":"0"},{"t":"*","v":[{"t":"s","v":"f"},{"t":"s","v":"v"}]}]}}"#)
        #expect(hscan.view.kind == .hash && hscan.view.cursor == "0")

        let stream = try decode(#"{"argv":["XRANGE","events","-","+"],"reply":{"t":"*","v":[{"t":"*","v":[{"t":"s","v":"1-0"},{"t":"*","v":[{"t":"s","v":"type"},{"t":"s","v":"signup"},{"t":"s","v":"user"},{"t":"s","v":"7"}]}]},{"t":"*","v":[{"t":"s","v":"2-0"},{"t":"*","v":[{"t":"s","v":"type"},{"t":"s","v":"login"}]}]}]}}"#)
        #expect(stream.view.kind == .stream)
        #expect(stream.view.table.columns == ["id", "type", "user"])
        #expect(stream.view.table.rows[1].map(\.text) == ["2-0", "login", ""])

        let xread = try decode(#"{"argv":["XREAD","STREAMS","events","0"],"reply":{"t":"*","v":[{"t":"*","v":[{"t":"s","v":"events"},{"t":"*","v":[{"t":"*","v":[{"t":"s","v":"1-0"},{"t":"*","v":[{"t":"s","v":"type"},{"t":"s","v":"signup"}]}]}]}]}]}}"#)
        #expect(xread.view.kind == .stream && xread.view.table.columns == ["stream", "id", "type"])

        let error = try decode(#"{"argv":["HGET","str","f"],"reply":{"t":"-","v":"WRONGTYPE Operation against a key holding the wrong kind of value"}}"#)
        #expect(error.view.kind == .error)

        let string = try decode(#"{"argv":["GET","greeting"],"reply":{"t":"s","v":"{\"hello\":1}"}}"#)
        #expect(string.view.kind == .value)
        #expect(string.summary == "11 bytes")
        let integer = try decode(#"{"argv":["INCR","n"],"reply":{"t":"i","v":3}}"#)
        #expect(integer.summary == "(integer) 3")
        let nested = try decode(#"{"argv":["COMMAND","INFO","get"],"reply":{"t":"*","v":[{"t":"*","v":[{"t":"s","v":"get"}]}]}}"#)
        #expect(nested.view.kind == .value)
    }

    @Test func loadMoreFollowsCursorsAndRanges() throws {
        let scan = try decode(#"{"argv":["SCAN","0","MATCH","p190:*","COUNT","100"],"reply":{"t":"*","v":[{"t":"s","v":"17"},{"t":"*","v":[{"t":"s","v":"p190:a"}]}]}}"#)
        let arguments = ["SCAN", "0", "MATCH", "p190:*", "COUNT", "100"].map { Array($0.utf8) }
        let next = try #require(RedisPaging.next(arguments: arguments, view: scan.view, shown: 1))
        #expect(next[1] == Array("17".utf8))
        let page = try decode(#"{"argv":["SCAN","17","MATCH","p190:*","COUNT","100"],"reply":{"t":"*","v":[{"t":"s","v":"0"},{"t":"*","v":[{"t":"s","v":"p190:b"}]}]}}"#)
        let merged = try #require(scan.appending(page))
        #expect(merged.view.table.rows.map { $0[0].text } == ["p190:a", "p190:b"])
        #expect(merged.view.cursor == "0" && merged.pages == 2)
        #expect(RedisPaging.next(arguments: next, view: merged.view, shown: 2) == nil)

        let hscan = ["HSCAN", "h", "0"].map { Array($0.utf8) }
        let hview = try decode(#"{"argv":["HSCAN","h","0"],"reply":{"t":"*","v":[{"t":"s","v":"9"},{"t":"*","v":[{"t":"s","v":"f"},{"t":"s","v":"v"}]}]}}"#).view
        #expect(RedisPaging.next(arguments: hscan, view: hview, shown: 1)?[2] == Array("9".utf8))

        let cut = try decode(#"{"argv":["LRANGE","q","0","-1"],"reply":{"t":"*","v":[{"t":"s","v":"a"},{"t":"s","v":"b"}],"o":3}}"#)
        let lrange = ["LRANGE", "q", "0", "-1"].map { Array($0.utf8) }
        #expect(RedisPaging.next(arguments: lrange, view: cut.view, shown: 2) == ["LRANGE", "q", "2", "-1"].map { Array($0.utf8) })
        let whole = try decode(#"{"argv":["LRANGE","q","0","-1"],"reply":{"t":"*","v":[{"t":"s","v":"a"}]}}"#)
        #expect(RedisPaging.next(arguments: lrange, view: whole.view, shown: 1) == nil)
        // BYSCORE ranges don't page by index.
        let byScore = ["ZRANGE", "z", "0", "10", "BYSCORE"].map { Array($0.utf8) }
        #expect(RedisPaging.next(arguments: byScore, view: cut.view, shown: 2) == nil)
        #expect(RedisPaging.next(arguments: ["GET", "a"].map { Array($0.utf8) }, view: cut.view, shown: 2) == nil)
    }

    // MARK: Generated PHP

    @Test func generatedPHPIsByteExactAndHoldsNoLineText() {
        let command = RedisScript.Command(arguments: [Array("SET".utf8), [0xFF, 0x24, 0x22, 0x5C, 0x41]], text: "SET \"\\xff$\\\"\\\\A\"", range: NSRange(location: 0, length: 0), line: 4)
        let code = RedisTabRun.code(commands: [command], connection: "cache", maxElements: 50)
        #expect(code.contains(#"['argv' => ["SET", "\xFF\$\"\\A"], 'line' => 4, 'cap' => 50]"#), "\(code)")
        #expect(code.contains(#"], "cache", 50, false, false);"#), "\(code)")
        let auth = RedisScript.Command(arguments: [Array("AUTH".utf8), Array("s3cret".utf8)], text: "AUTH s3cret", range: NSRange(location: 0, length: 0), line: 1)
        #expect(RedisTabRun.code(commands: [auth], connection: nil).contains("'secret' => [1]"))
        #expect(RedisTabRun.cap(for: ["HGETALL", "h"], maxElements: 100) == 200)
        #expect(RedisTabRun.cap(for: ["ZRANGE", "z", "0", "-1", "withscores"], maxElements: 100) == 200)
        #expect(RedisTabRun.cap(for: ["LRANGE", "l", "0", "-1"], maxElements: 100) == 100)
        #expect(RedisTabRun.keysCode(db: 2, pattern: "p190:*", cursor: "0", count: 100, type: nil, connection: nil).contains(#"RedisTab::keys(2, "p190:*", "0", 100, null, null)"#))
    }

    // MARK: Connections

    @Test func redisConnectionModel() throws {
        let target = TargetRef.local(UUID())
        var connection = DatabaseConnection(name: "Cache", scope: target, driver: .redis, host: "127.0.0.1", database: "2", user: "reader")
        #expect(connection.driver.family == .redis && DatabaseDriverKind.mysql.family == .sql)
        #expect(connection.effectivePort == 6379)
        #expect(connection.summary == "redis, 127.0.0.1:6379/2")
        #expect(connection.validate().isEmpty)
        #expect(connection.driver.supportsReadOnly && connection.driver.supportsSocket && connection.driver.supportsTLSFiles)
        #expect(!connection.driver.supportsCharset && !connection.driver.supportsOptions && !connection.driver.supportsInitStatements)
        #expect(connection.driver.tlsModes == [.disable, .require, .verifyFull])

        connection.database = "two"
        #expect(connection.validate().contains(.invalidRedisDatabase))
        connection.database = "-1"
        #expect(connection.validate().contains(.invalidRedisDatabase))
        connection.database = ""
        #expect(connection.validate().isEmpty)

        // Init statements, charset, and options aren't kept; the port 6379 is the default.
        connection.initStatements = ["SET x 1"]
        connection.charset = "utf8"
        connection.options = [DatabaseOption(key: "a", value: "b")]
        connection.port = 6379
        let normalized = connection.normalized
        #expect(normalized.initStatements.isEmpty && normalized.charset == nil && normalized.options.isEmpty && normalized.port == nil)

        // A socket replaces the host and port.
        connection.socket = "/tmp/redis.sock"
        #expect(connection.normalized.host.isEmpty && connection.normalized.location.hasPrefix("socket /tmp/redis.sock"))

        // Encoding: "driver":"redis", no password; a Runlet before #190 leaves it out.
        let data = try JSONEncoder().encode(DatabaseConnection(name: "Cache", scope: target, driver: .redis, host: "cache"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["driver"] as? String == "redis")
        #expect(!object.keys.contains { $0.lowercased().contains("pass") })
        #expect(try JSONDecoder().decode(DatabaseConnection.self, from: data).driver == .redis)
    }

    @Test func familiesKeepPickersApart() {
        let target = TargetRef.docker(UUID())
        var library = TargetLibrary()
        let sql = library.saveDatabaseConnection(DatabaseConnection(name: "Reporting", scope: target, driver: .pgsql, host: "db"))
        let redis = library.saveDatabaseConnection(DatabaseConnection(name: "Cache", scope: target, driver: .redis, host: "cache"))
        let shared = library.saveDatabaseConnection(DatabaseConnection(name: "Shared cache", scope: nil, driver: .redis, host: "cache"))
        #expect(library.databaseConnections(for: target, family: .sql).map(\.id) == [sql.id])
        #expect(library.databaseConnections(for: target, family: .redis).map(\.id) == [redis.id])
        #expect(library.allTargetsDatabaseConnections(family: .redis).map(\.id) == [shared.id])
        #expect(library.allTargetsDatabaseConnections(family: .sql).isEmpty)
        // A tab of one family never resolves to the other's connection, by id or by name.
        #expect(library.databaseConnection(id: redis.id, name: "Cache", on: target, family: .sql) == nil)
        #expect(library.databaseConnection(id: redis.id, name: "Cache", on: target, family: .redis)?.id == redis.id)
        #expect(library.databaseConnection(id: nil, name: "Reporting", on: target, family: .redis) == nil)
        #expect(library.resolve(.saved(name: "Cache", id: nil, allTargets: false), on: target, family: .sql) == .missing("Cache"))
        #expect(library.resolve(.saved(name: "Cache", id: nil, allTargets: false), on: target, family: .redis) == .saved(redis))
        #expect(TabLanguage.redis.connectionFamily == .redis && TabLanguage.sql.connectionFamily == .sql && TabLanguage.php.connectionFamily == nil)
    }

    @Test func tabStateKeepsTheLanguageAndOlderSessionsDecode() throws {
        let state = TabState(title: "Redis 1", code: "PING", language: .redis, sqlConnection: "cache", redisTransaction: true)
        let decoded = try JSONDecoder().decode(TabState.self, from: JSONEncoder().encode(state))
        #expect(decoded.language == .redis && decoded.sqlConnection == "cache" && decoded.redisTransaction == true)
        // An older session (no redisTransaction) and a language from a newer Runlet.
        let old = #"{"id":"\#(UUID().uuidString)","title":"T","code":"x","target":{"sandbox":{}},"selection":{"location":0,"length":0},"createdAt":0,"language":"future-database"}"#
        let legacy = try JSONDecoder().decode(TabState.self, from: Data(old.utf8))
        #expect(legacy.language == .php && legacy.redisTransaction == nil)
        #expect(TabLanguage.forFile(URL(fileURLWithPath: "/tmp/a.redis")) == .redis)
        // History keeps a Redis run's connection; a PHP run's none.
        let entry = HistoryEntry(runId: UUID(), code: "GET a", target: .sandbox, targetLabel: "Sandbox", status: .completed, reason: "completed", elapsedMs: 1, language: .redis, connection: .application("cache"))
        #expect(entry.connection == .application("cache") && entry.language == .redis)
    }

    @Test func tablePlusMapsRedis() {
        #expect(TablePlusMapping.driver("Redis").driver == .redis)
        #expect(TablePlusMapping.driver("MongoDB").driver == nil)
        #expect(TablePlusMapping.tls(mode: 1, rawDriver: "Redis", driver: .redis).tls?.mode == .require)
        #expect(TablePlusMapping.tls(mode: 0, rawDriver: "Redis", driver: .redis).tls == nil)
    }
}
