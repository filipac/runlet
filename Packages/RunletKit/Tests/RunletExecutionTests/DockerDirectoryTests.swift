import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// Browse… for a local Docker profile's working directory (#62): the listing it decodes, the
/// `docker exec` command line, failure messages, and which container it may list in.
struct DockerDirectoryTests {
    static let oddPath = "/srv/it's \"odd\" $HOME `x` -v"

    // MARK: Listing output

    @Test func decodesAContainerListingWithSymlinksKept() throws {
        let line = #"{"path":"/var/www","home":"/root","markers":[],"entries":[{"name":"html","path":"/var/www/html","isSymlink":false,"target":null,"readable":true,"markers":["laravel","composer"]},{"name":"current","path":"/var/www/current","isSymlink":true,"target":"releases/2","readable":true,"markers":["laravel"]},{"name":"Private","path":"/var/www/Private","isSymlink":false,"target":null,"readable":false,"markers":[]}],"truncated":false,"error":null}"#
        // A login script or PHP notice may print first: the listing is the last line.
        let output = Data("Deprecated: something\n\(line)\n".utf8)
        let listing = try #require(RemoteDirectories.decodeListing(output, requested: "/var/www", place: .container("app-1", user: nil)))
        #expect(listing.error == nil && listing.notice == nil)
        #expect(listing.path == "/var/www" && listing.parent == "/var")
        #expect(listing.entries.map(\.name) == ["current", "html", "Private"], "sorted like Finder")
        let current = try #require(listing.entries.first { $0.name == "current" })
        #expect(current.path == "/var/www/current" && current.isSymlink && current.target == "releases/2", "the symlink's own path, not its target")
        #expect(listing.entries.first { $0.name == "html" }?.isApplication == true)
        #expect(listing.entries.first { $0.name == "Private" }?.readable == false)

        #expect(RemoteDirectories.decodeListing(Data("not json".utf8), requested: "/", place: .container("app-1", user: nil)) == nil)
        #expect(RemoteDirectories.decodeListing(Data(), requested: "/", place: .container("app-1", user: nil)) == nil)
    }

    @Test func containerListingErrorsNameTheContainerAndUser() throws {
        func error(_ code: String, user: String?) throws -> String {
            let line = #"{"path":"/srv/x","home":"/root","markers":[],"entries":[],"truncated":false,"error":"\#(code)"}"#
            return try #require(RemoteDirectories.decodeListing(Data(line.utf8), requested: "/srv/x", place: .container("shop-app-1", user: user))?.error)
        }
        #expect(try error("missing", user: nil) == "/srv/x doesn't exist in shop-app-1.")
        #expect(try error("notDirectory", user: nil) == "/srv/x in shop-app-1 is a file, not a folder.")
        #expect(try error("unreadable", user: "www-data").hasPrefix("The user “www-data” can't open /srv/x in shop-app-1 (permission denied)."))
        #expect(try error("unreadable", user: nil).hasPrefix("The container's default user can't open /srv/x in shop-app-1 (permission denied)."))
        #expect(try error("relative", user: nil).contains("isn't an absolute path"))
        // Servers keep their wording.
        #expect(RemoteDirectories.listingError("missing", path: "/srv/x", host: "forge@shop") == "/srv/x doesn't exist on forge@shop.")
    }

    // MARK: Command line

