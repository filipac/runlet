import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// Detect and the directory browser against the SSH fixture (part of the serialized
/// `SSHRunTests` suite, since one of its tests pauses the container).
extension SSHRunTests {
    /// Folders the tests below look for, created as root (the login can't write in its home).
    func prepareFolders(_ environment: SSHFixture.Environment) async throws {
        try await environment.exec("""
        mkdir -p /home/runlet/shop/releases/1 && touch /home/runlet/shop/releases/1/artisan \
        && ln -sfn releases/1 /home/runlet/shop/current \
        && mkdir -p /srv/private && chmod 700 /srv/private \
        && mkdir -p "/srv/browse it's \\"odd\\" \\$HOME \\`x\\`/inner dir" && touch "/srv/browse it's \\"odd\\" \\$HOME \\`x\\`/composer.json" \
        && mkdir -p /srv/.hidden
        """)
    }

    @Test func detectFindsTheHomeFolderAndApplications() async throws {
        let environment = try await SSHFixture.environment()
        try await prepareFolders(environment)
        let endpoint = environment.endpoint()
        let client = environment.client()
        defer { Task { await client.disconnect(endpoint) } }

        let detection = await client.detectDirectories(endpoint, phpExecutable: "php")
        #expect(detection.error == nil, "\(detection.error ?? "")")
        #expect(detection.home == "/home/runlet")
        #expect(detection.user == "runlet")
        // Forge-style `current` is kept as a symlink, not resolved to releases/1.
        let shop = detection.candidates.first { $0.path == "/home/runlet/shop/current" }
        #expect(shop?.isSymlink == true && shop?.target == "releases/1" && shop?.markers == ["laravel"], "\(detection.candidates.map(\.path))")
        #expect(detection.candidates.contains { $0.path == "/srv/app" && $0.markers.contains("composer") })
        #expect(detection.candidates.contains { $0.path.hasPrefix("/srv/browse it's") })
        #expect(!detection.candidates.contains { $0.path == "/home/runlet/site/current" }, "folders without an app aren't candidates")

        // A wrong PHP still finds the home folder (from the shell) and explains.
        let noPHP = await client.detectDirectories(endpoint, phpExecutable: "php9.9")
        #expect(noPHP.home == "/home/runlet")
        #expect(noPHP.error?.contains("PHP was not found") == true, "\(noPHP.error ?? "")")
    }

    @Test func listsFoldersOnTheServerReadOnly() async throws {
        let environment = try await SSHFixture.environment()
        try await prepareFolders(environment)
        let endpoint = environment.endpoint()
        let client = environment.client()
        defer { Task { await client.disconnect(endpoint) } }

        // Blank and `~` list the home folder.
        let home = await client.listDirectory(endpoint, phpExecutable: "php", path: "")
        #expect(home.error == nil && home.path == "/home/runlet", "\(home)")
        #expect(home.entries.map(\.name).contains("site") && home.entries.map(\.name).contains("shop"))
        #expect(home.parent == "/home")
        #expect(home.entries.allSatisfy { !$0.name.hasPrefix(".") || $0.name == ".ssh" }, "files aren't listed")

        let site = await client.listDirectory(endpoint, phpExecutable: "php", path: "~/site")
        #expect(site.path == "/home/runlet/site")
        let current = site.entries.first { $0.name == "current" }
        #expect(current?.isSymlink == true && current?.target == "releases/20260101" && current?.path == "/home/runlet/site/current")
        #expect(site.entries.map(\.name) == ["current", "releases"], "sorted, folders only")

        // `.` and `..` resolve lexically (symlinks stay).
        let dotted = await client.listDirectory(endpoint, phpExecutable: "php", path: "/home/runlet/site/current/../current/.")
        #expect(dotted.path == "/home/runlet/site/current" && dotted.error == nil, "\(dotted)")

        let srv = await client.listDirectory(endpoint, phpExecutable: "php", path: "/srv/")
        #expect(srv.entries.first { $0.name == "app" }?.markers == ["composer"])
        #expect(srv.entries.first { $0.name == "private" }?.readable == false)
        #expect(srv.entries.contains { $0.name == ".hidden" }, "hidden folders are listed; the browser hides them by default")

        // Quoting: a folder name with quotes, `$`, and backticks.
        let odd = "/srv/browse it's \"odd\" $HOME `x`"
        let oddListing = await client.listDirectory(endpoint, phpExecutable: "php", path: odd)
        #expect(oddListing.error == nil && oddListing.path == odd, "\(oddListing)")
        #expect(oddListing.entries.map(\.name) == ["inner dir"])
        #expect(oddListing.markers == ["composer"])

        let denied = await client.listDirectory(endpoint, phpExecutable: "php", path: "/srv/private")
        #expect(denied.error?.contains("permission denied") == true, "\(denied)")
        let missing = await client.listDirectory(endpoint, phpExecutable: "php", path: "/srv/nope")
        #expect(missing.error?.contains("doesn't exist") == true)
        let file = await client.listDirectory(endpoint, phpExecutable: "php", path: "/etc/hostname")
        #expect(file.error?.contains("is a file") == true)
        let relative = await client.listDirectory(endpoint, phpExecutable: "php", path: "srv")
        #expect(relative.error?.contains("isn't an absolute path") == true)
        let noPHP = await client.listDirectory(endpoint, phpExecutable: "php9.9", path: "/srv")
        #expect(noPHP.error?.contains("PHP was not found") == true)

        // An unknown host key is refused here too (no prompt, nothing accepted).
        let unknown = environment.endpoint(host: SSHFixture.Environment.unknownKeyHost)
        let refused = await client.listDirectory(unknown, phpExecutable: "php", path: "/srv")
        #expect(refused.error?.contains("never accepts a host key") == true, "\(refused)")
    }
}
