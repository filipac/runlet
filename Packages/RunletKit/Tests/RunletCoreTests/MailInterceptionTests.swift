import Foundation
import Testing
@testable import RunletCore

/// #193: the mail chip's mode and where it comes from.
struct MailInterceptionTests {
    private let project = LocalProject(name: "app", path: "/tmp/app")
    private let profile = DockerProfile(name: "api", identity: ContainerIdentity(containerName: "api"), workingDirectory: "/var/www")
    private let host = SSHProfile(name: "web", host: "web-1", remoteDirectory: "/srv/app")

    private func library(local: Bool? = nil, docker: Bool? = nil, ssh: Bool? = nil) -> TargetLibrary {
        var project = project, profile = profile, host = host
        project.interceptMail = local
        profile.interceptMail = docker
        host.interceptMail = ssh
        return TargetLibrary(localProjects: [project], dockerProfiles: [profile], sshProfiles: [host])
    }

    private var savedTargets: [TargetRef] { [.local(project.id), .docker(profile.id), .ssh(host.id)] }

    @Test func savedTargetsFollowSettingsWithoutAnOverride() {
        let library = library()
        for target in savedTargets {
            for global in [false, true] {
                let mode = library.mailInterception(for: target, global: global, runInspector: true)
                #expect(mode == MailInterception(intercept: global, source: .settings, override: nil, hasOption: true, state: global ? .intercepting : .sending))
                #expect(mode.intercept == library.interceptMail(for: target, global: global))
            }
        }
    }

    @Test func anOverrideWinsOverSettings() {
        let intercepting = library(local: true, docker: true, ssh: true)
        let sending = library(local: false, docker: false, ssh: false)
        for target in savedTargets {
            let on = intercepting.mailInterception(for: target, global: false, runInspector: true)
            #expect(on == MailInterception(intercept: true, source: .target, override: true, hasOption: true, state: .intercepting))
            #expect(on.intercept == intercepting.interceptMail(for: target, global: false))
            let off = sending.mailInterception(for: target, global: true, runInspector: true)
            #expect(off == MailInterception(intercept: false, source: .target, override: false, hasOption: true, state: .sending))
            #expect(off.intercept == sending.interceptMail(for: target, global: true))
        }
        // Overrides are per target: the others keep following Settings.
        let one = library(docker: true)
        #expect(one.mailInterception(for: .docker(profile.id), global: false, runInspector: true).source == .target)
        #expect(one.mailInterception(for: .local(project.id), global: false, runInspector: true).source == .settings)
        #expect(one.mailInterception(for: .ssh(host.id), global: false, runInspector: true).source == .settings)
    }

    @Test func theSandboxAndMissingTargetsHaveNoOption() {
        let library = library(local: true)
        let missing: [TargetRef] = [.local(UUID()), .docker(UUID()), .ssh(UUID())]
        for target in [TargetRef.sandbox] + missing {
            for global in [false, true] {
                let mode = library.mailInterception(for: target, global: global, runInspector: true)
                #expect(mode == MailInterception(intercept: global, source: .settings, override: nil, hasOption: false, state: global ? .intercepting : .sending))
                #expect(mode.intercept == library.interceptMail(for: target, global: global))
            }
        }
    }

    @Test func inspectorOffDimsOnlyWhenMailIsSent() {
        let library = library(local: true, docker: false)
        // Sending with the inspector off records nothing.
        #expect(library.mailInterception(for: .docker(profile.id), global: true, runInspector: false).state == .inspectorOff)
        #expect(library.mailInterception(for: .sandbox, global: false, runInspector: false).state == .inspectorOff)
        #expect(library.mailInterception(for: .ssh(host.id), global: false, runInspector: false).state == .inspectorOff)
        // Interception keeps the inspector on for the run (AppModel.inspectorOptions), so it
        // still intercepts.
        #expect(library.mailInterception(for: .local(project.id), global: false, runInspector: false).state == .intercepting)
        #expect(library.mailInterception(for: .sandbox, global: true, runInspector: false).state == .intercepting)
    }

    @Test func onlySwitchingAProductionTargetToSendingAsks() {
        let intercepting = library(local: true).mailInterception(for: .local(project.id), global: false, runInspector: true)
        #expect(intercepting.asksFirst(choosing: false, global: false, production: true))
        // Default asks only when Settings says Send.
        #expect(intercepting.asksFirst(choosing: nil, global: false, production: true))
        #expect(!intercepting.asksFirst(choosing: nil, global: true, production: true))
        #expect(!intercepting.asksFirst(choosing: true, global: false, production: true))
        // Development targets never ask.
        #expect(!intercepting.asksFirst(choosing: false, global: false, production: false))
        // A target that already sends doesn't ask again.
        let sending = library(local: false).mailInterception(for: .local(project.id), global: false, runInspector: true)
        #expect(!sending.asksFirst(choosing: nil, global: false, production: true))
        #expect(!sending.asksFirst(choosing: true, global: false, production: true))
    }

    @Test func theWarningComesFromWhatTheRunReported() {
        #expect(InspectorInfo(sections: [], interceptMail: true, interceptingMail: true, driverName: "Laravel").interceptionWarning == nil)
        #expect(InspectorInfo(sections: [], interceptMail: false, driverName: "WordPress").interceptionWarning == nil)
        #expect(InspectorInfo(sections: [], interceptMail: true, driverName: "WordPress").interceptionWarning
            == "Intercept Mail is on, but the WordPress driver can't intercept mail. Mail this run sends is delivered normally.")
        #expect(InspectorInfo(sections: [], interceptMail: true).interceptionWarning
            == "Intercept Mail is on, but this project's driver can't intercept mail. Mail this run sends is delivered normally.")
    }
}
