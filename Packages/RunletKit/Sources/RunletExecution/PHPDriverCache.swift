import Foundation
import RunletCore

/// What each PHP on this Mac can open connections with (#184), read once. Discovery reads the
/// drivers of every installation it lists (`PHPInstallation.drivers`); a path it doesn't list (a
/// default PHP typed in Settings) is probed once, the first time a connection needs it. Both are
/// kept until the installations change (`update(installations:)`), so a run never probes.
public final class PHPDriverCache: @unchecked Sendable {
    private let lock = NSLock()
    private var listed: [String: PHPDrivers] = [:]
    private var listedPaths: Set<String> = []
    private var probes: [String: Task<PHPDrivers?, Never>] = [:]
    private var probed: [String: PHPDrivers] = [:]
    private var _probeCount = 0
    private let probe: @Sendable (String) async -> PHPDrivers?

    public init(probe: @escaping @Sendable (String) async -> PHPDrivers? = { await PHPDiscovery.drivers(executable: $0) }) {
        self.probe = probe
    }

    /// The installations changed (discovery ran again, Runlet's PHP was installed or removed):
    /// their drivers replace what was known, and paths probed before are probed again when needed.
    public func update(installations: [PHPInstallation]) {
        lock.lock(); defer { lock.unlock() }
        listed = [:]
        listedPaths = []
        for php in installations {
            listedPaths.insert(php.path)
            if let drivers = php.drivers { listed[php.path] = drivers }
        }
        probes.values.forEach { $0.cancel() }
        probes = [:]
        probed = [:]
    }

    /// What `path` has, if known now. Never runs PHP.
    public func known(_ path: String) -> PHPDrivers? {
        lock.lock(); defer { lock.unlock() }
        return listed[path] ?? probed[path]
    }

    /// How many probes ran since the cache was made (tests).
    public var probeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _probeCount
    }

    /// Reads the drivers of the `paths` discovery didn't list and that weren't probed since the
    /// installations last changed: one probe per path, shared by callers that ask at the same time.
    /// A listed installation whose check failed isn't probed again until discovery runs.
    public func prepare(_ paths: [String]) async {
        let waiting: [(String, Task<PHPDrivers?, Never>)] = lock.withLock {
            var waiting: [(String, Task<PHPDrivers?, Never>)] = []
            for path in Set(paths) where !listedPaths.contains(path) && probed[path] == nil {
                if let task = probes[path] {
                    waiting.append((path, task))
                } else {
                    let probe = self.probe
                    let task = Task { await probe(path) }
                    probes[path] = task
                    _probeCount += 1
                    waiting.append((path, task))
                }
            }
            return waiting
        }
        for (path, task) in waiting {
            let drivers = await task.value
            lock.withLock {
                // Kept only while the installations it was read for are current.
                if let drivers, probes[path] == task { probed[path] = drivers }
            }
        }
    }
}
