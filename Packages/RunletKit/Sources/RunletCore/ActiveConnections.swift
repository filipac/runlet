import Foundation

// MARK: - Connection Manager (#180)

/// What a Connection Manager row is. The order of the cases is the window's section order.
public enum ActiveConnectionKind: String, Sendable, Codable, CaseIterable, Comparable {
    /// An SSH profile's shared connection (an OpenSSH control master).
    case ssh
    /// A local forward on an SSH profile's shared connection, for a saved database connection (#143).
    case tunnel
    /// A database session held by running SQL work: a statement, Run All, Explain, Load Next,
    /// Load Schema, Show Definition, or a read of the Database pane's Server section.
    case database
    /// A PHP run in progress, on any target.
    case phpRun
    /// An AI client connected to Runlet's MCP server.
    case aiClient
    /// #20: a log the Logs window follows in a container or on a server (`docker logs`,
    /// `docker exec … tail -F`, `ssh … tail -F`). Read-only.
    case logFollow

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
    }

    /// The section's title in the Connection Manager.
    public var sectionTitle: String {
        switch self {
        case .ssh: "SSH Connections"
        case .tunnel: "SSH Tunnels"
        case .database: "Database Sessions"
        case .phpRun: "PHP Runs"
        case .aiClient: "AI Clients"
        case .logFollow: "Log Follows"
        }
    }

    /// The line under a section's title: what its rows are, and when they exist.
    public var sectionNote: String {
        switch self {
        case .ssh: "Shared connections that runs, shells, and tunnels on an SSH profile reuse."
        case .tunnel: "Local forwards on an SSH profile's shared connection, for saved database connections."
        case .database: "Open while a statement runs: Runlet opens a database connection per statement, in a fresh PHP process, and keeps no idle connections."
        case .phpRun: "Runs in progress, on every kind of target."
        case .aiClient: "AI clients connected to Runlet's MCP server. Disconnecting one doesn't turn the server off."
        case .logFollow: "Logs the Logs window follows in a container or on a server. They only read, and stop when the window closes."
        }
    }

    /// An SF Symbol for the kind.
    public var symbol: String {
        switch self {
        case .ssh: "server.rack"
        case .tunnel: "arrow.left.arrow.right"
        case .database: "cylinder.split.1x2"
        case .phpRun: "bolt.fill"
        case .aiClient: "sparkles"
        case .logFollow: "doc.text.magnifyingglass"
        }
    }

    /// "1 SSH connection", "3 database sessions".
    public func counted(_ count: Int) -> String {
        let (one, many): (String, String) = switch self {
        case .ssh: ("SSH connection", "SSH connections")
        case .tunnel: ("SSH tunnel", "SSH tunnels")
        case .database: ("database session", "database sessions")
        case .phpRun: ("PHP run", "PHP runs")
        case .aiClient: ("AI client", "AI clients")
        case .logFollow: ("log follow", "log follows")
        }
        return "\(count) \(count == 1 ? one : many)"
    }

    /// What Close does, for the button's help and the context menu.
    public var closeHelp: String {
        switch self {
        case .ssh: "Disconnect the shared connection (ssh -O exit), as the profile's Disconnect does."
        case .tunnel: "Cancel the forward (ssh -O cancel). The SSH connection stays."
        case .database: "Stop the work, as the tab's Stop does: the statement is cancelled on the server first when the database reported its session."
        case .phpRun: "Stop the run, as the tab's Stop does."
        case .aiClient: "Disconnect the client. Runlet's MCP server keeps listening, so the client's next call connects again."
        case .logFollow: "Stop following, as the Logs window's Stop does: the tail in the container or on the server ends too."
        }
    }
}

