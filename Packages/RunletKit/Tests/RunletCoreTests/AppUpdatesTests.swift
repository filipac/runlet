import Foundation
import Testing
@testable import RunletCore

/// In-app updates (#233): version ordering, channels, which update is offered, when automatic
/// checks run, install locations, and the watchdog's install, launch, and rollback decisions.
struct AppUpdatesTests {
    private func v(_ text: String, _ build: String) -> RunletVersion {
        RunletVersion(text, build: build)!
    }

    // MARK: Versions

    @Test func parsesTagsAndInfoPlists() {
        let beta = v("v0.4.0-beta.6", "12")
        #expect(beta.major == 0 && beta.minor == 4 && beta.patch == 0)
        #expect(beta.prerelease == ["beta", "6"])
        #expect(beta.isPrerelease)
        #expect(beta.semanticVersion == "0.4.0-beta.6")
        #expect(beta.displayName == "0.4.0 beta 6")
        #expect(beta.description == "0.4.0 beta 6 (12)")
        #expect(v("0.3", "6").semanticVersion == "0.3.0")
        #expect(v("1.2.3+sha.abc", "7").semanticVersion == "1.2.3")
        #expect(v("1.0.0-rc.1.x", "7").displayName == "1.0.0-rc.1.x")
        // CFBundleShortVersionString plus RunletPrerelease, as a pre-release build has them.
        let info = RunletVersion.fromInfoDictionary(["CFBundleShortVersionString": "0.4.0", "RunletPrerelease": "beta.7", "CFBundleVersion": "13"])
        #expect(info?.semanticVersion == "0.4.0-beta.7")
        #expect(info?.build == "13")
        let release = RunletVersion.fromInfoDictionary(["CFBundleShortVersionString": "0.4.0", "RunletPrerelease": "", "CFBundleVersion": "14"])
        #expect(release?.isPrerelease == false)
        #expect(RunletVersion.fromInfoDictionary(["CFBundleShortVersionString": "0.4.0"]) == nil)
        for bad in ["", "x.y", "1.2.3.4", "1..2", "1.2.3-", "1.2.3-beta..1", "-1.0.0", "1.2.3-bé"] {
            #expect(RunletVersion(bad, build: "1") == nil, "\(bad)")
        }
        #expect(RunletVersion("1.0.0", build: " ") == nil)
    }

    @Test func betasSortBeforeTheirReleaseAndBuildsBreakTies() {
        #expect(v("0.4.0-beta.6", "12") < v("0.4.0", "13"))
        // The semantic version decides before the build: a release beats a later-built beta of it.
        #expect(v("0.4.0-beta.9", "20") < v("0.4.0", "13"))
        #expect(v("0.4.0", "13") < v("0.4.1-beta.1", "14"))
        #expect(v("0.4.0-beta.2", "8") < v("0.4.0-beta.10", "9"))
        #expect(v("0.4.0-alpha.3", "1") < v("0.4.0-beta.1", "1"))
        #expect(v("0.4.0-beta", "1") < v("0.4.0-beta.1", "1"))
        #expect(v("0.4.0-1", "1") < v("0.4.0-beta", "1"))
        #expect(v("0.3.0", "6") < v("0.10.0", "1"))
        // Same version: the build number, numerically.
        #expect(v("0.4.0", "9") < v("0.4.0", "12"))
        #expect(v("0.4.0", "1.9") < v("0.4.0", "1.10"))
        #expect(v("0.4.0", "12") == v("0.4.0", "12"))
        #expect(v("v0.4.0", "12") == v("0.4.0", " 12"))
        #expect(!(v("0.4.0-beta.6", "12") < v("0.4.0-beta.6", "12")))
        let sorted = [v("0.4.0", "13"), v("0.3.0", "6"), v("0.4.0-beta.1", "7"), v("0.4.0-beta.6", "12"), v("0.4.1-beta.1", "14")].sorted()
        #expect(sorted.map(\.semanticVersion) == ["0.3.0", "0.4.0-beta.1", "0.4.0-beta.6", "0.4.0", "0.4.1-beta.1"])
    }

