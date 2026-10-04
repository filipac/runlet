import Foundation
import Testing
@testable import RunletCore

/// The guided tour and What's New (#232): versions, the manifest's model and aggregation, the
/// bundled manifest (`Runlet/WhatsNew.json`) against the app's anchors, commands, and version,
/// and the rules for when either appears by itself.
struct WhatsNewTests {
    // MARK: Versions

    @Test func versionsParseAndOrder() throws {
        let beta6 = try #require(AppVersion(version: "0.4.0", build: "12"))
        let beta7 = try #require(AppVersion(version: "0.4.0", build: "13"))
        let previous = try #require(AppVersion(version: "0.3.0", build: "6"))
        #expect(beta6.components == [0, 4, 0])
        #expect(previous < beta6 && beta6 < beta7)
        #expect(beta6.sameVersion(as: beta7))
        #expect(!beta6.sameVersion(as: previous))
        // Numbers, not text: 0.10.0 is newer than 0.9.0, and "0.4" is "0.4.0".
        #expect(AppVersion(version: "0.9.0", build: 50) < AppVersion(version: "0.10.0", build: 1))
        #expect(AppVersion(version: "0.4", build: 13) == AppVersion(version: "0.4.0", build: 13))
        #expect(Set([AppVersion(version: "0.4", build: 13), AppVersion(version: "0.4.0", build: 13)]).count == 1)
        #expect(!(AppVersion(version: "0.4", build: 13) < AppVersion(version: "0.4.0", build: 13)))
        #expect(AppVersion(version: "1.0", build: "x") == nil)
        #expect(AppVersion(version: "1.0beta", build: "3") == nil)
        #expect(AppVersion(version: "", build: "3") == nil)
        #expect(AppVersion(version: "1.0", build: "0") == nil)
        #expect(AppVersion(infoDictionary: ["CFBundleShortVersionString": "0.4.0", "CFBundleVersion": "13"]) == beta7)
        #expect(AppVersion(infoDictionary: nil) == nil)
        #expect(beta7.description == "0.4.0 (13)")
    }

    // MARK: Aggregation

    private func release(_ version: String, _ build: Int, _ features: [WhatsNewFeature] = [], also: [String] = []) -> WhatsNewRelease {
        WhatsNewRelease(version: version, build: build, label: "\(version) (\(build))",
                        features: features.isEmpty && also.isEmpty ? [WhatsNewFeature(id: "f-\(build)", title: "F\(build)", text: "Text.")] : features, also: also)
    }

    private var sample: WhatsNewManifest {
        WhatsNewManifest(tour: [TourStep(anchor: .runButton, title: "Run", text: "Press Run.")], releases: [
            release("0.3.0", 6),
            release("0.4.0", 7),
            release("0.4.0", 12, [WhatsNewFeature(id: "plain", title: "Plain", text: "T."), WhatsNewFeature(id: "big", title: "Big", text: "T.", important: true)]),
            release("0.4.0", 13, also: ["Small thing."]),
            release("0.5.0", 20),
        ])
    }

    @Test func releasesSinceTheLastSeenNewestFirst() {
        let manifest = sample
        let beta7 = AppVersion(version: "0.4.0", build: 13)
        #expect(manifest.releases(after: AppVersion(version: "0.4.0", build: 12), through: beta7).map(\.build) == [13])
        // Skipped builds are aggregated, newest first; nothing newer than the running app.
        #expect(manifest.releases(after: AppVersion(version: "0.3.0", build: 6), through: beta7).map(\.build) == [13, 12, 7])
        #expect(manifest.releases(after: AppVersion(version: "0.2.2", build: 5), through: beta7).map(\.build) == [13, 12, 7, 6])
        // Already seen: nothing.
        #expect(manifest.releases(after: beta7, through: beta7).isEmpty)
        // Unknown baseline (a Runlet from before What's New): this version's builds.
        #expect(manifest.releases(after: nil, through: beta7).map(\.build) == [13, 12, 7])
        // A build between entries gets the ones up to it.
        #expect(manifest.releases(after: nil, through: AppVersion(version: "0.4.0", build: 10)).map(\.build) == [7])
    }

