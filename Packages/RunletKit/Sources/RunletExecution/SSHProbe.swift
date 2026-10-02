import Foundation
import RunletCore

/// What Test Connection found on an SSH host. It comes from one `php -r` program that only
/// reads files (nothing in the project runs) and from `ssh` itself.
public struct SSHProbe: Sendable, Equatable, Codable {
    public var phpVersion: String?
    public var phpBinary: String?
    public var user: String?
    public var uid: Int?
    public var home: String?
    /// `PHP_OS_FAMILY` (Linux, BSD, Darwin, …).
    public var os: String?
    public var directoryExists: Bool
    public var directoryReadable: Bool
    /// The directory's real path (differs for symlinks such as Forge's `current`).
    public var realDirectory: String?
    public var framework: String
    public var temporaryDirectory: String?
    public var temporaryDirectoryWritable: Bool
    public var hasTokenizer: Bool
    /// `posix`, `shell`, or `none`.
    public var canSignal: String
    /// Linux `/proc`, which Stop needs to check a process before signalling it.
    public var hasProc: Bool
    /// Other PHP binaries on the server (`/usr/bin/php8.3`, …).
    public var phpCandidates: [String]
    /// Application folders found on the server (containing `artisan` or `composer.json`).
    public var candidates: [String]
    /// `composer.json` `name` in the directory.
    public var composerName: String?
    /// The checkout's `remote.origin.url`, branch, and commit, read from `.git` files.
    public var gitRemote: String?
    public var gitBranch: String?
    public var gitCommit: String?
    /// CRC-32 (hex) and size of `composer.lock`, for deployments without `.git`.
    public var composerLockCRC: String?
    public var composerLockSize: Int?
    /// Profiler extensions the server's PHP loads (Profile Run needs Excimer).
    public var profilers: PHPProfilers?
    /// Round trip of the probe, including connecting when no shared connection was open.
    public var elapsedMs: Int?
    public var error: String?

    public init(error: String) {
        directoryExists = false
        directoryReadable = false
        framework = "plain"
        temporaryDirectoryWritable = false
        hasTokenizer = false
        canSignal = "none"
        hasProc = false
        phpCandidates = []
        candidates = []
        self.error = error
    }

    /// The server's checkout state, for the drift check (`LocalCheckout.drift`).
    public var checkout: CheckoutState {
        CheckoutState(branch: gitBranch, commit: gitCommit, remote: gitRemote, composerLockCRC: composerLockCRC, composerLockSize: composerLockSize)
    }
}

