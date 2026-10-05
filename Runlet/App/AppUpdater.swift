import AppKit
import RunletCore
import Sparkle

/// In-app updates (#233). Sparkle 2 checks the appcast, downloads the archive, verifies its EdDSA
/// signature (and the feed's), extracts it, releases it from quarantine, and swaps the bundle.
/// Runlet supplies the rest: which update to offer (`UpdateSelection`), when to check
/// (`UpdateCheckPolicy`), its own update window (this class is Sparkle's user driver), a backup of
/// the running version, and the watchdog (`UpdateWatchdog`) that starts the new version after the
/// swap and puts the backup back if it doesn't start.
///
/// Install and Relaunch: once Sparkle has the update extracted and its installer waiting, Runlet
/// copies itself to `Updates/Backup`, writes `Updates/pending.json`, starts the watchdog, answers
/// Sparkle "later" (its installer then installs when Runlet quits, without relaunching), and
/// quits. The watchdog relaunches, so the new version gets the same `RUNLET_DATA_DIR`.
@MainActor
@Observable
final class AppUpdater: NSObject {
    /// An update the feed offers, as the window shows it.
    struct Offer: Equatable {
        var version: RunletVersion
        /// The release notes: Markdown (`sparkle:format="markdown"`), plain text, or HTML.
        var notes: String
        var notesFormat: String
        var size: UInt64?
        var date: Date?
        /// The release's page on GitHub (the item's `<link>`).
        var releasePage: URL?
        var userInitiated: Bool
        /// Sparkle already has it downloaded (an earlier session stopped before installing).
        var isDownloaded: Bool
    }

    enum Problem: Equatable {
        /// No update key in this build (`RUNLET_UPDATE_PUBLIC_KEY` was empty).
        case notConfigured
        /// Runlet runs from a disk image or a translocated copy.
        case mustMove(UpdateInstallLocation)
        /// The feed couldn't be read (offline, missing, or not signed with Runlet's key).
        case couldNotCheck(detail: String)
        /// Download, verification, or installation failed; nothing was installed.
        case failed(title: String, detail: String)
        /// What the watchdog reported after the last Install and Relaunch, shown by the version
        /// that runs now.
        case afterUpdate(UpdateResult, record: UpdateRecord?)
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case found(Offer)
        case downloading(Offer, received: UInt64, expected: UInt64?)
        case extracting(Offer, progress: Double)
        /// Downloaded and verified; waiting for runs to end before quitting.
        case readyToInstall(Offer)
        /// Quitting so the installer can replace the app.
        case installing(Offer)
        case problem(Problem)
    }

    private(set) var phase: Phase = .idle
    /// The running version (Info.plist), nil only in a broken bundle.
    let running: RunletVersion?
    /// Whether this build has an update key (`SUPublicEDKey`, 32 bytes of base64).
    let isConfigured: Bool
    /// When the last check finished, and what it found (Settings ▸ General ▸ Updates).
    private(set) var lastCheck: Date?
    private(set) var lastCheckSummary: String?
    /// The update this version was installed by, read from `pending.json` at launch: the start
    /// of #232's What's New.
    private(set) var installedUpdate: UpdateRecord?
    /// Where Runlet runs, checked before each check.
    private(set) var installLocation: UpdateInstallLocation = .ready

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var policy = UpdateCheckPolicy(launch: .current(isDebugBuild: AppUpdater.isDebugBuild))
    @ObservationIgnored private var everActive = false
    @ObservationIgnored private var lastAutomaticCheck: Date?
    @ObservationIgnored private var scheduleTimer: Timer?
    @ObservationIgnored private var deferTimer: Timer?
    @ObservationIgnored private var currentCheckIsUserInitiated = false
    @ObservationIgnored private var foundReply: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var installReply: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var cancelCheck: (() -> Void)?
    @ObservationIgnored private var cancelDownload: (() -> Void)?
    /// Install and Relaunch was chosen for the offer being downloaded.
    @ObservationIgnored private var installChosen = false

