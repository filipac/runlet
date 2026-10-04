import Foundation

/// The connection a Run History entry ran on, or the one an SQL snippet opens on (#149). Only
/// names (and, for history, a saved connection's id): never a password or any other part of a
/// connection's definition.
///
/// - `application`: one the application configures, by name; nil is its default connection.
/// - `saved`: a saved connection (#138), by its name; history also keeps its id and whether it
///   was a connection of all targets (#142). Snippets keep only the name, so they move between
///   targets and Macs.
/// - `named`: a bare name from a project snippet (`-- @connection reporting`): a saved
///   connection with that name if there is one, else the application's connection.
public enum SQLConnectionReference: Sendable, Hashable, Codable {
    case application(String?)
    case saved(name: String, id: UUID? = nil, allTargets: Bool = false)
    case named(String)

    /// "Default connection", "reporting", "Reporting".
    public var title: String {
        switch self {
        case .application(let name): name ?? "Default connection"
        case .saved(let name, _, _), .named(let name): name
        }
    }

    /// The name, without the application's default connection (which has none).
    public var name: String? {
        switch self {
        case .application(let name): name
        case .saved(let name, _, _), .named(let name): name
        }
    }

    /// Groups history entries for the Connection filter and tells runs apart in history: a
    /// saved connection by its id (a renamed one stays one), else by kind and name.
    public var identity: String {
        switch self {
        case .application(let name): "app:" + (name ?? "")
        case .saved(let name, let id, _): id.map { "saved:" + $0.uuidString } ?? "saved-name:" + name.lowercased()
        case .named(let name): "named:" + name.lowercased()
        }
    }

    /// For a snippet: the name and kind only (no id), and nothing for the application's
    /// default connection, which every SQL tab starts on.
    public var forSnippet: SQLConnectionReference? {
        switch self {
        case .application(nil): nil
        case .application(let name?): name.isEmpty ? nil : .application(name)
        case .saved(let name, _, let allTargets): .saved(name: name, allTargets: allTargets)
        case .named(let name): name.isEmpty ? nil : .named(name)
        }
    }

    /// The reference to a saved connection, as history records it.
    public init(_ connection: DatabaseConnection) {
        self = .saved(name: connection.name, id: connection.id, allTargets: connection.isAllTargets)
    }

    /// "The connection “Reporting” from this entry no longer exists; using the default
    /// connection." — `source` is "entry" or "snippet".
    public static func missingNote(_ name: String, source: String) -> String {
        "The connection “\(name)” from this \(source) no longer exists; using the default connection."
    }

    // MARK: Codable

    private enum Kind: String, Codable {
        case application, saved, named
    }

    private enum CodingKeys: String, CodingKey {
        case kind, name, id, allTargets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decodeIfPresent(String.self, forKey: .name)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .application:
            self = .application(name?.isEmpty == false ? name : nil)
        case .saved:
            guard let name, !name.isEmpty else { throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "A saved connection reference needs a name.") }
            self = .saved(name: name, id: try? c.decodeIfPresent(UUID.self, forKey: .id), allTargets: (try? c.decodeIfPresent(Bool.self, forKey: .allTargets)) == true)
        case .named:
            guard let name, !name.isEmpty else { throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "A connection reference needs a name.") }
            self = .named(name)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .application(let name):
            try c.encode(Kind.application, forKey: .kind)
            try c.encodeIfPresent(name, forKey: .name)
        case .saved(let name, let id, let allTargets):
            try c.encode(Kind.saved, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(id, forKey: .id)
            if allTargets { try c.encode(true, forKey: .allTargets) }
        case .named(let name):
            try c.encode(Kind.named, forKey: .kind)
            try c.encode(name, forKey: .name)
        }
    }
}

/// What a history entry's or snippet's connection is on a target (#149).
public enum SQLConnectionResolution: Sendable, Equatable {
    /// An application connection by name; nil is the default connection.
    case application(String?)
    case saved(DatabaseConnection)
    /// The saved connection no longer exists for the target: the tab uses the default
    /// connection, and says so (`SQLConnectionReference.missingNote`).
    case missing(String)
}

extension TargetLibrary {
    /// Where a history entry or snippet opens (#149), on `target` (the tab's):
    ///
    /// - An application connection: its name, as recorded (application connection names come
    ///   from the application's configuration, so Runlet can't check them before a run).
    /// - A saved connection: by id when it belongs to `target` or to all targets, else by name,
    ///   the target's own first, then one of all targets (`databaseConnection(id:name:on:)`, the
    ///   rule workspaces use). Another target's own connection is never used. None: `missing`,
    ///   and the tab uses the default connection.
    /// - A bare name (`-- @connection reporting`): a saved connection with that name, looked up
    ///   the same way, else the application's connection with that name.
    /// #190: `family` keeps a tab on connections of its own kind (SQL or Redis).
    public func resolve(_ reference: SQLConnectionReference, on target: TargetRef, family: DatabaseFamily? = nil) -> SQLConnectionResolution {
        switch reference {
        case .application(let name):
            return .application(name)
        case .saved(let name, let id, _):
            return databaseConnection(id: id, name: name, on: target, family: family).map(SQLConnectionResolution.saved) ?? .missing(name)
        case .named(let name):
            return databaseConnection(id: nil, name: name, on: target, family: family).map(SQLConnectionResolution.saved) ?? .application(name)
        }
    }
}