/// One row of the Connection Manager (#180): something Runlet has open right now. Built by the
/// app from state it already keeps (SSH control sockets on this Mac, tabs' runs, the database
/// work in progress, the MCP server's clients, #143's forwards); building one never connects,
/// reads, or runs anything. It holds no secrets: the list removes passwords and tokens from
/// every text (`ConnectionText.redacted`), and the app never puts one in.
public struct ActiveConnection: Identifiable, Sendable, Equatable {
    /// Stable while the connection exists: `ssh:<profile>`, `tunnel:<connection>`, `run:<tab>`,
    /// `work:<id>`, `mcp:<client>`.
    public var id: String
    public var kind: ActiveConnectionKind
    /// What it is: a profile's name, a statement's first line, a run's first line, a client's name.
    public var title: String
    /// Where it goes: `deploy@bastion`, `127.0.0.1:53012 → db.internal:5432`, `mysql · shop on …`.
    public var destination: String
    /// Which tab or feature uses it.
    public var owner: String?
    /// The tab it belongs to, for Reveal Tab.
    public var ownerTabId: UUID?
    /// Since when; nil while it is still being prepared.
    public var startedAt: Date?
    /// The target's (or the saved connection's) environment marking.
    public var environment: TargetEnvironment
    /// Facts worth a glance: the database session's id, a client's calls, how a login closes.
    public var details: [String]
    /// The ids of the connections it runs over (an SSH master, a tunnel): closing one of those
    /// ends this one too.
    public var via: [String]
    /// SSH: the login used a password or a one-time code, so reconnecting asks for it again.
    public var needsLoginToReconnect: Bool
    /// How many runs its own bookkeeping says hold it now (a tunnel's leases, #143), counting
    /// ones the list doesn't show (Test Connection, Stop's cancel runner).
    public var inUseBy: Int
    /// A Close (Stop, Disconnect) is under way.
    public var isClosing: Bool
    /// #183: a run waiting for a free run slot (`RunSlots`). It has opened nothing yet, so it is
    /// listed but never counted, and isn't among the users of the connections in `via`;
    /// `startedAt` is when it joined the queue.
    public var isQueued: Bool
    /// A queued run's place: 1 is the next to start; nil when unknown.
    public var queuePosition: Int?

    public init(id: String, kind: ActiveConnectionKind, title: String, destination: String, owner: String? = nil, ownerTabId: UUID? = nil, startedAt: Date? = nil, environment: TargetEnvironment = .development, details: [String] = [], via: [String] = [], needsLoginToReconnect: Bool = false, inUseBy: Int = 0, isClosing: Bool = false, isQueued: Bool = false, queuePosition: Int? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.destination = destination
        self.owner = owner
        self.ownerTabId = ownerTabId
        self.startedAt = startedAt
        self.environment = environment
        self.details = details
        self.via = via
        self.needsLoginToReconnect = needsLoginToReconnect
        self.inUseBy = inUseBy
        self.isClosing = isClosing
        self.isQueued = isQueued
        self.queuePosition = queuePosition
    }

    public var isProduction: Bool { environment == .production }

    /// The row of a run with the engine's view of it (#183): queued since it joined the queue,
    /// or running since it got its slot (so "since" restarts at the actual start). nil (the
    /// engine doesn't know the run yet, or no longer) leaves the row as it is.
    public func withSlot(_ state: RunSlots.State?) -> ActiveConnection {
        guard let state else { return self }
        var copy = self
        switch state {
        case .queued(let position, let since):
            copy.isQueued = true
            copy.queuePosition = position
            copy.startedAt = since
        case .running(let since):
            copy.isQueued = false
            copy.queuePosition = nil
            copy.startedAt = since
        }
        return copy
    }

    /// "2nd in line. Waits for a free run slot; nothing is open yet." for a queued row.
    public var queueNote: String? {
        guard isQueued else { return nil }
        let place = queuePosition.map { ConnectionText.queuePlace($0) }.map { $0.prefix(1).uppercased() + $0.dropFirst() + ". " } ?? ""
        return place + "Waits for a free run slot; nothing is open yet."
    }

    /// Close's help: a queued run leaves the queue, and nothing reaches a server.
    public var closeHelp: String {
        isQueued ? "Remove it from the queue. It hasn't started, so nothing is sent to a server." : kind.closeHelp
    }

    /// The same row with every text passed through `ConnectionText.redacted`.
    public var redacted: ActiveConnection {
        var copy = self
        copy.title = ConnectionText.redacted(title)
        copy.destination = ConnectionText.redacted(destination)
        copy.owner = owner.map(ConnectionText.redacted)
        copy.details = details.map(ConnectionText.redacted)
        return copy
    }
}

/// What Close asks before it acts (#180). Only an SSH connection that carries work (runs,
/// statements, tunnels) or needs a password or 2FA login again, and a tunnel a statement is
/// using, ask; stopping a run,
/// stopping a statement, and disconnecting an AI client never do. Closing never asks the
/// production question: ending something is always allowed.
public struct ActiveConnectionCloseConfirmation: Sendable, Equatable {
    public var title: String
    public var message: String
    /// The confirming button: "Disconnect", "Close Tunnel".
    public var button: String