    static let isDebugBuild: Bool = {
        #if DEBUG
        true
        #else
        false
        #endif
    }()

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        running = RunletVersion.fromInfoDictionary(info)
        isConfigured = Self.isValidPublicKey(info["SUPublicEDKey"] as? String)
        super.init()
    }

    static func isValidPublicKey(_ key: String?) -> Bool {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty, !key.hasPrefix("$(") else { return false }
        return Data(base64Encoded: key)?.count == 32
    }

    var channel: UpdateChannel {
        model?.settings.updateChannel ?? UpdateChannel.default(for: running)
    }

    var defaultChannel: UpdateChannel { UpdateChannel.default(for: running) }

    private var files: UpdateFiles? {
        model.map { UpdateFiles(directory: $0.paths.updates) }
    }

    /// Whether code runs in any tab: an update is never offered then, and Install waits.
    var isRunInProgress: Bool {
        // #25: a Quick Run panel's run counts too.
        model?.allTabsWithQuickRun.contains { $0.isRunning } ?? false
    }

    /// Why automatic checks don't run in this session, if they don't.
    var automaticCheckBlocker: String? {
        policy.automaticCheckBlocker(enabled: model?.settings.automaticUpdateChecks ?? false, everActive: everActive)
    }

    // MARK: Launch

    /// At launch: the "launched" marker for the watchdog, what the last update left, and the
    /// automatic checks.
    func start(model: AppModel) {
        self.model = model
        guard !policy.launch.isSelfTest, let files else { return }
        if let running {
            try? UpdateWatchdog.writeLaunchedMarker(files, build: running.build)
        }
        readLastUpdate(files)
        everActive = NSApp.isActive
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.everActive = true
                self?.checkAutomaticallyIfDue()
            }
        }
        // At launch (once the window is up), then hourly ticks that check once a day.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkAutomaticallyIfDue() }
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAutomaticallyIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
    }

    /// `pending.json` from the version that quit to install: this is the new version (#232's
    /// What's New starts here), or the old one again after the watchdog put it back.
    private func readLastUpdate(_ files: UpdateFiles) {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: files.pending) else { return }
        try? fm.removeItem(at: files.pending)
        guard let record = try? JSONDecoder().decode(UpdateRecord.self, from: data), let running else { return }
        if RunletVersion.compareBuilds(record.toBuild, running.build) == .orderedSame {
            installedUpdate = record
            lastCheckSummary = "Updated from \(record.fromVersion)"
            didLaunchAfterUpdate(record)
        } else if let resultData = try? Data(contentsOf: files.result), let result = try? JSONDecoder().decode(UpdateResult.self, from: resultData), result.outcome != .updated {
            try? fm.removeItem(at: files.result)
            phase = .problem(.afterUpdate(result, record: record))
            showWindow()
        }
    }

    /// The first launch of a version Install and Relaunch installed. #232 (What's New, not built
    /// yet) presents its window from here, with `record.fromVersion` → `record.toVersion`.
    private func didLaunchAfterUpdate(_ record: UpdateRecord) {
        #if DEBUG
        FileHandle.standardError.write(Data("RUNLET_UPDATE: launched after updating from \(record.fromVersion) (\(record.fromBuild)) to \(record.toVersion) (\(record.toBuild))\n".utf8))
        #endif
    }

    private func checkAutomaticallyIfDue() {
        guard automaticCheckBlocker == nil, UpdateCheckPolicy.isDue(lastCheck: lastAutomaticCheck, now: Date()) else { return }
        switch phase {
        case .idle, .upToDate, .problem(.couldNotCheck): break
        default: return
        }
        lastAutomaticCheck = Date()
        check(userInitiated: false)
    }

    // MARK: Checking

    /// Runlet ▸ Check for Updates…, Open Anything, and Settings' Check Now (`userInitiated`), or
    /// an automatic check, which shows nothing unless it finds an update.
    func check(userInitiated: Bool) {
        if userInitiated, case .installing = phase { return showWindow() }
        if let updater, updater.sessionInProgress {
            if userInitiated { showWindow() }
            return
        }
        guard isConfigured else {
            phase = .problem(.notConfigured)
            if userInitiated { showWindow() }
            return
        }
        installLocation = UpdateInstallLocation.check(bundlePath: Bundle.main.bundlePath)
        if installLocation.mustMove {
            phase = .problem(.mustMove(installLocation))
            lastCheckSummary = "Move Runlet to Applications to update it"
            if userInitiated { showWindow() }
            return
        }
        do {
            try startUpdaterIfNeeded()
        } catch {
            phase = .problem(.couldNotCheck(detail: error.localizedDescription))
            if userInitiated { showWindow() }
            return
        }
        currentCheckIsUserInitiated = userInitiated
        installChosen = false
        if userInitiated {
            phase = .checking
            showWindow()
            updater?.checkForUpdates()
        } else {
            updater?.checkForUpdatesInBackground()
        }
    }

    private func startUpdaterIfNeeded() throws {
        guard updater == nil else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        // One plain request: no version in the user agent, no system profile.
        updater.userAgentString = "Runlet"
        updater.sendsSystemProfile = false
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        try updater.start()
        self.updater = updater
    }

    // MARK: The window's buttons

    /// Install and Relaunch on an offer: download, verify, and install (Sparkle), then quit.
    func installOffer() {
        guard let reply = foundReply else { return }
        foundReply = nil
        installChosen = true
        reply(.install)
    }

    /// Later: dismisses the offer until the next check.
    func later() {
        if let reply = foundReply {
            foundReply = nil
            reply(.dismiss)
        }
        stopDeferring()
        phase = .idle
        UpdateWindow.close()
    }

    /// Skip This Version: not offered again by automatic checks (Sparkle remembers it).
    func skipVersion() {
        if let reply = foundReply {
            foundReply = nil
            reply(.skip)
        }
        stopDeferring()
        phase = .idle
        UpdateWindow.close()
    }

    /// Cancel while checking, downloading, or waiting to install. Nothing is installed.
    func cancel() {
        if let cancelCheck { self.cancelCheck = nil; cancelCheck() }
        if let cancelDownload { self.cancelDownload = nil; cancelDownload() }
        if let installReply { self.installReply = nil; installReply(.skip) }
        installChosen = false
        phase = .idle
        UpdateWindow.close()
    }

    /// Install and Relaunch once the update is ready (enabled when no code runs).
    func installNow() {
        guard case .readyToInstall(let offer) = phase, let reply = installReply else { return }
        installReply = nil
        installAndQuit(offer, reply: reply)
    }

    /// Closing the window: an offer counts as Later; a download keeps going in the background.
    func windowWillClose() {
        switch phase {
        case .found: later()
        case .upToDate, .problem: phase = .idle
        default: break
        }
    }

    func showWindow() {
        UpdateWindow.show(self)
    }

    // MARK: Installing

    private func installAndQuit(_ offer: Offer, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let running, let files else { return reply(.skip) }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: files.directory, withIntermediateDirectories: true)
            try? fm.removeItem(at: files.failed)
            try UpdateBackup.make(of: Bundle.main.bundleURL, at: files.backup)
            try JSONEncoder().encode(UpdateRecord(from: running, to: offer.version)).write(to: files.pending, options: .atomic)
            let plan = UpdateWatchdog.Plan(
                appPath: Bundle.main.bundlePath, backupPath: files.backup.path, stateDirectory: files.directory.path,
                processIdentifier: getpid(), bundleIdentifier: Bundle.main.bundleIdentifier ?? "", build: offer.version.build,
                launchTimeout: Self.launchTimeout, launcherArguments: Self.relaunchArguments
            )
            _ = try DetachedProcess.spawn("/bin/sh", arguments: UpdateWatchdog.arguments(plan), environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()])
        } catch {
            try? fm.removeItem(at: files.backup)
            try? fm.removeItem(at: files.pending)
            reply(.skip)
            phase = .problem(.failed(title: "The update wasn't installed", detail: "Runlet couldn't keep a copy of this version to go back to, so it left everything as it was. \(error.localizedDescription)"))
            showWindow()
            return
        }
        phase = .installing(offer)
        // "Later" to Sparkle: its installer, already waiting, replaces the app when Runlet quits and
        // doesn't relaunch it. The watchdog does, with this session's data folder.
        reply(.dismiss)
        // A run loop timer, not a main-queue block: quitting runs a nested run loop until
        // `applicationShouldTerminate` replies, and the main queue (where that reply comes from)
        // isn't drained inside a main-queue block.
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.5)
    }

    /// Seconds the new version has to start before the watchdog puts the old one back.
    private static var launchTimeout: Int {
        #if DEBUG
        if let seconds = ProcessInfo.processInfo.environment["RUNLET_UPDATE_LAUNCH_TIMEOUT"].flatMap(Int.init) { return seconds }
        #endif
        return 60
    }

    /// `open` arguments for starting the new version: a new instance of this exact bundle, with
    /// `RUNLET_DATA_DIR` when set. Debug builds also pass `RUNLET_RELAUNCH_<NAME>` on as
    /// `RUNLET_<NAME>`, write its standard error to `RUNLET_UPDATE_RELAUNCH_STDERR`, and start it
    /// in the background with `RUNLET_UPDATE_RELAUNCH_BACKGROUND=1` (end-to-end tests).
    private static var relaunchArguments: [String] {
        let environment = ProcessInfo.processInfo.environment
        var pass: [String: String] = [:]
        if let data = environment["RUNLET_DATA_DIR"], !data.isEmpty { pass["RUNLET_DATA_DIR"] = data }
        var arguments = ["-n"]
        #if DEBUG
        for (key, value) in environment where key.hasPrefix("RUNLET_RELAUNCH_") {
            pass["RUNLET_" + key.dropFirst("RUNLET_RELAUNCH_".count)] = value
        }
        if let stderr = environment["RUNLET_UPDATE_RELAUNCH_STDERR"] { arguments += ["--stderr", stderr] }
        if environment["RUNLET_UPDATE_RELAUNCH_BACKGROUND"] == "1" { arguments += ["-g", "-j"] }
        #endif
        return arguments + UpdateWatchdog.environmentArguments(pass)
    }

    // MARK: Deferring offers while code runs

    private func presentOffer(_ offer: Offer) {
        phase = .found(offer)
        if UpdateCheckPolicy.mayPresent(userInitiated: offer.userInitiated, runInProgress: isRunInProgress) {
            stopDeferring()
            showWindow()
            return
        }
        guard deferTimer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .found(let offer) = self.phase else { self?.stopDeferring(); return }
                if !self.isRunInProgress { self.presentOffer(offer) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        deferTimer = timer
    }

    private func stopDeferring() {
        deferTimer?.invalidate()
        deferTimer = nil
    }

    private var currentOffer: Offer? {
        switch phase {
        case .found(let offer), .downloading(let offer, _, _), .extracting(let offer, _), .readyToInstall(let offer), .installing(let offer): offer
        default: nil
        }
    }

    // MARK: Errors

    private func problem(for error: NSError) -> Problem {
        // Sparkle wraps errors (a bad archive signature is an installation error with a validation
        // error under it; a 404 is two levels down): the innermost says what happened.
        var chain = [error]
        while let next = chain.last?.userInfo[NSUnderlyingErrorKey] as? NSError, chain.count < 8 { chain.append(next) }
        let detail = chain.last?.localizedDescription ?? error.localizedDescription
        let codes = Set(chain.filter { $0.domain == SUSparkleErrorDomain }.map { Int($0.code) })
        guard error.domain == SUSparkleErrorDomain else {
            return .failed(title: "The update wasn't installed", detail: error.localizedDescription)
        }
        if currentOffer != nil, !codes.isDisjoint(with: [Int(SUError.signatureError.rawValue), Int(SUError.validationError.rawValue), Int(SUError.insufficientSigningError.rawValue)]) {
            return .failed(title: "The update couldn't be verified", detail: "Its signature doesn't match Runlet's update key, so it wasn't installed. Runlet is unchanged.")
        }
        switch Int(error.code) {
        case Int(SUError.runningFromDiskImageError.rawValue):
            return .mustMove(.readOnlyVolume(path: Bundle.main.bundlePath))
        case Int(SUError.signatureError.rawValue), Int(SUError.validationError.rawValue), Int(SUError.insufficientSigningError.rawValue):
            return .failed(title: "The update couldn't be verified", detail: "Its signature doesn't match Runlet's update key, so it wasn't installed. Runlet is unchanged.")
        case Int(SUError.installationCanceledError.rawValue), Int(SUError.installationAuthorizeLaterError.rawValue):
            return .failed(title: "The update wasn't installed", detail: "Installing it needs an administrator's name and password, and the request was canceled. Runlet is unchanged.")
        case Int(SUError.installationWriteNoPermissionError.rawValue):
            return .failed(title: "The update wasn't installed", detail: "Runlet can't write to its folder. Move Runlet to a folder you can change, such as Applications, or ask an administrator.")
        case Int(SUError.downgradeError.rawValue):
            return .failed(title: "The update wasn't installed", detail: "It's older than this version of Runlet.")
        case Int(SUError.downloadError.rawValue) where currentOffer != nil:
            return .failed(title: "The update couldn't be downloaded", detail: detail)
        default:
            if currentOffer == nil { return .couldNotCheck(detail: detail) }
            return .failed(title: "The update wasn't installed", detail: error.localizedDescription)
        }
    }

    private func finishCheck(_ summary: String) {
        lastCheck = Date()
        lastCheckSummary = summary
    }

    private func offer(_ item: SUAppcastItem, userInitiated: Bool, downloaded: Bool) -> Offer? {
        guard let version = RunletVersion(item.displayVersionString, build: item.versionString) else { return nil }
        return Offer(version: version, notes: item.itemDescription ?? "", notesFormat: item.itemDescriptionFormat ?? "html",
                     size: item.contentLength > 0 ? item.contentLength : nil, date: item.date,
                     releasePage: item.infoURL ?? item.fullReleaseNotesURL, userInitiated: userInitiated, isDownloaded: downloaded)
    }

    #if DEBUG
    /// Debug steps (UpdateDebugSteps): the phase as text.
    var debugState: String {
        let version = running.map(\.description) ?? "?"
        let phaseText: String = switch phase {
        case .idle: "idle"
        case .checking: "checking"
        case .upToDate: "upToDate"
        case .found(let offer): "found \(offer.version) size=\(offer.size.map(String.init) ?? "?")"
        case .downloading(let offer, let received, let expected): "downloading \(offer.version) \(received)/\(expected.map(String.init) ?? "?")"
        case .extracting(let offer, let progress): "extracting \(offer.version) \(Int(progress * 100))%"
        case .readyToInstall(let offer): "readyToInstall \(offer.version)"
        case .installing(let offer): "installing \(offer.version)"
        case .problem(let problem): "problem \(problem)"
        }
        return "running=\(version) configured=\(isConfigured) channel=\(channel.rawValue) phase=\(phaseText) automatic=\(automaticCheckBlocker ?? "on") installed=\(installedUpdate.map { "\($0.fromVersion)->\($0.toVersion)" } ?? "none") location=\(installLocation)"
    }

    /// `update:auto`: an automatic check now, as the schedule would run it.
    func debugAutomaticCheck() {
        check(userInitiated: false)
    }
    #endif
}

