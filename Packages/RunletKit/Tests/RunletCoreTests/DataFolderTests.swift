import Foundation
import Testing
@testable import RunletCore

/// Runlet Dev (#267): a Debug build names its own data folder, and the `runlet` command
/// follows the app it belongs to.
struct DataFolderTests {
    /// A throwaway .app bundle whose Info.plist has `info`.
    private func bundle(_ info: [String: Any]) throws -> Bundle {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-data-folder-\(UUID().uuidString).app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist = info
        plist["CFBundleIdentifier"] = plist["CFBundleIdentifier"] ?? "dev.runlet.Runlet.test"
        plist["CFBundlePackageType"] = "APPL"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        return try #require(Bundle(url: app))
    }

    @Test func theFolderComesFromTheAppsInfoPlist() throws {
        #expect(AppPaths.folderName(appBundle: try bundle([AppPaths.folderKey: "Runlet Dev"])) == "Runlet Dev")
        #expect(AppPaths.folderName(appBundle: try bundle([AppPaths.folderKey: "Runlet"])) == "Runlet")
        // No key (older builds, the test runner), or a value that isn't a plain name: the release's.
        #expect(AppPaths.folderName(appBundle: try bundle([:])) == "Runlet")
        #expect(AppPaths.folderName(appBundle: nil) == "Runlet")
        for odd in ["", "  ", "../Runlet", "a/b", ".hidden", "$(RUNLET_DATA_FOLDER)"] {
            #expect(AppPaths.folderName(appBundle: try bundle([AppPaths.folderKey: odd])) == "Runlet", "\(odd)")
        }
    }

    @Test func standardPathsUseItAndRunletDataDirStillWins() throws {
        let dev = try bundle([AppPaths.folderKey: "Runlet Dev"])
        let paths = AppPaths.standard(appBundle: dev, environment: [:])
        #expect(paths.root.lastPathComponent == "Runlet Dev")
        #expect(paths.root.deletingLastPathComponent().lastPathComponent == "Application Support")
        let scratch = AppPaths.standard(appBundle: dev, environment: ["RUNLET_DATA_DIR": "/tmp/runlet-scratch"])
        #expect(scratch.root.path == "/tmp/runlet-scratch")
        #expect(AppPaths.standard(appBundle: nil, environment: [:]).root.lastPathComponent == "Runlet")
    }

    @Test func runletDevHasItsOwnKeychainItemsAndSocket() throws {
        let release = AppPaths.standard(appBundle: try bundle([AppPaths.folderKey: "Runlet"]), environment: [:])
        let dev = AppPaths.standard(appBundle: try bundle([AppPaths.folderKey: "Runlet Dev"]), environment: [:])
        #expect(KeychainCredentialStore.service(for: release) == KeychainCredentialStore.baseService)
        #expect(KeychainCredentialStore.service(for: dev) != KeychainCredentialStore.baseService)
        #expect(KeychainCredentialStore.service(for: dev).hasPrefix(KeychainCredentialStore.baseService + "."))
        #expect(MCPSocketPaths.socketPath(for: dev) != MCPSocketPaths.socketPath(for: release))
    }

    @Test func theCommandFollowsAnyRunletApp() {
        #expect(CommandLineTool.isRunletApp("dev.runlet.Runlet"))
        #expect(CommandLineTool.isRunletApp("dev.runlet.Runlet.dev"))
        #expect(CommandLineTool.isRunletApp("dev.runlet.Runlet.prshots"))
        #expect(!CommandLineTool.isRunletApp("dev.runlet.RunletOther"))
        #expect(!CommandLineTool.isRunletApp("dev.runlet.cli"))
        #expect(!CommandLineTool.isRunletApp(nil))
    }
}
