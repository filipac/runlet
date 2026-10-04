import Darwin
import Foundation

// In-app updates (#233). The app downloads, verifies, and installs with Sparkle 2; everything here
// is Runlet's own logic around it, without Sparkle: version ordering, channels, which update to
// offer, when automatic checks may run, whether the app's location can be updated, and the
// watchdog that relaunches the new version and restores the old one if it doesn't start.

/// A Runlet version: semantic version (`0.4.0`, `0.4.0-beta.6`) plus the build number
/// (`CFBundleVersion`). Ordered by the semantic version first (a pre-release sorts before its
/// release, SemVer 2.0 §11), then by the build number.
public struct RunletVersion: Sendable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// Pre-release identifiers: `["beta", "6"]` for `0.4.0-beta.6`; empty for a release.
    public var prerelease: [String]
    /// `CFBundleVersion` (`sparkle:version`), compared numerically.
    public var build: String

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = [], build: String) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.build = build
    }

    /// Parses `0.4.0`, `v0.4.0-beta.6`, or `0.4` (missing parts are 0), with an optional
    /// pre-release given separately (`RunletPrerelease`, e.g. `beta.6`) when `version` has none.
    /// Build metadata after `+` is ignored. Nil for anything else.
    public init?(_ version: String, prerelease separate: String? = nil, build: String) {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
        var prerelease: [String] = []
        if let dash = text.firstIndex(of: "-") {
            prerelease = text[text.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            text = String(text[..<dash])
        } else if let separate = separate?.trimmingCharacters(in: .whitespacesAndNewlines), !separate.isEmpty {
            prerelease = separate.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        }
        guard prerelease.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        let build = build.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !build.isEmpty else { return nil }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: prerelease, build: build)
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    /// `0.4.0-beta.6`: the semantic version, as in a release tag (without the `v`).
    public var semanticVersion: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    /// `0.4.0 beta 6`, as release names say it; other pre-releases keep their dots.
    public var displayName: String {
        let base = "\(major).\(minor).\(patch)"
        guard !prerelease.isEmpty else { return base }
        if prerelease.count == 2, prerelease[0].allSatisfy(\.isLetter), Int(prerelease[1]) != nil {
            return "\(base) \(prerelease[0]) \(prerelease[1])"
        }
        return "\(base)-\(prerelease.joined(separator: "."))"
    }

    /// `0.4.0 beta 6 (12)`.
    public var description: String { "\(displayName) (\(build))" }

    public static func < (lhs: RunletVersion, rhs: RunletVersion) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    public static func == (lhs: RunletVersion, rhs: RunletVersion) -> Bool {
        compare(lhs, rhs) == .orderedSame
    }

    /// The order of two versions: semantic version, then build number.
    public static func compare(_ lhs: RunletVersion, _ rhs: RunletVersion) -> ComparisonResult {
        let core = semanticCompare(lhs, rhs)
        return core != .orderedSame ? core : compareBuilds(lhs.build, rhs.build)
    }

    /// The order of the semantic versions alone (builds ignored).
    public static func semanticCompare(_ lhs: RunletVersion, _ rhs: RunletVersion) -> ComparisonResult {
        for (a, b) in [(lhs.major, rhs.major), (lhs.minor, rhs.minor), (lhs.patch, rhs.patch)] where a != b {
            return a < b ? .orderedAscending : .orderedDescending
        }
        // A release is newer than any of its pre-releases.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): break
        }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) {
            let order = compareIdentifiers(a, b)
            if order != .orderedSame { return order }
        }
        if lhs.prerelease.count == rhs.prerelease.count { return .orderedSame }
        return lhs.prerelease.count < rhs.prerelease.count ? .orderedAscending : .orderedDescending
    }

    /// SemVer pre-release identifiers: numbers numerically, below any word; words in ASCII order.
    private static func compareIdentifiers(_ a: String, _ b: String) -> ComparisonResult {
        switch (Int(a), Int(b)) {
        case let (x?, y?): return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        case (.some, nil): return .orderedAscending
        case (nil, .some): return .orderedDescending
        case (nil, nil): return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        }
    }

    /// Build numbers: numeric parts compared as numbers (`12` > `9`, `1.10` > `1.9`).
    public static func compareBuilds(_ a: String, _ b: String) -> ComparisonResult {
        normalizedBuild(a).compare(normalizedBuild(b), options: [.numeric])
    }

    private static func normalizedBuild(_ build: String) -> String {
        build.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The running app's version from its Info.plist: `CFBundleShortVersionString`,
    /// `RunletPrerelease` (`beta.6` on a pre-release build, empty otherwise), and `CFBundleVersion`.
    public static func fromInfoDictionary(_ info: [String: Any]) -> RunletVersion? {
        guard let short = info["CFBundleShortVersionString"] as? String, let build = info["CFBundleVersion"] as? String else { return nil }
        return RunletVersion(short, prerelease: info["RunletPrerelease"] as? String, build: build)
    }
}

