import Foundation
import Testing
@testable import RunletCore

/// Feature flags (#187): the registry, the accessor, and how settings files keep them.
struct FeatureFlagTests {
    @Test func registryIsUniqueAndOffByDefault() {
        let ids = FeatureFlag.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(FeatureFlag.all.allSatisfy { !$0.defaultValue })
        #expect(FeatureFlag.all.first == .tablePlusImport)
        #expect(FeatureFlag.tablePlusImport.title == "Import connections from TablePlus")
        #expect(FeatureFlag.tablePlusImport.issue == 188)
        #expect(FeatureFlag.named("tablePlusImport") == .tablePlusImport)
        #expect(FeatureFlag.named("nope") == nil)
    }

    @Test func accessorUsesSavedChoiceThenForcedThenDefault() {
        var settings = AppSettings()
        #expect(!settings.isEnabled(.tablePlusImport))
        #expect(settings.isEnabled(.tablePlusImport, forcedOn: ["tablePlusImport"]))
        settings.setEnabled(.tablePlusImport, true)
        #expect(settings.isEnabled(.tablePlusImport))
        settings.setEnabled(.tablePlusImport, false)
        #expect(!settings.isEnabled(.tablePlusImport))
        // Forced on wins over a saved "off".
        #expect(settings.isEnabled(.tablePlusImport, forcedOn: ["tablePlusImport"]))
    }

    @Test func environmentListParsing() {
        #expect(FeatureFlag.ids(in: nil).isEmpty)
        #expect(FeatureFlag.ids(in: "").isEmpty)
        #expect(FeatureFlag.ids(in: "tableplusimport") == ["tablePlusImport"])
        #expect(FeatureFlag.ids(in: " unknown , tablePlusImport,,") == ["tablePlusImport"])
        #expect(FeatureFlag.ids(in: "unknown other").isEmpty)
    }

    @Test func flagsRoundTripAndUnknownFlagsAreKept() throws {
        var settings = AppSettings()
        settings.setEnabled(.tablePlusImport, true)
        settings.featureFlags["fromANewerRunlet"] = true
        settings.showAdvancedSettings = true
        let data = try JSONEncoder().encode(settings)
        var decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == settings)
        #expect(decoded.isEnabled(.tablePlusImport))
        // Changing a known flag keeps the unknown one.
        decoded.setEnabled(.tablePlusImport, false)
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(decoded))
        #expect(again.featureFlags == ["tablePlusImport": false, "fromANewerRunlet": true])
        #expect(again.showAdvancedSettings)
    }

    @Test func oldAndOddSettingsFilesDecode() throws {
        // A settings file from before #187.
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"fontSize":14}"#.utf8))
        #expect(old.featureFlags.isEmpty)
        #expect(!old.showAdvancedSettings)
        #expect(!old.isEnabled(.tablePlusImport))
        #expect(old.fontSize == 14)
        // A removed flag, and an entry that isn't a Bool, don't break decoding or the others.
        let odd = #"{"featureFlags":{"removedFlag":true,"tablePlusImport":true,"weird":"yes"},"showAdvancedSettings":"maybe"}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(odd.utf8))
        #expect(decoded.featureFlags == ["removedFlag": true, "tablePlusImport": true])
        #expect(decoded.isEnabled(.tablePlusImport))
        #expect(!decoded.showAdvancedSettings)
        // A flags value that isn't an object.
        let broken = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"featureFlags":[1,2]}"#.utf8))
        #expect(broken.featureFlags.isEmpty)
    }

    @Test func scratchDataFolderKeepsItsOwnFlags() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-flags-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let paths = AppPaths(root: folder)
        let store = JSONDocumentStore<AppSettings>(url: paths.settings)
        var settings = AppSettings()
        settings.setEnabled(.tablePlusImport, true)
        try store.save(settings)
        #expect(store.load(default: AppSettings()).value.isEnabled(.tablePlusImport))
        let other = JSONDocumentStore<AppSettings>(url: AppPaths(root: folder.appendingPathComponent("other")).settings)
        #expect(!other.load(default: AppSettings()).value.isEnabled(.tablePlusImport))
    }
}
