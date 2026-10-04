import Foundation
@testable import RunletCore
import Testing
@testable import RunletExecution

/// The command builder (#218) against the live Redis fixture: the lines the builder writes for
/// SET (with options), HSET (several pairs), ZRANGE (BYSCORE REV LIMIT WITHSCORES), XADD, SCAN
/// (MATCH COUNT TYPE), and EXPIRE run as shown, and values with spaces, quotes, and newlines
/// reach Redis exactly. Keys start with `p218:`.
extension RedisLiveTests {
    private func resetBuilderKeys() throws {
        let keys = try cli(["KEYS", "p218:*"])
        let names = (try? JSONDecoder().decode(RedisValue.self, from: Data(keys.utf8)))?.elements?.compactMap(\.stringValue) ?? []
        if !names.isEmpty { try cli(["DEL"] + names) }
    }

    private func form(_ name: String) throws -> RedisCommandForm {
        try #require(RedisCommandSpecs.spec(named: name).map(RedisCommandForm.init(spec:)))
    }

    private func set(_ form: inout RedisCommandForm, _ name: String, _ value: String, row: Int = 0) throws {
        let index = try #require(form.spec?.arguments.firstIndex { $0.name == name })
        while form.values[index].rows.count <= row { form.values[index].rows.append(.init()) }
        form.values[index].rows[row].value = value
    }

    private func on(_ form: inout RedisCommandForm, _ name: String, choice: Int? = nil) throws {
        let index = try #require(form.spec?.arguments.firstIndex { $0.name == name })
        form.values[index].isOn = true
        if let choice { form.values[index].rows[0].choice = choice }
    }

    @Test func builtCommandsRunAsShown() async throws {
        try resetBuilderKeys()
        let tricky = "two words, \"quoted\"\nand a second line\twith a tab \\ and café"

        var setCommand = try form("SET")
        try set(&setCommand, "key", "p218:greeting")
        try set(&setCommand, "value", tricky)
        try on(&setCommand, "condition", choice: 0)
        let expiration = try #require(setCommand.spec?.arguments.firstIndex { $0.name == "expiration" })
        setCommand.values[expiration].isOn = true
        setCommand.values[expiration].rows[0].choice = 0
        setCommand.values[expiration].rows[0].children[0].rows[0].value = "600"

        var hset = try form("HSET")
        try set(&hset, "key", "p218:user:1")
        let data = try #require(hset.spec?.arguments.firstIndex { $0.name == "data" })
        hset.values[data].rows = [
            .init(children: [.init(isOn: true, rows: [.init(value: "name")]), .init(isOn: true, rows: [.init(value: "Ada Lovelace")])]),
            .init(children: [.init(isOn: true, rows: [.init(value: "role")]), .init(isOn: true, rows: [.init(value: "admin")])]),
        ]

        let zadd = RedisCommandForm.prefilled("ZADD", ["p218:scores", "12", "ada", "9.5", "grace", "7", "linus", "3", "alan"])
        var zrange = try form("ZRANGE")
        try set(&zrange, "key", "p218:scores")
        // With REV, the range goes from the highest score down.
        try set(&zrange, "start", "+inf")
        try set(&zrange, "stop", "(5")
        try on(&zrange, "sortby", choice: 0)
        try on(&zrange, "rev")
        let limit = try #require(zrange.spec?.arguments.firstIndex { $0.name == "limit" })
        zrange.values[limit].isOn = true
        zrange.values[limit].rows[0].children[0].rows[0].value = "0"
        zrange.values[limit].rows[0].children[1].rows[0].value = "2"
        try on(&zrange, "withscores")

        let xadd = RedisCommandForm.prefilled("XADD", ["p218:events", "MAXLEN", "~", "1000", "*", "type", "signup", "note", "line one\nline two"])
        var scan = try form("SCAN")
        try set(&scan, "cursor", "0")
        try set(&scan, "pattern", "p218:*")
        try set(&scan, "count", "1000")
        try set(&scan, "type", "hash")
        var expire = try form("EXPIRE")
        try set(&expire, "key", "p218:user:1")
        try set(&expire, "seconds", "3600")
        try on(&expire, "condition", choice: 0)
        let get = RedisCommandForm.prefilled("GET", ["p218:greeting"])

        let forms = [setCommand, hset, zadd, zrange, xadd, scan, expire, get]
        for form in forms { #expect(form.canWrite, "\(form.line): \(form.issues)") }
        let script = forms.map(\.line).joined(separator: "\n")
        #expect(forms[0].line == #"SET p218:greeting "two words, \"quoted\"\nand a second line\twith a tab \\ and caf\xc3\xa9" NX EX 600"#)
        #expect(zrange.line == "ZRANGE p218:scores +inf (5 BYSCORE REV LIMIT 0 2 WITHSCORES")

        let (connection, store) = saved()
        let events = try await run(script, on: connection, store: store)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let replies = events.redisReplies
        #expect(replies.count == forms.count)
        guard replies.count == forms.count else { return }
        #expect(replies[0].reply == .status("OK"))
        #expect(replies[1].reply == .integer(2))
        #expect(replies[2].reply == .integer(4))
        #expect(replies[3].view.kind == .zset)
        // Redis's order (the card's table sorts by score): highest first, two of them.
        #expect(replies[3].reply.elements?.compactMap(\.stringValue) == ["ada", "12", "grace", "9.5"], "BYSCORE REV LIMIT 0 2 WITHSCORES")
        #expect(replies[4].reply.stringValue?.contains("-") == true, "XADD returns the new id")
        #expect(replies[5].view.kind == .keys)
        #expect(replies[5].view.table.rows.map { $0[0].text } == ["p218:user:1"], "TYPE hash")
        #expect(replies[6].reply == .integer(1))
        #expect(replies[7].reply == .string(tricky), "the value reaches Redis exactly")
        // Each line reads back into the form it came from.
        for form in forms { #expect(try RedisCommandForm.parse(line: form.line).get() == form, "\(form.line)") }
        try resetBuilderKeys()
    }
}