// MARK: - Sparkle delegate

extension AppUpdater: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channel.appcastChannels
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        #if DEBUG
        // A local feed for end-to-end tests and screenshots; never in Release builds.
        if let url = ProcessInfo.processInfo.environment["RUNLET_UPDATE_FEED_URL"], !url.isEmpty { return url }
        #endif
        return nil
    }

    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        guard let running else { return SUAppcastItem.empty() }
        let items = appcast.items.compactMap { item in
            RunletVersion(item.displayVersionString, build: item.versionString).map { (item, UpdateCandidate(version: $0, channel: item.channel)) }
        }
        guard let best = UpdateSelection.best(items.map(\.1), channel: channel, running: running) else { return SUAppcastItem.empty() }
        return items.first { $0.1 == best }?.0 ?? SUAppcastItem.empty()
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool {
        false // The notes are in the appcast item.
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        guard let error = error as NSError? else {
            if case .found = phase {} else if case .installing = phase {} else { finishCheck("Up to date") }
            return
        }
        if error.domain == SUSparkleErrorDomain, error.code == Int(SUError.noUpdateError.rawValue) {
            finishCheck("Up to date")
        } else if case .couldNotCheck = problem(for: error) {
            finishCheck("Couldn't check for updates")
        } else {
            finishCheck("The last update didn't install")
        }
    }
}

