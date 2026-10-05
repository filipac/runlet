import Foundation
import RunletCore

/// Runlet's runner kept on an SSH host (#48), so a run sends only its own request instead of
/// the whole runner (about 1.7 MB) on stdin.
///
/// With the profile's "Keep the runner and compiled PHP on the server"
/// (`SSHEndpoint.keepCompiledPHP`), stdin starts with a small loader that `php -n` runs before
/// the runner (`RemoteShell.runScript(…, runnerCache: true)`). It reads the rest of stdin and
/// writes the runner's program into a pipe to the runner's PHP, which reads it exactly as it
/// reads a streamed runner, so the runner, its output, and Stop work as without the cache:
///
/// - `.use`: stdin holds only the request. The loader reads `~/.cache/runlet/runner/<sha256>.php`
///   (a regular file, not a symlink, owned by the login, mode 0600 or stricter, in a folder of
///   the login's that isn't group- or world-writable, with the right size and SHA-256) and
///   writes it, then the request. Otherwise the runner's PHP gets `missProgram`, which exits 75.
/// - `.save`: stdin holds the runner, then the request. The loader checks the runner's SHA-256,
///   saves it (a temporary file in the same folder, then a rename), keeps the `keep` most
///   recently used runners, and writes the program. Saving never stops the run.
/// - `.stream`: no loader; the runner streams as without the cache.
///
/// The request (and a saved connection's password in it) is never written on the server.
/// `SSHRunnerAttempts` goes on to the next step when an attempt ends with a miss.
enum SSHRunnerCache {
    enum Step: String, Sendable {
        case use, save, stream
    }

    /// How many runners a server keeps: the most recently used.
    static let keep = 3
    /// `php -n -r` code that reads the loader from stdin: its length on the first line, then
    /// the code. No quotes or backslashes, so every login shell passes it unchanged.
    static let bootstrap = "eval(stream_get_contents(STDIN, (int) fgets(STDIN)));"
    static let missExitCode: Int32 = 75
    static let missMarker = "Runlet: runner cache miss"
    /// What the runner's PHP runs instead of the runner when the server has no valid copy, or
    /// when the loader failed (written by the shell then). No single quotes or backslashes.
    static let missProgram = #"<?php fwrite(STDERR, "\#(missMarker)" . PHP_EOL); exit(75);"#

    /// The server had no valid runner (or the loader failed): the process exited 75 and said so.
    static func isMiss(exitCode: Int32, stderr: String) -> Bool {
        exitCode == missExitCode && stderr.contains(missMarker)
    }

    /// stdin of a `.use` or `.save` attempt: the loader's length, the loader with this run's
    /// parameters, then the request (`.use`) or the runner and the request (`.save`).
    static func stdin(_ step: Step, bundle: RunnerBundle, request: Data) -> Data {
        var data = Data(capacity: (step == .save ? bundle.source.count : 0) + request.count + 4096)
        let loader = loader(step, bundle: bundle)
        data.append(Data("\(loader.count)\n".utf8))
        data.append(loader)
        if step == .save { data.append(bundle.source) }
        data.append(request)
        return data
    }

    static func loader(_ step: Step, bundle: RunnerBundle) -> Data {
        Data("$mode = '\(step == .save ? "save" : "use")'; $hash = '\(bundle.sha256)'; $size = \(bundle.source.count); $keep = \(keep);\n\(loaderBody)".utf8)
    }

