import Foundation
import Testing
@testable import RunletCore

/// Completion in Redis tabs (#206): positions (command, subcommand, options, values, keys),
/// the command table and its agreement with the builder's specs (#218) and the classification
/// table (#190), key positions per command family, quoting of key names, the keys Runlet
/// already read, Load Keys for Completion's item and pattern, and hover.
struct RedisCompletionTests {
    // MARK: Helpers

    /// The completions at the `|` in `marked`.
    private func complete(_ marked: String, keys: [RedisCompletion.KnownKey] = [], offer: RedisCompletion.KeyLoadOffer? = nil) -> SQLCompletion.Result? {
        let caret = (marked as NSString).range(of: "|").location
        let text = (marked as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "")
        return RedisCompletion.suggestions(in: text, caret: caret, keys: keys, loadOffer: offer)
    }

    private func labels(_ marked: String, _ kind: SQLCompletion.Kind, keys: [RedisCompletion.KnownKey] = []) -> [String] {
        complete(marked, keys: keys)?.items.filter { $0.kind == kind }.map(\.label) ?? []
    }

    private func item(_ marked: String, _ label: String, keys: [RedisCompletion.KnownKey] = []) throws -> SQLCompletion.Item {
        try #require(complete(marked, keys: keys)?.items.first { $0.label == label }, "no \(label) at \(marked)")
    }

    private let keys: [RedisCompletion.KnownKey] = [
        .init(name: "user:1", type: "hash", source: .keyBrowser),
        .init(name: "user:2", type: "string", source: .keyBrowser),
        .init(name: "queue", type: "list", source: .keyBrowser),
        .init(name: "my key", source: .loaded),
        .init(name: "events", source: .reply),
    ]

    // MARK: Commands

    @Test func commandsAtTheStartOfALineWithSyntaxSummaryAndBadges() throws {
        let result = try #require(complete("ZR|"))
        #expect(result.anchor == 0)
        #expect(result.prefix == "ZR")
        let zrange = try item("ZR|", "ZRANGE")
        #expect(zrange.kind == .command)
        #expect(zrange.detail == "key start stop [BYSCORE | BYLEX] [REV] [LIMIT offset count] [WITHSCORES]")
        #expect(zrange.documentation?.hasPrefix("Returns members in a range of ranks") == true)
        #expect(zrange.badges.isEmpty)
        #expect(try item("ZR|", "ZREMRANGEBYRANK").badges == ["WRITE"])
        #expect(try item("FL|", "FLUSHDB").badges == ["DANGEROUS", "WRITE"])
        #expect(try item("FL|", "FLUSHDB").documentation?.contains("Dangerous: it deletes every key in the current database") == true)
        #expect(try item("BL|", "BLPOP").badges == ["WRITE", "BLOCKS"])
        #expect(try item("KE|", "KEYS").badges == ["DANGEROUS"])
        // A command Runlet only classifies: listed after the ones it has a syntax for.
        let geoadd = try item("GE|", "GEOADD")
        #expect(geoadd.detail == nil && geoadd.rank == 1 && geoadd.badges == ["WRITE"])
        #expect(geoadd.documentation == "Can write: a read-only connection refuses it; Runlet has no syntax for its arguments.")
        #expect(try item("GE|", "GET").rank == 0)
        // Streaming commands are refused, so never offered.
        #expect(!labels("SU|", .command).contains("SUBSCRIBE"))
        #expect(!labels("MO|", .command).contains("MONITOR"))
    }

    @Test func commandsFollowTheTypedCase() throws {
        #expect(try item("zr|", "zrange").insertText == "zrange")
        #expect(try item("  Ge|", "GET").kind == .command)
        // An empty word (Show Completions on a blank line): upper case.
        #expect(labels("|", .command).contains("HGETALL"))
        #expect(labels("\n  |", .command).contains("HGETALL"))
    }

