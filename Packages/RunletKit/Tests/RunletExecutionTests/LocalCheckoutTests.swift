import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// The local side of an SSH profile's folder: checkout state, drift, and folder suggestions.
struct LocalCheckoutTests {
    func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-checkout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func crc32MatchesPHP() {
        // php -r 'echo hash("crc32b", "123456789");' → cbf43926
        #expect(String(format: "%08x", CRC32.checksum(Data("123456789".utf8))) == "cbf43926")
        #expect(CRC32.checksum(Data()) == 0)
    }

    @Test func readsBranchCommitRemoteAndLockWithoutGit() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let commit = String(repeating: "a", count: 40)
        try write("ref: refs/heads/feature/x\n", to: root.appendingPathComponent(".git/HEAD"))
        try write("# pack-refs\n\(commit) refs/heads/feature/x\n", to: root.appendingPathComponent(".git/packed-refs"))
        try write("[core]\n\tbare = false\n[remote \"origin\"]\n\turl = git@github.com:acme/shop.git\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n", to: root.appendingPathComponent(".git/config"))
        try write("123456789", to: root.appendingPathComponent("composer.lock"))
        let state = LocalCheckout.read(root.path)
        #expect(state.branch == "feature/x")
        #expect(state.commit == commit)
        #expect(state.remote == "git@github.com:acme/shop.git")
        #expect(state.composerLockCRC == "cbf43926" && state.composerLockSize == 9)
        #expect(state.summary == "feature/x @aaaaaaa")

        // A detached worktree: `.git` is a file pointing elsewhere, HEAD is a commit.
        let worktree = try scratch()
        defer { try? FileManager.default.removeItem(at: worktree) }
        try write("gitdir: \(root.path)/.git\n", to: worktree.appendingPathComponent(".git"))
        #expect(LocalCheckout.read(worktree.path).remote == "git@github.com:acme/shop.git")
    }

    @Test func driftComparesCommitsThenComposerLock() {
        let host = "forge@shop"
        let same = CheckoutState(branch: "main", commit: "abc")
        #expect(CheckoutDrift.warning(local: same, remote: same, host: host) == nil)
        let warning = CheckoutDrift.warning(local: CheckoutState(branch: "feature/x", commit: "1234567890"), remote: CheckoutState(branch: "main", commit: "abcdef1234"), host: host)
        #expect(warning?.contains("feature/x @1234567") == true && warning?.contains("main @abcdef1") == true)
        // Zero-downtime releases have no .git on the server: composer.lock decides.
        let locks = CheckoutDrift.warning(local: CheckoutState(commit: "x", composerLockCRC: "1", composerLockSize: 5), remote: CheckoutState(composerLockCRC: "2", composerLockSize: 5), host: host)
        #expect(locks?.contains("composer.lock") == true)
        #expect(CheckoutDrift.warning(local: CheckoutState(composerLockCRC: "1", composerLockSize: 5), remote: CheckoutState(composerLockCRC: "1", composerLockSize: 5), host: host) == nil)
        #expect(CheckoutDrift.warning(local: CheckoutState(), remote: CheckoutState(commit: "x"), host: host) == nil)
    }

    @Test func normalizesGitRemotes() {
        let expected = "github.com/acme/shop"
        for url in ["git@github.com:Acme/Shop.git", "https://github.com/acme/shop", "https://github.com/acme/shop.git/", "ssh://git@github.com:22/acme/shop.git", "https://token@github.com/acme/shop"] {
            #expect(LocalFolderSuggestions.normalizedRemote(url) == expected, "\(url)")
        }
        #expect(LocalFolderSuggestions.normalizedRemote("git@gitlab.com:acme/shop.git") != expected)
    }

    @Test func suggestsFoldersByRemoteThenComposerNameThenFolderName() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        // ~/Code/shop-checkout: same remote. ~/Code/clients/legacy: same composer name.
        // ~/Code/shop: same folder name as the Forge site. ~/Code/other: nothing in common.
        try write("[remote \"origin\"]\n\turl = https://github.com/acme/shop.git\n", to: root.appendingPathComponent("shop-checkout/.git/config"))
        try write(#"{"name": "acme/shop"}"#, to: root.appendingPathComponent("clients/legacy/composer.json"))
        try write(#"{"name": "someone/else"}"#, to: root.appendingPathComponent("shop/composer.json"))
        try write(#"{"name": "x/y"}"#, to: root.appendingPathComponent("other/composer.json"))
        var probe = SSHProbe(error: "")
        probe.error = nil
        probe.gitRemote = "git@github.com:acme/shop.git"
        probe.composerName = "acme/shop"
        probe.realDirectory = "/home/forge/shop.example.com/releases/20260101"
        let suggestions = LocalFolderSuggestions.suggest(remoteDirectory: "/home/forge/shop.example.com/current", probe: probe, knownFolders: [], scanRoots: [root])
        let resolved = root.resolvingSymlinksInPath().path
        func shortened(_ path: String) -> String { path.replacingOccurrences(of: resolved, with: "").replacingOccurrences(of: root.path, with: "") }
        #expect(suggestions.map { shortened($0.path) } == ["/shop-checkout", "/clients/legacy", "/shop"])
        #expect(suggestions.map(\.reason) == [.gitRemote, .composerName, .folderName])

        // Without Test Connection, only the folder name is known.
        let offline = LocalFolderSuggestions.suggest(remoteDirectory: "/home/forge/shop.example.com/current", probe: nil, knownFolders: [], scanRoots: [root])
        #expect(offline.map { shortened($0.path) } == ["/shop"])
        #expect(LocalFolderSuggestions.folderNames(for: "/var/www/html", realDirectory: nil).isEmpty)
    }
}
