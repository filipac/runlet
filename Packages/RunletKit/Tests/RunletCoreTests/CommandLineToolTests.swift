import Foundation
import Testing
@testable import RunletCore

struct CommandLineToolTests {
    static let cwd = "/Users/me/code/shop"
    static let home = "/Users/me"
    /// A fake file system: folders and files by absolute path.
    static let folders: Set<String> = ["/Users/me", "/Users/me/code/shop", "/Users/me/code/blog", "/", "/Users/me/code/shop/app"]
    static let files: Set<String> = ["/Users/me/code/shop/scratch.php", "/Users/me/code/shop/Work.runlet", "/Users/me/notes.txt", "/Users/me/code/shop/app/User.PHP"]

    static func parse(_ arguments: String...) throws(CommandLineTool.UsageError) -> CommandLineTool.Invocation {
        try CommandLineTool.parse(arguments, currentDirectory: cwd, home: home) { path in
            folders.contains(path) ? .directory : files.contains(path) ? .file : nil
        }
    }

    static func request(_ arguments: String...) throws -> OpenRequest {
        let invocation = try CommandLineTool.parse(arguments, currentDirectory: cwd, home: home) { path in
            folders.contains(path) ? .directory : files.contains(path) ? .file : nil
        }
        guard case .open(let request) = invocation else {
            Issue.record("expected an open request, got \(invocation)")
            return OpenRequest(items: [])
        }
        return request
    }

    static func error(_ arguments: String...) -> String? {
        do {
            _ = try CommandLineTool.parse(arguments, currentDirectory: cwd, home: home) { path in
                folders.contains(path) ? .directory : files.contains(path) ? .file : nil
            }
            return nil
        } catch {
            return error.description
        }
    }

    @Test func noArgumentsOpensTheCurrentFolder() throws {
        let request = try Self.request()
        #expect(request.items == [.folder("/Users/me/code/shop")])
        #expect(request.target == nil)
        #expect(!request.newWindow)
        #expect(try Self.request(".").items == [.folder("/Users/me/code/shop")])
    }

