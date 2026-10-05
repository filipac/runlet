import Foundation
import Testing
@testable import RunletCore

/// The Quick Run panel (#25): which targets it offers and refuses, what Open in Tab moves, how
/// the session keeps its code, History's mark, and its global shortcut through a fake registrar
/// (no test ever registers a real one).
struct QuickRunTests {
    // MARK: Targets

    private static let shop = LocalProject(name: "shop", path: "/tmp/shop", environment: .development, lastOpenedAt: Date(timeIntervalSince1970: 100))
    private static let blog = LocalProject(name: "blog", path: "/tmp/blog", lastOpenedAt: Date(timeIntervalSince1970: 300))
    private static let live = LocalProject(name: "live", path: "/tmp/live", environment: .production, lastOpenedAt: Date(timeIntervalSince1970: 500))
    private static let stagingDocker = DockerProfile(name: "staging-app", identity: ContainerIdentity(containerName: "app"), workingDirectory: "/var/www", environment: .staging)
    private static let prodDocker = DockerProfile(name: "prod-app", identity: ContainerIdentity(containerName: "app"), workingDirectory: "/var/www", environment: .production)
    private static let devHost = SSHProfile(name: "dev-box", host: "dev.example.com", remoteDirectory: "/srv/app")
    private static let prodHost = SSHProfile(name: "shop-prod", host: "shop.example.com", remoteDirectory: "/srv/shop", environment: .production)

    private static var library: TargetLibrary {
        TargetLibrary(localProjects: [shop, blog, live], dockerProfiles: [stagingDocker, prodDocker], sshProfiles: [devHost, prodHost])
    }

    @Test func productionTargetsAreNeverOffered() {
        let offered = QuickRun.offeredTargets(in: Self.library)
        // The sandbox first, then each kind most recently opened first; staging stays.
        #expect(offered == [.sandbox, .local(Self.blog.id), .local(Self.shop.id), .docker(Self.stagingDocker.id), .ssh(Self.devHost.id)])
        #expect(!offered.contains(.local(Self.live.id)))
        #expect(!offered.contains(.docker(Self.prodDocker.id)))
        #expect(!offered.contains(.ssh(Self.prodHost.id)))
    }

    @Test func targetsWhoseApplicationSaysProductionAreNotOffered() {
        let reported = [TargetRef.local(Self.shop.id).stableKey: "Production", TargetRef.local(Self.blog.id).stableKey: "local"]
        let offered = QuickRun.offeredTargets(in: Self.library, reportedEnvironments: reported)
        #expect(!offered.contains(.local(Self.shop.id)))
        #expect(offered.contains(.local(Self.blog.id)))
        #expect(offered.first == .sandbox)
    }

    @Test func runTimeCheckRefusesProduction() throws {
        #expect(QuickRun.refusal(for: .sandbox, in: Self.library) == nil)
        #expect(QuickRun.refusal(for: .local(Self.shop.id), in: Self.library) == nil)
        // Staging runs as usual, without a confirmation.
        #expect(QuickRun.refusal(for: .docker(Self.stagingDocker.id), in: Self.library) == nil)
        let marked = try #require(QuickRun.refusal(for: .ssh(Self.prodHost.id), in: Self.library))
        #expect(marked.contains("“shop-prod” is marked as production"))
        let reported = try #require(QuickRun.refusal(for: .local(Self.shop.id), in: Self.library, reportedEnvironment: " live "))
        #expect(reported.contains("“live”"))
        #expect(QuickRun.refusal(for: .local(Self.shop.id), in: Self.library, reportedEnvironment: "preprod") == nil)
        #expect(QuickRun.refusal(for: .local(UUID()), in: Self.library) != nil)
    }