    @Test func sectionsGroupAVersionsBuildsAndFeatureImportantItems() {
        let sections = sample.sections(after: AppVersion(version: "0.2.0", build: 1), through: AppVersion(version: "0.5.0", build: 20))
        #expect(sections.map(\.version) == ["0.5.0", "0.4.0", "0.3.0"])
        let current = sections[1]
        #expect(current.releases.map(\.build) == [13, 12, 7])
        #expect(current.label == "0.4.0 (13)")
        // Important first, then the others, newest build first.
        #expect(current.features.map(\.id) == ["big", "plain", "f-7"])
        #expect(current.featured.map(\.id) == ["big"])
        #expect(current.regular.map(\.id) == ["plain", "f-7"])
        #expect(current.also == ["Small thing."])
        // At most three banners; the other important features lead the grid.
        let many = WhatsNewSection(releases: [release("1.0", 30, (1...5).map { WhatsNewFeature(id: "i\($0)", title: "I", text: "T.", important: true) }
            + [WhatsNewFeature(id: "n", title: "N", text: "T.")])])
        #expect(many.featured.map(\.id) == ["i1", "i2", "i3"])
        #expect(many.regular.map(\.id) == ["i4", "i5", "n"])
    }

    @Test func helpMenuShowsTheCurrentVersionsEntries() {
        let manifest = sample
        #expect(manifest.currentSections(for: AppVersion(version: "0.4.0", build: 13)).map { $0.releases.map(\.build) } == [[13, 12, 7]])
        #expect(manifest.currentSections(for: AppVersion(version: "0.4.0", build: 12)).map { $0.releases.map(\.build) } == [[12, 7]])
        // A development build older than every entry shows the newest version's.
        let ahead = WhatsNewManifest(releases: [release("0.4.0", 12), release("0.4.0", 13)])
        #expect(ahead.currentSections(for: AppVersion(version: "0.3.0", build: 6)).map { $0.releases.map(\.build) } == [[13, 12]])
        #expect(WhatsNewManifest().currentSections(for: AppVersion(version: "1.0", build: 1)).isEmpty)
    }

    @Test func coverageOfAVersion() {
        let manifest = sample
        #expect(manifest.hasEntry(for: AppVersion(version: "0.4.0", build: 13)))
        #expect(!manifest.hasEntry(for: AppVersion(version: "0.4.0", build: 14)))
        // Entries written ahead of the release commit cover the older version main still has.
        #expect(manifest.covers(AppVersion(version: "0.4.0", build: 14)))
        #expect(!manifest.covers(AppVersion(version: "0.5.0", build: 21)))
        #expect(manifest.covers(AppVersion(version: "0.5.0", build: 20)))
    }

    @Test func problemsAreReported() {
        var manifest = sample
        #expect(manifest.problems(commands: ["run.run"]).isEmpty)
        manifest.tour.append(TourStep(title: "Nowhere", text: "No anchor, menu, or keys."))
        manifest.tour.append(TourStep(anchor: nil, title: "Bad", text: "T.", command: "run.nope"))
        manifest.releases.append(release("0.4", 13))
        manifest.releases.append(WhatsNewRelease(version: "zero", build: 1, label: "Broken", features: [
            WhatsNewFeature(id: "Bad Id", title: "Bad", text: "T.", flag: "noSuchFlag",
                            tour: [TourStep(title: "S", text: "T.", menu: "View ▸ Logs")]),
            WhatsNewFeature(id: "big", title: "Again", text: "T."),
        ]))
        var step = TourStep(title: "Odd", text: "T.")
        step.anchor = "no-such-anchor"
        step.prepare = "inspector-commands"
        manifest.releases[0].features[0].tour = [step]
        let problems = manifest.problems(commands: ["run.run"])
        #expect(problems.contains("tour step 2 has no anchor, menu, command, or keys to show"))
        #expect(problems.contains("tour step 3 names unknown command run.nope"))
        #expect(problems.contains("0.4 (13) (0.4 build 13) is listed twice"))
        #expect(problems.contains("Broken (zero build 1): the version or build doesn't parse"))
        #expect(problems.contains("feature id Bad Id isn't lowercase words with dashes"))
        #expect(problems.contains("feature Bad Id names unknown feature flag noSuchFlag"))
        #expect(problems.contains("feature big is listed twice"))
        #expect(problems.contains("feature f-6 step 1 points at unknown anchor no-such-anchor"))
        // The Commands pane boots the application, so a step can never open it.
        #expect(problems.contains("feature f-6 step 1 has unknown preparation inspector-commands"))
        #expect(TourPreparation(rawValue: "inspector-commands") == nil)
    }

    // MARK: The bundled manifest

    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static func bundledManifest() throws -> WhatsNewManifest {
        try WhatsNewManifest.decode(Data(contentsOf: repository.appendingPathComponent("Runlet/WhatsNew.json")))
    }