    // MARK: Channels and selection

    @Test func defaultChannelFollowsTheRunningBuild() {
        #expect(UpdateChannel.default(for: v("0.4.0-beta.6", "12")) == .beta)
        #expect(UpdateChannel.default(for: v("0.3.0", "6")) == .stable)
        #expect(UpdateChannel.default(for: nil) == .stable)
        #expect(UpdateChannel.stable.appcastChannels.isEmpty)
        #expect(UpdateChannel.beta.appcastChannels == ["beta"])
    }

    private var feed: [UpdateCandidate] {
        [
            UpdateCandidate(version: v("0.3.0", "6"), channel: nil),
            UpdateCandidate(version: v("0.4.0-beta.5", "11"), channel: "beta"),
            UpdateCandidate(version: v("0.4.0-beta.6", "12"), channel: "beta"),
        ]
    }

    @Test func stableOffersReleasesOnly() {
        // On 0.3.0 with only betas newer: up to date.
        #expect(UpdateSelection.best(feed, channel: .stable, running: v("0.3.0", "6")) == nil)
        // An older stable is offered the newest release.
        #expect(UpdateSelection.best(feed, channel: .stable, running: v("0.2.2", "5"))?.version == v("0.3.0", "6"))
        // A beta listed without its channel tag still never reaches Stable.
        let untagged = feed + [UpdateCandidate(version: v("0.5.0-beta.1", "20"), channel: nil)]
        #expect(UpdateSelection.best(untagged, channel: .stable, running: v("0.3.0", "6")) == nil)
    }

    @Test func betaOffersNewerBetasThenTheRelease() {
        #expect(UpdateSelection.best(feed, channel: .beta, running: v("0.3.0", "6"))?.version == v("0.4.0-beta.6", "12"))
        #expect(UpdateSelection.best(feed, channel: .beta, running: v("0.4.0-beta.5", "11"))?.version == v("0.4.0-beta.6", "12"))
        // On the latest beta: nothing.
        #expect(UpdateSelection.best(feed, channel: .beta, running: v("0.4.0-beta.6", "12")) == nil)
        // The release that supersedes the beta.
        let released = feed + [UpdateCandidate(version: v("0.4.0", "13"), channel: nil)]
        #expect(UpdateSelection.best(released, channel: .beta, running: v("0.4.0-beta.6", "12"))?.version == v("0.4.0", "13"))
        // Switching a beta build to Stable never offers an older release (no downgrades).
        #expect(UpdateSelection.best(feed, channel: .stable, running: v("0.4.0-beta.6", "12")) == nil)
        #expect(UpdateSelection.best(released, channel: .stable, running: v("0.4.0-beta.6", "12"))?.version == v("0.4.0", "13"))
    }

    @Test func skippedVersionIsNotOffered() {
        let skipped = v("0.4.0-beta.6", "12")
        #expect(UpdateSelection.best(feed, channel: .beta, running: v("0.4.0-beta.5", "11"), skipped: skipped) == nil)
        // Something newer than the skipped version still is.
        let newer = feed + [UpdateCandidate(version: v("0.4.0-beta.7", "13"), channel: "beta")]
        #expect(UpdateSelection.best(newer, channel: .beta, running: v("0.4.0-beta.5", "11"), skipped: skipped)?.version == v("0.4.0-beta.7", "13"))
        #expect(UpdateSelection.best([], channel: .beta, running: v("0.4.0-beta.5", "11")) == nil)
    }

    // MARK: When checks run

