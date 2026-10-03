import Foundation
import Testing
@testable import RunletCore

/// Installs only into temporary folders.
struct CommandLineInstallTests {
    let root: URL
    let tool: URL
    let otherTool: URL
    let bin: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-cli-\(UUID().uuidString)", isDirectory: true)
        tool = root.appendingPathComponent("Applications/Runlet.app/Contents/Helpers/runlet")
        otherTool = root.appendingPathComponent("Old/Runlet.app/Contents/Helpers/runlet")
        bin = root.appendingPathComponent("home/.local/bin", isDirectory: true)
        for executable in [tool, otherTool] {
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: executable)
        }
    }

    @Test func installsALinkCreatingTheFolder() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let link = CommandLineInstall.link(in: bin)
        #expect(CommandLineInstall.status(of: link, tool: tool) == .notInstalled)
        try CommandLineInstall.install(tool: tool, at: link)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == tool.path)
        #expect(CommandLineInstall.status(of: link, tool: tool) == .installed)
        try CommandLineInstall.install(tool: tool, at: link)
        #expect(CommandLineInstall.status(of: link, tool: tool) == .installed, "installing again changes nothing")
    }

    @Test func aLinkToAnotherRunletIsReplacedOnlyWhenAsked() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let link = CommandLineInstall.link(in: bin)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: otherTool)
        #expect(CommandLineInstall.status(of: link, tool: tool) == .linkedElsewhere(otherTool.path))
        #expect(throws: CommandLineInstall.InstallError.linkedElsewhere(link.path)) { try CommandLineInstall.install(tool: tool, at: link) }
        try CommandLineInstall.install(tool: tool, at: link, replacing: true)
        #expect(CommandLineInstall.status(of: link, tool: tool) == .installed)
    }

    @Test func somethingElseIsNeverTouched() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let link = CommandLineInstall.link(in: bin)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("someone else's runlet".utf8).write(to: link)
        #expect(CommandLineInstall.status(of: link, tool: tool) == .blocked)
        #expect(throws: CommandLineInstall.InstallError.blocked(link.path)) { try CommandLineInstall.install(tool: tool, at: link, replacing: true) }
        #expect(throws: CommandLineInstall.InstallError.notRunletLink(link.path)) { try CommandLineInstall.uninstall(link: link, tool: tool) }
        #expect(try String(contentsOf: link, encoding: .utf8) == "someone else's runlet")

        // A link to some other program is not Runlet's either.
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/usr/bin/true")
        #expect(CommandLineInstall.status(of: link, tool: tool) == .blocked)
    }

    @Test func uninstallRemovesOnlyTheLink() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let link = CommandLineInstall.link(in: bin)
        try CommandLineInstall.install(tool: tool, at: link)
        try CommandLineInstall.uninstall(link: link, tool: tool)
        #expect(CommandLineInstall.status(of: link, tool: tool) == .notInstalled)
        #expect(FileManager.default.fileExists(atPath: tool.path), "the tool itself stays")
        try CommandLineInstall.uninstall(link: link, tool: tool)
    }

    @Test func aRelativeLinkCountsToo() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let link = CommandLineInstall.link(in: bin)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../../Applications/Runlet.app/Contents/Helpers/runlet")
        #expect(CommandLineInstall.status(of: link, tool: tool) == .installed)
    }

    @Test func administratorIsNeededOnlyForFoldersThisUserCantWrite() {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!CommandLineInstall.needsAdministrator(for: bin), "a missing folder under a writable one")
        #expect(CommandLineInstall.needsAdministrator(for: URL(fileURLWithPath: "/System/runlet-test/bin")))
    }

    // #92: the folders a Mac may have, checked without traps (only temporary folders).

    @Test func aFolderThisUserCantWriteNeedsAnAdministratorAndInstallingThereFailsCleanly() throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bin.path)
        let link = CommandLineInstall.link(in: bin)
        #expect(CommandLineInstall.needsAdministrator(for: bin), "like a root-owned /usr/local/bin")
        #expect(CommandLineInstall.needsAdministrator(for: bin.appendingPathComponent("missing/deeper", isDirectory: true)), "its nearest existing folder decides")
        #expect(CommandLineInstall.status(of: link, tool: tool) == .notInstalled)
        #expect(throws: (any Error).self) { try CommandLineInstall.install(tool: tool, at: link) }
        #expect(CommandLineInstall.status(of: link, tool: tool) == .notInstalled)
    }

    @Test func missingFoldersAreCreatedAndAFileInTheirPlaceIsAnError() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appendingPathComponent("a/b/c/bin", isDirectory: true)
        #expect(!CommandLineInstall.needsAdministrator(for: deep))
        try CommandLineInstall.install(tool: tool, at: CommandLineInstall.link(in: deep))
        #expect(CommandLineInstall.status(of: CommandLineInstall.link(in: deep), tool: tool) == .installed)

        // A file named like the folder: the link can't go there, and nothing is replaced.
        try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: bin)
        let link = CommandLineInstall.link(in: bin)
        #expect(CommandLineInstall.status(of: link, tool: tool) == .notInstalled)
        #expect(!CommandLineInstall.needsAdministrator(for: bin))
        #expect(throws: (any Error).self) { try CommandLineInstall.install(tool: tool, at: link) }
        try CommandLineInstall.uninstall(link: link, tool: tool)
        #expect(try String(contentsOf: bin, encoding: .utf8) == "not a folder")
    }

    @Test func danglingLinks() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let link = CommandLineInstall.link(in: bin)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // To a Runlet.app that was deleted: another copy, replaced or removed only on request.
        let gone = root.appendingPathComponent("Gone/Runlet.app/Contents/Helpers/runlet").path
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: gone)
        #expect(CommandLineInstall.status(of: link, tool: tool) == .linkedElsewhere(gone))
        try CommandLineInstall.uninstall(link: link, tool: tool)
        #expect(CommandLineInstall.status(of: link, tool: tool) == .notInstalled)
        // To nothing that is Runlet's: left alone.
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/nonexistent/runlet")
        #expect(CommandLineInstall.status(of: link, tool: tool) == .blocked)
        #expect(throws: CommandLineInstall.InstallError.blocked(link.path)) { try CommandLineInstall.install(tool: tool, at: link, replacing: true) }
    }

    @Test func oddPathsAreHandled() {
        let home = "/Users/me"
        let local = URL(fileURLWithPath: "/Users/me/.local/bin")
        for path in ["", ":", ":::", ".", "relative/bin", "~", "~other/bin", "/", "//Users//me//.local//bin//x/.."] {
            _ = CommandLineInstall.isOnPath(local, path: path, home: home)
        }
        #expect(!CommandLineInstall.isOnPath(local, path: "", home: home))
        #expect(CommandLineInstall.isOnPath(local, path: "::/Users//me/.local/bin/::", home: home))
        #expect(!CommandLineInstall.needsAdministrator(for: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("runlet-missing-\(UUID().uuidString)/x/y", isDirectory: true)))
        #expect(CommandLineInstall.needsAdministrator(for: URL(fileURLWithPath: "/")), "the loop stops at /")
    }

    @Test func administratorScriptsQuoteEveryPath() {
        let tool = URL(fileURLWithPath: "/Applications/My \"Apps\"/Runlet.app/Contents/Helpers/runlet")
        let link = URL(fileURLWithPath: "/usr/local/bin/runlet")
        let script = CommandLineInstall.administratorInstallScript(tool: tool, link: link)
        #expect(script.contains(#"set toolPath to "/Applications/My \"Apps\"/Runlet.app/Contents/Helpers/runlet""#))
        #expect(script.contains(#"set folderPath to "/usr/local/bin""#))
        #expect(script.contains("quoted form of toolPath"))
        #expect(script.contains("with administrator privileges"))
        #expect(!script.contains("rm -"), "never removes anything but a link")
        #expect(CommandLineInstall.appleScriptString(#"a\b"c"#) == #""a\\b\"c""#)
        #expect(CommandLineInstall.administratorUninstallScript(link: link).contains("[ ! -L \" & quoted form of linkPath & \" ] || /bin/rm"))
    }

    @Test func pathChecks() {
        let home = "/Users/me"
        let local = URL(fileURLWithPath: "/Users/me/.local/bin")
        #expect(CommandLineInstall.isOnPath(local, path: "/usr/bin:/Users/me/.local/bin/:/bin", home: home))
        #expect(CommandLineInstall.isOnPath(local, path: "~/.local/bin:/bin", home: home))
        #expect(!CommandLineInstall.isOnPath(local, path: "/usr/bin:/bin", home: home))
        #expect(CommandLineInstall.pathExport(for: local, home: home) == #"export PATH="$HOME/.local/bin:$PATH""#)
        #expect(CommandLineInstall.standardFolders(home: home).map(\.path) == ["/usr/local/bin", "/Users/me/.local/bin"])
    }
}