/// Settings ▸ General ▸ Updates (#233): which releases Runlet offers.
public enum UpdateChannel: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Releases only (GitHub releases that aren't pre-releases).
    case stable
    /// Pre-releases too (`vX.Y.Z-beta.N`).
    case beta

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .stable: "Stable"
        case .beta: "Beta"
        }
    }

    /// The channel a build uses until the user picks one: Beta on a pre-release build.
    public static func `default`(for running: RunletVersion?) -> UpdateChannel {
        running?.isPrerelease == true ? .beta : .stable
    }

    /// Sparkle's `allowedChannels`: appcast items tagged `<sparkle:channel>beta</sparkle:channel>`
    /// are offered on Beta only; untagged items are on every channel.
    public var appcastChannels: Set<String> {
        switch self {
        case .stable: []
        case .beta: [UpdateCandidate.betaChannel]
        }
    }
}

/// One update the feed lists (an appcast item), as `UpdateSelection` sees it.
public struct UpdateCandidate: Sendable, Equatable {
    public static let betaChannel = "beta"

    public var version: RunletVersion
    /// The item's `sparkle:channel`; nil for releases.
    public var channel: String?

    public init(version: RunletVersion, channel: String?) {
        self.version = version
        self.channel = channel
    }

    /// Whether this is a pre-release: tagged for the beta channel, or with a pre-release version
    /// (so a beta listed without its tag never reaches Stable).
    public var isBeta: Bool { channel != nil || version.isPrerelease }
}

/// Which update to offer (#233).
public enum UpdateSelection {
    /// The newest candidate the channel allows that is newer than `running`, leaving out the
    /// skipped version; nil when there is none (Runlet is up to date). On Beta, a newer beta or
    /// the release that supersedes the running beta; on Stable, releases only.
    public static func best(_ candidates: [UpdateCandidate], channel: UpdateChannel, running: RunletVersion, skipped: RunletVersion? = nil) -> UpdateCandidate? {
        candidates
            .filter { (channel == .beta || !$0.isBeta) && $0.version > running && $0.version != skipped }
            .max { $0.version < $1.version }
    }
}

/// Where automatic checks stand (#233): whether one may run now, and why not.
public struct UpdateCheckPolicy: Sendable, Equatable {
    /// How Runlet was started, read once at launch.
    public struct Launch: Sendable, Equatable {
        /// A Debug build. It never checks on its own: a newer release would replace a development
        /// build. `RUNLET_UPDATE_AUTOMATIC=1` (Debug only) turns checks on for end-to-end tests.
        public var isDebugBuild: Bool
        public var forceAutomaticChecks: Bool
        /// `Runlet --self-test`.
        public var isSelfTest: Bool
        /// Started in the background by `runlet mcp` (`--launched-by-mcp`): no check until the
        /// user brings Runlet forward.
        public var launchedByMCP: Bool
        /// A scripted Debug session (`RUNLET_DEBUG_STEPS`, `RUNLET_SNAPSHOT_DIR`), such as
        /// screenshots and UI checks.
        public var isScripted: Bool

        public init(isDebugBuild: Bool, forceAutomaticChecks: Bool = false, isSelfTest: Bool = false, launchedByMCP: Bool = false, isScripted: Bool = false) {
            self.isDebugBuild = isDebugBuild
            self.forceAutomaticChecks = forceAutomaticChecks
            self.isSelfTest = isSelfTest
            self.launchedByMCP = launchedByMCP
            self.isScripted = isScripted
        }

        public static func current(arguments: [String] = CommandLine.arguments, environment: [String: String] = ProcessInfo.processInfo.environment, isDebugBuild: Bool) -> Launch {
            Launch(
                isDebugBuild: isDebugBuild,
                forceAutomaticChecks: isDebugBuild && environment["RUNLET_UPDATE_AUTOMATIC"] == "1",
                isSelfTest: arguments.contains("--self-test"),
                launchedByMCP: arguments.contains(launchedByMCPArgument),
                isScripted: ["RUNLET_DEBUG_STEPS", "RUNLET_DEBUG_INSPECTOR", "RUNLET_SNAPSHOT_DIR"].contains { !(environment[$0] ?? "").isEmpty }
            )
        }
    }