    public init(title: String, message: String, button: String) {
        self.title = title
        self.message = message
        self.button = button
    }
}

/// Every active connection at one moment, grouped and counted (#180): the status bar item's
/// count and tooltip, and the Connection Manager's sections. Pure: the app passes in what its
/// providers report.
public struct ActiveConnectionList: Sendable, Equatable {
    public struct Group: Sendable, Equatable, Identifiable {
        public var kind: ActiveConnectionKind
        /// Active rows first, then queued runs (#183) in the order they start.
        public var items: [ActiveConnection]
        public var id: ActiveConnectionKind { kind }

        /// The rows that count: not queued.
        public var activeCount: Int { items.lazy.filter { !$0.isQueued }.count }
        public var queuedCount: Int { items.lazy.filter(\.isQueued).count }

        /// "4 PHP runs, 1 queued", "4 PHP runs", or "1 PHP run queued".
        public var countText: String {
            let queued = queuedCount
            guard queued > 0 else { return kind.counted(activeCount) }
            return activeCount == 0 ? "\(kind.counted(queued)) queued" : "\(kind.counted(activeCount)), \(queued) queued"
        }
    }

    /// Sorted: by kind (the section order), then active rows oldest first and queued runs in the
    /// order they start (#183), then by title.
    public let items: [ActiveConnection]

    /// Redacts every text, drops repeated ids (the first one stays), and sorts.
    public init(_ items: [ActiveConnection]) {
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.id).inserted }.map(\.redacted)
        self.items = unique.sorted { a, b in
            if a.kind != b.kind { return a.kind < b.kind }
            if a.isQueued != b.isQueued { return !a.isQueued }
            if a.isQueued, let x = a.queuePosition, let y = b.queuePosition, x != y { return x < y }
            switch (a.startedAt, b.startedAt) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            if a.title != b.title { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
            return a.id < b.id
        }
    }

    public static let empty = ActiveConnectionList([])

    /// Nothing is listed, active or queued.
    public var isEmpty: Bool { items.isEmpty }
    /// Active connections: queued runs (#183) have opened nothing, so they don't count.
    public var count: Int { items.lazy.filter { !$0.isQueued }.count }
    /// Runs waiting for a free run slot (#183).
    public var queuedCount: Int { items.lazy.filter(\.isQueued).count }

    public func count(of kind: ActiveConnectionKind) -> Int {
        items.lazy.filter { $0.kind == kind && !$0.isQueued }.count
    }

    /// The non-empty sections, in order.
    public var groups: [Group] {
        ActiveConnectionKind.allCases.compactMap { kind in
            let members = items.filter { $0.kind == kind }
            return members.isEmpty ? nil : Group(kind: kind, items: members)
        }
    }

    public func item(_ id: String) -> ActiveConnection? {
        items.first { $0.id == id }
    }

    /// The connections that run over `id` (an SSH master's runs and tunnels, a tunnel's
    /// statements). A queued run (#183) doesn't use it yet, and doesn't end with it.
    public func users(of id: String) -> [ActiveConnection] {
        items.filter { $0.via.contains(id) && !$0.isQueued }
    }

    /// "2 PHP runs and 1 SSH tunnel": what uses `id`; nil when nothing does.
    public func usage(of id: String) -> String? {
        let users = users(of: id)
        guard !users.isEmpty else { return nil }
        let parts = ActiveConnectionKind.allCases.compactMap { kind -> String? in
            let count = users.lazy.filter { $0.kind == kind }.count
            return count == 0 ? nil : kind.counted(count)
        }
        return ConnectionText.list(parts)
    }

    /// "3 active connections", or "No active connections"; "8 active connections, 1 run
    /// queued" while runs wait for a slot (#183).
    public var summary: String {
        let active = switch count {
        case 0: "No active connections"
        case 1: "1 active connection"
        default: "\(count) active connections"
        }
        let queued = queuedCount
        return queued == 0 ? active : "\(active), \(queued) run\(queued == 1 ? "" : "s") queued"
    }

    /// The status bar item's tooltip: the counts per kind, one per line, and how to open the
    /// window. While runs wait for a slot (#183) it starts "8 active, 1 queued".
    public var tooltip: String {
        guard !isEmpty else { return "No active connections. Click for the Connection Manager." }
        let lines = groups.map(\.countText)
        let queued = queuedCount
        guard queued > 0 else {
            return (["Active connections:"] + lines + ["Click for the Connection Manager."]).joined(separator: "\n")
        }
        return (["\(count) active, \(queued) queued:"] + lines + ["Queued runs wait for a free run slot and open nothing until they start.", "Click for the Connection Manager."]).joined(separator: "\n")
    }

    /// What Close on `id` asks first, or nil when it acts at once.
    public func closeConfirmation(for id: String) -> ActiveConnectionCloseConfirmation? {
        guard let item = item(id) else { return nil }
        switch item.kind {
        case .ssh:
            let usage = usage(of: id)
            guard usage != nil || item.needsLoginToReconnect else { return nil }
            var message: [String] = []
            if let usage {
                let users = users(of: id).count
                message.append("\(usage) \(users == 1 ? "uses" : "use") this connection and \(users == 1 ? "ends" : "end") with it.")
            }
            if item.needsLoginToReconnect {
                message.append("Its login used a password or a one-time code: to connect again, you'll have to log in again with Connect….")
            }
            return ActiveConnectionCloseConfirmation(title: "Disconnect from “\(item.title)”?", message: message.joined(separator: " "), button: "Disconnect")
        case .tunnel:
            let users = max(users(of: id).count, item.inUseBy)
            guard users > 0 else { return nil }
            let what = users == 1 ? "A statement is using this tunnel; it ends with it." : "\(users) statements are using this tunnel; they end with it."
            return ActiveConnectionCloseConfirmation(title: "Close the tunnel to \(item.destination)?", message: what + " The SSH connection stays.", button: "Close Tunnel")
        case .database, .phpRun, .aiClient, .logFollow:
            return nil
        }
    }
}