    @Test func pathsResolveAndAreSortedIntoKinds() throws {
        let request = try Self.request("scratch.php", "../blog", "Work.runlet", "~/notes.txt", "./app/../app/User.PHP")
        #expect(request.items == [
            .file("/Users/me/code/shop/scratch.php"),
            .folder("/Users/me/code/blog"),
            .workspace("/Users/me/code/shop/Work.runlet"),
            .file("/Users/me/notes.txt"),
            .file("/Users/me/code/shop/app/User.PHP"),
        ])
    }

    @Test func optionsAreRead() throws {
        let request = try Self.request("-n", "--target", "Acme", "scratch.php")
        #expect(request.newWindow)
        #expect(request.target == "Acme")
        #expect(try Self.request("--target=docker:Acme", "scratch.php").target == "docker:Acme")
        #expect(try Self.request("-t", "sandbox").items.isEmpty, "a target alone opens a new tab, not the current folder")
    }

    @Test func targetPathsAreMadeAbsolute() throws {
        #expect(try Self.request("-t", ".", "scratch.php").target == "/Users/me/code/shop")
        #expect(try Self.request("-t", "local:../blog", "scratch.php").target == "local:/Users/me/code/blog")
        #expect(try Self.request("-t", "docker:web/app", "scratch.php").target == "docker:web/app", "Docker names are never paths")
    }

    @Test func helpAndVersion() throws {
        #expect(try Self.parse("--help") == .help)
        #expect(try Self.parse("scratch.php", "-h") == .help)
        #expect(try Self.parse("-v") == .version)
    }

    @Test func mistakesAreExplained() {
        #expect(Self.error("missing.php") == "no such file or folder: missing.php")
        #expect(Self.error("--frobnicate") == "unknown option --frobnicate")
        #expect(Self.error("--target") == "--target needs a target name")
        #expect(Self.error("-t", " ", "scratch.php") == "--target needs a target name")
        #expect(Self.error("-t", "a", "-t", "b") == "only one --target can be given")
        #expect(Self.error("-") == "reading code from standard input isn't supported yet")
        #expect(Self.error("-t", "Acme", ".")?.hasPrefix("--target applies to files") == true)
        #expect(Self.error("-t", "Acme", "Work.runlet")?.hasPrefix("--target applies to files") == true)
    }

    @Test func homeAndRootAreNotProjects() {
        #expect(Self.error("~")?.contains("your home folder") == true)
        #expect(Self.error("/")?.contains("the root folder") == true)
    }

    @Test func doubleDashEndsOptions() throws {
        let invocation = try CommandLineTool.parse(["--", "-n"], currentDirectory: Self.cwd, home: Self.home) { path in
            path == "/Users/me/code/shop/-n" ? .file : nil
        }
        #expect(invocation == .open(OpenRequest(id: Self.id(invocation), items: [.file("/Users/me/code/shop/-n")])))
    }

    static func id(_ invocation: CommandLineTool.Invocation) -> UUID {
        if case .open(let request) = invocation { return request.id }
        return UUID()
    }

    @Test func requestsAndRepliesSurviveTheirJSONForm() throws {
        let request = OpenRequest(items: [.folder("/a b"), .file("/c\"d.php"), .workspace("/w.runlet")], target: "Acme", newWindow: true, recipient: 42)
        #expect(OpenRequest.decode(request.encoded) == request)
        let reply = OpenReply(id: request.id, errors: ["No target named “x”."])
        #expect(OpenReply.decode(reply.encoded) == reply)
        #expect(OpenRequest.decode("not json") == nil)
    }

    // MARK: Targets by name

    static let shop = LocalProject(name: "Shop", path: "/Users/me/code/shop")
    static let shopAdmin = LocalProject(name: "Shop Admin", path: "/Users/me/code/shop-admin")
    static let blog = LocalProject(name: "acme", path: "/Users/me/code/blog")
    static let acme = DockerProfile(name: "Acme", identity: ContainerIdentity(containerName: "acme-app"), workingDirectory: "/var/www/html")
    static var library: TargetLibrary {
        TargetLibrary(localProjects: [shop, shopAdmin, blog], dockerProfiles: [acme])
    }

    @Test func targetsAreFoundByName() {
        let library = Self.library
        #expect(library.target(matching: "sandbox") == .found(.sandbox))
        #expect(library.target(matching: "Laravel Sandbox") == .found(.sandbox))
        #expect(library.target(matching: "shop") == .found(.local(Self.shop.id)), "an exact name wins over a longer one")
        #expect(library.target(matching: "shop a") == .found(.local(Self.shopAdmin.id)), "a unique prefix")
        #expect(library.target(matching: "docker:acme") == .found(.docker(Self.acme.id)))
        #expect(library.target(matching: "local:ACME") == .found(.local(Self.blog.id)))
        #expect(library.target(matching: "nope") == .notFound)
        #expect(library.target(matching: "local:sandbox") == .notFound, "a kind prefix leaves the sandbox out")
    }

    @Test func clashingNamesAskForAKind() {
        guard case .ambiguous(let descriptions) = Self.library.target(matching: "acme") else {
            Issue.record("expected an ambiguous match")
            return
        }
        #expect(descriptions.count == 2)
        #expect(descriptions.contains { $0.contains("Docker profile") })
        #expect(descriptions.contains { $0.contains("local project") })
    }

    @Test func projectsAreFoundByPath() {
        let library = Self.library
        #expect(library.target(matching: "/Users/me/code/blog") == .found(.local(Self.blog.id)))
        #expect(library.target(matching: "local:/Users/me/code/blog/") == .found(.local(Self.blog.id)))
        #expect(library.target(matching: "~/code/shop", home: Self.home) == .found(.local(Self.shop.id)))
        #expect(library.target(matching: "/Users/me/elsewhere") == .notFound)
    }
}