extension SSHClient {
    /// The probe program. Arguments: directory, temporary directory (blank: the system's).
    static let probeScript = #"""
    $wd = $argv[1]; $tmp = $argv[2] !== '' ? $argv[2] : sys_get_temp_dir();
    $fw = 'plain';
    $drivers = glob("$wd/.runlet/*Driver.php") ?: [];
    if ($drivers) { $fw = 'custom:' . implode(',', array_map(function ($f) { return basename($f, '.php'); }, $drivers)); }
    elseif (is_file("$wd/bootstrap/app.php") && (is_file("$wd/artisan") || is_dir("$wd/vendor/laravel-zero/framework"))) { $fw = 'laravel'; }
    elseif (is_file("$wd/wp-load.php") || is_file("$wd/web/wp/wp-load.php") || is_file("$wd/public/wp/wp-load.php") || is_file("$wd/wordpress/wp-load.php") || is_file("$wd/wp/wp-load.php")) { $fw = 'wordpress'; }
    elseif (is_file("$wd/bin/console") && (is_file("$wd/src/Kernel.php") || is_file("$wd/config/bundles.php"))) { $fw = 'symfony'; }
    elseif (is_file("$wd/composer.json") || is_file("$wd/vendor/autoload.php")) { $fw = 'composer'; }
    $uid = function_exists('posix_geteuid') ? posix_geteuid() : null; $user = null; $home = getenv('HOME') ?: null;
    if ($uid !== null && function_exists('posix_getpwuid')) { $pw = @posix_getpwuid($uid); $user = $pw['name'] ?? null; $home = $home ?: ($pw['dir'] ?? null); }
    $cands = [];
    $patterns = ['/var/www/*', '/var/www/*/current', '/srv/*', '/srv/*/current', '/home/*/*', '/home/*/*/current', '/opt/*'];
    if ($home) { array_unshift($patterns, "$home/*", "$home/*/current"); }
    foreach ($patterns as $pattern) {
        foreach (glob($pattern, GLOB_ONLYDIR) ?: [] as $d) {
            if ((is_file("$d/artisan") || is_file("$d/composer.json")) && !in_array($d, $cands, true)) { $cands[] = $d; }
            if (count($cands) >= 40) { break 2; }
        }
    }
    $phps = [];
    foreach (array_merge(glob('/usr/bin/php*') ?: [], glob('/usr/local/bin/php*') ?: [], glob('/opt/*/bin/php') ?: [], glob('/opt/remi/php*/root/usr/bin/php') ?: []) as $f) {
        if (preg_match('~/php[0-9.]*$~', $f) && is_file($f) && is_executable($f) && !in_array($f, $phps, true)) { $phps[] = $f; }
    }
    $composer = null; $c = @file_get_contents("$wd/composer.json");
    if ($c !== false) { $j = json_decode($c, true); if (is_array($j) && isset($j['name']) && is_string($j['name'])) { $composer = $j['name']; } }
    $git = "$wd/.git"; $branch = null; $commit = null; $remote = null;
    if (is_file($git)) { $g = trim((string) @file_get_contents($git)); if (strpos($g, 'gitdir: ') === 0) { $git = substr($g, 8); if ($git !== '' && $git[0] !== '/') { $git = "$wd/$git"; } } }
    $head = @file_get_contents("$git/HEAD");
    if ($head !== false) {
        $head = trim($head);
        if (strpos($head, 'ref: ') === 0) {
            $ref = substr($head, 5); $branch = preg_replace('~^refs/heads/~', '', $ref);
            $commit = trim((string) @file_get_contents("$git/$ref"));
            if ($commit === '') { foreach (@file("$git/packed-refs") ?: [] as $line) { $line = rtrim($line); if (substr($line, -strlen($ref) - 1) === " $ref") { $commit = substr($line, 0, 40); break; } } }
            if ($commit === '') { $commit = null; }
        } elseif (preg_match('/^[0-9a-f]{40}$/', $head)) { $commit = $head; }
        $config = @file_get_contents("$git/config");
        if ($config !== false && preg_match('/\[remote "origin"\][^\[]*?\burl\s*=\s*(\S+)/s', $config, $m)) { $remote = $m[1]; }
    }
    $lock = "$wd/composer.lock"; $lockCRC = null; $lockSize = null;
    if (is_file($lock) && is_readable($lock)) { $lockCRC = hash_file('crc32b', $lock) ?: null; $lockSize = filesize($lock); }
    $signal = function_exists('posix_kill') ? 'posix' : ((function_exists('exec') && is_file('/bin/sh')) ? 'shell' : 'none');
    echo json_encode([
        'phpVersion' => PHP_VERSION, 'phpBinary' => PHP_BINARY, 'user' => $user, 'uid' => $uid, 'home' => $home, 'os' => PHP_OS_FAMILY,
        'directoryExists' => is_dir($wd), 'directoryReadable' => is_readable($wd), 'realDirectory' => @realpath($wd) ?: null,
        'framework' => $fw, 'temporaryDirectory' => $tmp, 'temporaryDirectoryWritable' => is_dir($tmp) && is_writable($tmp),
        'hasTokenizer' => function_exists('token_get_all'), 'canSignal' => $signal, 'hasProc' => is_dir('/proc/self'),
        'phpCandidates' => $phps, 'candidates' => $cands, 'composerName' => $composer,
        'gitRemote' => $remote, 'gitBranch' => $branch, 'gitCommit' => $commit, 'composerLockCRC' => $lockCRC, 'composerLockSize' => $lockSize,
        'profilers' => ['excimer' => extension_loaded('excimer') ? (string) phpversion('excimer') : null, 'spx' => extension_loaded('spx') ? (string) phpversion('spx') : null],
    ]);
    """#

    /// Test Connection: runs `probeScript` with the profile's PHP in BatchMode through the
    /// shared connection (opening it for automatic authentication). Reads files only; no
    /// project code runs and nothing is written.
    public func probe(_ endpoint: SSHEndpoint, phpExecutable: String, directory: String, temporaryDirectory: String? = nil, timeout: Duration = .seconds(20)) async -> SSHProbe {
        let command = RemoteShell.phpCommand(php: phpExecutable, code: Self.probeScript, arguments: [directory, temporaryDirectory ?? ""])
        let started = ContinuousClock.now
        do {
            let result = try await run(endpoint, remoteCommand: command, timeout: timeout)
            let elapsed = ContinuousClock.now - started
            let output = String(decoding: result.stdout, as: UTF8.self)
            // A login script may print before PHP; the JSON is the last line.
            let json = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            if result.exitCode == 0, var probe = try? JSONDecoder().decode(SSHProbe.self, from: Data(json.utf8)) {
                probe.elapsedMs = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
                return probe
            }
            let stderr = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = stderr.isEmpty ? output.trimmingCharacters(in: .whitespacesAndNewlines) : stderr
            let message = SSHFailure.explain(raw, exitCode: result.exitCode, host: endpoint.displayName, directory: directory, php: phpExecutable)
                ?? (raw.isEmpty ? "The probe failed with exit code \(result.exitCode)." : raw)
            return SSHProbe(error: message)
        } catch {
            return SSHProbe(error: "\(error)")
        }
    }
}

/// A checkout's branch, commit, and `composer.lock` fingerprint (on the server or on this Mac).
public struct CheckoutState: Sendable, Equatable, Codable {
    public var branch: String?
    public var commit: String?
    public var remote: String?
    public var composerLockCRC: String?
    public var composerLockSize: Int?

    public init(branch: String? = nil, commit: String? = nil, remote: String? = nil, composerLockCRC: String? = nil, composerLockSize: Int? = nil) {
        self.branch = branch
        self.commit = commit
        self.remote = remote
        self.composerLockCRC = composerLockCRC
        self.composerLockSize = composerLockSize
    }

    /// "main @ab12cd3", "@ab12cd3", or nil.
    public var summary: String? {
        let short = commit.map { "@" + $0.prefix(7) }
        switch (branch, short) {
        case (let branch?, let short?): return "\(branch) \(short)"
        case (let branch?, nil): return branch
        case (nil, let short?): return short
        default: return nil
        }
    }
}
