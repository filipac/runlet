import Foundation
import Testing
@testable import RunletCore

/// App Info panels (#19): decoding the runner's `panels` events, the app's own bounds, the
/// redaction rule, and when opening App Info runs anything.
struct AppInfoTests {
    private func frame(_ json: String) -> Data { Data(json.utf8) }

    // MARK: Decoding

    @Test func decodesBuiltinAndDriverEventsInOrder() throws {
        var report = AppInfoReport()
        try report.add(panelsFrame: frame("""
        {"origin": "builtin", "source": "Laravel", "redacted": 0, "sections": [
          {"title": "Environment", "rows": [
            {"key": "Application Name", "value": "Shop"},
            {"key": "Debug Mode", "value": "Enabled"}]},
          {"title": "PHP", "rows": [
            {"key": "PDO drivers", "value": ["mysql", "sqlite"]},
            {"key": "Extensions", "value": 68}]}]}
        """))
        try report.add(panelsFrame: frame("""
        {"origin": "driver", "source": "AcmeApiDriver", "driverFile": ".runlet/AcmeApiDriver.php", "redacted": 1, "sections": [
          {"title": "Acme", "rows": [
            {"key": "Read-only", "value": false},
            {"key": "Ratio", "value": 0.25},
            {"key": "Region", "value": null},
            {"key": "API token", "value": "••••••", "redacted": true}], "omittedRows": 3}],
          "notes": ["AcmeApiDriver returned panels that are not sections of rows, which Runlet skipped: #0."]}
        """))
        #expect(report.sections.map(\.title) == ["Environment", "PHP", "Acme"])
        #expect(report.sections.map(\.origin) == [.builtin, .builtin, .driver])
        #expect(report.sections[2].source == "AcmeApiDriver")
        #expect(report.sections[2].omittedRows == 3)
        #expect(report.driverFile == ".runlet/AcmeApiDriver.php")
        #expect(report.sections[0].rows[1] == AppInfoRow(key: "Debug Mode", value: .text("Enabled")))
        #expect(report.sections[1].rows[0].value == .list(["mysql", "sqlite"]))
        #expect(report.sections[1].rows[1].value == .integer(68))
        let acme = report.sections[2].rows
        #expect(acme[0].value == .flag(false) && acme[0].value.displayText == "No")
        #expect(acme[1].value == .number(0.25) && acme[1].value.displayText == "0.25")
        #expect(acme[2].value == AppInfoValue.none && acme[2].value.displayText == "—")
        #expect(acme[3].redacted && acme[3].value.displayText == AppInfoRedaction.mask)
        #expect(report.redactedCount == 1, "the runner's count; already-redacted rows aren't counted twice")
        #expect(report.notes.count == 1)
        #expect(report.hasSections)
        // Lists copy one item per line.
        #expect(AppInfoValue.list(["a", "b"]).copyText == "a\nb")
        #expect(AppInfoValue.integer(3).copyText == "3")
    }