    /// `project.yml`'s CFBundleShortVersionString and CFBundleVersion.
    static func projectVersion() throws -> AppVersion {
        let yml = try String(contentsOf: repository.appendingPathComponent("project.yml"), encoding: .utf8)
        func value(_ key: String) -> String? {
            yml.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + ":") }
                .map { $0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        let version = try #require(value("CFBundleShortVersionString"))
        let build = try #require(value("CFBundleVersion"))
        return try #require(AppVersion(version: version, build: build))
    }

    @Test func bundledManifestParsesWithoutProblems() throws {
        let manifest = try Self.bundledManifest()
        #expect(manifest.problems().isEmpty, "\(manifest.problems())")
        #expect(manifest.releases.allSatisfy { $0.appVersion.isValid })
        #expect(!manifest.tour.isEmpty && manifest.tour.count <= 10)
        #expect(manifest.changelog != nil)
    }

    @Test func everyAnchorTheManifestNamesExistsAndIsOnAView() throws {
        let manifest = try Self.bundledManifest()
        let known = Set(TourAnchor.allCases.map(\.rawValue))
        for id in manifest.anchorIds {
            #expect(known.contains(id), "unknown anchor \(id)")
        }
        // …and some view in the app marks itself with it.
        let sources = try Self.appSources()
        for anchor in TourAnchor.allCases where manifest.anchorIds.contains(anchor.rawValue) {
            let used = sources.contains(".tourAnchor(.\(anchor))")
            #expect(used, "no view uses .tourAnchor(.\(anchor))")
        }
    }

    @Test func everyCommandTheManifestNamesIsInTheCatalog() throws {
        let manifest = try Self.bundledManifest()
        let catalog = try String(contentsOf: Self.repository.appendingPathComponent("Runlet/App/Commands.swift"), encoding: .utf8)
        let steps = manifest.tour + manifest.releases.flatMap { $0.features.flatMap(\.tour) }
        for command in Set(steps.compactMap(\.command)) {
            #expect(catalog.contains("id: \"\(command)\""), "unknown command \(command)")
        }
    }

    @Test func currentVersionInProjectYmlHasAnEntry() throws {
        let manifest = try Self.bundledManifest()
        let version = try Self.projectVersion()
        // The release commit sets project.yml's version; main may still have the previous one
        // while the next release's entries are written. scripts/package.sh warns when the
        // packaged version has no entry of its own.
        #expect(manifest.covers(version), "no What's New entry for \(version): add one to Runlet/WhatsNew.json")
    }

    @Test func manifestCoversTheHighlightsOf040() throws {
        let manifest = try Self.bundledManifest()
        let ids = Set(manifest.releases.filter { $0.version == "0.4.0" }.flatMap { $0.features.map(\.id) })
        for id in ["database-connections", "database-tools", "sql-explain", "redis-mongodb-tabs", "builders", "connection-manager",
                   "queued-runs", "code-navigation", "tableplus-import", "snippet-api", "log-viewer", "dry-run", "source-excerpts", "move-lines"] {
            #expect(ids.contains(id), "0.4.0 has no \(id) entry")
        }
        // Each beta build has its own entry, from beta 1 (build 7) to beta 7 (build 13).
        #expect(Set(manifest.releases.filter { $0.version == "0.4.0" }.map(\.build)) == Set(7...13))
        // Important features have a Show Me tour; the TablePlus import says which flag it needs.
        for (feature, _) in manifest.releases.flatMap({ release in release.features.map { ($0, release) } }) where feature.important {
            #expect(!feature.tour.isEmpty, "\(feature.id) is important but has no Show Me tour")
        }
        #expect(manifest.feature("tableplus-import")?.feature.flag == FeatureFlag.tablePlusImport.id)
    }

