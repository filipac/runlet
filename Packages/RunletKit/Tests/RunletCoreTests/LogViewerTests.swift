import Foundation
@testable import RunletCore
import Testing

/// The log viewer's parsing, bounds, and filters (#20).
struct LogParsingTests {
    static let utc = TimeZone(secondsFromGMT: 0)!

    /// Laravel's default: `Y-m-d H:i:s`, no zone, the exception and its trace inside the
    /// context, over many lines.
    static let laravel = #"""
    [2026-10-04 10:22:31] local.INFO: Importing orders {"batch":42,"source":"api"}
    [2026-10-04 10:22:33] local.ERROR: Division by zero {"userId":7,"exception":"[object] (DivisionByZeroError(code: 0): Division by zero at /var/www/html/app/Services/Totals.php:18)
    [stacktrace]
    #0 /var/www/html/app/Http/Controllers/OrderController.php(31): App\\Services\\Totals->average()
    #1 /var/www/html/vendor/laravel/framework/src/Illuminate/Routing/Controller.php(54): App\\Http\\Controllers\\OrderController->show()
    #2 Standard input code(1234) : eval()'d code(5): App\\Http\\Controllers\\OrderController->show()
    #3 {main}
    "}
    [2026-10-04 10:22:34] local.WARNING: Slow query {"ms":812} []
    """#

    @Test func laravelEntriesGroupTheirTrace() throws {
        var buffer = LogBuffer(timeZone: Self.utc)
        buffer.append(Self.laravel + "\n")
        #expect(buffer.entries.count == 3)
        let info = buffer.entries[0]
        #expect(info.format == .monolog)
        #expect(info.level == .info)
        #expect(info.channel == "local")
        #expect(info.message == "Importing orders")
        #expect(info.context == #"{"batch":42,"source":"api"}"#)
        #expect(info.extra == nil)
        #expect(info.timestampText == "2026-10-04 10:22:31")
        #expect(info.timestampHasZone == false)
        #expect(info.timestamp == Date(timeIntervalSince1970: 1_791_109_351))

        let error = buffer.entries[1]
        #expect(error.level == .error)
        #expect(error.message == "Division by zero")
        #expect(error.isMultiline)
        #expect(error.lines.count == 6)
        #expect(error.context?.hasPrefix(#"{"userId":7,"exception":"[object] (DivisionByZeroError"#) == true)
        #expect(error.context?.hasSuffix("\"}") == true)
        #expect(error.summary == "Division by zero")

        let frames = error.frames
        #expect(frames.map(\.path) == [
            "/var/www/html/app/Services/Totals.php",
            "/var/www/html/app/Http/Controllers/OrderController.php",
            "/var/www/html/vendor/laravel/framework/src/Illuminate/Routing/Controller.php",
            "Standard input code(1234) : eval()'d code",
        ])
        #expect(frames.map(\.line) == [18, 31, 54, 5])
        #expect(frames[1].function == #"App\\Services\\Totals->average()"#)
        #expect(frames[3].snippetLine == 5)
        #expect(frames[0].shortLabel == "Totals.php:18")

        let warning = buffer.entries[2]
        #expect(warning.level == .warning)
        #expect(warning.message == "Slow query")
        #expect(warning.context == #"{"ms":812}"#)
    }

    @Test func monologDefaultFormatWithZoneAndExtra() {
        var buffer = LogBuffer(timeZone: .current)
        buffer.append(#"[2026-10-04T10:22:33.250000+02:00] request.CRITICAL: Uncaught PHP Exception RuntimeException: "boom" at /srv/app/src/Kernel.php line 12 {"exception":{"class":"RuntimeException"}} {"request_id":"abc"}"# + "\n")
        let entry = buffer.entries[0]
        #expect(entry.level == .critical)
        #expect(entry.channel == "request")
        #expect(entry.timestampHasZone)
        #expect(entry.timestamp == Date(timeIntervalSince1970: 1_791_102_153.25))
        #expect(entry.message == #"Uncaught PHP Exception RuntimeException: "boom" at /srv/app/src/Kernel.php line 12"#)
        #expect(entry.context == #"{"exception":{"class":"RuntimeException"}}"#)
        #expect(entry.extra == #"{"request_id":"abc"}"#)
    }

    @Test func messagesWithBracesKeepThem() {
        var buffer = LogBuffer(timeZone: Self.utc)
        buffer.append("[2026-10-04 10:00:00] app.NOTICE: Template {name} [draft] rendered {\"name\":\"x\"} []\n")
        buffer.append("[2026-10-04 10:00:01] app.DEBUG: No context here at all\n")
        buffer.append("[2026-10-04 10:00:02] app.DEBUG: Ends with a bracket [ok]\n")
        #expect(buffer.entries[0].message == "Template {name} [draft] rendered")
        #expect(buffer.entries[0].context == #"{"name":"x"}"#)
        #expect(buffer.entries[1].message == "No context here at all")
        #expect(buffer.entries[1].context == nil)
        // A lone trailing value is read as the context: Monolog always writes context before extra.
        #expect(buffer.entries[2].message == "Ends with a bracket")
        #expect(buffer.entries[2].context == "[ok]")
    }

    @Test func jsonFormatterLines() {
        var buffer = LogBuffer(timeZone: Self.utc)
        buffer.append(#"""
        {"message":"Payment captured","context":{"order":12,"amount":"19.99"},"level":200,"level_name":"INFO","channel":"billing","datetime":"2026-10-04T10:22:33.000000+00:00","extra":{}}
        {"message":"Gateway refused","context":{"exception":{"class":"App\\Gateway\\Refused","message":"card declined","code":402,"file":"/var/www/html/app/Gateway/Client.php:88","trace":["/var/www/html/app/Jobs/Charge.php:41"]}},"level":400,"level_name":"ERROR","channel":"billing","datetime":"2026-10-04T10:22:34+00:00","extra":{"uid":"9f3"}}
        {"msg":"from another logger","level":"warn","time":1791109355}
        """# + "\n")
        #expect(buffer.entries.count == 3)
        let first = buffer.entries[0]
        #expect(first.format == .json)
        #expect(first.level == .info)
        #expect(first.channel == "billing")
        #expect(first.message == "Payment captured")
        #expect(first.context == #"{"amount":"19.99","order":12}"#)
        #expect(first.extra == nil)
        #expect(first.timestamp == Date(timeIntervalSince1970: 1_791_109_353))
        let second = buffer.entries[1]
        #expect(second.level == .error)
        #expect(second.extra?.contains("9f3") == true)
        #expect(second.frames.map(\.shortLabel) == ["Client.php:88", "Charge.php:41"])
        let third = buffer.entries[2]
        #expect(third.level == .warning)
        #expect(third.message == "from another logger")
        #expect(third.timestamp == Date(timeIntervalSince1970: 1_791_109_355))
    }

    @Test func phpErrorLogAsWordPressWritesIt() {
        var buffer = LogBuffer()
        buffer.append("""
        [04-Oct-2026 10:22:33 UTC] PHP Warning:  Undefined variable $total in /srv/site/wp-content/themes/shop/functions.php on line 14
        [04-Oct-2026 10:22:34 UTC] PHP Fatal error:  Uncaught Error: Call to undefined function shop_total() in /srv/site/wp-content/plugins/cart/cart.php:9
        Stack trace:
        #0 /srv/site/wp-includes/class-wp-hook.php(324): cart_init('')
        #1 {main}
          thrown in /srv/site/wp-content/plugins/cart/cart.php on line 9
        [04-Oct-2026 10:22:35 UTC] cart: 3 items restored

        """)
        #expect(buffer.entries.count == 3)
        #expect(buffer.entries[0].format == .phpError)
        #expect(buffer.entries[0].level == .warning)
        #expect(buffer.entries[0].timestamp == Date(timeIntervalSince1970: 1_791_109_353))
        #expect(buffer.entries[0].frames.map(\.shortLabel) == ["functions.php:14"])
        #expect(buffer.entries[1].level == .critical)
        #expect(buffer.entries[1].lines.count == 4)
        #expect(buffer.entries[1].frames.map(\.shortLabel) == ["cart.php:9", "class-wp-hook.php:324"])
        #expect(buffer.entries[2].level == nil)
        #expect(buffer.entries[2].message == "cart: 3 items restored")
    }

    @Test func plainLinesAndMalformedInput() {
        var buffer = LogBuffer(timeZone: Self.utc)
        buffer.append(Data("""
        [not a date] local.ERROR: almost Monolog
        {"message": "cut off
        {"just":"an object"}
        [2026-13-45 99:99:99] local.BOGUS: not a level
        WARNING: [pool www] child 12 said into stderr
        Fatal: something odd
            at indented continuation
        \u{FF}\u{FE} bytes
        last line without newline
        """.utf8) + Data([0xC3, 0x28]) + Data("\r\n".utf8))
        let entries = buffer.entries
        #expect(entries.allSatisfy { $0.format == .plain })
        #expect(entries.map(\.header).first == "[not a date] local.ERROR: almost Monolog")
        #expect(entries.first { $0.header.hasPrefix("WARNING:") }?.level == .warning)
        #expect(entries.first { $0.header.hasPrefix("Fatal:") }?.lines == ["    at indented continuation"])
        // Invalid UTF-8 is replaced, never dropped, and CRLF loses its CR.
        #expect(entries.last?.header.hasPrefix("last line without newline") == true)
        #expect(entries.last?.header.hasSuffix("\r") == false)
        #expect(entries.count == 8)
    }

    @Test func partialLinesWaitForTheirNewlineAndOffsetsCount() {
        var buffer = LogBuffer(timeZone: Self.utc)
        buffer.begin(at: 100)
        buffer.append("[2026-10-04 10:00:00] app.INFO: one []\n[2026-10-04 10:00:01] app.INF")
        #expect(buffer.entries.count == 1)
        #expect(buffer.hasPartialLine)
        buffer.append("O: two []\n", receivedAt: Date(timeIntervalSince1970: 5))
        #expect(buffer.entries.map(\.message) == ["one", "two"])
        #expect(buffer.entries[0].offset == 100)
        #expect(buffer.entries[1].offset == 100 + 39)
        #expect(buffer.entries[1].receivedAt == Date(timeIntervalSince1970: 5))
        #expect(buffer.position == 100 + 39 + 39)
        buffer.append("[2026-10-04 10:00:02] app.INFO: tail without newline")
        buffer.flush()
        #expect(buffer.entries.last?.message == "tail without newline")
        // After a Monolog entry, a line that isn't a header is part of it (a multi-line message).
        buffer.append("second line of the message\n")
        #expect(buffer.entries.last?.lines == ["second line of the message"])
        #expect(!buffer.hasPartialLine)
    }

    @Test func aTraceArrivingLaterJoinsItsEntry() {
        var buffer = LogBuffer(timeZone: Self.utc)
        buffer.append("[2026-10-04 10:00:00] app.ERROR: boom {\"exception\":\"[object] (Exception(code: 0): boom at /a/b.php:3)\n")
        #expect(buffer.entries[0].message.hasPrefix("boom {"))
        buffer.append("[stacktrace]\n#0 {main}\n\"} \n")
        #expect(buffer.entries.count == 1)
        #expect(buffer.entries[0].message == "boom")
        #expect(buffer.entries[0].lines.count == 3)
        // A new source (rotation) never continues the old entry.
        buffer.begin(at: 0)
        buffer.append("#0 /x/y.php(1): f()\n")
        #expect(buffer.entries.count == 2)
    }

    @Test func memoryIsBounded() {
        var buffer = LogBuffer(capacity: 10, timeZone: Self.utc)
        for index in 0..<25 { buffer.append("[2026-10-04 10:00:00] app.INFO: entry \(index) []\n") }
        #expect(buffer.entries.count == 10)
        #expect(buffer.dropped == 15)
        #expect(buffer.entries.first?.message == "entry 15")
        #expect(buffer.entries.map(\.id) == Array(16...25))

        var traces = LogBuffer(timeZone: Self.utc)
        traces.append("[2026-10-04 10:00:00] app.ERROR: deep []\n")
        traces.append(String(repeating: "#1 /a.php(1): f()\n", count: LogBuffer.maxLinesPerEntry + 5))
        #expect(traces.entries[0].lines.count == LogBuffer.maxLinesPerEntry)
        #expect(traces.entries[0].omittedLines == 5)
        #expect(traces.entries[0].copyText.hasSuffix("… 5 more lines not kept"))

        var long = LogBuffer(timeZone: Self.utc)
        long.append(String(repeating: "x", count: LogBuffer.maxLineBytes * 2) + "\nnext\n")
        #expect(long.entries.count == 2)
        #expect(long.entries[0].header.utf8.count <= LogBuffer.maxLineBytes + 4)
        #expect(long.entries[1].header == "next")

        buffer.clear()
        #expect(buffer.entries.isEmpty && buffer.dropped == 0)
        buffer.append("[2026-10-04 10:00:00] app.INFO: after clear []\n")
        #expect(buffer.entries.map(\.id) == [26])
    }

    @Test func levelsAndAliases() {
        #expect(LogLevel(name: "WARN") == .warning)
        #expect(LogLevel(name: "fatal") == .critical)
        #expect(LogLevel(name: "nope") == nil)
        #expect(LogLevel(monolog: 250) == .notice)
        #expect(LogLevel(monolog: 450) == .error)
        #expect(LogLevel(monolog: 50) == nil)
        #expect(LogLevel.allCases.sorted() == LogLevel.allCases)
        #expect(LogLevel.emergency.label == "EMERGENCY")
    }

    @Test func filtersByLevelSearchAndRun() {
        var buffer = LogBuffer(timeZone: Self.utc)
        buffer.begin(at: 0)
        buffer.append("plain line\n" + Self.laravel + "\n")
        let entries = Array(buffer.entries.dropFirst()) + [buffer.entries[0]]
        #expect(LogFilter(minimumLevel: .warning).apply(entries).map(\.level) == [.error, .warning])
        #expect(LogFilter().apply(entries).count == 4)
        #expect(LogFilter(search: "totals average").apply(entries).count == 1)
        #expect(LogFilter(search: "SLOW").apply(entries).map(\.message) == ["Slow query"])
        #expect(LogFilter(minimumLevel: .debug).apply(entries).count == 3) // the plain line has no level

        // Written by the last run: the file's bytes from its start to its end…
        let second = try! #require(entries[1].offset)
        let third = try! #require(entries[2].offset)
        let byOffset = LogRunWindow(startedAt: .distantPast, endedAt: .distantPast, startOffset: second, endOffset: third)
        #expect(LogFilter(run: byOffset).apply(entries).map(\.message) == ["Division by zero"])
        // …or the time a follow read it…
        let at = Date(timeIntervalSince1970: 1000)
        var followed = LogBuffer()
        followed.append("[2026-10-04 10:00:00] app.INFO: before []\n", receivedAt: at.addingTimeInterval(-60))
        followed.append("[2026-10-04 10:00:00] app.INFO: during []\n", receivedAt: at.addingTimeInterval(1))
        followed.append("[2026-10-04 10:00:00] app.INFO: just after []\n", receivedAt: at.addingTimeInterval(6))
        followed.append("[2026-10-04 10:00:00] app.INFO: later []\n", receivedAt: at.addingTimeInterval(60))
        let byTime = LogRunWindow(startedAt: at, endedAt: at.addingTimeInterval(5))
        #expect(LogFilter(run: byTime).apply(followed.entries).map(\.message) == ["during", "just after"])
        // …or, for lines read before, their own time.
        let window = LogRunWindow(startedAt: Date(timeIntervalSince1970: 1_791_109_352.5), endedAt: Date(timeIntervalSince1970: 1_791_109_353.5), slack: 0)
        #expect(LogFilter(run: window).apply(entries).map(\.message) == ["Division by zero"])
    }

    @Test func timestamps() {
        #expect(LogTimestamps.iso("2026-10-04T10:22:33Z")?.date == Date(timeIntervalSince1970: 1_791_109_353))
        #expect(LogTimestamps.iso("2026-10-04 12:22:33+0200")?.date == Date(timeIntervalSince1970: 1_791_109_353))
        #expect(LogTimestamps.iso("2026-10-04 10:22:33", defaultZone: Self.utc)?.hasZone == false)
        #expect(LogTimestamps.iso("yesterday") == nil)
        #expect(LogTimestamps.phpErrorLog("04-Oct-2026 10:22:33", zone: "UTC") == Date(timeIntervalSince1970: 1_791_109_353))
        #expect(LogTimestamps.phpErrorLog("04-Oct-2026 10:22:33", zone: nil) == nil)
        #expect(LogTimestamps.display(Date(timeIntervalSince1970: 1_791_109_353), zone: Self.utc) == "2026-10-04 10:22:33")
    }

    @Test func framesInTextLines() {
        #expect(LogFrames.find(in: "at /app/User.php:42").map(\.shortLabel) == ["User.php:42"])
        #expect(LogFrames.find(in: "in /app/User.php on line 42").map(\.line) == [42])
        let trace = LogFrames.find(in: "#4 /app/vendor/x/Y.php(9): Y->z()")
        #expect(trace.first?.function == "Y->z()")
        #expect(trace.first?.range == 3..<(3 + "/app/vendor/x/Y.php(9)".utf16.count))
        #expect(LogFrames.find(in: "Standard input code(120) : eval()'d code:7").first?.snippetLine == 7)
        #expect(LogFrames.find(in: "nothing here.php or /etc/hosts").isEmpty)
    }
}

/// Reading log files on this Mac: bounded tail reads, following with rotation and
/// truncation, and finding the files (#20).
@Suite(.serialized) struct LogFileTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-logs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func file(_ name: String, _ text: String) throws -> String {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    func append(_ path: String, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test func tailReadsOnlyTheEndFromALineBoundary() throws {
        let line = "[2026-10-04 10:00:00] app.INFO: a line of the log []\n"
        let count = 40_000
        let path = try file("big.log", String(repeating: line, count: count))
        let size = UInt64(line.utf8.count * count)
        let chunk = try LogTail.read(path: path, maxBytes: 64 * 1024)
        #expect(chunk.data.count <= 64 * 1024)
        #expect(chunk.end == size)
        #expect(chunk.start == chunk.skipped)
        #expect(chunk.start % UInt64(line.utf8.count) == 0)
        #expect(String(decoding: chunk.data.prefix(1), as: UTF8.self) == "[")

        var buffer = LogBuffer()
        buffer.begin(at: chunk.start)
        buffer.append(chunk.data)
        #expect(buffer.entries.count == chunk.data.count / line.utf8.count)
        #expect(buffer.position == size)

        let small = try file("small.log", "one\ntwo\n")
        let whole = try LogTail.read(path: small)
        #expect(whole.start == 0 && whole.skipped == 0 && whole.data.count == 8)

        let range = try LogTail.read(path: path, range: 100..<300)
        #expect(range.start == 100 && range.end == 300)
        let capped = try LogTail.read(path: path, range: 0..<size, maxBytes: 1000)
        #expect(capped.end == size && capped.data.count == 1000 && capped.skipped == size - 1000)
        #expect(throws: LogTail.ReadError.self) { try LogTail.read(path: folder.appendingPathComponent("none.log").path) }
    }

    /// Collects a follower's events.
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [LogFileFollower.Event] = []
        func add(_ event: LogFileFollower.Event) { lock.withLock { events.append(event) } }
        var all: [LogFileFollower.Event] { lock.withLock { events } }
        var text: String {
            all.compactMap { if case .appended(let data, _, _) = $0 { String(decoding: data, as: UTF8.self) } else { nil } }.joined()
        }

        func wait(until condition: (Events) -> Bool, timeout: TimeInterval = 5) async {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition(self), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }
    }

    @Test func followsAppendsTruncationRotationAndRemoval() async throws {
        let path = try file("storage/logs/laravel.log", "first\n")
        let start = try LogTail.read(path: path)
        let events = Events()
        let queue = DispatchQueue(label: "test.log-follower")
        let follower = LogFileFollower(path: path, from: start.end, identity: start.identity, pollInterval: 0.5, throttle: 0.02, deliveryQueue: queue) { events.add($0) }
        defer { follower.cancel() }

        try append(path, "second\n")
        await events.wait { $0.text == "second\n" }
        #expect(events.text == "second\n")
        if case .appended(_, let at, let skipped) = events.all.first {
            #expect(at == 6 && skipped == 0)
        }

        // Truncation (copytruncate, `> laravel.log`): read again from the start.
        try Data("x\n".utf8).write(to: URL(fileURLWithPath: path), options: [])
        await events.wait { $0.all.contains(.truncated) && $0.text.hasSuffix("x\n") }
        #expect(events.all.contains(.truncated))
        #expect(events.text == "second\nx\n")

        // Rotation: the old file is renamed with a last line still unread; a new file appears.
        try append(path, "last of old\n")
        try FileManager.default.moveItem(atPath: path, toPath: path + ".1")
        _ = try file("storage/logs/laravel.log", "new file\n")
        await events.wait { $0.all.contains(.rotated) && $0.text.hasSuffix("new file\n") }
        #expect(events.all.contains(.rotated))
        #expect(events.text == "second\nx\nlast of old\nnew file\n")

        // Removal, then a file at the path again.
        try FileManager.default.removeItem(atPath: path)
        await events.wait { $0.all.contains(.missing) }
        #expect(events.all.contains(.missing))
        _ = try file("storage/logs/laravel.log", "back\n")
        await events.wait { $0.text.hasSuffix("back\n") }
        #expect(events.text.hasSuffix("back\n"))

        // After cancel nothing more arrives.
        follower.cancel()
        let count = events.all.count
        try append(path, "ignored\n")
        try await Task.sleep(for: .milliseconds(300))
        #expect(events.all.count == count)
    }

    @Test func aBigBurstIsReadBoundedly() async throws {
        let path = try file("burst.log", "")
        let events = Events()
        let follower = LogFileFollower(path: path, from: 0, identity: LogFileIdentity.of(path: path)?.identity, maxReadBytes: 4096, pollInterval: 0.5, throttle: 0.02, deliveryQueue: DispatchQueue(label: "test.burst")) { events.add($0) }
        defer { follower.cancel() }
        try append(path, String(repeating: "0123456789\n", count: 1000))
        await events.wait { !$0.text.isEmpty }
        guard case .appended(let data, let start, let skipped) = events.all.first else {
            Issue.record("nothing read: \(events.all)")
            return
        }
        #expect(data.count == 4096)
        #expect(skipped == 11_000 - 4096)
        #expect(start == skipped)
    }

    @Test func findsLogsInAProjectFolder() throws {
        _ = try file("storage/logs/laravel.log", "a\n")
        _ = try file("storage/logs/2026/10/laravel-2026-10-04.log", "b\n")
        _ = try file("storage/logs/.hidden/secret.log", "c\n")
        _ = try file("storage/logs/notes.txt", "d\n")
        _ = try file("var/log/dev.log", "e\n")
        _ = try file("wp-content/debug.log", "f\n")
        _ = try file("logs/custom/app.log", "g\n")
        _ = try file("logs/custom/worker-1.log", "h\n")
        _ = try file("logs/single.txt", "i\n")
        let found = LogDiscovery.find(in: folder.path, driverPaths: ["logs/custom/worker-*.log", "logs/single.txt", "/etc/hosts", "../outside.log", "logs/missing.log"])
        let relative = Set(found.map(\.relativePath))
        #expect(relative == ["storage/logs/laravel.log", "storage/logs/2026/10/laravel-2026-10-04.log", "var/log/dev.log", "wp-content/debug.log", "logs/custom/worker-1.log", "logs/single.txt"])
        #expect(found.prefix(2).allSatisfy { $0.origin == .driver })
        #expect(found.first { $0.relativePath == "var/log/dev.log" }?.origin == .symfony)
        #expect(LogDiscovery.find(in: folder.path, driverPaths: ["logs/custom"]).filter { $0.origin == .driver }.count == 2)
        #expect(LogDiscovery.find(in: folder.appendingPathComponent("none").path).isEmpty)
        #expect(LogDiscovery.usualPaths(framework: "laravel") == ["storage/logs/laravel.log"])
        #expect(LogDiscovery.usualPaths(framework: nil).count == 4)
    }
}