    @Test func automaticChecksAreSilentWhereTheyMustBe() {
        func blocker(_ launch: UpdateCheckPolicy.Launch, enabled: Bool = true, active: Bool = true) -> String? {
            UpdateCheckPolicy(launch: launch).automaticCheckBlocker(enabled: enabled, everActive: active)
        }
        let release = UpdateCheckPolicy.Launch(isDebugBuild: false)
        #expect(blocker(release) == nil)
        #expect(blocker(release, enabled: false) == "automatic checks are off")
        #expect(blocker(UpdateCheckPolicy.Launch(isDebugBuild: false, isSelfTest: true)) == "self-test")
        // `runlet mcp` started it in the background: no check until the user brings it forward.
        let mcp = UpdateCheckPolicy.Launch(isDebugBuild: false, launchedByMCP: true)
        #expect(blocker(mcp, active: false) == "started by runlet mcp")
        #expect(blocker(mcp, active: true) == nil)
        // Debug builds (UI tests, Xcode runs) and scripted screenshot sessions never check on their own.
        #expect(blocker(UpdateCheckPolicy.Launch(isDebugBuild: true)) == "Debug build")
        #expect(blocker(UpdateCheckPolicy.Launch(isDebugBuild: true, isScripted: true)) == "scripted Debug session")
        #expect(blocker(UpdateCheckPolicy.Launch(isDebugBuild: true, forceAutomaticChecks: true)) == nil)
        #expect(blocker(UpdateCheckPolicy.Launch(isDebugBuild: true, forceAutomaticChecks: true, isSelfTest: true)) == "self-test")
    }

    @Test func launchContextFromArgumentsAndEnvironment() {
        let plain = UpdateCheckPolicy.Launch.current(arguments: ["Runlet"], environment: [:], isDebugBuild: false)
        #expect(plain == UpdateCheckPolicy.Launch(isDebugBuild: false))
        let mcp = UpdateCheckPolicy.Launch.current(arguments: ["Runlet", "--launched-by-mcp"], environment: ["RUNLET_UPDATE_AUTOMATIC": "1"], isDebugBuild: false)
        #expect(mcp.launchedByMCP)
        #expect(!mcp.forceAutomaticChecks) // Release builds ignore the test switch.
        let scripted = UpdateCheckPolicy.Launch.current(arguments: ["Runlet"], environment: ["RUNLET_DEBUG_STEPS": "snapshot", "RUNLET_UPDATE_AUTOMATIC": "1"], isDebugBuild: true)
        #expect(scripted.isScripted && scripted.forceAutomaticChecks)
        #expect(UpdateCheckPolicy.Launch.current(arguments: ["Runlet", "--self-test"], environment: [:], isDebugBuild: false).isSelfTest)
    }

    @Test func checksAtLaunchThenOnceADayAndNeverOfferDuringRuns() {
        let now = Date()
        #expect(UpdateCheckPolicy.isDue(lastCheck: nil, now: now))
        #expect(!UpdateCheckPolicy.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        #expect(UpdateCheckPolicy.isDue(lastCheck: now.addingTimeInterval(-UpdateCheckPolicy.interval), now: now))
        #expect(!UpdateCheckPolicy.mayPresent(userInitiated: false, runInProgress: true))
        #expect(UpdateCheckPolicy.mayPresent(userInitiated: false, runInProgress: false))
        #expect(UpdateCheckPolicy.mayPresent(userInitiated: true, runInProgress: true))
    }