    static func appSources() throws -> String {
        let root = repository.appendingPathComponent("Runlet")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    // MARK: When it appears

    private let beta6 = AppVersion(version: "0.4.0", build: 12)
    private let beta7 = AppVersion(version: "0.4.0", build: 13)

    @Test func aNewUserGetsTheTourOnceAndNoWhatsNew() {
        let state = OnboardingState.initial(existingFiles: [])
        #expect(state.isNewUser)
        let first = OnboardingPolicy.decide(state: state, current: beta7, manifest: sample, showTips: true, showWhatsNew: true)
        #expect(first.presentation == .tour)
        #expect(first.state.tour == .started)
        #expect(first.state.whatsNewSeen == beta7)
        // Started, then finished or skipped (or Runlet quit): it never comes back by itself.
        for status in [OnboardingState.TourStatus.started, .finished, .skipped] {
            var later = first.state
            later.tour = status
            #expect(OnboardingPolicy.decide(state: later, current: beta7, manifest: sample, showTips: true, showWhatsNew: true).presentation == .nothing)
        }
        // Tips off: nothing, and this version still counts as seen.
        let off = OnboardingPolicy.decide(state: state, current: beta7, manifest: sample, showTips: false, showWhatsNew: true)
        #expect(off.presentation == .nothing)
        #expect(off.state.whatsNewSeen == beta7 && off.state.tour == nil)
    }

    @Test func aNewUserGetsWhatsNewAfterTheirFirstUpdate() {
        var state = OnboardingState(isNewUser: true, tour: .finished, whatsNewSeen: beta6)
        let decision = OnboardingPolicy.decide(state: state, current: beta7, manifest: sample, showTips: true, showWhatsNew: true)
        #expect(decision.presentation == .whatsNew(since: beta6))
        #expect(decision.state.whatsNewSeen == beta7)
        state = decision.state
        #expect(OnboardingPolicy.decide(state: state, current: beta7, manifest: sample, showTips: true, showWhatsNew: true).presentation == .nothing)
    }

    @Test func someoneWhoUpdatesGetsWhatsNewOncePerVersionOrBuild() {
        // Data from a Runlet before What's New: everything in this version.
        let earlier = OnboardingState.initial(existingFiles: ["settings.json", "session.json"])
        #expect(!earlier.isNewUser)
        let first = OnboardingPolicy.decide(state: earlier, current: beta7, manifest: sample, showTips: true, showWhatsNew: true)
        #expect(first.presentation == .whatsNew(since: nil))
        #expect(first.state.whatsNewSeen == beta7)
        #expect(first.state.tour == nil)
        // Once per version or build.
        #expect(OnboardingPolicy.decide(state: first.state, current: beta7, manifest: sample, showTips: true, showWhatsNew: true).presentation == .nothing)
        // A newer build (a beta), however it was installed or relaunched.
        let next = AppVersion(version: "0.5.0", build: 20)
        #expect(OnboardingPolicy.decide(state: first.state, current: next, manifest: sample, showTips: true, showWhatsNew: true).presentation == .whatsNew(since: beta7))
        // An older build (going back) shows nothing and keeps the newer one as seen.
        let back = OnboardingPolicy.decide(state: first.state, current: beta6, manifest: sample, showTips: true, showWhatsNew: true)
        #expect(back.presentation == .nothing && back.state.whatsNewSeen == beta7)
    }

    @Test func settingOffOrNothingNewStillCountsAsSeen() {
        let state = OnboardingState(isNewUser: false, whatsNewSeen: beta6)
        let off = OnboardingPolicy.decide(state: state, current: beta7, manifest: sample, showTips: true, showWhatsNew: false)
        #expect(off.presentation == .nothing && off.state.whatsNewSeen == beta7)
        let empty = OnboardingPolicy.decide(state: state, current: beta7, manifest: WhatsNewManifest(), showTips: true, showWhatsNew: true)
        #expect(empty.presentation == .nothing && empty.state.whatsNewSeen == beta7)
    }

    // MARK: Never interrupts

    private func launch(_ environment: [String: String] = [:], arguments: [String] = ["/Applications/Runlet.app/Contents/MacOS/Runlet"], debug: Bool = false) -> OnboardingLaunch {
        OnboardingLaunch(arguments: arguments, environment: environment, isDebugBuild: debug)
    }

    @Test func anOrdinaryLaunchMayShowIt() {
        #expect(launch().blocker() == nil)
        #expect(launch(debug: true).blocker() == nil)
        // Opening files from Finder or `runlet` is an ordinary launch.
        #expect(launch(arguments: ["Runlet", "/tmp/a.php", "-NSDocumentRevisionsDebugMode", "YES"]).blocker() == nil)
    }

    @Test func selfTestAndPackagingNeverShowIt() {
        // scripts/package.sh runs the packaged app's --self-test with a scratch data folder.
        #expect(launch(arguments: ["Runlet", "--self-test"]).blocker() == .selfTest)
        #expect(launch(["RUNLET_DATA_DIR": "/tmp/selftest"], arguments: ["Runlet", "--self-test", "--docker"]).blocker() == .selfTest)
    }

    @Test func runletMCPNeverShowsIt() {
        #expect(launch(arguments: ["Runlet", OnboardingLaunch.mcpArgument]).blocker() == .mcpLaunch)
        // `runlet mcp` passes the argument when it starts Runlet.
        let mcp = try? String(contentsOf: Self.repository.appendingPathComponent("RunletCLI/MCPCommand.swift"), encoding: .utf8)
        #expect(mcp?.contains("OnboardingLaunch.mcpArgument") == true)
    }

    @Test func scratchDataNeverShowsItUnlessADebugStepAsks() {
        let scratch = ["RUNLET_DATA_DIR": "/tmp/runlet-scratch"]
        #expect(launch(scratch, debug: true).blocker() == .scratchData)
        #expect(launch(scratch, debug: false).blocker() == .scratchData)
        // `onboarding:auto` lifts only this rule, and only in Debug builds.
        #expect(launch(scratch, debug: true).blocker(debugAllowsAutomatic: true) == nil)
        #expect(launch(scratch, debug: false).blocker(debugAllowsAutomatic: true) == .scratchData)
        #expect(launch(scratch, arguments: ["Runlet", "--self-test"], debug: true).blocker(debugAllowsAutomatic: true) == .selfTest)
        // An empty value is no scratch folder.
        #expect(launch(["RUNLET_DATA_DIR": ""]).blocker() == nil)
        // DEBUG steps that ask for it, so it can be snapshotted.
        #expect(launch(scratch.merging(["RUNLET_DEBUG_STEPS": "ghost, tour:start,snapshot"]) { $1 }, debug: true).debugStepsAskForIt)
        #expect(launch(scratch.merging(["RUNLET_DEBUG_STEPS": "whats-new:show"]) { $1 }, debug: true).debugStepsAskForIt)
        #expect(!launch(scratch.merging(["RUNLET_DEBUG_STEPS": "ghost,snapshot,touring"]) { $1 }, debug: true).debugStepsAskForIt)
        #expect(!launch(scratch.merging(["RUNLET_DEBUG_STEPS": "tour:start"]) { $1 }, debug: false).debugStepsAskForIt)
    }

    @Test func uiTestsNeverShowIt() throws {
        #expect(launch(["RUNLET_UI_TESTS": "1"]).blocker() == .uiTest)
        #expect(launch(["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]).blocker() == .uiTest)
        // Every UI test launches Runlet with a scratch data folder, which blocks it on its own.
        let folder = Self.repository.appendingPathComponent("RunletUITests")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let launches = text.components(separatedBy: "XCUIApplication(").count - 1
            let scratch = text.components(separatedBy: "launchEnvironment[\"RUNLET_DATA_DIR\"]").count - 1
            #expect(launches <= scratch, "\(file.lastPathComponent) launches Runlet without a scratch RUNLET_DATA_DIR")
        }
    }

