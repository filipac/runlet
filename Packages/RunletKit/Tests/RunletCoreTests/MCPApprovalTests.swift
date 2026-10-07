import Foundation
import Testing
@testable import RunletCore

struct MCPApprovalTests {
    static let local = UUID()
    static let docker = UUID()
    static let ssh = UUID()
    static let targets: [TargetRef] = [.sandbox, .local(local), .docker(docker), .ssh(ssh)]

    typealias Policy = MCPApprovalPolicy

    static let asks = Policy.Decision.ask(.init(offersSessionAllowance: true, isProduction: false, connectsSSH: false))

    @Test func sandboxLocalAndDockerOfferTheSessionAllowance() {
        for target in [TargetRef.sandbox, .local(Self.local), .docker(Self.docker)] {
            for environment in [TargetEnvironment.development, .staging] {
                #expect(Policy.decide(.init(target: target, environment: environment)) == Self.asks, "\(target) \(environment) asks and offers the tick")
                #expect(Policy.decide(.init(target: target, environment: environment, allowedForSession: true)) == .run, "\(target) \(environment) allowed")
            }
        }
    }

    @Test func productionAlwaysAsksWithAWarningAndIgnoresTheGrace() {
        for target in Self.targets {
            let decision = Policy.decide(.init(target: target, environment: .production, ssh: .connected, allowedForSession: true, productionGraceActive: true))
            guard case .ask(let prompt) = decision else {
                Issue.record("\(target) on production: \(decision)")
                continue
            }
            #expect(prompt.isProduction)
            #expect(!prompt.offersSessionAllowance)
        }
    }

    @Test func sshIsNeverConnectedSilently() {
        let target = TargetRef.ssh(Self.ssh)
        #expect(Policy.decide(.init(target: target, environment: .development, ssh: .connected)) == Self.asks)
        #expect(Policy.decide(.init(target: target, environment: .development, ssh: .willConnect)) == .ask(.init(offersSessionAllowance: true, isProduction: false, connectsSSH: true)), "the sheet says approving connects")
        #expect(Policy.decide(.init(target: target, environment: .development, ssh: nil)) == .ask(.init(offersSessionAllowance: true, isProduction: false, connectsSSH: true)), "unknown counts as connecting")
        guard case .refuse(let reason) = Policy.decide(.init(target: target, environment: .production, ssh: .needsLogin, allowedForSession: true)) else {
            Issue.record("a host that needs a login must be refused")
            return
        }
        #expect(reason.contains("Connect…"))
    }

    @Test func anAllowedSSHHostSkipsTheSheetOnlyWhileConnected() {
        let target = TargetRef.ssh(Self.ssh)
        for environment in [TargetEnvironment.development, .staging] {
            #expect(Policy.decide(.init(target: target, environment: environment, ssh: .connected, allowedForSession: true)) == .run)
            #expect(Policy.decide(.init(target: target, environment: environment, ssh: .willConnect, allowedForSession: true)) == .ask(.init(offersSessionAllowance: true, isProduction: false, connectsSSH: true)), "approving connects, so it asks")
            #expect(Policy.decide(.init(target: target, environment: environment, ssh: nil, allowedForSession: true)) == .ask(.init(offersSessionAllowance: true, isProduction: false, connectsSSH: true)))
            guard case .refuse = Policy.decide(.init(target: target, environment: environment, ssh: .needsLogin, allowedForSession: true)) else {
                Issue.record("an allowed host that needs a login is still refused")
                continue
            }
        }
    }

