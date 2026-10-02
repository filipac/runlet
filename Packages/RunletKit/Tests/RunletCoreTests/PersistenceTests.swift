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
}