    @Test func aTargetMarkedProductionAfterItWasPickedIsRefused() {
        var library = Self.library
        let target = TargetRef.local(Self.shop.id)
        #expect(QuickRun.offeredTargets(in: library).contains(target))
        #expect(QuickRun.refusal(for: target, in: library) == nil)
        // Marked production while the panel is open: ⌘R checks again.
        library.localProjects[0].environment = .production
        #expect(QuickRun.refusal(for: target, in: library) != nil)
        #expect(!QuickRun.offeredTargets(in: library).contains(target))
    }

    // MARK: Open in Tab

    @Test func openInTabMovesTheCodeAndTheTarget() throws {
        let draft = QuickRunDraft(code: "Str::slug('Hello World')", target: .local(Self.shop.id))
        let handoff = try #require(QuickRun.handoff(draft, in: Self.library))
        #expect(handoff.title == "Quick Run")
        #expect(handoff.code == "Str::slug('Hello World')")
        #expect(handoff.target == .local(Self.shop.id))
        // The code moved: the panel is left empty, on the same target.
        #expect(handoff.remaining == QuickRunDraft(code: "", target: .local(Self.shop.id)))
    }

    @Test func openInTabNeedsCodeAndFallsBackFromARemovedTarget() throws {
        #expect(QuickRun.handoff(QuickRunDraft(code: "  \n", target: .sandbox), in: Self.library) == nil)
        let handoff = try #require(QuickRun.handoff(QuickRunDraft(code: "now()", target: .docker(UUID())), in: Self.library))
        #expect(handoff.target == .sandbox)
        // A production target's code still opens in a tab, where every run asks first.
        #expect(QuickRun.handoff(QuickRunDraft(code: "now()", target: .ssh(Self.prodHost.id)), in: Self.library)?.target == .ssh(Self.prodHost.id))
    }

    // MARK: Persistence

    @Test func theSessionKeepsThePanelsCode() throws {
        let draft = QuickRunDraft(code: "now()->addDays(3)->toDateString()", target: .local(Self.shop.id))
        let session = SessionState(windows: [WindowState(tabs: [TabState(title: "Tab 1")])], quickRun: draft)
        let decoded = try JSONDecoder().decode(SessionState.self, from: JSONEncoder().encode(session))
        #expect(decoded.quickRun == draft)
        #expect(decoded == session)
    }

    @Test func olderSessionsHaveNoDraftAndAnUnreadableOneIsLeftOut() throws {
        let older = try JSONDecoder().decode(SessionState.self, from: Data(#"{"windows": []}"#.utf8))
        #expect(older.quickRun == nil)
        let newer = try JSONDecoder().decode(SessionState.self, from: Data(#"{"windows": [], "quickRun": {"code": "1", "target": {"cloud": {}}}}"#.utf8))
        #expect(newer.quickRun == nil)
        #expect(newer.windows.isEmpty)
        // Never used: nothing is written.
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SessionState(windows: []))) as? [String: Any]
        #expect(encoded?["quickRun"] == nil)
    }

    @Test func restoringKeepsTheCodeAndDropsARemovedTarget() {
        #expect(QuickRun.restored(nil, in: Self.library) == QuickRunDraft())
        let kept = QuickRunDraft(code: "1 + 1", target: .local(Self.shop.id))
        #expect(QuickRun.restored(kept, in: Self.library) == kept)
        #expect(QuickRun.restored(QuickRunDraft(code: "1 + 1", target: .ssh(UUID())), in: Self.library) == QuickRunDraft(code: "1 + 1", target: .sandbox))
        // A production target stays, so the panel can say why it won't run there.
        let production = QuickRunDraft(code: "1", target: .local(Self.live.id))
        #expect(QuickRun.restored(production, in: Self.library) == production)
    }

    // MARK: History and settings

    @Test func historyMarksQuickRuns() throws {
        let entry = HistoryEntry(runId: UUID(), code: "now()", target: .sandbox, targetLabel: "Sandbox", status: .completed, reason: "completed", elapsedMs: 12, quickRun: true)
        #expect(entry.isQuickRun)
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded.isQuickRun)
        let tabRun = HistoryEntry(runId: UUID(), code: "now()", target: .sandbox, targetLabel: "Sandbox", status: .completed, reason: "completed", elapsedMs: 9)
        #expect(!tabRun.isQuickRun)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tabRun)) as? [String: Any]
        #expect(encoded?["quickRun"] == nil)
        // The same code run again from a tab moves the entry to the top as a tab's run.
        let history = HistoryLog.recording(tabRun, into: [entry], limit: 10)
        #expect(history.count == 1)
        #expect(!history[0].isQuickRun)
    }

    @Test func theHotKeyIsOffByDefaultAndSaved() throws {
        let defaults = AppSettings()
        #expect(!defaults.quickRunHotKeyEnabled)
        #expect(defaults.quickRunHotKey == .quickRunDefault)
        #expect(GlobalHotKey.quickRunDefault.displayString == "⌃⌥R")
        var settings = AppSettings()
        settings.quickRunHotKeyEnabled = true
        settings.quickRunHotKey = GlobalHotKey(keyCode: 49, combo: KeyCombo("space", [.command, .shift]))
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.quickRunHotKeyEnabled)
        #expect(decoded.quickRunHotKey == settings.quickRunHotKey)
        let older = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(!older.quickRunHotKeyEnabled)
        #expect(older.quickRunHotKey == .quickRunDefault)
    }

