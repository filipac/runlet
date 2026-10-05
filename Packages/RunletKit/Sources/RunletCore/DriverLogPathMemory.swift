import Foundation

/// The `logPaths()` each target's project driver declared on its last command listing (#271),
/// kept across launches (in facts.json) so the Logs window shows the driver's log files without
/// listing the project's commands again. Keyed by `TargetRef.stableKey`.
public struct DriverLogPathMemory: Codable, Equatable, Sendable {
    /// Target key → the paths the driver declared, maybe none (it declared that it has none).
    public var paths: [String: [String]]

    public init(paths: [String: [String]] = [:]) {
        self.paths = paths
    }

    /// Remembers what a fresh listing declared. Returns whether anything changed (to save).
    /// A listing that didn't reach the driver's `logPaths()` changes nothing.
    @discardableResult
    public mutating func remember(_ catalog: ProjectCommandCatalog, for key: String) -> Bool {
        guard catalog.logPathsDeclared, paths[key] != catalog.logPaths else { return false }
        paths[key] = catalog.logPaths
        return true
    }

    /// The driver's paths for a target: the loaded listing's when it declared them, else the
    /// remembered ones.
    public func paths(for key: String, loaded catalog: ProjectCommandCatalog?) -> [String] {
        if let catalog, catalog.logPathsDeclared { return catalog.logPaths }
        return paths[key] ?? []
    }

    /// Whether Runlet knows what the target's driver declares (loaded now, or remembered).
    public func knows(_ key: String, loaded catalog: ProjectCommandCatalog?) -> Bool {
        catalog?.logPathsDeclared == true || paths[key] != nil
    }

    /// Forgets a target (it was removed).
    public mutating func forget(_ key: String) {
        paths[key] = nil
    }
}