    @Test func listsWithTheProfilesUserAndPHPAndThePathAsOneArgument() {
        let docker = DockerCLI(executable: "/usr/local/bin/docker")
        let arguments = docker.listDirectoryArguments(containerId: "abc123", user: "1000:1000", phpExecutable: "/usr/local/bin/php", path: Self.oddPath)
        #expect(arguments == ["exec", "--user", "1000:1000", "abc123", "/usr/local/bin/php", "-r", RemoteDirectories.listScript, "--", Self.oddPath, "1000"])
        // No terminal, no stdin, no working directory: nothing but the listing.
        #expect(!arguments.contains("-i") && !arguments.contains("-t") && !arguments.contains("-it") && !arguments.contains("--workdir") && !arguments.contains("-w"))
        // This Mac's Docker gets the words as they are (no shell in between).
        let spec = docker.spec(arguments)
        #expect(spec.executable == "/usr/local/bin/docker" && spec.arguments == arguments && spec.standardInput == nil)

        // Blank user: the container's default user.
        #expect(docker.listDirectoryArguments(containerId: "abc123", user: nil, phpExecutable: "php", path: "")
            == ["exec", "abc123", "php", "-r", RemoteDirectories.listScript, "--", "", "1000"])
        #expect(!docker.listDirectoryArguments(containerId: "abc123", user: "", phpExecutable: "php", path: "/").contains("--user"))
    }

    @Test func overSSHEveryWordIsQuotedAndTheCodeTravelsAsBase64() throws {
        let control = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rlt-browse-\(UUID().uuidString.prefix(6))/ab.sock").path
        let docker = DockerCLI(ssh: SSHClient(executable: "/usr/bin/ssh", environment: [:]), endpoint: SSHEndpoint(host: "app-prod", controlPath: control), dockerCommand: "sudo -n docker")
        let arguments = docker.listDirectoryArguments(containerId: "abc123", user: "www-data", phpExecutable: "php", path: Self.oddPath)
        #expect(arguments[6] == RemoteShell.inlinePHP(RemoteDirectories.listScript))
        let argv = docker.spec(arguments).arguments
        let outer = try ProjectCommandLauncherTests.shellWords(try #require(argv.last))
        #expect(outer.prefix(2) == ["/bin/sh", "-c"])
        #expect(try ProjectCommandLauncherTests.shellWords(outer[2]) == ["sudo", "-n", "docker"] + arguments)
    }

    // MARK: Failures

    @Test func explainsDockerExecFailures() throws {
        func explain(_ output: String, exit: Int32 = 1, user: String? = nil) -> String? {
            DockerExecFailure.explain(output, exitCode: exit, container: "app-1", php: "php9.9", user: user)
        }
        // Docker's own messages (as Docker 28 prints them), kept below the explanation.
        let noPHP = #"OCI runtime exec failed: exec failed: unable to start container process: exec: "php9.9": executable file not found in $PATH"#
        #expect(explain(noPHP, exit: 127)?.hasPrefix("PHP wasn't found in app-1 as “php9.9”.") == true)
        #expect(explain(noPHP, exit: 127)?.hasSuffix(noPHP) == true)
        let noPath = #"OCI runtime exec failed: exec failed: unable to start container process: exec: "/usr/bin/php9": stat /usr/bin/php9: no such file or directory"#
        #expect(explain(noPath, exit: 127)?.hasPrefix("PHP wasn't found") == true)
        #expect(explain("Error response from daemon: unable to find user nosuchuser: no matching entries in passwd file", user: "nosuchuser")?.hasPrefix("The execution user “nosuchuser” doesn't exist in app-1.") == true)
        #expect(explain("Error response from daemon: container 4f2a is not running")?.hasPrefix("The container app-1 isn't running.") == true)
        #expect(explain("Error response from daemon: Container 4f2a is paused, unpause the container before exec")?.hasPrefix("The container app-1 is paused.") == true)
        #expect(explain("Error response from daemon: No such container: 4f2a")?.hasPrefix("The container app-1 no longer exists") == true)
        #expect(explain("Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?")?.hasPrefix("Docker isn't running") == true)
        #expect(explain("permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock")?.hasPrefix("This Mac's user may not use Docker") == true)
        // Anything else (a PHP error, say) is shown as it is.
        #expect(explain("PHP Parse error: syntax error", exit: 255) == nil)
        #expect(explain("") == nil)
    }

    // MARK: Which container

    static func container(_ id: String, name: String, service: String? = "web", running: Bool = true, status: String = "running") -> ContainerInfo {
        var labels: [String: String] = [:]
        if let service {
            labels["com.docker.compose.project"] = "shop"
            labels["com.docker.compose.service"] = service
        }
        return ContainerInfo(id: id, name: name, image: "php:8.4-cli", running: running, status: status, labels: labels, workingDir: "/var/www/html", user: "", mounts: [], created: "")
    }

    static let compose = ContainerIdentity(composeProject: "shop", composeService: "web", containerName: "shop-web-1", lastContainerId: "aaaa", lastImage: "php:8.4-cli")
    static let named = ContainerIdentity(containerName: "legacy", lastContainerId: "aaaa", lastImage: "php:8.4-cli")

    @Test func listsOnlyInTheSelectedContainerWhileItRuns() {
        let selected = Self.container("aaaa", name: "shop-web-1")
        let other = Self.container("bbbb", name: "shop-web-2")
        // The running list isn't consulted: even another match there changes nothing.
        #expect(DockerDirectoryBrowsing.target(selectedId: "aaaa", current: selected, identity: Self.compose, running: [other]) == .container(selected, notice: nil))
    }

    @Test func aStoppedOrRemovedContainerIsReported() {
        let stopped = Self.container("aaaa", name: "shop-web-1", running: false, status: "exited")
        guard case .failure(let message) = DockerDirectoryBrowsing.target(selectedId: "aaaa", current: stopped, identity: Self.compose, running: []) else {
            Issue.record("a stopped container must not be listed")
            return
        }
        #expect(message.hasPrefix("The container shop-web-1 isn't running (exited). Start it"))

        guard case .failure(let gone) = DockerDirectoryBrowsing.target(selectedId: "aaaa", current: nil, identity: Self.compose, running: [Self.container("cccc", name: "other", service: "db")]) else {
            Issue.record("a removed container must not be replaced by another service")
            return
        }
        #expect(gone.contains("no longer exists") && gone.contains("shop/web"))
    }

    @Test func aRecreatedComposeServiceIsFollowedWithANotice() {
        let replacement = Self.container("bbbb", name: "shop-web-1")
        guard case .container(let container, let notice) = DockerDirectoryBrowsing.target(selectedId: "aaaa", current: nil, identity: Self.compose, running: [replacement]) else {
            Issue.record("a recreated Compose service is followed, as runs follow it")
            return
        }
        #expect(container == replacement)
        #expect(notice?.contains("shop/web was recreated") == true && notice?.contains("bbbb") == true)
    }

    @Test func whatARunWouldAskAboutIsAnError() {
        // Several replicas: never pick one.
        let replicas = [Self.container("bbbb", name: "shop-web-1"), Self.container("cccc", name: "shop-web-2")]
        guard case .failure(let ambiguous) = DockerDirectoryBrowsing.target(selectedId: "aaaa", current: nil, identity: Self.compose, running: replicas) else {
            Issue.record("replicas must be chosen by the user")
            return
        }
        #expect(ambiguous.contains("2 running containers match"))

        // A container known only by its name, recreated: the user confirms it first.
        let renamed = Self.container("bbbb", name: "legacy", service: nil)
        guard case .failure(let confirm) = DockerDirectoryBrowsing.target(selectedId: "aaaa", current: nil, identity: Self.named, running: [renamed]) else {
            Issue.record("a recreated name-only container needs confirmation")
            return
        }
        #expect(confirm.contains("was recreated (new ID bbbb)") && confirm.contains("confirm"))
    }
}