    @Test func carbonModifiers() {
        #expect(GlobalHotKey(keyCode: 15, combo: KeyCombo("r", [.control, .option])).carbonModifiers == 0x1800)
        #expect(GlobalHotKey(keyCode: 49, combo: KeyCombo("space", [.command, .shift])).carbonModifiers == 0x0300)
        #expect(GlobalHotKey(keyCode: 15, combo: KeyCombo("r", [.shift])).isValid == false)
        #expect(GlobalHotKey(keyCode: 15, combo: KeyCombo("r", [])).isValid == false)
        #expect(GlobalHotKey(keyCode: 15, combo: KeyCombo("r", [.command])).isValid)
    }
}

// MARK: - Global shortcut

/// The global shortcut's registration, through a registrar that records instead of registering.
@MainActor
struct QuickRunHotKeyTests {
    final class FakeRegistrar: GlobalHotKeyRegistering {
        var registered: GlobalHotKey?
        var calls: [String] = []
        var failure: String?
        var systemKeyCodes: Set<Int> = []
        var onPress: (@MainActor () -> Void)?

        func register(_ hotKey: GlobalHotKey, onPress: @escaping @MainActor () -> Void) -> String? {
            calls.append("register \(hotKey.displayString)")
            if let failure { return failure }
            registered = hotKey
            self.onPress = onPress
            return nil
        }

        func unregister() {
            calls.append("unregister")
            registered = nil
            onPress = nil
        }

        func isUsedBySystem(_ hotKey: GlobalHotKey) -> Bool { systemKeyCodes.contains(hotKey.keyCode) }
    }

    private let other = GlobalHotKey(keyCode: 49, combo: KeyCombo("space", [.command, .shift]))

    @Test func offRegistersNothing() {
        let registrar = FakeRegistrar()
        let controller = GlobalHotKeyController(registrar: registrar) {}
        #expect(controller.apply(enabled: false, hotKey: .quickRunDefault) == .off)
        #expect(registrar.calls.isEmpty)
    }

    @Test func enablingRegistersAndAPressOpensThePanel() {
        let registrar = FakeRegistrar()
        var presses = 0
        let controller = GlobalHotKeyController(registrar: registrar) { presses += 1 }
        #expect(controller.apply(enabled: true, hotKey: .quickRunDefault) == .active(.quickRunDefault))
        #expect(registrar.registered == .quickRunDefault)
        registrar.onPress?()
        #expect(presses == 1)
        // The same settings again change nothing.
        controller.apply(enabled: true, hotKey: .quickRunDefault)
        #expect(registrar.calls == ["register ⌃⌥R"])
    }