    /// The argument `runlet mcp` launches Runlet with.
    public static let launchedByMCPArgument = "--launched-by-mcp"
    /// Automatic checks run at launch, then at most once a day while Runlet runs.
    public static let interval: TimeInterval = 24 * 60 * 60

    public var launch: Launch

    public init(launch: Launch) {
        self.launch = launch
    }

    /// Why an automatic check can't run now, or nil when it may. `everActive`: Runlet has been
    /// the active app since it started.
    public func automaticCheckBlocker(enabled: Bool, everActive: Bool) -> String? {
        if launch.isSelfTest { return "self-test" }
        if launch.isDebugBuild && !launch.forceAutomaticChecks { return launch.isScripted ? "scripted Debug session" : "Debug build" }
        if launch.isScripted && !launch.forceAutomaticChecks { return "scripted session" }
        if !enabled { return "automatic checks are off" }
        if launch.launchedByMCP && !everActive { return "started by runlet mcp" }
        return nil
    }

    /// Whether an automatic check is due: never checked in this session, or the last check was at
    /// least `interval` ago.
    public static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    /// Whether an update found by an automatic check may be shown now: never while code runs. A
    /// check the user asked for is shown at once (its Install waits for runs to end).
    public static func mayPresent(userInitiated: Bool, runInProgress: Bool) -> Bool {
        userInitiated || !runInProgress
    }
}

/// Whether Runlet's own copy can be replaced in place (#233).
public enum UpdateInstallLocation: Sendable, Equatable {
    /// The folder is writable: the update installs without asking.
    case ready
    /// The folder (or the app) isn't writable by this user, as `/Applications` owned by an
    /// administrator: macOS asks for an administrator's name and password to install.
    case needsAdministrator(folder: String)
    /// On a read-only volume, such as the disk image Runlet came on.
    case readOnlyVolume(path: String)
    /// Moved by macOS to a random read-only location (App Translocation), because it was opened
    /// straight from the Downloads folder or the disk image while quarantined.
    case translocated

    /// Whether the user has to move Runlet before it can update.
    public var mustMove: Bool {
        switch self {
        case .readOnlyVolume, .translocated: true
        case .ready, .needsAdministrator: false
        }
    }

    /// What the file system says about a path, replaceable in tests.
    public struct Probe: Sendable {
        public var isTranslocated: @Sendable (String) -> Bool
        public var isOnReadOnlyVolume: @Sendable (String) -> Bool
        public var isWritable: @Sendable (String) -> Bool

        public init(isTranslocated: @escaping @Sendable (String) -> Bool, isOnReadOnlyVolume: @escaping @Sendable (String) -> Bool, isWritable: @escaping @Sendable (String) -> Bool) {
            self.isTranslocated = isTranslocated
            self.isOnReadOnlyVolume = isOnReadOnlyVolume
            self.isWritable = isWritable
        }

        public static let live = Probe(
            isTranslocated: { UpdateInstallLocation.isTranslocated($0) },
            isOnReadOnlyVolume: { path in
                (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
            },
            isWritable: { FileManager.default.isWritableFile(atPath: $0) }
        )
    }

    /// The app bundle at `bundlePath`: translocated first, then a read-only volume, then whether
    /// both the bundle and its folder are writable (the installer swaps the bundle in the folder).
    public static func check(bundlePath: String, probe: Probe = .live) -> UpdateInstallLocation {
        if probe.isTranslocated(bundlePath) { return .translocated }
        if probe.isOnReadOnlyVolume(bundlePath) { return .readOnlyVolume(path: bundlePath) }
        let folder = (bundlePath as NSString).deletingLastPathComponent
        if !probe.isWritable(folder) || !probe.isWritable(bundlePath) { return .needsAdministrator(folder: folder) }
        return .ready
    }