/// The same against the disposable `runlet-fixtures` containers (start them with
/// `scripts/setup-fixtures.sh docker`). Run with `Tests/Fixtures/docker/fixtures-only-docker`
/// first on PATH as `docker` (docs/validation.md): these tests only `inspect` and `exec` into
/// fixture containers by name, and never list containers.
@Suite(.enabled(if: TestSupport.hasDocker, "requires a running Docker engine"))
struct DockerDirectoryFixtureTests {
    var docker: DockerCLI { TestSupport.docker! }

    func fixture(_ service: String) async throws -> ContainerInfo {
        let container = try #require(await docker.inspect("runlet-fixtures-\(service)-1"), "start fixtures with scripts/setup-fixtures.sh docker")
        try #require(container.composeProject == "runlet-fixtures" && container.running)
        return container
    }

    func list(_ container: ContainerInfo, _ path: String, user: String? = nil, php: String = "php") async -> RemoteDirectoryListing {
        await docker.listProfileDirectory(selectedId: container.id, identity: container.identity, user: user, phpExecutable: php, path: path)
    }

    @Test func browsesTheSelectedFixtureContainer() async throws {
        let laravel = try await fixture("laravel")
        let www = await list(laravel, "/var/www")
        #expect(www.error == nil && www.notice == nil, "\(www)")
        let html = try #require(www.entries.first { $0.name == "html" })
        #expect(html.path == "/var/www/html" && html.markers.contains("laravel"))

        // Symlinked folders are listed and kept as they are (Debian's /bin → usr/bin).
        let root = await list(laravel, "/")
        let bin = try #require(root.entries.first { $0.name == "bin" }, "\(root)")
        #expect(bin.isSymlink && bin.target == "usr/bin" && bin.path == "/bin")
        let inside = await list(laravel, "/bin/../bin/.")
        #expect(inside.path == "/bin" && inside.error == nil, "lexical, not resolved to /usr/bin")

        // Blank and ~ list the user's home folder.
        #expect(await list(laravel, "").path == "/root")

        let missing = await list(laravel, "/nope")
        #expect(missing.error == "/nope doesn't exist in \(laravel.name).")
        let file = await list(laravel, "/etc/hostname")
        #expect(file.error == "/etc/hostname in \(laravel.name) is a file, not a folder.")
        let noPHP = await list(laravel, "/", php: "php9.9")
        #expect(noPHP.error?.hasPrefix("PHP wasn't found in \(laravel.name) as “php9.9”.") == true, "\(noPHP)")
        let noUser = await list(laravel, "/", user: "nosuchuser")
        #expect(noUser.error?.hasPrefix("The execution user “nosuchuser” doesn't exist") == true, "\(noUser)")
    }

    @Test func permissionsAreTheExecutionUsers() async throws {
        // The restricted fixture runs as 1000:1000 by default.
        let restricted = try await fixture("restricted")
        let root = await list(restricted, "/")
        #expect(root.entries.first { $0.name == "root" }?.readable == false, "\(root)")
        let denied = await list(restricted, "/root")
        #expect(denied.error?.hasPrefix("The container's default user can't open /root in \(restricted.name) (permission denied).") == true, "\(denied)")
        // As root it opens.
        #expect(await list(restricted, "/root", user: "0").error == nil)
        #expect(await list(restricted, "/app").entries.contains { $0.name == "src" })
    }
}
