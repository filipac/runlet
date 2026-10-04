import Foundation
import Testing
@testable import RunletCore

/// The Redis command builder (#218): the command specs and their agreement with the
/// classification table, form → command line (per family, quoting, repeated arguments), command
/// line → form (round trips, options in any order, unmapped words, lines typed halfway), the
/// caret edits, and the key browser's Insert Command items.
struct RedisCommandBuilderTests {
    // MARK: Helpers

    private func form(_ name: String) throws -> RedisCommandForm {
        try #require(RedisCommandSpecs.spec(named: name).map(RedisCommandForm.init(spec:)))
    }

    private func index(_ form: RedisCommandForm, _ name: String) throws -> Int {
        try #require(form.spec?.arguments.firstIndex { $0.name == name })
    }

    /// Sets a top-level value argument's first (or `row`th) value.
    private func set(_ form: inout RedisCommandForm, _ name: String, _ value: String?, row: Int = 0) throws {
        let i = try index(form, name)
        while form.values[i].rows.count <= row { form.values[i].rows.append(.init()) }
        form.values[i].rows[row].value = value
    }

    /// Turns a top-level optional token, choice, or block on, choosing `choice`.
    private func turnOn(_ form: inout RedisCommandForm, _ name: String, choice: Int? = nil) throws {
        let i = try index(form, name)
        form.values[i].isOn = true
        if let choice { form.values[i].rows[0].choice = choice }
    }

    private func parse(_ line: String) throws -> RedisCommandForm {
        try RedisCommandForm.parse(line: line).get()
    }

    // MARK: Specs and the classification table

    @Test func everySpecIsInTheClassificationTableWithItsClass() {
        for spec in RedisCommandSpecs.all {
            #expect(RedisCommands.isKnown(spec.tableKey), "\(spec.name) isn't in RedisCommands")
            #expect(spec.info.access == spec.access, "\(spec.name): the spec says \(spec.access), the table \(spec.info.access)")
            #expect(spec.info.name == spec.name)
        }
        #expect(Set(RedisCommandSpecs.all.map(\.name)).count == RedisCommandSpecs.all.count, "a command is listed twice")
        // Dangerous commands are marked from the table.
        for name in ["KEYS", "FLUSHDB", "FLUSHALL", "CONFIG SET"] {
            #expect(RedisCommandSpecs.spec(named: name)?.info.dangerous == true, "\(name)")
        }
        #expect(RedisCommandSpecs.spec(named: "GET")?.info.dangerous == false)
    }

