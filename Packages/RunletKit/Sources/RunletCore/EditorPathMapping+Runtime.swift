import Foundation

extension EditorPathMapping {
    /// Where the target's PHP sees the host file `hostPath` (#22): the container or server
    /// path of a file in the profile's local folder. Nil for host targets (the paths are the
    /// same), without a local folder, or for a file outside it. The inverse of `resolve`.
    public func runtimePath(forHostPath hostPath: String) -> String? {
        guard hostPath.hasPrefix("/") else { return nil }
        let path = Self.normalize(hostPath)
        func relative(to root: String) -> String? {
            let root = Self.normalize(root)
            if root == "/" { return path }
            if path == root { return "" }
            return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count)) : nil
        }
        func join(_ root: String, _ relative: String) -> String {
            let root = Self.normalize(root)
            if relative.isEmpty { return root }
            return root == "/" ? relative : root + relative
        }
        switch kind {
        case .host:
            return nil
        case .container(let containerRoot, let hostRoot):
            guard let hostRoot, let rest = relative(to: hostRoot) else { return nil }
            return join(containerRoot, rest)
        case .remote(let remoteRoots, let localRoot, _):
            // The profile's own directory (the first root), not a release it resolved to.
            guard let localRoot, let first = remoteRoots.first, let rest = relative(to: localRoot) else { return nil }
            return join(first, rest)
        }
    }

    /// Where the target runs, for labels ("the container", "forge@example.com"); nil for this Mac.
    public var runtimeLocationName: String? {
        switch kind {
        case .host: nil
        case .container: "the container"
        case .remote(_, _, let host): host
        }
    }
}
