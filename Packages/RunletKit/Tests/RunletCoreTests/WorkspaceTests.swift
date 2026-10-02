import Foundation
import Testing
@testable import RunletCore

struct WorkspaceTests {
    let base = URL(fileURLWithPath: "/Users/dev/Code/shop", isDirectory: true)

    @Test func pathsAreRelativeInsideTheWorkspaceFolder() {
        #expect(WorkspaceTargets.storedPath("/Users/dev/Code/shop/api", relativeTo: base) == "api")
        #expect(WorkspaceTargets.storedPath("/Users/dev/Code/shop", relativeTo: base) == ".")
        #expect(WorkspaceTargets.storedPath("/opt/other", relativeTo: base) == "/opt/other")
        #expect(WorkspaceTargets.resolvedPath("api", relativeTo: base) == "/Users/dev/Code/shop/api")
        #expect(WorkspaceTargets.resolvedPath(".", relativeTo: base) == "/Users/dev/Code/shop")
        #expect(WorkspaceTargets.resolvedPath("/opt/other", relativeTo: base) == "/opt/other")
        #expect(WorkspaceTargets.resolvedPath("~/x", relativeTo: base) == NSHomeDirectory() + "/x")
    }

    @Test func roundTripEmbedsDefinitionsWithoutMachineState() throws {
        let project = LocalProject(name: "API", path: "/Users/dev/Code/shop/api", phpExecutable: "/opt/php84/bin/php")
        var profile = DockerProfile(name: "Shop", identity: ContainerIdentity(composeProject: "shop", composeService: "php", containerName: "shop-php-1", lastContainerId: "abc123", lastImage: "php:8.3"), workingDirectory: "/var/www/html", user: "www-data", localSourcePath: "/Users/dev/Code/shop/api")
        profile.languagePHPVersion = "8.3"
        let library = TargetLibrary(localProjects: [project], dockerProfiles: [profile])
        let document = WorkspaceDocument(tabs: [
            WorkspaceTab(title: "Local", code: "1", target: WorkspaceTargets.definition(for: .local(project.id), library: library, base: base)),
            WorkspaceTab(title: "Docker", code: "2", target: WorkspaceTargets.definition(for: .docker(profile.id), library: library, base: base)),
            WorkspaceTab(title: "Sandbox", code: "3", target: .sandbox),
        ], selectedIndex: 1)
        let data = try document.encoded()
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("abc123"), "container IDs are machine state")
        #expect(!json.contains(profile.id.uuidString), "profile IDs are machine state")
        #expect(json.contains("\"path\" : \"api\""))
        let decoded = try WorkspaceDocument.read(from: data)
        #expect(decoded == document)

        // Matching on the same machine finds the existing targets.
        #expect(WorkspaceTargets.match(decoded.tabs[0].target, in: library, base: base) == .local(project.id))
        #expect(WorkspaceTargets.match(decoded.tabs[1].target, in: library, base: base) == .docker(profile.id))
        // On another machine (empty library) new targets are created from the definitions.
        #expect(WorkspaceTargets.match(decoded.tabs[1].target, in: TargetLibrary(), base: base) == nil)
        let created = WorkspaceTargets.makeTarget(decoded.tabs[1].target, base: base)
        #expect(created.profile?.identity.composeService == "php")
        #expect(created.profile?.identity.lastContainerId == nil)
        #expect(created.profile?.localSourcePath == "/Users/dev/Code/shop/api")
        #expect(created.profile?.user == "www-data")
    }

    @Test func rejectsForeignAndNewerFiles() {
        #expect(throws: WorkspaceDocument.ReadError.notAWorkspace) { try WorkspaceDocument.read(from: Data("{}".utf8)) }
        #expect(throws: WorkspaceDocument.ReadError.newerVersion(9)) {
            try WorkspaceDocument.read(from: Data(#"{"format":"runlet-workspace","version":9,"tabs":[]}"#.utf8))
        }
    }

    @Test func legacySingleWindowSessionStillLoads() throws {
        let tab = TabState(title: "Old", code: "1")
        let legacy = try JSONEncoder().encode(["tabs": [tab]])
        let session = try JSONDecoder().decode(SessionState.self, from: legacy)
        #expect(session.windows.count == 1)
        #expect(session.windows[0].tabs == [tab])
        let modern = try JSONDecoder().decode(SessionState.self, from: JSONEncoder().encode(session))
        #expect(modern == session)
    }
}