    /// App Translocation: Security's `SecTranslocateIsTranslocatedURL` (looked up at run time, so
    /// RunletCore needs no framework), else the `/AppTranslocation/` folder macOS uses.
    public static func isTranslocated(_ path: String) -> Bool {
        if path.contains("/AppTranslocation/") { return true }
        typealias Function = @convention(c) (CFURL, UnsafeMutablePointer<DarwinBoolean>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> DarwinBoolean
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_NOLOAD) ?? dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SecTranslocateIsTranslocatedURL") else { return false }
        let function = unsafeBitCast(symbol, to: Function.self)
        var translocated: DarwinBoolean = false
        let ok = function(URL(fileURLWithPath: path) as CFURL, &translocated, nil)
        return ok.boolValue && translocated.boolValue
    }
}

/// The files of an update in progress, in `AppPaths.updates` (#233).
public struct UpdateFiles: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The copy of the running app, kept until the new version has started. Not named `.app`, so
    /// Launch Services never registers it.
    public var backup: URL { directory.appendingPathComponent("Backup/Runlet.backup", isDirectory: true) }
    /// Where a version that didn't start is moved when the backup goes back.
    public var failed: URL { directory.appendingPathComponent("Failed.backup", isDirectory: true) }
    /// Written by Runlet at launch: its build number, then its process id ("launched OK").
    public var launchedMarker: URL { directory.appendingPathComponent("launched") }
    /// The update being installed (`UpdateRecord`), written before Runlet quits for it.
    public var pending: URL { directory.appendingPathComponent("pending.json") }
    /// What the watchdog decided (`UpdateResult`).
    public var result: URL { directory.appendingPathComponent("result.json") }
    public var log: URL { directory.appendingPathComponent("watchdog.log") }
}

/// The update Runlet quit to install: written to `UpdateFiles.pending` before quitting, read by
/// the version that starts next (#232's What's New starts from it).
public struct UpdateRecord: Sendable, Codable, Equatable {
    public var fromVersion: String
    public var fromBuild: String
    public var toVersion: String
    public var toBuild: String
    public var date: Date

    public init(from: RunletVersion, to: RunletVersion, date: Date = Date()) {
        fromVersion = from.displayName
        fromBuild = from.build
        toVersion = to.displayName
        toBuild = to.build
        self.date = date
    }
}

/// What the watchdog wrote to `UpdateFiles.result`.
public struct UpdateResult: Sendable, Codable, Equatable {
    public enum Outcome: String, Sendable, Codable {
        /// The new version started; the backup is gone.
        case updated
        /// The new version didn't start (or wasn't the right app); the backup is back in place.
        case rolledBack
        /// The installer didn't replace the app; the old version was started again.
        case notInstalled
        /// The new version didn't start and the backup couldn't be put back.
        case restoreFailed
    }

    public var outcome: Outcome
    /// The build the update was to install.
    public var build: String
    public var detail: String

    public init(outcome: Outcome, build: String, detail: String) {
        self.outcome = outcome
        self.build = build
        self.detail = detail
    }
}

/// The watchdog (#233): a small shell script Runlet starts, detached, just before it quits for an
/// update. It waits for Runlet to quit and for Sparkle's installer to swap the bundle, checks the
/// new bundle (identifier, build, no quarantine), starts it, and waits for its "launched" marker.
/// Without the marker in time it stops the new version, puts the backup back, writes why, and
/// starts the old version, which says so. With the marker it removes the backup.
public enum UpdateWatchdog {
    public struct Plan: Sendable, Equatable {
        public var appPath: String
        public var backupPath: String
        public var stateDirectory: String
        public var processIdentifier: Int32
        public var bundleIdentifier: String
        public var build: String
        /// Seconds to wait for the installer after Runlet quit.
        public var installTimeout: Int
        /// Seconds the new version has to write its marker.
        public var launchTimeout: Int
        /// Starts an app: `/usr/bin/open` (with `-n` and `--env` pairs in `launcherArguments`);
        /// tests use a script.
        public var launcher: String
        public var launcherArguments: [String]

        public init(appPath: String, backupPath: String, stateDirectory: String, processIdentifier: Int32, bundleIdentifier: String, build: String,
                    installTimeout: Int = 120, launchTimeout: Int = 60, launcher: String = "/usr/bin/open", launcherArguments: [String] = ["-n"]) {
            self.appPath = appPath
            self.backupPath = backupPath
            self.stateDirectory = stateDirectory
            self.processIdentifier = processIdentifier
            self.bundleIdentifier = bundleIdentifier
            self.build = build
            self.installTimeout = installTimeout
            self.launchTimeout = launchTimeout
            self.launcher = launcher
            self.launcherArguments = launcherArguments
        }
    }

    /// `/bin/sh` arguments: `-c <script> <name> <plan…>`. Values travel as arguments, never inside
    /// the script text.
    public static func arguments(_ plan: Plan) -> [String] {
        ["-c", script, "runlet-update-watchdog", plan.appPath, plan.backupPath, plan.stateDirectory, String(plan.processIdentifier),
         plan.bundleIdentifier, plan.build, String(plan.installTimeout), String(plan.launchTimeout), plan.launcher] + plan.launcherArguments
    }