    @Test func coversEveryDataTypeScanAndServerReads() {
        let names = Set(RedisCommandSpecs.all.map(\.name))
        let required = [
            "GET", "SET", "MGET", "MSET", "INCR", "GETEX", "DEL", "EXISTS", "TYPE", "TTL", "PTTL", "EXPIRE", "PERSIST", "RENAME",
            "SCAN", "HSCAN", "SSCAN", "ZSCAN", "HSET", "HGET", "HGETALL", "HDEL", "LPUSH", "RPUSH", "LRANGE", "LPOP", "BLPOP",
            "SADD", "SMEMBERS", "SISMEMBER", "ZADD", "ZRANGE", "ZRANGEBYSCORE", "ZSCORE", "ZUNION", "XADD", "XRANGE", "XREVRANGE",
            "XREAD", "XINFO STREAM", "XINFO GROUPS", "XLEN", "INFO", "DBSIZE", "MEMORY USAGE", "CONFIG GET", "SELECT",
        ]
        for name in required { #expect(names.contains(name), "\(name) has no spec") }
        for group in RedisCommandSpec.Group.allCases {
            #expect(RedisCommandSpecs.all.contains { $0.group == group }, "\(group) is empty")
        }
    }

    @Test func syntaxReadsLikeRedisDocs() {
        let syntax = { (name: String) in RedisCommandSpecs.spec(named: name)?.syntax ?? "" }
        #expect(syntax("SET") == "SET key value [NX | XX] [GET] [EX seconds | PX milliseconds | EXAT unix-time-seconds | PXAT unix-time-milliseconds | KEEPTTL]")
        #expect(syntax("ZRANGE") == "ZRANGE key start stop [BYSCORE | BYLEX] [REV] [LIMIT offset count] [WITHSCORES]")
        #expect(syntax("SCAN") == "SCAN cursor [MATCH pattern] [COUNT count] [TYPE type]")
        #expect(syntax("HSET") == "HSET key field value [field value ...]")
        #expect(syntax("XADD") == "XADD key [NOMKSTREAM] [<MAXLEN | MINID> [= | ~] threshold [LIMIT count]] <* | id> field value [field value ...]")
        #expect(syntax("XREAD") == "XREAD [COUNT count] [BLOCK milliseconds] STREAMS key [key ...] id [id ...]")
        #expect(syntax("ZUNION") == "ZUNION numkeys key [key ...] [WEIGHTS weight [weight ...]] [AGGREGATE <SUM | MIN | MAX>] [WITHSCORES]")
        #expect(syntax("DEL") == "DEL key [key ...]")
        #expect(syntax("MEMORY USAGE") == "MEMORY USAGE key [SAMPLES count]")
    }

    @Test func pickerGroupsAndSearches() {
        let all = RedisCommandSpecs.grouped()
        #expect(all.map(\.group) == RedisCommandSpec.Group.allCases)
        let found = RedisCommandSpecs.grouped(matching: "zrange")
        #expect(found.count == 1)
        #expect(found.first?.commands.first?.name == "ZRANGE", "the exact name comes first")
        // By summary.
        #expect(RedisCommandSpecs.grouped(matching: "time to live").flatMap(\.commands).contains { $0.name == "TTL" })
        #expect(RedisCommandSpecs.grouped(matching: "no such command").isEmpty)
    }

    // MARK: Form → command line

    @Test func buildsSetWithOptions() throws {
        var form = try form("SET")
        try set(&form, "key", "session:42")
        try set(&form, "value", "hello world")
        try turnOn(&form, "condition", choice: 0)
        let expiration = try index(form, "expiration")
        form.values[expiration].isOn = true
        form.values[expiration].rows[0].choice = 0
        form.values[expiration].rows[0].children[0].rows[0].value = "60"
        #expect(form.line == #"SET session:42 "hello world" NX EX 60"#)
        #expect(form.canWrite)
        // GUI → text → GUI gives the same form.
        #expect(try parse(form.line) == form)
        #expect(form.info.access == .write)
        // KEEPTTL, and GET.
        form.values[expiration].rows[0].choice = 4
        try turnOn(&form, "get")
        #expect(form.line == #"SET session:42 "hello world" NX GET KEEPTTL"#)
        // The seconds typed for EX stay in the hidden branch, so only the line compares.
        #expect(try parse(form.line).line == form.line)
    }

    @Test func buildsHashSetWithSeveralPairs() throws {
        var form = try form("HSET")
        try set(&form, "key", "user:1")
        let data = try index(form, "data")
        let pair = { (field: String?, value: String?) in
            RedisArgumentValue.Row(children: [RedisArgumentValue(isOn: true, rows: [.init(value: field)]), RedisArgumentValue(isOn: true, rows: [.init(value: value)])])
        }
        form.values[data].rows = [pair("name", "Ada Lovelace"), pair("role", "admin"), pair(nil, nil)]
        // The blank row added last is skipped.
        #expect(form.line == #"HSET user:1 name "Ada Lovelace" role admin"#)
        #expect(form.canWrite)
        // An explicit empty string is written as "".
        form.values[data].rows[1].children[1].rows[0].value = ""
        #expect(form.line == #"HSET user:1 name "Ada Lovelace" role """#)
        #expect(form.canWrite)
        #expect(form.issues.contains { !$0.isBlocking })
    }

    @Test func buildsZRangeWithModernOptions() throws {
        var form = try form("ZRANGE")
        try set(&form, "key", "scores")
        // With REV, the range goes from the highest score down.
        try set(&form, "start", "+inf")
        try set(&form, "stop", "(10")
        try turnOn(&form, "sortby", choice: 0)
        try turnOn(&form, "rev")
        let limit = try index(form, "limit")
        form.values[limit].isOn = true
        form.values[limit].rows[0].children[0].rows[0].value = "0"
        form.values[limit].rows[0].children[1].rows[0].value = "10"
        try turnOn(&form, "withscores")
        #expect(form.line == "ZRANGE scores +inf (10 BYSCORE REV LIMIT 0 10 WITHSCORES")
        #expect(form.info.access == .read)
        #expect(try parse(form.line) == form)
        // A LIMIT count that isn't a number blocks writing.
        form.values[limit].rows[0].children[1].rows[0].value = "ten"
        #expect(!form.canWrite)
        #expect(form.issues.first?.message == "count must be a whole number.")
    }

    @Test func buildsXAddAndScanAndExpire() throws {
        var xadd = try form("XADD")
        try set(&xadd, "key", "events")
        let trim = try index(xadd, "trim")
        xadd.values[trim].isOn = true
        xadd.values[trim].rows[0].children[1].isOn = true
        xadd.values[trim].rows[0].children[1].rows[0].choice = 1
        xadd.values[trim].rows[0].children[2].rows[0].value = "1000"
        let data = try index(xadd, "data")
        xadd.values[data].rows = [
            .init(children: [.init(isOn: true, rows: [.init(value: "type")]), .init(isOn: true, rows: [.init(value: "signup")])]),
            .init(children: [.init(isOn: true, rows: [.init(value: "note")]), .init(isOn: true, rows: [.init(value: "line one\nline \"two\"")])]),
        ]
        #expect(xadd.line == #"XADD events MAXLEN ~ 1000 * type signup note "line one\nline \"two\"""#)

        var scan = try form("SCAN")
        try set(&scan, "cursor", "0")
        try set(&scan, "pattern", "user:*")
        try set(&scan, "count", "100")
        try set(&scan, "type", "hash")
        #expect(scan.line == "SCAN 0 MATCH user:* COUNT 100 TYPE hash")
        #expect(try parse(xadd.line) == xadd)
        #expect(try parse(scan.line) == scan)

        var expire = try form("EXPIRE")
        try set(&expire, "key", "session:42")
        #expect(!expire.canWrite, "seconds are required")
        try set(&expire, "seconds", "3600")
        try turnOn(&expire, "condition", choice: 2)
        #expect(expire.line == "EXPIRE session:42 3600 GT")
        #expect(expire.canWrite)
        #expect(try parse(expire.line) == expire)
    }

    @Test func numkeysCountsTheKeys() throws {
        var form = try form("ZUNION")
        try set(&form, "key", "a")
        try set(&form, "key", "b", row: 1)
        try turnOn(&form, "withscores")
        #expect(form.line == "ZUNION 2 a b WITHSCORES")
        try set(&form, "key", "c", row: 2)
        #expect(form.line == "ZUNION 3 a b c WITHSCORES")
    }

    @Test func missingRequiredValuesBlockWriting() throws {
        let get = try form("GET")
        #expect(!get.canWrite)
        #expect(get.issues == [.init("Fill in key.")])
        #expect(get.line == "GET")
        var raw = RedisCommandForm(rawName: "")
        #expect(!raw.canWrite)
        raw.rawName = "CLUSTER INFO"
        #expect(raw.canWrite)
        #expect(raw.arguments == ["CLUSTER", "INFO"])
    }

    // MARK: Command line → form

    @Test func handTypedLinesRoundTrip() throws {
        let lines = [
            "GET user:1",
            #"SET greeting "hello world" XX GET PX 1500"#,
            "SET counter 0 KEEPTTL",
            #"MSET a 1 b "two words""#,
            "HSET user:1 name Ada role admin",
            "HGETALL user:1",
            "HRANDFIELD user:1 3 WITHVALUES",
            "HSCAN user:1 0 MATCH n* COUNT 50 NOVALUES",
            "HEXPIRE user:1 60 NX FIELDS 2 name role",
            "LPUSH queue job1 job2 job3",
            "LRANGE queue 0 -1",
            "LINSERT queue BEFORE job2 job1.5",
            "LPOS queue job2 RANK 1 COUNT 2 MAXLEN 100",
            "LMOVE src dst LEFT RIGHT",
            "LMPOP 2 q1 q2 LEFT COUNT 3",
            "BLPOP q1 q2 5",
            "SADD tags red green",
            "SINTERCARD 2 s1 s2 LIMIT 10",
            "ZADD scores NX CH 1.5 ada 2 bob",
            "ZRANGE scores 0 -1 WITHSCORES",
            "ZRANGE scores +inf (1 BYSCORE REV LIMIT 0 10 WITHSCORES",
            "ZRANGEBYSCORE scores -inf +inf WITHSCORES LIMIT 0 5",
            "ZUNION 2 a b WEIGHTS 1 2 AGGREGATE MIN WITHSCORES",
            "ZINTERSTORE out 2 a b AGGREGATE MAX",
            "XADD events NOMKSTREAM MAXLEN ~ 1000 LIMIT 100 * type signup",
            "XADD events 1700000000000-0 type signup",
            "XRANGE events - + COUNT 10",
            "XREAD COUNT 10 BLOCK 5000 STREAMS s1 s2 0 $",
            "XREADGROUP GROUP g c COUNT 1 NOACK STREAMS s1 >",
            "XINFO STREAM events FULL COUNT 5",
            "XGROUP CREATE events g $ MKSTREAM",
            "XPENDING events g IDLE 1000 - + 10 consumer1",
            "SCAN 0 MATCH user:* COUNT 100 TYPE hash",
            "EXPIRE session:42 60 NX",
            "COPY a b DB 2 REPLACE",
            "INFO memory keyspace",
            "MEMORY USAGE user:1 SAMPLES 0",
            "CONFIG GET maxmemory*",
            "CLIENT LIST TYPE NORMAL",
            "FLUSHDB ASYNC",
            "DBSIZE",
            "PING",
        ]
        for line in lines {
            let form = try parse(line)
            #expect(form.spec != nil, "\(line): no spec")
            #expect(form.extra.isEmpty, "\(line): unplaced \(form.extra)")
            #expect(form.line == line, "\(line) came back as \(form.line)")
            #expect(form.issues.filter(\.isBlocking).isEmpty, "\(line): \(form.issues)")
            // And the form the line makes reads back to itself.
            #expect(try parse(form.line) == form, "\(line)")
        }
    }

    @Test func quotingRoundTripsThroughTheParser() throws {
        let values = ["two words", #"say "hi""#, "it's", "line one\nline two", "tab\there", #"back\slash"#, "", "café ☕", "  padded  ", "#not-a-comment", "*"]
        for text in values {
            var form = try form("SET")
            try set(&form, "key", "k")
            try set(&form, "value", text)
            let parsed = try RedisScript.parse(form.line).get()
            #expect(parsed.map { String(decoding: $0, as: UTF8.self) } == ["SET", "k", text], "\(text.debugDescription) → \(form.line)")
            #expect(try parse(form.line).values == form.values, "\(text.debugDescription)")
        }
    }

    @Test func optionsInAnyOrderAndAnyCase() throws {
        let form = try parse("set k v ex 10 nx")
        #expect(form.extra.isEmpty)
        #expect(form.line == "SET k v NX EX 10")
        let zrange = try parse("ZRANGE s 0 -1 WITHSCORES LIMIT 0 2 REV BYSCORE")
        #expect(zrange.extra.isEmpty)
        #expect(zrange.line == "ZRANGE s 0 -1 BYSCORE REV LIMIT 0 2 WITHSCORES")
        let scan = try parse("SCAN 0 TYPE zset COUNT 10 MATCH a*")
        #expect(scan.line == "SCAN 0 MATCH a* COUNT 10 TYPE zset")
    }

    @Test func wordsTheFormCantPlaceStayRaw() throws {
        let form = try parse("SET k v FOO EX 10")
        #expect(form.extra == ["FOO", "EX", "10"])
        #expect(form.line == "SET k v FOO EX 10", "nothing is lost")
        let twice = try parse("ZRANGE s 0 -1 BYSCORE BYLEX")
        #expect(twice.extra == ["BYLEX"])
        #expect(twice.line == "ZRANGE s 0 -1 BYSCORE BYLEX")
        // A command without a spec is raw arguments.
        let raw = try parse(#"CLUSTER COUNTKEYSINSLOT 7000"#)
        #expect(raw.spec == nil)
        #expect(raw.rawName == "CLUSTER")
        #expect(raw.extra == ["COUNTKEYSINSLOT", "7000"])
        #expect(raw.line == "CLUSTER COUNTKEYSINSLOT 7000")
        let unknown = try parse(#"MYMODULE.DO "a b" c"#)
        #expect(unknown.line == #"MYMODULE.DO "a b" c"#)
    }

    @Test func linesTypedHalfwayFillWhatTheyHave() throws {
        let zrange = try parse("ZRANGE scores")
        #expect(zrange.extra.isEmpty)
        #expect(zrange.issues.filter(\.isBlocking).map(\.message) == ["Fill in start.", "Fill in stop."])
        #expect(zrange.line == "ZRANGE scores")
        let hset = try parse("HSET h f1 v1 f2")
        #expect(hset.extra.isEmpty)
        let data = try index(hset, "data")
        #expect(hset.values[data].rows.count == 2)
        #expect(hset.values[data].rows[1].children[1].rows[0].value == nil)
        #expect(hset.line == "HSET h f1 v1 f2", "a missing value isn't written as \"\"")
        #expect(!hset.canWrite)
        let limit = try parse("ZRANGE s 0 -1 LIMIT 0")
        #expect(limit.extra.isEmpty)
        #expect(limit.line == "ZRANGE s 0 -1 LIMIT 0")
        let set = try parse("SET k v EX")
        #expect(set.extra.isEmpty)
        #expect(set.issues.map(\.message).contains("Fill in seconds."))
    }

    @Test func repeatedArgumentsTakeTheirShare() throws {
        let blpop = try parse("BLPOP q1 q2 q3 0")
        let keys = try index(blpop, "key")
        #expect(blpop.values[keys].rows.compactMap(\.value) == ["q1", "q2", "q3"])
        #expect(blpop.values[try index(blpop, "timeout")].rows[0].value == "0")
        let xread = try parse("XREAD STREAMS a b c 0 1 2")
        let streams = try index(xread, "streams")
        #expect(xread.values[streams].rows.map { $0.children.map { $0.rows[0].value ?? "-" } } == [["a", "0"], ["b", "1"], ["c", "2"]])
        let zunion = try parse("ZUNION 3 a b c WITHSCORES")
        #expect(zunion.values[try index(zunion, "key")].rows.compactMap(\.value) == ["a", "b", "c"])
        let sort = try parse("SINTERCARD 1 LIMIT")
        #expect(sort.values[try index(sort, "key")].rows.compactMap(\.value) == ["LIMIT"], "numkeys says LIMIT is a key")
    }

    @Test func rolesMarkKeysAndTokens() throws {
        #expect(RedisCommandForm.parseWithRoles(["SET", "k", "v", "EX", "10"]).roles == [.command, .key, .value("value"), .token, .value("seconds")])
        #expect(RedisCommandForm.parseWithRoles(["XINFO", "STREAM", "s"]).roles == [.command, .command, .key])
        #expect(RedisCommandForm.parseWithRoles(["XREAD", "STREAMS", "a", "b", "0", "0"]).roles == [.command, .token, .key, .key, .value("id"), .value("id")])
        #expect(RedisCommandForm.parseWithRoles(["ZUNION", "2", "a", "b"]).roles == [.command, .count, .key, .key])
        #expect(RedisCommandForm.parseWithRoles(["SET", "k", "v", "FOO"]).roles.last == .unknown)
    }

    @Test func unreadableLinesStartFresh() {
        #expect(RedisCommandForm.parse(line: "   ") == .failure(.blank))
        #expect(RedisCommandForm.parse(line: "# SET k v") == .failure(.comment))
        if case .failure(.unreadable(let why)) = RedisCommandForm.parse(line: #"SET k "open"#) {
            #expect(why == "A quote isn't closed.")
        } else {
            Issue.record("an unclosed quote should be unreadable")
        }
        if case .failure(.unreadable) = RedisCommandForm.parse(line: #"SET k "\xff""#) {} else {
            Issue.record("bytes that aren't UTF-8 should be unreadable")
        }
    }

    // MARK: Writing into the tab

    @Test func insertPutsTheCommandOnTheNextLine() {
        let text = "GET a\nGET b"
        let edit = RedisBuilderText.insert("TTL a", in: text, at: 2)
        #expect(edit.range == NSRange(location: 5, length: 0))
        #expect(edit.replacement == "\nTTL a")
        let applied = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        #expect(applied == "GET a\nTTL a\nGET b")
        #expect(edit.caret == 11)
        // On a blank line, the command goes there.
        let blank = RedisBuilderText.insert("PING", in: "GET a\n\nGET b", at: 6)
        #expect((("GET a\n\nGET b" as NSString).replacingCharacters(in: blank.range, with: blank.replacement)) == "GET a\nPING\nGET b")
        // In an empty tab, and at the end of the last line.
        #expect(RedisBuilderText.insert("PING", in: "", at: 0).replacement == "PING")
        let end = RedisBuilderText.insert("PING", in: "GET a", at: 5)
        #expect(end.range.location == 5 && end.replacement == "\nPING")
    }

    @Test func replaceSwapsTheCaretsCommandLine() throws {
        let text = "# header\n  GET a  \nGET b"
        let edit = try #require(RedisBuilderText.replace("GET z", in: text, at: 12))
        let applied = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        #expect(applied == "# header\n  GET z  \nGET b", "the indentation stays")
        #expect(RedisBuilderText.replace("GET z", in: text, at: 3) == nil, "a comment isn't replaced")
        let unreadable = #"SET k "open"#
        let fix = try #require(RedisBuilderText.replace("SET k open", in: unreadable, at: 0))
        #expect((unreadable as NSString).replacingCharacters(in: fix.range, with: fix.replacement) == "SET k open")
    }

    @Test func readsTheCaretsLine() throws {
        let text = "GET a\n\n# note\nZRANGE s 0 -1 WITHSCORES\nSET k \"open"
        #expect(RedisBuilderText.read(text, at: 0).line == 1)
        #expect(try RedisBuilderText.read(text, at: 2).result.get().line == "GET a")
        #expect(RedisBuilderText.read(text, at: 6).result == .failure(.blank))
        #expect(RedisBuilderText.read(text, at: 8).result == .failure(.comment))
        let zrange = RedisBuilderText.read(text, at: 20)
        #expect(zrange.line == 4)
        #expect(try zrange.result.get().spec?.name == "ZRANGE")
        if case .failure(.unreadable) = RedisBuilderText.read(text, at: (text as NSString).length).result {} else {
            Issue.record("the last line has an open quote")
        }
    }

    // MARK: Key browser

    @Test func keyBrowserItemsFollowTheType() {
        let types: [String?: String] = [
            "string": "GET k", "hash": "HGETALL k", "list": "LRANGE k 0 -1", "set": "SMEMBERS k",
            "zset": "ZRANGE k 0 -1 WITHSCORES", "stream": "XRANGE k - +", nil: "TYPE k",
        ]
        for (type, line) in types {
            let entry = RedisKeyEntry(key: "k", raw: Data("k".utf8).base64EncodedString(), type: type)
            let items = entry.builderCommands
            #expect(items.first?.form.line == line, "\(type ?? "unknown")")
            #expect(items.dropFirst().map(\.title) == ["TTL", "EXPIRE…", "PERSIST", "DEL", "RENAME…"])
        }
        let entry = RedisKeyEntry(key: "user 1", raw: Data("user 1".utf8).base64EncodedString(), type: "string")
        let expire = entry.builderCommands[2].form
        #expect(expire.line == #"EXPIRE "user 1""#)
        #expect(!expire.canWrite, "the seconds are left to fill in")
        #expect(entry.builderCommands[4].form.info.access == .write)
        // A key that isn't UTF-8 has no builder items.
        #expect(RedisKeyEntry(key: nil, raw: Data([0xFF]).base64EncodedString()).builderCommands.isEmpty)
    }
}