/// Texts for Connection Manager rows (#180).
public enum ConnectionText {
    /// `text` without secrets: the password of `user:password@host` (in URLs and DSNs) and the
    /// values of password, token, secret, and key parameters (`password=…`, `pwd=…`) become
    /// •••, as do SQL's `IDENTIFIED BY '…'` and `PASSWORD '…'`. Host names, ports, user names,
    /// and database names stay.
    public static func redacted(_ text: String) -> String {
        var result = text
        for (pattern, template) in redactions {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }

    private static let redactions: [(String, String)] = [
        // scheme://user:password@host → scheme://user:•••@host
        (#"(://[^:/@\s]+):[^@/\s]+@"#, "$1:•••@"),
        // user:password@host without a scheme
        (#"(^|[\s(=,;])([^\s:/@(=,;]+):[^@\s/]+@"#, "$1$2:•••@"),
        // password=…; pwd=… token=… (DSNs, query strings, PDO options)
        (#"\b(password|passwd|pwd|pass|token|secret|api[_-]?key|access[_-]?key|auth)(\s*[=:]\s*)("[^"]*"|'[^']*'|[^;&\s,)]+)"#, "$1$2•••"),
        // MySQL: IDENTIFIED BY 'secret' / IDENTIFIED WITH plugin BY 'secret'
        (#"(IDENTIFIED\b[^']*?\bBY\s+)('[^']*'|"[^"]*")"#, "$1'•••'"),
        // PostgreSQL: PASSWORD 'secret'; MySQL: PASSWORD('secret')
        (#"(\bPASSWORD\s*\(?\s*)('[^']*'|"[^"]*")"#, "$1'•••'"),
    ]

    /// The first line of code worth showing: not blank, not `<?php`, and not a comment (`--`,
    /// `//`, `#`, `/* … */`) unless there is nothing else; shortened to `limit`.
    public static func firstLine(of code: String, limit: Int = 80) -> String {
        let lines = code.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.lowercased() != "<?php" && $0 != "?>" }
        let line = lines.first { !isComment($0) } ?? lines.first ?? ""
        return shortened(line, limit: limit)
    }

    private static func isComment(_ line: String) -> Bool {
        line.hasPrefix("--") || line.hasPrefix("//") || line.hasPrefix("/*") || line.hasPrefix("*")
            || (line.hasPrefix("#") && !line.hasPrefix("#["))
    }

    /// `text` cut to `limit` characters with an ellipsis.
    public static func shortened(_ text: String, limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    /// How long ago `date` was, compactly: "12 s", "3 min", "1 h 4 min", "2 d 3 h".
    public static func elapsed(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) min" }
        let days = hours / 24
        return hours % 24 == 0 ? "\(days) d" : "\(days) d \(hours % 24) h"
    }

    /// A queued run's place (#183): "next to start", "2nd in line", "3rd in line".
    public static func queuePlace(_ position: Int) -> String {
        position <= 1 ? "next to start" : "\(ordinal(position)) in line"
    }

    /// "1st", "2nd", "3rd", "4th", "11th", "22nd".
    public static func ordinal(_ number: Int) -> String {
        let suffix = switch (number % 100, number % 10) {
        case (11...13, _): "th"
        case (_, 1): "st"
        case (_, 2): "nd"
        case (_, 3): "rd"
        default: "th"
        }
        return "\(number)\(suffix)"
    }

    /// "a", "a and b", "a, b, and c".
    public static func list(_ parts: [String]) -> String {
        switch parts.count {
        case 0: ""
        case 1: parts[0]
        case 2: "\(parts[0]) and \(parts[1])"
        default: parts.dropLast().joined(separator: ", ") + ", and " + parts[parts.count - 1]
        }
    }
}

/// Rows whose texts depend only on what a subsystem reports (#180): SSH shared connections,
/// SSH tunnels (#143), and AI clients. The app's providers fill these in from their state.
public enum ConnectionRows {
    /// A tab that uses a connection.
    public struct OwnerTab: Sendable, Equatable {
        public var id: UUID
        public var title: String

        public init(id: UUID, title: String) {
            self.id = id
            self.title = title
        }
    }

    public static func sshId(_ profileId: UUID) -> String { "ssh:\(profileId)" }
    public static func tunnelId(_ connectionId: UUID) -> String { "tunnel:\(connectionId)" }
    public static func aiClientId(_ connectionId: UUID) -> String { "mcp:\(connectionId)" }

    /// "Tab “Orders”", "3 tabs", or `fallback` without tabs; the tab's id when there is one.
    static func owner(_ tabs: [OwnerTab], fallback: String?) -> (String?, UUID?) {
        switch tabs.count {
        case 0: (fallback, nil)
        case 1: ("Tab “\(tabs[0].title)”", tabs[0].id)
        default: ("\(tabs.count) tabs", nil)
        }
    }

    /// An SSH profile's shared connection (control master).
    public struct SSHMaster: Sendable, Equatable {
        public var profileId: UUID
        public var name: String
        /// `deploy@bastion.example.com:2222`.
        public var destination: String
        /// A password, keyboard-interactive, or 2FA login (Connect…).
        public var interactive: Bool
        /// Agent and key logins: minutes it stays unused; nil until Runlet quits.
        public var keepAliveMinutes: Int?
        public var jumpHost: String?
        public var environment: TargetEnvironment
        /// When the control socket appeared.
        public var openedAt: Date?
        /// Tabs on the profile.
        public var tabs: [OwnerTab]

        public init(profileId: UUID, name: String, destination: String, interactive: Bool, keepAliveMinutes: Int? = nil, jumpHost: String? = nil, environment: TargetEnvironment = .development, openedAt: Date? = nil, tabs: [OwnerTab] = []) {
            self.profileId = profileId
            self.name = name
            self.destination = destination
            self.interactive = interactive
            self.keepAliveMinutes = keepAliveMinutes
            self.jumpHost = jumpHost
            self.environment = environment
            self.openedAt = openedAt
            self.tabs = tabs
        }
    }

    public static func ssh(_ master: SSHMaster) -> ActiveConnection {
        let login = master.interactive
            ? "Password or 2FA login (Connect…); stays until you disconnect"
            : master.keepAliveMinutes.map { "Agent or key login; closes after \($0) min unused, or when Runlet quits" } ?? "Agent or key login; closes when Runlet quits"
        var details = [login]
        if let jump = master.jumpHost, !jump.isEmpty { details.append("Through \(jump)") }
        let (owner, tab) = owner(master.tabs, fallback: nil)
        return ActiveConnection(id: sshId(master.profileId), kind: .ssh, title: master.name, destination: master.destination, owner: owner, ownerTabId: tab,
                                startedAt: master.openedAt, environment: master.environment, details: details, needsLoginToReconnect: master.interactive)
    }

    /// A local forward on an SSH profile's shared connection, for a saved connection (#143).
    public struct Tunnel: Sendable, Equatable {
        public var connectionId: UUID
        public var connectionName: String
        public var profileId: UUID
        public var profileName: String
        public var localPort: Int
        public var remoteHost: String
        public var remotePort: Int
        public var openedAt: Date
        public var lastUsedAt: Date
        /// Runs holding the forward now.
        public var leases: Int
        /// The stricter of the saved connection's and the profile's markings.
        public var environment: TargetEnvironment
        /// SQL tabs on the saved connection.
        public var tabs: [OwnerTab]
        /// How long it stays unused.
        public var idleTimeout: Duration

        public init(connectionId: UUID, connectionName: String, profileId: UUID, profileName: String, localPort: Int, remoteHost: String, remotePort: Int, openedAt: Date, lastUsedAt: Date, leases: Int, environment: TargetEnvironment = .development, tabs: [OwnerTab] = [], idleTimeout: Duration = .seconds(300)) {
            self.connectionId = connectionId
            self.connectionName = connectionName
            self.profileId = profileId
            self.profileName = profileName
            self.localPort = localPort
            self.remoteHost = remoteHost
            self.remotePort = remotePort
            self.openedAt = openedAt
            self.lastUsedAt = lastUsedAt
            self.leases = leases
            self.environment = environment
            self.tabs = tabs
            self.idleTimeout = idleTimeout
        }
    }

    /// Only the forward's host and ports, never the connection's user or password.
    public static func tunnel(_ tunnel: Tunnel) -> ActiveConnection {
        let host = tunnel.remoteHost.contains(":") && !tunnel.remoteHost.hasPrefix("[") ? "[\(tunnel.remoteHost)]" : tunnel.remoteHost
        let idle = ConnectionText.elapsed(since: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: Double(tunnel.idleTimeout.components.seconds)))
        var details = ["On \(tunnel.profileName)'s shared connection", "Last used \(tunnel.lastUsedAt.formatted(date: .omitted, time: .standard))"]
        details.append(tunnel.leases > 0 ? "In use by \(tunnel.leases) run\(tunnel.leases == 1 ? "" : "s")" : "Unused; closes after \(idle) unused")
        let (owner, tab) = owner(tunnel.tabs, fallback: "Saved connection “\(tunnel.connectionName)”")
        return ActiveConnection(id: tunnelId(tunnel.connectionId), kind: .tunnel, title: tunnel.connectionName,
                                destination: "127.0.0.1:\(tunnel.localPort) → \(host):\(tunnel.remotePort) through \(tunnel.profileName)",
                                owner: owner, ownerTabId: tab, startedAt: tunnel.openedAt, environment: tunnel.environment, details: details,
                                via: [sshId(tunnel.profileId)], inUseBy: tunnel.leases)
    }

    /// An AI client connected to Runlet's MCP server (#43).
    public struct AIClient: Sendable, Equatable {
        public var connectionId: UUID
        /// What the client calls itself (its title, else its name).
        public var name: String
        public var version: String?
        public var connectedAt: Date
        public var calls: Int
        /// `runlet mcp`'s process.
        public var helperPID: Int32?
        /// The targets whose runs the user allowed for this session (#326), by label.
        public var allowedTargets: [String]
        /// The tab its runs use.
        public var tab: OwnerTab?

        public init(connectionId: UUID, name: String, version: String? = nil, connectedAt: Date, calls: Int = 0, helperPID: Int32? = nil, allowedTargets: [String] = [], tab: OwnerTab? = nil) {
            self.connectionId = connectionId
            self.name = name
            self.version = version
            self.connectedAt = connectedAt
            self.calls = calls
            self.helperPID = helperPID
            self.allowedTargets = allowedTargets
            self.tab = tab
        }
    }

    public static func aiClient(_ client: AIClient) -> ActiveConnection {
        var details = ["\(client.calls) call\(client.calls == 1 ? "" : "s")"]
        if let version = client.version { details.append("Version \(version)") }
        if let pid = client.helperPID { details.append("runlet mcp, process \(pid)") }
        if !client.allowedTargets.isEmpty { details.append("Runs allowed for this session: " + client.allowedTargets.joined(separator: ", ")) }
        return ActiveConnection(id: aiClientId(client.connectionId), kind: .aiClient, title: client.name, destination: "Runlet's MCP server on this Mac",
                                owner: client.tab.map { "Runs in tab “\($0.title)”" }, ownerTabId: client.tab?.id, startedAt: client.connectedAt, details: details)
    }
}
