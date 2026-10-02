import Foundation
import Testing
@testable import RunletCore

struct SSHModelTests {
    @Test func validatesFieldsThatReachSSHArguments() {
        var profile = SSHProfile(name: "App", host: "app-prod", remoteDirectory: "/home/forge/app.test/current")
        #expect(profile.validate().isEmpty)
        profile.host = "-oProxyCommand=x"
        profile.remoteDirectory = "home/forge"
        profile.phpExecutable = "-n"
        profile.user = "bad user"
        profile.port = 0
        profile.jumpHost = "a b"
        profile.keepAliveMinutes = 0
        profile.name = " "
        #expect(Set(profile.validate()) == [.emptyName, .invalidHost, .relativeRemoteDirectory, .invalidPHP, .invalidUser, .invalidPort, .invalidJumpHost, .invalidKeepAlive])
        #expect(SSHProfile(name: "x", host: "a host", remoteDirectory: "/x").validate() == [.invalidHost])
    }

    @Test func librariesWithoutSSHProfilesAndUnknownValuesStillLoad() throws {
        let old = #"{"localProjects":[{"id":"6F2C1C55-7E43-4E0B-9B83-6C1B1F3F2A10","name":"A","path":"/a","revision":1}],"dockerProfiles":[]}"#
        let library = try JSONDecoder().decode(TargetLibrary.self, from: Data(old.utf8))
        #expect(library.sshProfiles.isEmpty)
        #expect(library.localProjects.first?.environment == nil)
        #expect(library.environment(for: .local(library.localProjects[0].id)) == .development)

        let newer = #"{"id":"6F2C1C55-7E43-4E0B-9B83-6C1B1F3F2A11","name":"S","host":"h","remoteDirectory":"/srv","environment":"qa","color":"chartreuse","authentication":"passkey"}"#
        let profile = try JSONDecoder().decode(SSHProfile.self, from: Data(newer.utf8))
        #expect(profile.environment == .development)
        #expect(profile.color == .gray)
        #expect(profile.authentication == .automatic)
        #expect(profile.phpExecutable == "php")
        #expect(profile.keepAliveMinutes == 10)
        #expect(profile.compression)

        var saved = SSHProfile(name: "S", host: "h", remoteDirectory: "/srv", keepAliveMinutes: nil, environment: .production, color: .red)
        saved = try JSONDecoder().decode(SSHProfile.self, from: JSONEncoder().encode(saved))
        #expect(saved.keepAliveMinutes == nil, "until Disconnect survives a round trip")
        #expect(saved.environment == .production && saved.color == .red)
    }

    @Test func libraryAnswersPerTargetQuestions() {
        let ssh = SSHProfile(name: "Prod", host: "app-prod", remoteDirectory: "/srv", localSourcePath: "~/Code/app", strictTypes: true, environment: .production, color: .orange)
        let docker = DockerProfile(name: "D", identity: ContainerIdentity(containerName: "d"), workingDirectory: "/app", environment: .staging)
        let library = TargetLibrary(dockerProfiles: [docker], sshProfiles: [ssh])
        #expect(library.isProduction(.ssh(ssh.id)))
        #expect(!library.isProduction(.docker(docker.id)) && library.environment(for: .docker(docker.id)) == .staging)
        #expect(library.color(for: .ssh(ssh.id)) == .orange)
        #expect(library.strictTypes(for: .ssh(ssh.id), global: false))
        #expect(library.localFolder(for: .ssh(ssh.id)) == NSHomeDirectory() + "/Code/app")
        #expect(library.localFolder(for: .docker(docker.id)) == nil)
        #expect(TargetRef.ssh(ssh.id).stableKey == "ssh:\(ssh.id.uuidString)")
    }

    @Test func serverPathsMapToTheLocalFolderIncludingReleases() {
        let mapping = EditorPathMapping.remote(roots: ["/home/forge/app.test/current", "/home/forge/app.test/releases/20260101120000", nil], localRoot: "/Users/dev/app", host: "forge@app")
        #expect(mapping.resolve("/home/forge/app.test/current/app/User.php") == .mapped("/Users/dev/app/app/User.php"))
        #expect(mapping.resolve("/home/forge/app.test/releases/20260101120000/routes/web.php") == .mapped("/Users/dev/app/routes/web.php"))
        // An older or newer release than the one the run reported maps too.
        #expect(mapping.resolve("/home/forge/app.test/releases/20251231/vendor/x.php") == .mapped("/Users/dev/app/vendor/x.php"))
        #expect(mapping.resolve("/home/forge/app.test/current") == .mapped("/Users/dev/app"))
        #expect(mapping.resolve("/etc/php/8.3/cli/php.ini").reason?.contains("outside") == true)
        #expect(mapping.resolve("/home/forge/app.test/currently/x.php").path == nil)

        let limited = EditorPathMapping.remote(roots: ["/srv/app"], localRoot: nil, host: "deploy@app-prod")
        #expect(limited.resolve("/srv/app/a.php").reason?.contains("Set a local folder in the SSH profile") == true)
        #expect(limited.resolve("/srv/app/a.php").reason?.contains("deploy@app-prod") == true)

        let endpoint = SSHEndpoint(host: "app-prod", controlPath: "/tmp/x.sock")
        let snapshot = TargetSnapshot(kind: .ssh, label: "x", targetId: "x", workingDirectory: "/srv/app/current", phpExecutable: "php", ssh: endpoint)
        let fromRun = EditorPathMapping.forSnapshot(snapshot, localSource: "/Users/dev/app", runtimeDirectory: "/srv/app/releases/7")
        #expect(fromRun.resolve("/srv/app/releases/7/a.php") == .mapped("/Users/dev/app/a.php"))
    }

    @Test func workspacesEmbedSSHHostsWithoutSecrets() throws {
        let base = URL(fileURLWithPath: "/Users/dev/Code/app")
        let profile = SSHProfile(name: "Prod", host: "app-prod", user: "forge", remoteDirectory: "/home/forge/app/current", authentication: .interactive, localSourcePath: "/Users/dev/Code/app", environment: .production)
        let library = TargetLibrary(sshProfiles: [profile])
        let definition = WorkspaceTargets.definition(for: .ssh(profile.id), library: library, base: base)
        let document = WorkspaceDocument(tabs: [WorkspaceTab(title: "t", code: "1", target: definition)], selectedIndex: 0)
        let data = try document.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"kind\" : \"ssh\""))
        #expect(!text.contains("sock") && !text.contains(profile.id.uuidString), "no control sockets or profile ids")
        let decoded = try WorkspaceDocument.read(from: data)
        #expect(WorkspaceTargets.match(decoded.tabs[0].target, in: library, base: base) == .ssh(profile.id))
        let made = WorkspaceTargets.makeTarget(decoded.tabs[0].target, base: base)
        #expect(made.sshProfile?.localSourcePath == "/Users/dev/Code/app")
        #expect(made.sshProfile?.environment == .production)
        #expect(made.sshProfile?.authentication == .interactive)
        #expect(decoded.tabs[0].target.displayName == "Prod (SSH)")
    }
}