    /// The loader (PHP 7.4 syntax; with `php -n` only core functions, PCRE, and hash exist).
    /// `$argv[1]` is the login's user ID (`id -u`).
    static let loaderBody = #"""
    $in = (string) stream_get_contents(STDIN);
    $out = fopen('php://stdout', 'wb');
    $miss = '\#(missProgram)';
    $uid = isset($argv[1]) && preg_match('/^[0-9]+$/', $argv[1]) ? (int) $argv[1] : -1;
    $home = (string) getenv('HOME');
    $dir = $uid >= 0 && $home !== '' && $home[0] === '/' && function_exists('hash') && in_array('sha256', hash_algos(), true)
        ? rtrim($home, '/') . '/.cache/runlet/runner' : '';
    $file = $dir . '/' . $hash . '.php';
    $private = function ($path, $follow) use ($uid) {
        clearstatcache();
        $s = $follow ? @stat($path) : @lstat($path);
        return is_array($s) && ($s['mode'] & 0170000) === 0040000 && $s['uid'] === $uid && ($s['mode'] & 0022) === 0;
    };
    if ($mode === 'use') {
        $runner = null;
        $link = $dir !== '' && $private(dirname($dir), true) && $private($dir, false) ? @lstat($file) : false;
        if (is_array($link) && ($link['mode'] & 0170000) === 0100000 && ($h = @fopen($file, 'rb')) !== false) {
            $s = fstat($h);
            if (is_array($s) && $s['ino'] === $link['ino'] && $s['dev'] === $link['dev'] && $s['uid'] === $uid
                && ($s['mode'] & 0077) === 0 && $s['size'] === $size) {
                $data = stream_get_contents($h);
                if (is_string($data) && strlen($data) === $size && hash_equals($hash, hash('sha256', $data))) {
                    $runner = $data;
                }
            }
            fclose($h);
        }
        if ($runner === null) {
            fwrite($out, $miss);
            exit(0);
        }
        if ($link['mtime'] < time() - 3600) {
            @touch($file);
        }
        fwrite($out, $runner);
        fwrite($out, $in);
        exit(0);
    }
    $runner = substr($in, 0, $size);
    if ($dir !== '' && strlen($runner) === $size && hash_equals($hash, hash('sha256', $runner))) {
        try {
            umask(077);
            if (!is_dir($dir)) {
                @mkdir($dir, 0700, true);
            }
            if ($private(dirname($dir), true) && $private($dir, false)
                && ($h = @fopen($tmp = $dir . '/.' . $hash . '.' . getmypid() . '.' . mt_rand() . '.tmp', 'xb')) !== false) {
                $ok = fwrite($h, $runner) === $size;
                $ok = fflush($h) && $ok;
                $ok = fclose($h) && $ok;
                if ($ok && @chmod($tmp, 0600) && @rename($tmp, $file)) {
                    $used = [];
                    foreach (@scandir($dir) ?: [] as $name) {
                        $s = @lstat($dir . '/' . $name);
                        if (!is_array($s)) {
                            continue;
                        }
                        if (preg_match('/^[0-9a-f]{64}\.php$/', $name)) {
                            $used[$dir . '/' . $name] = $s['mtime'];
                        } elseif (preg_match('/^\.[0-9a-f]{64}\.[0-9]+\.[0-9]+\.tmp$/', $name) && $s['mtime'] < time() - 600) {
                            @unlink($dir . '/' . $name);
                        }
                    }
                    arsort($used);
                    foreach (array_slice(array_keys($used), $keep) as $path) {
                        if ($path !== $file) {
                            @unlink($path);
                        }
                    }
                } else {
                    @unlink($tmp);
                }
            }
        } catch (\Throwable $e) {
        }
    }
    fwrite($out, $in);
    exit(0);
    """#
}

/// What one engine learned about its SSH hosts' runner caches (#48), per profile (the shared
/// connection's control path) and runner. It starts optimistic: the first run tries the cache,
/// since a server usually keeps the runner from an earlier session.
final class RunnerCacheMemory: @unchecked Sendable {
    /// How long a server that can't keep the runner, or whose loader failed, is skipped.
    static let pause: Duration = .seconds(600)

    private struct Entry {
        var hash: String
        /// When a `.save` attempt last started the runner, so the save was done.
        var savedAt: ContinuousClock.Instant?
        /// Until then, runs send the runner (`.save`) instead of trying the cache first.
        var sendUntil: ContinuousClock.Instant?
        /// Until then, runs stream without the loader.
        var streamUntil: ContinuousClock.Instant?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let clock: @Sendable () -> ContinuousClock.Instant

    init(clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.clock = clock
    }

    var now: ContinuousClock.Instant { clock() }

    /// The first attempt of a run on `key` with runner `hash`.
    func firstStep(key: String, hash: String) -> SSHRunnerCache.Step {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key], entry.hash == hash else { return .use }
        let now = clock()
        if let until = entry.streamUntil, now < until { return .stream }
        if let until = entry.sendUntil, now < until { return .save }
        return .use
    }

    /// The runner started from `step`'s attempt: the server had it (`.use`) or saved it (`.save`).
    func started(key: String, hash: String, step: SSHRunnerCache.Step) {
        update(key, hash) { entry, now in
            switch step {
            case .use:
                // The cache works: a later miss (the folder was cleared) isn't held against it.
                entry.sendUntil = nil
                entry.savedAt = nil
            case .save: entry.savedAt = now
            case .stream: break
            }
        }
    }

    /// `step`'s attempt, begun at `begun`, missed. A `.use` miss after a save that finished
    /// before it began, with no hit since, means the server doesn't keep the runner (a
    /// read-only home, a full disk): runs then send it for a while. A `.save` miss means the
    /// loader failed: runs stream.
    func missed(key: String, hash: String, step: SSHRunnerCache.Step, begun: ContinuousClock.Instant) {
        update(key, hash) { entry, now in
            switch step {
            case .use:
                if let saved = entry.savedAt, saved < begun { entry.sendUntil = now + Self.pause }
            case .save:
                entry.streamUntil = now + Self.pause
            case .stream: break
            }
        }
    }

    private func update(_ key: String, _ hash: String, _ change: (inout Entry, ContinuousClock.Instant) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var entry = entries[key].flatMap { $0.hash == hash ? $0 : nil } ?? Entry(hash: hash)
        change(&entry, clock())
        entries[key] = entry
    }
}

/// The attempts of one SSH run that may use the runner kept on the server (#48): `.use`, then
/// `.save`, then `.stream`, from the step `RunnerCacheMemory` chose. Each attempt but `.stream`
/// holds its output until the runner's first frame (`RunSession.pump`); one that ends with a
/// miss instead is replaced by the next, which `make` builds from the request kept here.
final class SSHRunnerAttempts: @unchecked Sendable {
    typealias Next = (spec: ProcessSpec, bytes: Int, log: RunLogEntry, note: String?)

    let memory: RunnerCacheMemory
    let key: String
    let hash: String
    private let make: @Sendable (SSHRunnerCache.Step, Data) -> ProcessSpec
    private let lock = NSLock()
    private var _step: SSHRunnerCache.Step
    private var begun: ContinuousClock.Instant
    /// The run's request, for a next attempt; it may hold a saved connection's password, so it
    /// is dropped as soon as no attempt can follow.
    private var request: Data?

    init(step: SSHRunnerCache.Step, request: Data, memory: RunnerCacheMemory, key: String, hash: String, make: @escaping @Sendable (SSHRunnerCache.Step, Data) -> ProcessSpec) {
        _step = step
        self.request = step == .stream ? nil : request
        self.memory = memory
        self.key = key
        self.hash = hash
        self.make = make
        begun = memory.now
    }

    var step: SSHRunnerCache.Step {
        lock.lock(); defer { lock.unlock() }
        return _step
    }

    /// Whether the current attempt's output waits for the runner's first frame.
    var holdsOutput: Bool { step != .stream }

    /// The current attempt's spec.
    func spec() -> ProcessSpec? {
        lock.lock(); defer { lock.unlock() }
        return request.map { make(_step, $0) }
    }

    /// The runner started: no other attempt follows.
    func started() {
        let step = finish()
        memory.started(key: key, hash: hash, step: step)
    }

    /// The attempt ended without the runner, and not with a miss (or Stop came first).
    func ended() {
        _ = finish()
    }

    /// The current attempt missed: the next one (its spec, stdin size, Run Log line, and the
    /// launch line's note), or nil when there is none.
    func next() -> Next? {
        lock.lock()
        let missed = _step
        let begunAt = begun
        guard missed != .stream, let request else {
            lock.unlock()
            return nil
        }
        let step: SSHRunnerCache.Step = missed == .use ? .save : .stream
        _step = step
        begun = memory.now
        if step == .stream { self.request = nil }
        lock.unlock()
        memory.missed(key: key, hash: hash, step: missed, begun: begunAt)
        let spec = make(step, request)
        let log = missed == .use
            ? RunLogEntry(source: "runner cache", message: "The server had no valid copy of Runlet's runner; sending it with this run", detail: "It is kept in ~/.cache/runlet/runner for the next runs.")
            : RunLogEntry(source: "runner cache", message: "The runner cache's loader failed on the server; sending the run without it", detail: "Runs on this profile stream the runner for the next 10 minutes.")
        return (spec, spec.standardInput?.count ?? 0, log, Self.note(step, hash: hash))
    }

    /// The Run Log's launch detail for `step`'s stdin, or nil for the usual one.
    static func note(_ step: SSHRunnerCache.Step, hash: String) -> String? {
        switch step {
        case .use: "the request; the runner (\(hash.prefix(12))) is read from ~/.cache/runlet/runner on the server"
        case .save: "the runner and the request; the server keeps the runner (\(hash.prefix(12))) in ~/.cache/runlet/runner"
        case .stream: nil
        }
    }

    private func finish() -> SSHRunnerCache.Step {
        lock.lock(); defer { lock.unlock() }
        request = nil
        return _step
    }
}