    @Test func itWaitsWhileARunOrSheetIsUpOrTheUserTypes() {
        #expect(OnboardingActivity().waitReason == nil)
        #expect(OnboardingActivity(runInProgress: true).waitReason == "a run is in progress")
        #expect(OnboardingActivity(sheetOpen: true).waitReason == "a sheet or alert is open")
        #expect(OnboardingActivity(typedRecently: true).waitReason == "the user is typing")
        #expect(OnboardingActivity(isActive: false).waitReason == "Runlet isn't the active app")
        #expect(OnboardingActivity(hasMainWindow: false).waitReason == "no main window is on screen")
    }

    // MARK: Saved state and settings

    @Test func stateRoundTripsAndToleratesOldFiles() throws {
        let state = OnboardingState(isNewUser: false, tour: .skipped, whatsNewSeen: beta7)
        let decoded = try JSONDecoder().decode(OnboardingState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
        let partial = try JSONDecoder().decode(OnboardingState.self, from: Data(#"{"tour":"finished","whatsNewSeen":{"version":"0.4.0","build":"x"}}"#.utf8))
        #expect(partial == OnboardingState(isNewUser: false, tour: .finished, whatsNewSeen: nil))
        #expect(AppPaths(root: URL(fileURLWithPath: "/tmp/r")).onboarding.path == "/tmp/r/State/onboarding.json")
    }

    @Test func tipsSettingsDefaultOnAndLoadFromOlderFiles() throws {
        let fresh = AppSettings()
        #expect(fresh.showWhatsNewAfterUpdates && fresh.showTipsOnFirstLaunch)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"fontSize":14}"#.utf8))
        #expect(old.showWhatsNewAfterUpdates && old.showTipsOnFirstLaunch)
        var changed = AppSettings()
        changed.showWhatsNewAfterUpdates = false
        changed.showTipsOnFirstLaunch = false
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(changed))
        #expect(!back.showWhatsNewAfterUpdates && !back.showTipsOnFirstLaunch)
    }
}