// MARK: - Sparkle user driver

extension AppUpdater: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Runlet asks nothing: automatic checks are its own setting (SUEnableAutomaticChecks is off).
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        cancelCheck = cancellation
        phase = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancelCheck = nil
        guard let offer = offer(appcastItem, userInitiated: state.userInitiated, downloaded: state.stage != .notDownloaded) else {
            reply(.dismiss)
            return
        }
        foundReply = reply
        finishCheck("Runlet \(offer.version.displayName) is available")
        presentOffer(offer)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        cancelCheck = nil
        finishCheck("Up to date")
        phase = .upToDate
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        cancelCheck = nil
        cancelDownload = nil
        let problem = problem(for: error as NSError)
        let wasInstalling = installChosen
        installChosen = false
        acknowledgement()
        if case .installing = phase { return }
        stopDeferring()
        guard currentCheckIsUserInitiated || wasInstalling else {
            // An automatic check that went wrong stays quiet (Settings shows it).
            phase = .idle
            return
        }
        phase = .problem(problem)
        showWindow()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        cancelDownload = cancellation
        guard let offer = currentOffer else { return }
        phase = .downloading(offer, received: 0, expected: offer.size)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        guard case .downloading(let offer, let received, _) = phase else { return }
        phase = .downloading(offer, received: received, expected: expectedContentLength > 0 ? expectedContentLength : offer.size)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard case .downloading(let offer, let received, let expected) = phase else { return }
        phase = .downloading(offer, received: received + length, expected: expected)
    }

    func showDownloadDidStartExtractingUpdate() {
        cancelDownload = nil
        guard let offer = currentOffer else { return }
        phase = .extracting(offer, progress: 0)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        guard case .extracting(let offer, _) = phase else { return }
        phase = .extracting(offer, progress: progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let offer = currentOffer, installChosen || offer.isDownloaded else {
            // Never install without the user's Install and Relaunch.
            reply(.skip)
            return
        }
        if isRunInProgress {
            installReply = reply
            phase = .readyToInstall(offer)
            showWindow()
        } else {
            installAndQuit(offer, reply: reply)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {
        showWindow()
    }

    func dismissUpdateInstallation() {
        cancelCheck = nil
        cancelDownload = nil
        switch phase {
        case .checking, .found, .downloading, .extracting, .readyToInstall:
            if case .found = phase, foundReply != nil { return }
            stopDeferring()
            phase = .idle
            UpdateWindow.close()
        default:
            break
        }
    }
}