    @Test func settingsKeepChannelAndAutomaticChecks() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(old.updateChannel == nil)
        #expect(old.automaticUpdateChecks)
        var settings = AppSettings()
        settings.updateChannel = .beta
        settings.automaticUpdateChecks = false
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.updateChannel == .beta)
        #expect(!decoded.automaticUpdateChecks)
        let unknown = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"updateChannel":"nightly"}"#.utf8))
        #expect(unknown.updateChannel == nil)
    }

    // MARK: Install location

    @Test func installLocationOrder() {
        func probe(translocated: Bool = false, readOnly: Bool = false, writable: Set<String> = ["/Applications", "/Applications/Runlet.app"]) -> UpdateInstallLocation.Probe {
            UpdateInstallLocation.Probe(isTranslocated: { _ in translocated }, isOnReadOnlyVolume: { _ in readOnly }, isWritable: { writable.contains($0) })
        }
        let app = "/Applications/Runlet.app"
        #expect(UpdateInstallLocation.check(bundlePath: app, probe: probe()) == .ready)
        #expect(UpdateInstallLocation.check(bundlePath: app, probe: probe(writable: [])) == .needsAdministrator(folder: "/Applications"))
        #expect(UpdateInstallLocation.check(bundlePath: app, probe: probe(writable: ["/Applications"])) == .needsAdministrator(folder: "/Applications"))
        #expect(UpdateInstallLocation.check(bundlePath: "/Volumes/Runlet/Runlet.app", probe: probe(readOnly: true)) == .readOnlyVolume(path: "/Volumes/Runlet/Runlet.app"))
        #expect(UpdateInstallLocation.check(bundlePath: app, probe: probe(translocated: true, readOnly: true)) == .translocated)
        #expect(UpdateInstallLocation.translocated.mustMove)
        #expect(UpdateInstallLocation.readOnlyVolume(path: app).mustMove)
        #expect(!UpdateInstallLocation.needsAdministrator(folder: "/Applications").mustMove)
        #expect(UpdateInstallLocation.isTranslocated("/private/var/folders/xy/T/AppTranslocation/1234/d/Runlet.app"))
    }

    @Test func liveInstallLocationChecks() throws {
        let root = try temporaryDirectory()
        defer { unlock(root); try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Apps")
        let app = try makeApp(in: folder, build: "20")
        #expect(!UpdateInstallLocation.isTranslocated(app.path))
        #expect(UpdateInstallLocation.check(bundlePath: app.path) == .ready)
        // A folder the user can't write to, as /Applications owned by an administrator.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        #expect(UpdateInstallLocation.check(bundlePath: app.path) == .needsAdministrator(folder: folder.path))
    }

    // MARK: Watchdog

    @Test func watchdogStartsTheNewVersionAndRemovesTheBackup() throws {
        let fixture = try WatchdogFixture(launcherWritesMarker: true)
        defer { fixture.remove() }
        try fixture.install(build: "21", quarantined: true)
        try fixture.run()
        #expect(fixture.result == UpdateResult(outcome: .updated, build: "21", detail: ""))
        #expect(!FileManager.default.fileExists(atPath: fixture.backup.path))
        #expect(fixture.build(at: fixture.app) == "21")
        #expect(fixture.launches == ["21"])
        // The quarantine attribute went before the new version was started.
        #expect(!fixture.isQuarantined(fixture.app))
        #expect(fixture.launchedQuarantined == ["no"])
    }

    @Test func watchdogRestoresTheBackupWhenTheNewVersionDoesNotStart() throws {
        let fixture = try WatchdogFixture(launcherWritesMarker: false)
        defer { fixture.remove() }
        try fixture.install(build: "21")
        try fixture.run()
        #expect(fixture.result?.outcome == .rolledBack)
        #expect(fixture.result?.detail == "The new version didn't start within 2 seconds.")
        #expect(fixture.build(at: fixture.app) == "20")
        #expect(fixture.build(at: fixture.files.failed) == "21")
        #expect(!FileManager.default.fileExists(atPath: fixture.backup.path))
        // The new version, then the restored one.
        #expect(fixture.launches == ["21", "20"])
    }

    @Test func watchdogRestoresTheBackupForAnotherApp() throws {
        let fixture = try WatchdogFixture(launcherWritesMarker: true)
        defer { fixture.remove() }
        try fixture.install(build: "21", identifier: "com.example.Other")
        try fixture.run()
        #expect(fixture.result?.outcome == .rolledBack)
        #expect(fixture.result?.detail == "The new version has another bundle identifier.")
        #expect(fixture.build(at: fixture.app) == "20")
        #expect(fixture.launches == ["20"])
    }

    @Test func watchdogStartsTheOldVersionWhenNothingWasInstalled() throws {
        let fixture = try WatchdogFixture(launcherWritesMarker: true)
        defer { fixture.remove() }
        try fixture.run()
        #expect(fixture.result?.outcome == .notInstalled)
        #expect(fixture.build(at: fixture.app) == "20")
        #expect(!FileManager.default.fileExists(atPath: fixture.backup.path))
        #expect(fixture.launches == ["20"])
    }

    @Test func watchdogWaitsForRunletToQuit() throws {
        let fixture = try WatchdogFixture(launcherWritesMarker: true)
        defer { fixture.remove() }
        // Stand-in for Runlet: quits after a second, and the installer swaps the bundle after it.
        let runlet = Process()
        runlet.executableURL = URL(fileURLWithPath: "/bin/sh")
        runlet.arguments = try ["-c", "sleep 1; /bin/cp \"$0\" \"$1\"", fixture.newInfoPlist(build: "21").path, fixture.app.appendingPathComponent("Contents/Info.plist").path]
        try runlet.run()
        let started = Date()
        try fixture.run(pid: runlet.processIdentifier)
        #expect(Date().timeIntervalSince(started) >= 1)
        #expect(fixture.result?.outcome == .updated)
        #expect(fixture.launches == ["21"])
    }

    @Test func watchdogArgumentsCarryValuesOutsideTheScript() {
        let plan = UpdateWatchdog.Plan(appPath: "/A/Runlet.app", backupPath: "/S/Backup/Runlet.backup", stateDirectory: "/S", processIdentifier: 42,
                                       bundleIdentifier: "dev.runlet.Runlet", build: "21",
                                       launcherArguments: ["-n"] + UpdateWatchdog.environmentArguments(["RUNLET_DATA_DIR": "/tmp/x y", "A": "1"]))
        let arguments = UpdateWatchdog.arguments(plan)
        #expect(arguments.prefix(3) == ["-c", UpdateWatchdog.script, "runlet-update-watchdog"])
        #expect(Array(arguments.dropFirst(3)) == ["/A/Runlet.app", "/S/Backup/Runlet.backup", "/S", "42", "dev.runlet.Runlet", "21", "120", "60", "/usr/bin/open",
                                                  "-n", "--env", "A=1", "--env", "RUNLET_DATA_DIR=/tmp/x y"])
        #expect(!UpdateWatchdog.script.contains("/A/Runlet.app"))
    }

    @Test func launchedMarkerHasBuildThenProcess() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = UpdateFiles(directory: root.appendingPathComponent("Updates"))
        try UpdateWatchdog.writeLaunchedMarker(files, build: "21", processIdentifier: 99)
        #expect(try String(contentsOf: files.launchedMarker, encoding: .utf8) == "21\n99\n")
        let record = UpdateRecord(from: v("0.4.0-beta.6", "12"), to: v("0.4.0", "13"), date: Date(timeIntervalSince1970: 0))
        #expect(record.fromVersion == "0.4.0 beta 6" && record.toBuild == "13")
        #expect(try JSONDecoder().decode(UpdateRecord.self, from: JSONEncoder().encode(record)) == record)
    }

    @Test func detachedProcessAndBackup() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("out")
        let pid = try DetachedProcess.spawn("/bin/sh", arguments: ["-c", "echo \"$GREETING $$\" > \"$0\"", output.path], environment: ["GREETING": "hello"])
        #expect(pid > 0)
        let deadline = Date().addingTimeInterval(5)
        while (try? String(contentsOf: output, encoding: .utf8)) == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        #expect(try String(contentsOf: output, encoding: .utf8) == "hello \(pid)\n")
        // Its own session: not in the test's process group.
        #expect(getpgid(pid) == -1 || getpgid(pid) == pid)

        let app = try makeApp(in: root.appendingPathComponent("Apps"), build: "20")
        let backup = root.appendingPathComponent("Updates/Backup/Runlet.backup")
        try UpdateBackup.make(of: app, at: backup)
        try UpdateBackup.make(of: app, at: backup) // replaces an old backup
        #expect(FileManager.default.contentsEqual(atPath: app.appendingPathComponent("Contents/Info.plist").path, andPath: backup.appendingPathComponent("Contents/Info.plist").path))
    }
}