    @Test func driverErrorsKeepTheBuiltinSections() throws {
        var report = AppInfoReport()
        try report.add(panelsFrame: frame(#"{"origin": "builtin", "source": "Laravel", "sections": [{"title": "PHP", "rows": [{"key": "Version", "value": "8.4.1"}]}]}"#))
        try report.add(panelsFrame: frame(#"{"origin": "driver", "source": "OpsDriver", "sections": [], "error": "Runlet driver OpsDriver (.runlet/OpsDriver.php) failed in panels(): boom"}"#))
        #expect(report.sections.map(\.title) == ["PHP"])
        #expect(report.driverError?.hasSuffix("failed in panels(): boom") == true)
        // A built-in failure is a note.
        try report.add(panelsFrame: frame(#"{"origin": "builtin", "sections": [], "error": "Runlet could not read the App Info: nope"}"#))
        #expect(report.notes.last == "Runlet could not read the App Info: nope")
    }

    @Test func malformedFramesThrowAndOddValuesStillDecode() throws {
        var report = AppInfoReport()
        #expect(throws: (any Error).self) { try report.add(panelsFrame: Data("not json".utf8)) }
        // Missing fields are tolerated; an object value becomes a placeholder.
        try report.add(panelsFrame: frame(#"{"sections": [{"rows": [{"key": "x"}, {"key": "y", "value": {"a": 1}}]}]}"#))
        #expect(report.sections.first?.title == "Untitled")
        #expect(report.sections.first?.rows.first?.value == AppInfoValue.none)
        #expect(report.sections.first?.rows.last?.value == .text("(object)"))
        #expect(report.sections.first?.origin == .builtin)
    }

    // MARK: Bounds

    @Test func boundsSectionsRowsListsAndLengths() throws {
        var report = AppInfoReport()
        let rows = (0..<130).map { #"{"key": "row \#($0)", "value": "v"}"# }.joined(separator: ",")
        let longValue = String(repeating: "x", count: 5000)
        let longKey = String(repeating: "k", count: 500)
        let list = (0..<80).map { #""item\#($0)""# }.joined(separator: ",")
        try report.add(panelsFrame: frame("""
        {"sections": [
          {"title": "Many", "rows": [\(rows)]},
          {"title": "\(String(repeating: "T", count: 300))", "rows": [
            {"key": "\(longKey)", "value": "\(longValue)"},
            {"key": "List", "value": [\(list)]}]}]}
        """))
        let many = report.sections[0]
        #expect(many.rows.count == AppInfoLimits.maxRows)
        #expect(many.omittedRows == 30)
        let long = report.sections[1]
        #expect(long.title.count == AppInfoLimits.maxTitleCharacters + 1 && long.title.hasSuffix("…"))
        #expect(long.rows[0].key.count == AppInfoLimits.maxKeyCharacters + 1)
        #expect(long.rows[0].value.displayText.count == AppInfoLimits.maxValueCharacters + 1)
        guard case .list(let items) = long.rows[1].value else { Issue.record("not a list"); return }
        #expect(items.count == AppInfoLimits.maxListItems + 1)
        #expect(items.last == "… 30 more")

        // At most 20 sections in all, across events.
        let sections = (0..<25).map { #"{"title": "S\#($0)", "rows": []}"# }.joined(separator: ",")
        try report.add(panelsFrame: frame(#"{"origin": "driver", "sections": [\#(sections)], "omittedSections": 2}"#))
        #expect(report.sections.count == AppInfoLimits.maxSections)
        #expect(report.omittedSections == 2 + 25 - (AppInfoLimits.maxSections - 2))
    }

    // MARK: Redaction

    @Test func secretKeysAreRecognisedByTheirWords() {
        for key in ["APP_KEY", "DB_PASSWORD", "db-pass", "stripeSecret", "API token", "apiKey", "APIKEY", "AUTH_SALT", "SECURE_AUTH_KEY",
                    "MAILER_DSN", "Session cookie", "aws_secret_access_key", "client-credentials", "dbpassword", "Signature", "NONCE_KEY", "github_token"] {
            #expect(AppInfoRedaction.isSecretKey(key), "\(key)")
        }
        for key in ["Application Name", "Debug Mode", "Environment", "Cache", "Database", "URL", "WP_DEBUG", "Table prefix", "Monkey",
                    "Keyboard layout", "Passenger", "Locale", "public/storage", "PDO drivers"] {
            #expect(!AppInfoRedaction.isSecretKey(key), "\(key)")
        }
    }

    @Test func secretLookingValuesAreMasked() {
        let mask = AppInfoRedaction.mask
        let cases: [(String, String)] = [
            ("mysql://shop:s3cret@db:3306/shop", "mysql://shop:\(mask)@db:3306/shop"),
            ("redis://:hunter2@cache:6379", "redis://:\(mask)@cache:6379"),
            ("https://example.com/path", "https://example.com/path"),
            ("https://user@example.com", "https://user@example.com"),
            ("mysql:host=db;dbname=shop;password=hunter2", "mysql:host=db;dbname=shop;password=\(mask)"),
            ("https://cdn.test/a.png?sig=abc123&w=10", "https://cdn.test/a.png?sig=\(mask)&w=10"),
            ("client_secret: 'xyz'", "client_secret: \(mask)"),
            ("base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", mask),
            ("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijk", mask),
            ("sk_live_51HabcdefghijKLMNOP", mask),
            ("token ghp_abcdefghijklmnopqrstuvwxyz0123", "token \(mask)"),
            ("AKIAIOSFODNN7EXAMPLE", mask),
            ("Authorization: Bearer abcdefghijklmnopqrstuvwxyz", "Authorization: Bearer \(mask)"),
            ("-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----", mask),
            ("stack / single", "stack / single"),
            ("Not cached", "Not cached"),
            ("bypass=1", "bypass=1"),
        ]
        for (input, expected) in cases {
            #expect(AppInfoRedaction.redactText(input) == expected, "\(input)")
        }
        #expect(AppInfoRedaction.redactValue(.list(["ok", "postgres://a:b@h/d"])) == .list(["ok", "postgres://a:\(mask)@h/d"]))
        #expect(AppInfoRedaction.redactValue(.integer(3)) == .integer(3))
    }

    @Test func decodingRedactsWhatTheRunnerMissed() throws {
        var report = AppInfoReport()
        try report.add(panelsFrame: frame("""
        {"origin": "driver", "source": "OldRunner", "sections": [{"title": "Leaky", "rows": [
          {"key": "STRIPE_SECRET", "value": "sk_test_abcdefghijklmnop"},
          {"key": "Queue", "value": "redis://:pw@cache"},
          {"key": "Keys", "value": ["a", "b"]},
          {"key": "Driver", "value": "redis"}]}]}
        """))
        let rows = report.sections[0].rows
        #expect(rows[0] == AppInfoRow(key: "STRIPE_SECRET", value: .text(AppInfoRedaction.mask), redacted: true))
        #expect(rows[1].value == .text("redis://:\(AppInfoRedaction.mask)@cache") && rows[1].redacted)
        #expect(rows[2].value == .text(AppInfoRedaction.mask) && rows[2].redacted)
        #expect(rows[3].value == .text("redis") && !rows[3].redacted)
        #expect(report.redactedCount == 3)
    }

    // MARK: Opening and production

    @Test func openingLoadsOnlyWhenNothingIsCachedOrOnRefresh() {
        // Nothing cached: a development target loads at once; production asks first.
        #expect(AppInfoPolicy.onOpen(hasResult: false, isLoading: false, refresh: false, environment: .development) == .load)
        #expect(AppInfoPolicy.onOpen(hasResult: false, isLoading: false, refresh: false, environment: .staging) == .load)
        #expect(AppInfoPolicy.onOpen(hasResult: false, isLoading: false, refresh: false, environment: .production) == .confirmThenLoad)
        // Cached (or failed) results are shown without running anything, production included.
        #expect(AppInfoPolicy.onOpen(hasResult: true, isLoading: false, refresh: false, environment: .production) == .show)
        #expect(AppInfoPolicy.onOpen(hasResult: true, isLoading: false, refresh: false, environment: .development) == .show)
        // Refresh loads again; production asks again.
        #expect(AppInfoPolicy.onOpen(hasResult: true, isLoading: false, refresh: true, environment: .development) == .load)
        #expect(AppInfoPolicy.onOpen(hasResult: true, isLoading: false, refresh: true, environment: .production) == .confirmThenLoad)
        // A load in progress is shown, never started twice.
        #expect(AppInfoPolicy.onOpen(hasResult: false, isLoading: true, refresh: true, environment: .production) == .show)
    }

    @Test func productionAsksForEveryLoadEvenWithinTheRunGrace() {
        let target = TargetRef.ssh(UUID())
        var grace = ProductionGrace()
        grace.grant(target)
        let run = grace.needsConfirmation(.run, on: target, environment: .production)
        let appInfo = grace.needsConfirmation(.appInfo, on: target, environment: .production)
        let development = grace.needsConfirmation(.appInfo, on: target, environment: .development)
        #expect(!run && appInfo && !development)
    }

    @Test func ageReadsNaturally() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        #expect(AppInfoPolicy.age(of: start, now: start.addingTimeInterval(2)) == "just now")
        #expect(AppInfoPolicy.age(of: start, now: start.addingTimeInterval(42)) == "42 s ago")
        #expect(AppInfoPolicy.age(of: start, now: start.addingTimeInterval(185)) == "3 min ago")
        #expect(AppInfoPolicy.age(of: start, now: start.addingTimeInterval(7300)) == "2 h ago")
        #expect(AppInfoPolicy.age(of: start, now: start.addingTimeInterval(90000)) == "1 day ago")
        #expect(AppInfoPolicy.age(of: start, now: start.addingTimeInterval(-10)) == "just now")
    }
}
