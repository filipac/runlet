import Foundation
import Testing
@testable import RunletCore

struct PersistenceTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("runlet-store-\(UUID().uuidString)", isDirectory: true).appendingPathComponent("session.json")
    }

    @Test func roundTripsWithVersionedEnvelope() throws {
        let store = JSONDocumentStore<SessionState>(url: tempURL())
        let tab = TabState(title: "Tab 1", code: "echo 'ünï';", target: .docker(UUID()))
        try store.save(SessionState(tabs: [tab], selectedTabId: tab.id))
        let loaded = store.load(default: SessionState())
        #expect(loaded.value.tabs == [tab])
        #expect(loaded.recoveryNotes.isEmpty)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any]
        #expect(raw?["schemaVersion"] as? Int == persistenceSchemaVersion)
    }

    @Test func corruptFileIsPreservedAndLastGoodIsRestored() throws {
        let store = JSONDocumentStore<SessionState>(url: tempURL())
        let first = SessionState(tabs: [TabState(title: "first", code: "1")])
        let second = SessionState(tabs: [TabState(title: "second", code: "2")])
        try store.save(first)
        try store.save(second)
        try Data("{ not json".utf8).write(to: store.url)
        let loaded = store.load(default: SessionState())
        #expect(loaded.value.tabs.first?.title == "first")
        #expect(loaded.recoveryNotes.count == 2)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path)
        #expect(siblings.contains { $0.hasPrefix("session.corrupt-") })
    }

    @Test func newerSchemaIsNotSilentlyOverwritten() throws {
        let store = JSONDocumentStore<AppSettings>(url: tempURL())
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schemaVersion": 99, "savedAt": 0, "data": {}}"#.utf8).write(to: store.url)
        let loaded = store.load(default: AppSettings())
        #expect(!loaded.recoveryNotes.isEmpty)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path)
        #expect(siblings.contains { $0.contains("corrupt") })
    }

    @Test func settingsTolerateMissingKeys() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"fontSize": 16}"#.utf8))
        #expect(decoded.fontSize == 16)
        #expect(decoded.historyLimit == 1000)
        #expect(decoded.defaultTarget == .sandbox)
        #expect(decoded.libraryOpenBehavior == .reuseBlankTab)
        #expect(decoded.libraryPanelWidth == 320)
        #expect(decoded.editorSplitRight == 0.5)
        #expect(decoded.editorSplitBottom == 0.5)
    }

    @Test func editorSplitPositionsRoundTripAndRejectNonsense() throws {
        var settings = AppSettings()
        settings.editorSplitRight = 0.7
        settings.editorSplitBottom = 0.35
        let decoded = try JSONDecoder().decode(AppSettings.self, from: try JSONEncoder().encode(settings))
        #expect(decoded.editorSplitRight == 0.7)
        #expect(decoded.editorSplitBottom == 0.35)
        let invalid = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"editorSplitRight": 4, "editorSplitBottom": -1}"#.utf8))
        #expect(invalid.editorSplitRight == 0.5)
        #expect(invalid.editorSplitBottom == 0.5)
    }

    /// Format Code (#36): settings saved before formatting existed keep loading, with formatting
    /// before runs off; the new keys round-trip; unknown styles fall back to the default.
    @Test func formattingSettingsDefaultOffAndRoundTrip() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"fontSize": 15, "tabWidth": 2}"#.utf8))
        #expect(old.formatBeforeRun == false)
        #expect(old.formatStyle == .per)
        #expect(old.formatQuotes == .single)
        #expect(old.tabWidth == 2)
        var settings = AppSettings()
        settings.formatBeforeRun = true
        settings.formatStyle = .laravel
        settings.formatQuotes = .double
        let decoded = try JSONDecoder().decode(AppSettings.self, from: try JSONEncoder().encode(settings))
        #expect(decoded.formatBeforeRun && decoded.formatStyle == .laravel && decoded.formatQuotes == .double)
        let unknown = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"formatStyle": "pear", "formatQuotes": 3, "formatBeforeRun": "yes"}"#.utf8))
        #expect(unknown.formatStyle == .per && unknown.formatQuotes == .single && unknown.formatBeforeRun == false)
    }

    @Test func libraryOpenBehaviorRoundTripsAndToleratesUnknownValues() throws {
        var settings = AppSettings()
        settings.libraryOpenBehavior = .currentTab
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data).libraryOpenBehavior == .currentTab)
        let unknown = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"libraryOpenBehavior": "somewhereElse"}"#.utf8))
        #expect(unknown.libraryOpenBehavior == .reuseBlankTab)
    }

    @Test func dockerProfileValidation() {
        var profile = DockerProfile(name: "API", identity: ContainerIdentity(composeProject: "p", composeService: "app"), workingDirectory: "/var/www/html")
        #expect(profile.validate().isEmpty)
        profile.user = "sail"
        #expect(profile.validate().isEmpty)
        profile.user = "1000:1000"
        #expect(profile.validate().isEmpty)
        profile.user = "root; rm -rf /"
        profile.workingDirectory = "relative"
        profile.phpExecutable = "--version"
        #expect(Set(profile.validate()) == [.invalidUser, .relativeWorkingDirectory, .emptyPHP])
    }

    @Test func valueNodeDecodingAndPlainText() throws {
        let json = #"{"id":1,"type":"object","className":"App\\Models\\User","referenceId":"7","count":2,"entries":[{"key":"name","keyType":"property","visibility":"protected","value":{"id":2,"type":"string","length":3,"scalar":"Ana"}},{"key":"tags","keyType":"property","visibility":"public","value":{"id":3,"type":"array","count":300,"entries":[{"key":"0","keyType":"int","value":{"id":4,"type":"enum","className":"Tag","scalar":"Admin","backingValue":1}}],"truncation":{"reason":"children","omitted":299}}}]}"#
        let node = try JSONDecoder().decode(ValueNode.self, from: Data(json.utf8))
        #expect(node.entries?.last?.value.entries?.first?.value.backingValue == "1")
        let text = node.plainText()
        #expect(text.contains("App\\Models\\User #7 {"))
        #expect(text.contains("#name: \"Ana\""))
        #expect(text.contains("… 299 more"))
        let binary = ValueNode(id: 1, type: .string, scalar: Data([0x61, 0xff]).base64EncodedString())
        var encoded = binary
        encoded.encoding = "base64"
        #expect(encoded.displayString == "a\\xFF")
    }

    /// #52: old snippet envelopes remain readable without a schema migration.
    @Test func legacySnippetLibrariesLoadAndDescriptionsRoundTrip() throws {
        let store = JSONDocumentStore<[Snippet]>(url: tempURL())
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = UUID()
        let legacy: [String: Any] = ["id": id.uuidString, "label": "Legacy", "code": "echo 1;", "createdAt": 0, "updatedAt": 0]
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "savedAt": 0, "data": [legacy]]).write(to: store.url)
        let loaded = store.load(default: [])
        #expect(loaded.recoveryNotes.isEmpty)
        #expect(loaded.value.count == 1)
        #expect(loaded.value.first?.id == id)
        #expect(loaded.value.first?.description == nil)
        let described = Snippet(label: "Recent orders", code: "Order::latest()->get();", description: "Newest café orders — read only", target: .local(UUID()), targetLabel: "Shop")
        try store.save(loaded.value + [described])
        let roundTrip = store.load(default: [])
        #expect(roundTrip.recoveryNotes.isEmpty)
        #expect(roundTrip.value == loaded.value + [described])
        #expect(roundTrip.value.first?.description == nil)
    }

    @Test func clearedSnippetDescriptionsAreOmittedAndNullIsAccepted() throws {
        var snippet = Snippet(label: "Example", code: "1", description: "Notes")
        snippet.description = nil
        let encoded = try JSONEncoder().encode(snippet)
        let raw = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(raw["description"] == nil)
        var withNull = raw
        withNull["description"] = NSNull()
        let decoded = try JSONDecoder().decode(Snippet.self, from: JSONSerialization.data(withJSONObject: withNull))
        #expect(decoded == snippet)
    }

    /// #130: snippets saved before snippets had a language load as PHP; PHP snippets don't
    /// write the key, SQL snippets round-trip it.
    @Test func snippetLanguageIsBackwardCompatible() throws {
        let legacy = try JSONDecoder().decode(Snippet.self, from: Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","label":"Old","code":"1","createdAt":0,"updatedAt":0}"#.utf8))
        #expect(legacy.language == nil && legacy.tabLanguage == .php)
        let php = Snippet(label: "PHP", code: "1", language: .php)
        let raw = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(php)) as? [String: Any])
        #expect(raw["language"] == nil)
        let sql = Snippet(label: "SQL", code: "select 1;", language: .sql)
        let decoded = try JSONDecoder().decode(Snippet.self, from: JSONEncoder().encode(sql))
        #expect(decoded == sql && decoded.tabLanguage == .sql)
        // SQL snippets have no inputs, even with a docblock that would declare one in PHP.
        #expect(Snippet(label: "x", code: "/** @input int $id */\nselect 1;", language: .sql).inputs.isEmpty)
        #expect(!Snippet(label: "x", code: "/** @input int $id */\n$id;").inputs.isEmpty)
        // A language a newer Runlet may add loads as PHP.
        let future = try JSONDecoder().decode(Snippet.self, from: Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","label":"New","code":"1","createdAt":0,"updatedAt":0,"language":"graphql"}"#.utf8))
        #expect(future.tabLanguage == .php)
    }

    /// #9: cached/older completion records decode without the new optional fields.
    @Test func completionTimingFieldsAreBackwardCompatible() throws {
        let legacy = try JSONDecoder().decode(FinishedInfo.self, from: Data(#"{"status":"completed","reason":"completed","elapsedMs":55}"#.utf8))
        #expect(legacy.startedAt == nil && legacy.bootstrapMs == nil && legacy.executeMs == nil)
        let info = FinishedInfo(status: .completed, reason: "completed", elapsedMs: 200, peakMemory: 4096,
                                startedAt: Date(timeIntervalSinceReferenceDate: 123), bootstrapMs: 0, executeMs: 120)
        #expect(try JSONDecoder().decode(FinishedInfo.self, from: JSONEncoder().encode(info)) == info)
    }

}