    @Test func nothingInCommentsAfterAClosedQuoteOrOnALineRunletCantRead() {
        #expect(complete("# GE|") == nil)
        #expect(complete("  # GET |") == nil)
        #expect(complete("GET \"a b\"|") == nil)
        #expect(complete("\"GE|") == nil)
        #expect(complete("GET a\"b|") == nil)
        #expect(complete("SET \"a\"b c |") == nil)
        // The line above doesn't matter.
        #expect(complete("# comment\nZR|")?.anchor == 10)
    }

    // MARK: Subcommands

    @Test func containersThenTheirSubcommands() throws {
        let client = try item("CLI|", "CLIENT")
        #expect(client.insertText == "CLIENT ")
        #expect(client.reopens)
        #expect(try item("cli|", "client").insertText == "client ")
        let subcommands = labels("CLIENT |", .command)
        for name in ["LIST", "INFO", "KILL", "SETNAME", "GETNAME", "ID", "PAUSE"] { #expect(subcommands.contains(name), "\(name)") }
        #expect(!subcommands.contains("REPLY"), "CLIENT REPLY is refused")
        #expect(try item("CLIENT |", "KILL").badges == ["DANGEROUS", "WRITE"])
        #expect(try item("CLIENT |", "LIST").detail == "[TYPE <NORMAL | MASTER | REPLICA | PUBSUB>] [ID client-id [client-id ...]]")
        #expect(try item("XINFO S|", "STREAM").detail == "key [FULL [COUNT count]]")
        #expect(labels("XINFO |", .command) == ["CONSUMERS", "GROUPS", "HELP", "STREAM"])
        // The command word's case when nothing is typed yet.
        #expect(labels("config |", .command).contains("get"))
        #expect(try item("config |", "set").badges == ["DANGEROUS", "WRITE"])
        #expect(complete("CLIENT LIST |") == nil || !labels("CLIENT LIST |", .command).contains("LIST"))
    }

    // MARK: Options and values

    @Test func optionWordsTheGrammarAllowsNext() throws {
        #expect(labels("ZRANGE k 0 -1 |", .option) == ["BYSCORE", "BYLEX", "REV", "LIMIT", "WITHSCORES"])
        #expect(labels("ZRANGE k 0 -1 BY|", .option) == ["BYSCORE", "BYLEX", "REV", "LIMIT", "WITHSCORES"])
        #expect(complete("ZRANGE k 0 -1 BY|")?.prefix == "BY")
        #expect(labels("ZRANGE k 0 -1 BYSCORE |", .option) == ["REV", "LIMIT", "WITHSCORES"])
        #expect(labels("ZRANGE k 0 -1 WITHSCORES REV |", .option) == ["BYSCORE", "BYLEX", "LIMIT"])
        // ZRANGE k 0 BYSCORE would read BYSCORE as the stop.
        #expect(labels("ZRANGE k 0 |", .option).isEmpty)
        #expect(labels("SET k v |", .option) == ["NX", "XX", "GET", "EX", "PX", "EXAT", "PXAT", "KEEPTTL"])
        #expect(labels("set k v nx |", .option) == ["get", "ex", "px", "exat", "pxat", "keepttl"])
        #expect(labels("SET k v EX 60 |", .option) == ["NX", "XX", "GET"])
        #expect(try item("SET k v |", "EX").detail == "EX seconds")
        #expect(try item("SET k v |", "NX").detail == "NX | XX")
        #expect(try item("ZRANGE k 0 -1 |", "LIMIT").detail == "LIMIT offset count")
        #expect(try item("SET k v |", "EX").documentation?.hasPrefix("SET key value [NX | XX]") == true)
        // A value goes here: SET k NX would set k to "NX".
        #expect(complete("SET k |") == nil)
        #expect(complete("EXPIRE k |") == nil)
        #expect(labels("EXPIRE k 60 |", .option) == ["NX", "XX", "GT", "LT"])
        #expect(labels("SCAN 0 |", .option) == ["MATCH", "COUNT", "TYPE"])
        #expect(labels("SCAN 0 MATCH user:* |", .option) == ["COUNT", "TYPE"])
        #expect(labels("HSCAN h 0 |", .option) == ["MATCH", "COUNT", "NOVALUES"])
        #expect(labels("XADD s |", .option) == ["NOMKSTREAM", "MAXLEN", "MINID", "*"])
        #expect(labels("XADD s MAXLEN |", .option) == ["=", "~"])
        #expect(labels("XREAD |", .option) == ["COUNT", "BLOCK", "STREAMS"])
        #expect(labels("GETEX k |", .option) == ["EX", "PX", "EXAT", "PXAT", "PERSIST"])
        #expect(labels("LMPOP 2 a b |", .option) == ["LEFT", "RIGHT"])
        #expect(labels("ZUNION 2 a b |", .option) == ["WEIGHTS", "AGGREGATE", "WITHSCORES"])
        #expect(labels("ZUNION 2 a b AGGREGATE |", .option) == ["SUM", "MIN", "MAX"])
        #expect(labels("XGROUP CREATE s g |", .option) == ["$"])
        #expect(labels("FLUSHALL |", .option) == ["ASYNC", "SYNC"])
        // Options are words, not quoted strings.
        #expect(complete("SET k v \"N|") == nil)
    }

    @Test func suggestedValues() {
        #expect(labels("SCAN 0 TYPE |", .value) == ["string", "list", "set", "zset", "hash", "stream"])
        #expect(labels("INFO |", .value).contains("memory"))
        #expect(labels("INFO memory |", .value).contains("keyspace"))
        #expect(labels("CONFIG GET |", .value).contains("maxmemory"))
        #expect(complete("SCAN 0 TYPE |")?.items.first?.detail == "type")
    }

    // MARK: Keys

    @Test func keyPositionsPerCommandFamily() {
        // Strings, keys, hashes, lists, sets, sorted sets, streams, and the server's key commands.
        for line in [
            "GET |", "MGET a b |", "SET |", "INCR |", "DEL a |", "EXISTS |", "TTL |", "EXPIRE |", "RENAME a |", "COPY a |",
            "HGETALL |", "HSET |", "HSCAN |", "LRANGE |", "LPUSH |", "BLPOP |", "BLPOP a |", "LMOVE src |", "LMPOP 2 |", "LMPOP 2 a |",
            "SMEMBERS |", "SINTER a |", "SINTERSTORE dst |", "SMOVE a |", "ZRANGE |", "ZADD |", "ZUNIONSTORE dst 2 |", "ZUNION 2 a |",
            "ZRANGESTORE dst |", "XADD |", "XRANGE |", "XREAD STREAMS |", "XREAD STREAMS a |", "XREAD COUNT 10 STREAMS a |", "XREADGROUP GROUP g c STREAMS |",
            "XINFO STREAM |", "XGROUP CREATE |", "MEMORY USAGE |", "OBJECT ENCODING |", "TYPE |",
        ] {
            #expect(labels(line, .key, keys: keys).contains("user:1"), "\(line) is a key position")
        }
        for line in [
            "SET k |", "SET k v |", "GET k |", "HGET h |", "HSET h f |", "LRANGE l |", "LRANGE l 0 |", "SMOVE a b |", "ZADD z |",
            "ZUNIONSTORE dst |", "ZUNION |", "SCAN |", "SCAN 0 MATCH |", "XADD s |", "XREAD STREAMS a b 0 |", "EXPIRE k |", "SELECT |",
            "INFO |", "DBSIZE |", "CONFIG GET |", "FOO |", "GEOADD |", "CLIENT KILL |",
        ] {
            #expect(labels(line, .key, keys: keys).isEmpty, "\(line) isn't a key position")
        }
    }

    @Test func keysOfTheCommandsTypeFirstEachOnce() throws {
        let hash = try #require(complete("HGETALL |", keys: keys))
        #expect(hash.items.first { $0.label == "user:1" }?.rank == 0)
        #expect(hash.items.first { $0.label == "user:2" }?.rank == 2)
        #expect(hash.items.first { $0.label == "my key" }?.rank == 1, "a key whose type isn't known")
        #expect(hash.items.first { $0.label == "user:1" }?.detail == "hash · key browser")
        #expect(hash.items.first { $0.label == "my key" }?.detail == "loaded for completion")
        #expect(hash.items.first { $0.label == "events" }?.detail == "a reply in this tab")
        #expect(try item("GET u|", "user:2", keys: keys).rank == 0)
        #expect(try item("XRANGE |", "events", keys: keys).kind == .key)
        // DEL works on any type.
        #expect(Set(complete("DEL |", keys: keys)?.items.map(\.rank) ?? []) == [1])
        // A key the browser and a reply both list shows once, with the browser's type.
        let twice = keys + [.init(name: "user:1", source: .reply)]
        #expect(complete("HGET |", keys: twice)?.items.filter { $0.label == "user:1" }.count == 1)
        #expect(complete("HGET |", keys: twice)?.items.first { $0.label == "user:1" }?.detail == "hash · key browser")
        // No keys known: nothing (without Load Keys for Completion).
        #expect(complete("GET |") == nil)
    }

    @Test func keyNamesAreQuotedTheWayTheTabReadsThem() throws {
        let odd: [RedisCompletion.KnownKey] = [
            .init(name: "my key", source: .loaded), .init(name: "say \"hi\"", source: .loaded), .init(name: "it's", source: .loaded),
            .init(name: "line\nbreak", source: .loaded), .init(name: "back\\slash", source: .loaded), .init(name: "café:1", source: .loaded),
        ]
        // Unquoted: the typed word matches the name, the whole word is replaced by it, quoted.
        let plain = try item("GET my|", "my key", keys: odd)
        #expect(plain.insertText == "\"my key\"" && plain.filterText == "my key")
        #expect(complete("GET my|", keys: odd)?.anchor == 4)
        #expect(try item("GET s|", "say \"hi\"", keys: odd).insertText == #""say \"hi\"""#)
        #expect(try item("GET l|", "\"line\\nbreak\"", keys: odd).insertText == #""line\nbreak""#)
        #expect(try item("GET b|", "back\\slash", keys: odd).insertText == #""back\\slash""#)
        #expect(try item("GET c|", "café:1", keys: odd).insertText == "\"café:1\"")
        // In a double quote the editor closed: replaced from the opening quote, which stays.
        let paired = try #require(complete("GET \"my k|\"", keys: odd))
        #expect(paired.anchor == 4 && paired.prefix == "\"my k")
        let quoted = try #require(paired.items.first { $0.label == "my key" })
        #expect(quoted.insertText == "\"my key" && quoted.filterText == "\"my key")
        // In a double quote that isn't closed yet: closed.
        #expect(try item("GET \"my|", "my key", keys: odd).insertText == "\"my key\"")
        #expect(try item("GET \"sa|", "say \"hi\"", keys: odd).insertText == #""say \"hi\"""#)
        // Single quotes escape only \': a name with a backslash or a line break isn't offered there.
        #expect(try item("GET 'it|'", "it's", keys: odd).insertText == #"'it\'s"#)
        #expect(try item("GET 'i|", "it's", keys: odd).insertText == #"'it\'s'"#)
        #expect(complete("GET 'b|", keys: odd)?.items.contains { $0.label == "back\\slash" } == false)
        // Every insertion reads back as the key's exact name.
        var checked = 0
        for key in odd {
            let label = key.name.contains("\n") ? RedisScript.quoted(key.name) : key.name
            for marked in ["GET |", "GET \"|", "GET \"|\"", "GET '|", "GET '|'"] {
                let caret = (marked as NSString).range(of: "|").location
                let text = (marked as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "")
                let result = try #require(RedisCompletion.suggestions(in: text, caret: caret, keys: odd))
                // Single quotes can't hold a backslash or a line break.
                guard let found = result.items.first(where: { $0.label == label }) else {
                    #expect(marked.contains("'") && (key.name.contains("\\") || key.name.contains("\n")), "\(key.name) missing at \(marked)")
                    continue
                }
                let edited = (text as NSString).replacingCharacters(in: NSRange(location: result.anchor, length: caret - result.anchor), with: found.insertText)
                let parsed = try RedisScript.parse(edited).get()
                #expect(parsed.last.map { String(decoding: $0, as: UTF8.self) } == key.name, "\(marked) with \(key.name): \(edited)")
                checked += 1
            }
        }
        #expect(checked == odd.count * 5 - 4)
        // The prefix of a quoted word is its text, unescaped.
        #expect(RedisCompletion.context(in: #"GET "a\"b"#, caret: 9)?.prefix == "a\"b")
        #expect(RedisCompletion.context(in: #"HGET "my hash" f"#, caret: 16)?.words == ["HGET", "my hash"])
    }

    @Test func loadKeysForCompletionOnlyInKeyPositions() throws {
        let offer = RedisCompletion.KeyLoadOffer(title: "Load Keys for Completion…", detail: "SCAN 0 MATCH u* COUNT 1000")
        let result = try #require(complete("GET u|", offer: offer))
        let action = try #require(result.items.last)
        #expect(action.kind == .action && action.action == RedisCompletion.loadKeysAction && action.insertText.isEmpty)
        #expect(action.label == offer.title && action.detail == offer.detail)
        #expect(complete("SET k v |", offer: offer)?.items.contains { $0.kind == .action } == false)
        #expect(complete("SET k |", offer: offer) == nil)
        #expect(complete("GE|", offer: offer)?.items.contains { $0.kind == .action } == false)
    }

    @Test func loadPatternEscapesGlobCharacters() {
        #expect(RedisCompletion.loadPattern(prefix: "") == "*")
        #expect(RedisCompletion.loadPattern(prefix: "user:") == "user:*")
        #expect(RedisCompletion.loadPattern(prefix: #"a*b?[c]\"#) == #"a\*b\?\[c\]\\*"#)
    }

    @Test func knownKeysFromTheBrowserLoadsAndRepliesOfThatDatabase() {
        let browser: [RedisKeyEntry] = [
            RedisKeyEntry(key: "user:1", raw: Data("user:1".utf8).base64EncodedString(), type: "hash"),
            RedisKeyEntry(key: nil, raw: Data([0xff]).base64EncodedString(), type: "string"),
        ]
        let scan = RedisReplyInfo(argv: ["SCAN", "0"], reply: .array([.string("0"), .array([.string("a"), .string("b")], omitted: 0)], omitted: 0), db: 0)
        let keysReply = RedisReplyInfo(argv: ["keys", "*"], reply: .array([.string("c")], omitted: 0))
        let random = RedisReplyInfo(argv: ["RANDOMKEY"], reply: .string("d"), db: 0)
        let elsewhere = RedisReplyInfo(argv: ["SCAN", "0"], reply: .array([.string("0"), .array([.string("other-db")], omitted: 0)], omitted: 0), db: 3)
        let get = RedisReplyInfo(argv: ["GET", "x"], reply: .string("value"), db: 0)
        let known = RedisCompletion.knownKeys(db: 0, browser: (0, browser), loaded: ["e"], replies: [scan, keysReply, random, elsewhere, get])
        #expect(known.map(\.name) == ["user:1", "e", "a", "b", "c", "d"])
        #expect(known.first?.type == "hash" && known.first?.source == .keyBrowser)
        // The browser's scan of another database isn't this one's.
        #expect(RedisCompletion.knownKeys(db: 1, browser: (0, browser), loaded: [], replies: []).isEmpty)
    }

    // MARK: The same table as the builder and the run's classification

    @Test func completionUsesTheBuildersSpecs() throws {
        for spec in RedisCommandSpecs.all {
            let command = try #require(RedisCompletion.commands.first { $0.name == spec.name }, "\(spec.name) isn't offered")
            #expect(command.spec == spec)
            #expect(([spec.name] + [command.argumentSyntax].filter { !$0.isEmpty }).joined(separator: " ") == spec.syntax)
            // What the list shows is the spec's syntax and summary.
            let words = spec.words
            let marked = words.count == 1 ? String(words[0].prefix(3)) + "|" : words[0] + " " + String(words[1].prefix(2)) + "|"
            let offered = try item(marked, words.last!)
            #expect(offered.detail == (command.argumentSyntax.isEmpty ? nil : command.argumentSyntax), "\(spec.name)")
            #expect(offered.documentation?.hasPrefix(spec.summary) == true, "\(spec.name)")
            #expect(offered.badges == RedisCompletion.badges(spec.info), "\(spec.name)")
        }
    }

    @Test func completionTableAndClassificationTableAgreeOnCommandNames() {
        let offered = Set(RedisCompletion.commands.map { $0.words.joined(separator: "|") })
        for command in RedisCompletion.commands {
            #expect(RedisCommands.isKnown(command.words.joined(separator: "|")), "\(command.name) isn't classified")
            #expect(command.info.access != .unknown && command.info.access != .streaming, "\(command.name)")
            #expect(command.info == RedisCommands.classify(command.words))
        }
        let classified = RedisCommands.reads.union(RedisCommands.connection).union(RedisCommands.transaction).union(RedisCommands.writes)
            .union(RedisCommands.dangerous.keys).union(RedisCommands.blocking).subtracting(RedisCommands.streaming).subtracting(RedisCommands.containers)
        #expect(classified.subtracting(offered).isEmpty, "classified but not offered: \(classified.subtracting(offered).sorted())")
        #expect(offered.subtracting(classified).subtracting(RedisCommandSpecs.all.map(\.tableKey)).isEmpty)
        // Every container is offered, with its subcommands.
        let containers = labels("|", .command).filter { RedisCommands.containers.contains($0) }
        #expect(Set(containers) == RedisCommands.containers)
        for container in RedisCommands.containers {
            #expect(!RedisCompletion.subcommands(of: container).isEmpty, "\(container) has no subcommands")
        }
    }

    // MARK: Hover

    @Test func hoverOnACommandShowsItsSyntaxAndSummary() throws {
        let text = "ZRANGE scores 0 -1 WITHSCORES\nclient list\nFLUSHDB\nCLIENT\nGEOADD k 1 2 m\n# GET k"
        let zrange = try #require(RedisCompletion.hover(in: text, at: 2))
        #expect(zrange.contains("ZRANGE key start stop [BYSCORE | BYLEX] [REV] [LIMIT offset count] [WITHSCORES]"))
        #expect(zrange.contains("Returns members in a range of ranks"))
        #expect(zrange.contains("Sorted Sets · Reads only"))
        let client = try #require(RedisCompletion.hover(in: text, at: 31))
        #expect(client.contains("CLIENT LIST [TYPE <NORMAL | MASTER | REPLICA | PUBSUB>]") && client.contains("Lists the connected clients."))
        #expect(RedisCompletion.hover(in: text, at: 38) == client, "on the subcommand too")
        #expect(try #require(RedisCompletion.hover(in: text, at: 43)).contains("Dangerous: it deletes every key in the current database"))
        #expect(try #require(RedisCompletion.hover(in: text, at: 51)).contains("Subcommands: CACHING"))
        #expect(try #require(RedisCompletion.hover(in: text, at: 57)).contains("Runlet has no syntax for its arguments"))
        // Arguments, comments, and past the end: nothing.
        #expect(RedisCompletion.hover(in: text, at: 9) == nil)
        #expect(RedisCompletion.hover(in: text, at: (text as NSString).length - 3) == nil)
        #expect(RedisCompletion.hover(in: text, at: 10_000) == nil)
    }
}