    @Test func disablingUnregisters() {
        let registrar = FakeRegistrar()
        let controller = GlobalHotKeyController(registrar: registrar) {}
        controller.apply(enabled: true, hotKey: .quickRunDefault)
        #expect(controller.apply(enabled: false, hotKey: .quickRunDefault) == .off)
        #expect(registrar.registered == nil)
        #expect(registrar.calls == ["register ⌃⌥R", "unregister"])
        // Off again: nothing more to unregister.
        controller.apply(enabled: false, hotKey: .quickRunDefault)
        #expect(registrar.calls.count == 2)
    }

    @Test func aNewShortcutReplacesTheOldOne() {
        let registrar = FakeRegistrar()
        let controller = GlobalHotKeyController(registrar: registrar) {}
        controller.apply(enabled: true, hotKey: .quickRunDefault)
        #expect(controller.apply(enabled: true, hotKey: other) == .active(other))
        #expect(registrar.calls == ["register ⌃⌥R", "unregister", "register ⇧⌘Space"])
        #expect(registrar.registered == other)
    }

    @Test func aShortcutAnotherAppUsesIsReported() {
        let registrar = FakeRegistrar()
        registrar.failure = "Another app already uses ⌃⌥R as a global shortcut. Record another one."
        let controller = GlobalHotKeyController(registrar: registrar) {}
        let status = controller.apply(enabled: true, hotKey: .quickRunDefault)
        #expect(status == .unavailable(.quickRunDefault, reason: "Another app already uses ⌃⌥R as a global shortcut. Record another one."))
        #expect(!status.isActive)
        #expect(registrar.registered == nil)
        // Recording another shortcut tries again.
        registrar.failure = nil
        #expect(controller.apply(enabled: true, hotKey: other) == .active(other))
    }

    @Test func macOSsOwnShortcutsAndRunletsCommandsAreNotTaken() {
        let registrar = FakeRegistrar()
        registrar.systemKeyCodes = [49]
        let controller = GlobalHotKeyController(registrar: registrar) {}
        guard case .unavailable(_, let reason) = controller.apply(enabled: true, hotKey: other) else {
            Issue.record("registered a system shortcut")
            return
        }
        #expect(reason.contains("macOS uses ⇧⌘Space"))
        let profileRun = GlobalHotKey(keyCode: 15, combo: KeyCombo("r", [.command, .option]))
        guard case .unavailable(_, let command) = controller.apply(enabled: true, hotKey: profileRun, appShortcuts: ["Profile Run": KeyCombo("r", [.command, .option])]) else {
            Issue.record("registered a shortcut Runlet uses")
            return
        }
        #expect(command.contains("Runlet's Profile Run command uses ⌥⌘R"))
        #expect(registrar.calls.isEmpty)
    }

    @Test func aCommandTakingTheShortcutLaterUnregistersIt() {
        let registrar = FakeRegistrar()
        let controller = GlobalHotKeyController(registrar: registrar) {}
        controller.apply(enabled: true, hotKey: .quickRunDefault)
        let status = controller.apply(enabled: true, hotKey: .quickRunDefault, appShortcuts: ["Run": KeyCombo("r", [.control, .option])])
        #expect(!status.isActive)
        #expect(registrar.registered == nil)
        #expect(registrar.calls == ["register ⌃⌥R", "unregister"])
    }

    @Test func aShortcutWithoutCommandControlOrOptionIsRefused() {
        let registrar = FakeRegistrar()
        let controller = GlobalHotKeyController(registrar: registrar) {}
        let shiftOnly = GlobalHotKey(keyCode: 15, combo: KeyCombo("r", [.shift]))
        #expect(!controller.apply(enabled: true, hotKey: shiftOnly).isActive)
        #expect(controller.apply(enabled: true, hotKey: nil) == .noShortcut)
        #expect(registrar.calls.isEmpty)
    }
}