// MARK: - Helpers

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-updates-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

private func unlock(_ root: URL) {
    guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
    for case let url as URL in items {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

private func infoPlist(build: String, identifier: String) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundleVersion": build, "CFBundleShortVersionString": "0.5.0", "CFBundleExecutable": "Runlet"],
                                       format: .xml, options: 0)
}

@discardableResult
private func makeApp(in folder: URL, build: String, identifier: String = "dev.runlet.Runlet.test") throws -> URL {
    let app = folder.appendingPathComponent("Runlet.app", isDirectory: true)
    let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try infoPlist(build: build, identifier: identifier).write(to: app.appendingPathComponent("Contents/Info.plist"))
    try Data("#!/bin/sh\n".utf8).write(to: macOS.appendingPathComponent("Runlet"))
    return app
}

/// An installed app (build 20), its backup, and a fake launcher that records which build it
/// started and (optionally) writes the "launched" marker as a starting Runlet would.
private struct WatchdogFixture {
    let root: URL
    let app: URL
    let files: UpdateFiles
    let launcher: URL
    let launchLog: URL

    var backup: URL { files.backup }

    init(launcherWritesMarker: Bool) throws {
        root = try temporaryDirectory()
        app = try makeApp(in: root.appendingPathComponent("Apps"), build: "20")
        files = UpdateFiles(directory: root.appendingPathComponent("Data/Updates", isDirectory: true))
        try UpdateBackup.make(of: app, at: files.backup)
        launchLog = root.appendingPathComponent("launches")
        launcher = root.appendingPathComponent("fake-open")
        let marker = launcherWritesMarker ? "printf '%s\\n%s\\n' \"$build\" 4242 > \"$STATE_DIR/launched\"" : ":"
        let script = """
        #!/bin/sh
        app="$2"
        build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
        if /usr/bin/xattr "$app" 2>/dev/null | /usr/bin/grep -q com.apple.quarantine; then q=yes; else q=no; fi
        printf '%s %s\\n' "$build" "$q" >> "\(launchLog.path)"
        STATE_DIR="\(files.directory.path)"
        [ "$build" = 21 ] && \(marker)
        exit 0
        """
        try Data(script.utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
    }

    func newInfoPlist(build: String, identifier: String = "dev.runlet.Runlet.test") throws -> URL {
        let url = root.appendingPathComponent("Info-\(build).plist")
        try infoPlist(build: build, identifier: identifier).write(to: url)
        return url
    }

    /// What Sparkle's installer does: the new bundle in place of the old one.
    func install(build: String, identifier: String = "dev.runlet.Runlet.test", quarantined: Bool = false) throws {
        try FileManager.default.removeItem(at: app)
        try makeApp(in: app.deletingLastPathComponent(), build: build, identifier: identifier)
        if quarantined {
            let value = "0083;00000000;Safari;"
            _ = value.withCString { setxattr(app.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        }
    }

    /// Runs the watchdog to its end (Runlet already quit unless `pid` is given).
    func run(pid: Int32 = 999_999) throws {
        let plan = UpdateWatchdog.Plan(appPath: app.path, backupPath: backup.path, stateDirectory: files.directory.path, processIdentifier: pid,
                                       bundleIdentifier: "dev.runlet.Runlet.test", build: "21", installTimeout: 3, launchTimeout: 2,
                                       launcher: launcher.path, launcherArguments: ["-n"])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = UpdateWatchdog.arguments(plan)
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    var result: UpdateResult? {
        (try? Data(contentsOf: files.result)).flatMap { try? JSONDecoder().decode(UpdateResult.self, from: $0) }
    }

    private var launchLines: [[Substring]] {
        ((try? String(contentsOf: launchLog, encoding: .utf8)) ?? "").split(separator: "\n").map { $0.split(separator: " ") }
    }

    /// The builds the launcher started, in order.
    var launches: [String] { launchLines.map { String($0[0]) } }
    var launchedQuarantined: [String] { launchLines.map { String($0[1]) } }

    func build(at bundle: URL) -> String? {
        let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        let plist = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        return plist?["CFBundleVersion"] as? String
    }

    func isQuarantined(_ bundle: URL) -> Bool {
        getxattr(bundle.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