    @Test func onlyAnAllowedTargetThatIsntProductionRunsWithoutTheSheet() {
        for target in Self.targets {
            for environment in TargetEnvironment.allCases {
                for ssh in [Policy.SSHState.connected, .willConnect, .needsLogin, nil] as [Policy.SSHState?] {
                    for allowed in [false, true] {
                        for grace in [false, true] {
                            let decision = Policy.decide(.init(target: target, environment: environment, ssh: ssh, allowedForSession: allowed, productionGraceActive: grace))
                            let context = "\(target) \(environment) \(String(describing: ssh)) allowed=\(allowed) grace=\(grace)"
                            if decision == .run {
                                #expect(allowed && environment != .production, "\(context)")
                                if case .ssh = target { #expect(ssh == .connected, "\(context)") }
                            }
                            if case .ask(let prompt) = decision {
                                #expect(prompt.offersSessionAllowance == (environment != .production), "only production never offers the allowance: \(context)")
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func listingSaysHowEachTargetAsks() {
        for target in Self.targets {
            #expect(Policy.summary(for: target, environment: .development).contains("rest of the session"), "\(target)")
            #expect(Policy.summary(for: target, environment: .production).contains("production"), "\(target)")
            #expect(Policy.summary(for: target, environment: .production).contains("can't be allowed"), "\(target)")
        }
        #expect(Policy.summary(for: .ssh(Self.ssh), environment: .staging).contains("connected"))
    }
}

struct MCPSessionAllowanceTests {
    static let shop = LocalProject(name: "shop", path: "/Users/me/code/shop")
    static let lease = DockerProfile(name: "lease-api", identity: ContainerIdentity(composeProject: "lease", composeService: "app", lastContainerId: "abc123", lastImage: "php:8.4"), workingDirectory: "/var/www/html")
    static let staging = SSHProfile(name: "staging", host: "staging.example.com", user: "deploy", remoteDirectory: "/srv/app", environment: .staging,
                                    container: RemoteContainerStep(identity: ContainerIdentity(composeProject: "app", composeService: "php", lastContainerId: "def456"), workingDirectory: "/var/www/html", phpExecutable: "php"))
    static let library = TargetLibrary(localProjects: [shop], dockerProfiles: [lease], sshProfiles: [staging])

    typealias Policy = MCPApprovalPolicy

    /// What the app asks the policy: the target's environment and whether this connection allowed it.
    static func decide(_ target: TargetRef, _ allowance: MCPSessionAllowance, _ library: TargetLibrary, ssh: Policy.SSHState? = nil) -> Policy.Decision {
        Policy.decide(.init(target: target, environment: library.environment(for: target), ssh: ssh, allowedForSession: allowance.allows(target, in: library)))
    }

    @Test func allowingATargetAllowsOnlyThatTarget() {
        var allowance = MCPSessionAllowance()
        let docker = TargetRef.docker(Self.lease.id)
        allowance.allow(docker, settings: Self.library.settings(of: docker))
        #expect(allowance.targets == [docker])
        #expect(Self.decide(docker, allowance, Self.library) == .run)
        for other in [TargetRef.sandbox, .local(Self.shop.id), .ssh(Self.staging.id)] {
            #expect(!allowance.allows(other, in: Self.library), "\(other)")
            #expect(Self.decide(other, allowance, Self.library, ssh: .connected) != .run, "\(other)")
        }
        #expect(!MCPSessionAllowance().allows(docker, in: Self.library), "another connection has its own allowance")

        allowance.allow(.sandbox, settings: Self.library.settings(of: .sandbox))
        allowance.allow(docker, settings: Self.library.settings(of: docker))
        #expect(allowance.targets == [.sandbox, docker], "allowing again keeps one entry")
        allowance.removeAll()
        #expect(allowance.isEmpty)
        #expect(Self.decide(docker, allowance, Self.library) != .run)
    }

    @Test func everyKindOfTargetCanBeAllowed() {
        var allowance = MCPSessionAllowance()
        let targets: [TargetRef] = [.sandbox, .local(Self.shop.id), .docker(Self.lease.id), .ssh(Self.staging.id)]
        for target in targets { allowance.allow(target, settings: Self.library.settings(of: target)) }
        for target in targets {
            #expect(Self.decide(target, allowance, Self.library, ssh: .connected) == .run, "\(target)")
        }
        let ssh = TargetRef.ssh(Self.staging.id)
        #expect(Self.decide(ssh, allowance, Self.library, ssh: .willConnect) == .ask(.init(offersSessionAllowance: true, isProduction: false, connectsSSH: true)))
        #expect(Self.decide(ssh, allowance, Self.library, ssh: .needsLogin) != .run)
    }

    @Test func aTargetThatTurnedProductionAsksAgain() {
        var allowance = MCPSessionAllowance()
        let local = TargetRef.local(Self.shop.id)
        allowance.allow(local, settings: Self.library.settings(of: local))
        var library = Self.library
        library.localProjects[0].environment = .production
        guard case .ask(let prompt) = Self.decide(local, allowance, library) else {
            Issue.record("a production target must ask")
            return
        }
        #expect(prompt.isProduction)
        #expect(!prompt.offersSessionAllowance)
        // Even an allowance that (wrongly) still applies never skips production's sheet.
        #expect(Policy.decide(.init(target: local, environment: .production, allowedForSession: true)) != .run)
        allowance.prune(library)
        #expect(allowance.isEmpty, "pruning drops it")
        library.localProjects[0].environment = .development
        #expect(Self.decide(local, allowance, library) == MCPApprovalTests.asks, "back to development, it asks again")
    }

    @Test func editedOrRemovedTargetsAskAgain() {
        var allowance = MCPSessionAllowance()
        let docker = TargetRef.docker(Self.lease.id)
        let ssh = TargetRef.ssh(Self.staging.id)
        let local = TargetRef.local(Self.shop.id)
        for target in [docker, ssh, local] { allowance.allow(target, settings: Self.library.settings(of: target)) }

        // What Runlet refreshes by itself isn't an edit: a recreated container, a new revision
        // from that refresh, the last-opened date.
        var refreshed = Self.library
        refreshed.dockerProfiles[0].identity.lastContainerId = "fff999"
        refreshed.dockerProfiles[0].identity.lastImage = "php:8.5"
        refreshed.dockerProfiles[0].revision += 1
        refreshed.sshProfiles[0].container?.identity.lastContainerId = "eee888"
        refreshed.sshProfiles[0].lastOpenedAt = Date()
        refreshed.localProjects[0].lastOpenedAt = Date()
        for target in [docker, ssh, local] { #expect(allowance.allows(target, in: refreshed), "\(target)") }
        var kept = allowance
        kept.prune(refreshed)
        #expect(kept.targets == allowance.targets)

        // An edit ends that target's allowance only.
        var edited = Self.library
        edited.dockerProfiles[0].workingDirectory = "/srv/other"
        #expect(!allowance.allows(docker, in: edited))
        #expect(allowance.allows(ssh, in: edited))
        edited.sshProfiles[0].host = "other.example.com"
        #expect(!allowance.allows(ssh, in: edited))
        var pruned = allowance
        pruned.prune(edited)
        #expect(pruned.targets == [local])
        #expect(!pruned.allows(docker, in: Self.library), "putting the old settings back doesn't bring it back")

        // Removed.
        var removed = Self.library
        removed.localProjects = []
        #expect(!allowance.allows(local, in: removed))
        var gone = allowance
        gone.prune(removed)
        #expect(gone.targets == [docker, ssh])
        var none = MCPSessionAllowance()
        none.allow(local, settings: removed.settings(of: local))
        #expect(none.isEmpty, "a removed target can't be allowed")
    }
}

struct MCPCatalogTests {
    static let shop = LocalProject(name: "shop", path: "/Users/me/code/shop", environment: .production)
    static let shopCopy = LocalProject(name: "shop", path: "/Users/me/code/shop-copy")
    static let acme = DockerProfile(name: "acme", identity: ContainerIdentity(composeProject: "acme", composeService: "app"), workingDirectory: "/var/www/html")
    static let staging = SSHProfile(name: "staging", host: "staging.example.com", user: "deploy", remoteDirectory: "/srv/app", environment: .staging)
    static let prod = SSHProfile(name: "prod", host: "app.example.com", remoteDirectory: "/srv/app", authentication: .interactive, environment: .production)

    @Test func targetsMatchSSHProfilesAndIds() {
        let library = TargetLibrary(localProjects: [Self.shop], dockerProfiles: [Self.acme], sshProfiles: [Self.staging, Self.prod])
        #expect(library.target(matching: "staging") == .found(.ssh(Self.staging.id)))
        #expect(library.target(matching: "ssh:PROD") == .found(.ssh(Self.prod.id)))
        #expect(library.target(matching: "ssh:shop") == .notFound, "a kind prefix limits the search")
        #expect(library.target(matching: "docker:" + Self.acme.id.uuidString) == .found(.docker(Self.acme.id)))
        #expect(library.target(matching: "ssh:" + Self.acme.id.uuidString) == .notFound, "an id only matches its own kind")
        #expect(library.target(matching: "sandbox") == .found(.sandbox))
        #expect(library.target(matching: "ssh:sandbox") == .notFound)
        #expect(library.target(matching: "st") == .found(.ssh(Self.staging.id)), "a unique prefix")
    }

    @Test func selectorsResolveBackToTheirTarget() {
        let twin = SSHProfile(name: "staging", host: "other.example.com", remoteDirectory: "/srv")
        let library = TargetLibrary(localProjects: [Self.shop, Self.shopCopy], dockerProfiles: [Self.acme], sshProfiles: [Self.staging, twin])
        let all: [TargetRef] = [.sandbox, .local(Self.shop.id), .local(Self.shopCopy.id), .docker(Self.acme.id), .ssh(Self.staging.id), .ssh(twin.id)]
        for target in all {
            let selector = library.selector(for: target)
            #expect(library.target(matching: selector) == .found(target), "\(selector)")
        }
        #expect(library.selector(for: .docker(Self.acme.id)) == "docker:acme")
        #expect(library.selector(for: .local(Self.shop.id)) == "local:/Users/me/code/shop", "a shared name falls back to the folder")
        #expect(library.selector(for: .ssh(twin.id)) == "ssh:" + twin.id.uuidString)
    }

    @Test func cliTargetsWithSSHPrefixesStayNames() throws {
        let invocation = try CommandLineTool.parse(["-t", "ssh:prod/eu"], currentDirectory: "/Users/me", home: "/Users/me") { _ in nil }
        guard case .open(let request) = invocation else {
            Issue.record("expected open")
            return
        }
        #expect(request.target == "ssh:prod/eu", "not made into a path")
        #expect(try CommandLineTool.parse(["mcp"], currentDirectory: "/Users/me") { _ in .directory } == .mcp)
        #expect(throws: CommandLineTool.UsageError.self) { try CommandLineTool.parse(["mcp", "--verbose"], currentDirectory: "/Users/me") { _ in nil } }
        guard case .open(let folder) = try CommandLineTool.parse(["./mcp"], currentDirectory: "/Users/me", home: "/Users/home", kind: { _ in .directory }) else {
            Issue.record("./mcp opens the folder")
            return
        }
        #expect(folder.items == [.folder("/Users/me/mcp")])
    }

    @Test func targetListDescribesEveryTarget() {
        let library = TargetLibrary(localProjects: [Self.shop], dockerProfiles: [Self.acme], sshProfiles: [Self.staging, Self.prod])
        let json = MCPCatalog.targets(library, sandbox: .init(label: "Laravel Sandbox 12"), sshState: { $0.authentication == .interactive ? .needsLogin : .willConnect })
        guard case .array(let targets)? = json["targets"] else {
            Issue.record("no targets")
            return
        }
        #expect(targets.compactMap { $0["target"]?.stringValue } == ["sandbox", "local:shop", "docker:acme", "ssh:prod", "ssh:staging"])
        #expect(targets[0]["approval"]?.stringValue?.contains("session") == true)
        #expect(targets[1]["environment"] == "production")
        #expect(targets[1]["approval"]?.stringValue?.contains("production") == true)
        #expect(targets[2]["container"] == "acme/app")
        #expect(targets[3]["connection"]?.stringValue?.contains("Connect…") == true)
        #expect(targets[4]["connection"]?.stringValue?.contains("approving a run connects") == true)
        #expect(targets[4]["host"] == "deploy@staging.example.com")
    }

    @Test func projectSnippetIdsNameTheirTargetAndFile() {
        let target = TargetRef.local(Self.shop.id)
        let id = MCPCatalog.projectSnippetID(target: target, fileName: "recent-users.php")
        #expect(MCPCatalog.parseProjectSnippetID(id)?.targetKey == target.stableKey)
        #expect(MCPCatalog.parseProjectSnippetID(id)?.fileName == "recent-users.php")
        #expect(MCPCatalog.parseProjectSnippetID(target.stableKey + "#../../etc/passwd") == nil, "no paths")
        #expect(MCPCatalog.parseProjectSnippetID(UUID().uuidString) == nil)
        #expect(MCPCatalog.preview("<?php\n\n$a = 1;\n$b = 2;\n$c = 3;\n$d = 4;") == "$a = 1;\n$b = 2;\n$c = 3;")
    }
}

struct MCPRunReportTests {
    static func value(_ scalar: String, type: ValueNode.Kind = .int) -> ValueNode {
        ValueNode(id: 1, type: type, scalar: scalar)
    }

    @Test func reportReadsLikeTheOutput() {
        var report = MCPRunReport(clientName: "Claude Code", tabTitle: "Claude Code", targetLabel: "Laravel Sandbox")
        report.apply(.started(StartedInfo(phpVersion: "8.4.1")))
        report.apply(.stdout(Data("hello ".utf8)))
        report.apply(.stdout(Data("world\n".utf8)))
        report.apply(.dump(DumpInfo(index: 0, origin: "dump", value: Self.value("3"), inSnippet: true, snippetLine: 2)))
        report.apply(.result(ResultInfo(hasValue: true, value: Self.value("42"))))
        report.apply(.finished(FinishedInfo(status: .completed, reason: "completed", elapsedMs: 12)))
        let result = report.toolResult()
        #expect(!result.isError)
        #expect(result.text.contains("Ran on Laravel Sandbox in the Runlet tab “Claude Code”"))
        #expect(result.text.contains("PHP 8.4.1"))
        #expect(result.text.contains("Output:\nhello world"), "consecutive output is one block")
        #expect(result.text.contains("dump (line 2):\n3"))
        #expect(result.text.contains("Result (int):\n42"))
        #expect(result.text.contains("Finished: completed (completed) in 12 ms"))
        #expect(result.structured?["status"] == "completed")
        #expect(result.structured?["durationMs"] == 12)
        #expect(result.structured?["output"] == "hello world\n")
        #expect(result.structured?["result"]?["value"] == "42")
        #expect(result.structured?["dumps"] == [["value": "3", "line": 2]])
    }

    @Test func errorsCarryTheirLineAndFailTheCall() {
        var report = MCPRunReport(clientName: "c", tabTitle: "t", targetLabel: "shop")
        var error = RunErrorInfo(stage: .execute, className: "RuntimeException", message: "Boom")
        error.inSnippet = true
        error.snippetLine = 3
        report.apply(.error(error))
        report.apply(.finished(FinishedInfo(status: .failed, reason: "error", exitCode: 255, elapsedMs: 5)))
        let result = report.toolResult()
        #expect(result.isError, "the model sees its code failed")
        #expect(result.text.contains("Error: RuntimeException: Boom (line 3)"))
        #expect(result.text.contains("exit code 255"))
        #expect(result.structured?["errors"] == [["class": "RuntimeException", "message": "Boom", "stage": "execute", "line": 3]])
    }

    @Test func runsThatCantStartOrStillRunAreSaidSo() {
        var failed = MCPRunReport(clientName: "c", tabTitle: "t", targetLabel: "acme (Docker)")
        failed.failBeforeLaunch("Docker is not available.")
        #expect(failed.toolResult().isError)
        #expect(failed.toolResult().text.contains("Docker is not available. [launch]"))

        let started = Date(timeIntervalSince1970: 1000)
        let running = MCPRunReport(clientName: "c", tabTitle: "t", targetLabel: "sandbox", startedAt: started)
        let result = running.toolResult(now: started.addingTimeInterval(7))
        #expect(!result.isError)
        #expect(result.text.contains("Still running (started 7 s ago)"))
        #expect(result.structured?["status"] == "running")
    }

    @Test func longOutputIsCapped() {
        var report = MCPRunReport(clientName: "c", tabTitle: "t", targetLabel: "sandbox")
        for _ in 0..<100 { report.apply(.stdout(Data(String(repeating: "x", count: 1000).utf8))) }
        report.apply(.finished(FinishedInfo(status: .completed, reason: "completed", elapsedMs: 1)))
        let result = report.toolResult()
        #expect(report.truncated)
        #expect(result.text.count < MCPRunReport.maxTextCharacters + 2000)
        #expect(result.text.contains("cut off"))
        #expect(result.structured?["truncated"] == true)
    }
}
