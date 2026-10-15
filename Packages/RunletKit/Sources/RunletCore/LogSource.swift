import Foundation

/// Where a log comes from (#20, #374). Building the source list never reads remote data.
public struct LogSource: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// A file on this Mac: in a local project, the sandbox, or a Docker profile's local folder
        /// (its bind mount). Read directly and followed with a file watcher; nothing runs.
        case hostFile(String)
        /// A file in a Docker or Kubernetes container, or an SSH profile's container step.
        /// Followed with exec and `tail -F` once the user clicks Follow.
        case containerFile(String)
        /// A file on an SSH host, followed with `ssh … tail -F` once the user clicks Follow.
        case serverFile(String)
        /// The container's output (`docker logs` or `kubectl logs`, with `--follow --tail 500`), once the user clicks Follow.
        case containerOutput
    }

    public enum Group: String, Sendable, CaseIterable {
        case thisMac = "On This Mac"
        case container = "In the Container"
        case server = "On the Server"
        case output = "Output"
    }

    public var kind: Kind
    /// `storage/logs/laravel.log`, `Container output`.
    public var title: String
    /// `412 KB · 2 min ago`, `From the driver's logPaths()`.
    public var detail: String?
    public var group: Group

    public init(kind: Kind, title: String, detail: String? = nil, group: Group) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.group = group
    }

    public var id: String {
        switch kind {
        case .hostFile(let path): "host:\(path)"
        case .containerFile(let path): "container:\(path)"
        case .serverFile(let path): "server:\(path)"
        case .containerOutput: "output"
        }
    }

    /// Read in a container or on a server: only after Follow.
    public var isRemote: Bool {
        if case .hostFile = kind { return false }
        return true
    }

    public var path: String? {
        switch kind {
        case .hostFile(let path), .containerFile(let path), .serverFile(let path): path
        case .containerOutput: nil
        }
    }

    /// "tail -F", "docker logs".
    public var commandName: String {
        switch kind {
        case .hostFile: "file watcher"
        case .containerFile, .serverFile: "tail -F"
        case .containerOutput: "docker logs"
        }
    }
}

extension LogSource {
    /// Remote sources never read a file or connect (#374). Kubernetes uses the same list as Docker.
    public static func remoteSources(base: String?, group: Group, hasContainer: Bool, hasHostFolder: Bool,
                                     driverPaths: [String], found: [String]?, otherPaths: [String], framework: String?,
                                     hostSources: [LogSource] = [], outputCommand: String = "docker logs") -> [LogSource] {
        var sources = hostSources
        if let base = base {
            var seen = Set<String>()
            func add(_ path: String, detail: String?) {
                let absolute = path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path)
                guard seen.insert(absolute).inserted else { return }
                let title = absolute.hasPrefix(base + "/") ? String(absolute.dropFirst(base.count + 1)) : absolute
                let kind: LogSource.Kind = group == .server ? .serverFile(absolute) : .containerFile(absolute)
                sources.append(LogSource(kind: kind, title: title, detail: detail, group: group))
            }
            // With a local folder (a Docker profile's bind mount), the project's logs are its files
            // above: the container lists only what Find Logs found and absolute paths typed.
            let defaults = !hasHostFolder
            if defaults {
                for path in driverPaths where !path.contains("*") { add(path, detail: "From the driver") }
            }
            for path in found ?? [] { add(path, detail: "Found") }
            for path in otherPaths where defaults || (path.hasPrefix("/") && !sources.contains { $0.path == path }) {
                add(path, detail: "Other path")
            }
            if defaults {
                for path in LogDiscovery.usualPaths(framework: framework) { add(path, detail: found == nil ? "If it exists" : nil) }
            }
        }
        if hasContainer {
            sources.append(LogSource(kind: .containerOutput, title: "Container output", detail: outputCommand, group: .output))
        }
        return Array(sources.dropFirst(hostSources.count))
    }
}