    /// `open` arguments that pass these variables to the relaunched app.
    public static func environmentArguments(_ environment: [String: String]) -> [String] {
        environment.keys.sorted().flatMap { ["--env", "\($0)=\(environment[$0] ?? "")"] }
    }

    public static let script = #"""
    APP=$1 BACKUP=$2 STATE=$3 PID=$4 BUNDLE_ID=$5 BUILD=$6 INSTALL_WAIT=$7 LAUNCH_WAIT=$8 LAUNCHER=$9
    shift 9
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    LOG="$STATE/watchdog.log"
    log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$LOG"; }
    plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }
    result() {
        printf '{"outcome":"%s","build":"%s","detail":"%s"}\n' "$1" "$BUILD" "$2" > "$STATE/result.json.tmp" && mv -f "$STATE/result.json.tmp" "$STATE/result.json"
    }
    start() { log "starting $APP"; "$LAUNCHER" "$@" "$APP" >> "$LOG" 2>&1 || log "the launcher failed ($?)"; }
    stop_new() {
        ps -axo pid=,comm= | while read -r p c; do
            case "$c" in "$APP/Contents/MacOS/"*) log "stopping $p"; kill "$p" 2>/dev/null ;; esac
        done
        sleep 2
        ps -axo pid=,comm= | while read -r p c; do
            case "$c" in "$APP/Contents/MacOS/"*) kill -9 "$p" 2>/dev/null ;; esac
        done
    }
    restore() {
        reason=$1; shift
        log "restoring the previous version: $reason"
        stop_new
        rm -rf "$STATE/Failed.backup"
        if mv "$APP" "$STATE/Failed.backup" && mv "$BACKUP" "$APP"; then
            result rolledBack "$reason"
            start "$@"
        else
            log "could not restore $BACKUP"
            result restoreFailed "$reason"
        fi
    }
    rm -f "$STATE/launched" "$STATE/result.json"
    log "waiting for Runlet ($PID) to quit"
    n=0
    while kill -0 "$PID" 2>/dev/null; do
        sleep 0.2; n=$((n + 1))
        if [ "$n" -ge 1500 ]; then log "Runlet didn't quit"; rm -rf "$BACKUP"; exit 0; fi
    done
    log "waiting for build $BUILD at $APP"
    n=0
    while [ "$(plist "$APP" CFBundleVersion)" != "$BUILD" ]; do
        sleep 1; n=$((n + 1))
        if [ "$n" -ge "$INSTALL_WAIT" ]; then
            log "the update wasn't installed"
            rm -rf "$BACKUP"
            result notInstalled "The installer didn't replace the app."
            start "$@"
            exit 0
        fi
    done
    if [ "$(plist "$APP" CFBundleIdentifier)" != "$BUNDLE_ID" ]; then
        restore "The new version has another bundle identifier." "$@"
        exit 0
    fi
    if xattr "$APP" 2>/dev/null | grep -q '^com.apple.quarantine$'; then
        log "removing the quarantine attribute"
        xattr -dr com.apple.quarantine "$APP"
    fi
    start "$@"
    n=0
    while [ "$(head -n 1 "$STATE/launched" 2>/dev/null)" != "$BUILD" ]; do
        sleep 1; n=$((n + 1))
        if [ "$n" -ge "$LAUNCH_WAIT" ]; then
            restore "The new version didn't start within $LAUNCH_WAIT seconds." "$@"
            exit 0
        fi
    done
    log "build $BUILD started"
    rm -rf "$BACKUP"
    result updated ""
    """#

    /// Runlet's "launched OK" marker: its build, then its process id.
    public static func writeLaunchedMarker(_ files: UpdateFiles, build: String, processIdentifier: Int32 = getpid()) throws {
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        try Data("\(build)\n\(processIdentifier)\n".utf8).write(to: files.launchedMarker, options: .atomic)
    }
}

/// Starts a process in its own session, not waited for: it outlives Runlet (the update watchdog).
public enum DetachedProcess {
    /// Returns the process id. Standard input and output go to /dev/null.
    public static func spawn(_ executable: String, arguments: [String], environment: [String: String]) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
        }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
        return pid
    }
}

/// The copy of the running app the watchdog puts back when the new version doesn't start: an
/// APFS clone (instant, no extra space) when possible, else a copy.
public enum UpdateBackup {
    public static func make(of app: URL, at backup: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
        if clonefile(app.path, backup.path, 0) != 0 {
            try fm.copyItem(at: app, to: backup)
        }
    }
}
