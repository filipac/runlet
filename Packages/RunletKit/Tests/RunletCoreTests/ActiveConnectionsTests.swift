import Foundation
@testable import RunletCore
import Testing

/// The Connection Manager's list (#180): aggregation, ordering and grouping, counts, what uses
/// what, Close's confirmations, and that no secret reaches a row's text.
struct ActiveConnectionsTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    private var sample: [ActiveConnection] {
        [
            ActiveConnection(id: "mcp:1", kind: .aiClient, title: "Claude Code", destination: "Runlet's MCP server", startedAt: at(5)),
            ActiveConnection(id: "run:b", kind: .phpRun, title: "sleep(60);", destination: "bastion · deploy@bastion", owner: "Tab “B”", startedAt: at(30), via: ["ssh:bastion"]),
            ActiveConnection(id: "run:a", kind: .phpRun, title: "sleep(60);", destination: "Sandbox", owner: "Tab “A”", startedAt: at(20)),
            ActiveConnection(id: "ssh:bastion", kind: .ssh, title: "bastion", destination: "deploy@bastion", startedAt: at(1), environment: .production, needsLoginToReconnect: true),
            ActiveConnection(id: "ssh:acme", kind: .ssh, title: "acme", destination: "acme", startedAt: at(2)),
            ActiveConnection(id: "tunnel:reports", kind: .tunnel, title: "reports", destination: "127.0.0.1:53012 → db.internal:5432", startedAt: at(3), via: ["ssh:bastion"]),
            ActiveConnection(id: "run:sql", kind: .database, title: "SELECT SLEEP(60)", destination: "mysql · shop", owner: "Tab “Orders”", via: ["tunnel:reports", "ssh:bastion"]),
            ActiveConnection(id: "work:schema", kind: .database, title: "Load Schema", destination: "pgsql · shop", owner: "Database pane", startedAt: at(40)),
        ]
    }

    @Test func groupsInSectionOrderOldestFirst() {
        let list = ActiveConnectionList(sample)
        #expect(list.groups.map(\.kind) == [.ssh, .tunnel, .database, .phpRun, .aiClient])
        #expect(list.items.map(\.id) == ["ssh:bastion", "ssh:acme", "tunnel:reports", "work:schema", "run:sql", "run:a", "run:b", "mcp:1"])
        // Work still being prepared (no start yet) comes after work that started.
        #expect(list.groups[2].items.map(\.id) == ["work:schema", "run:sql"])
    }

    @Test func emptyGroupsAreLeftOut() {
        let list = ActiveConnectionList([ActiveConnection(id: "run:a", kind: .phpRun, title: "x", destination: "Sandbox")])
        #expect(list.groups.map(\.kind) == [.phpRun])
        #expect(ActiveConnectionList.empty.groups.isEmpty)
        #expect(ActiveConnectionList.empty.isEmpty)
    }

    @Test func repeatedIdsKeepTheFirst() {
        let list = ActiveConnectionList([
            ActiveConnection(id: "ssh:a", kind: .ssh, title: "first", destination: "a"),
            ActiveConnection(id: "ssh:a", kind: .ssh, title: "second", destination: "a"),
        ])
        #expect(list.count == 1)
        #expect(list.items.first?.title == "first")
    }

    @Test func countsPerKindAndSummary() {
        let list = ActiveConnectionList(sample)
        #expect(list.count == 8)
        #expect(list.count(of: .ssh) == 2)
        #expect(list.count(of: .tunnel) == 1)
        #expect(list.count(of: .database) == 2)
        #expect(list.count(of: .phpRun) == 2)
        #expect(list.count(of: .aiClient) == 1)
        #expect(list.summary == "8 active connections")
        #expect(ActiveConnectionList(Array(sample.prefix(1))).summary == "1 active connection")
        #expect(ActiveConnectionList.empty.summary == "No active connections")
    }

    @Test func tooltipListsTheCountsPerKind() {
        let tooltip = ActiveConnectionList(sample).tooltip
        #expect(tooltip == "Active connections:\n2 SSH connections\n1 SSH tunnel\n2 database sessions\n2 PHP runs\n1 AI client\nClick for the Connection Manager.")
        #expect(ActiveConnectionList.empty.tooltip.hasPrefix("No active connections"))
    }

    @Test func usersAndUsage() {
        let list = ActiveConnectionList(sample)
        #expect(Set(list.users(of: "ssh:bastion").map(\.id)) == ["run:b", "tunnel:reports", "run:sql"])
        #expect(list.usage(of: "ssh:bastion") == "1 SSH tunnel, 1 database session, and 1 PHP run")
        #expect(list.usage(of: "tunnel:reports") == "1 database session")
        #expect(list.usage(of: "ssh:acme") == nil)
    }

    @Test func sshCloseAsksWhenItCarriesWorkOrNeedsALoginAgain() throws {
        let list = ActiveConnectionList(sample)
        // Carries a run, a tunnel, and a statement, and its login used a password or 2FA.
        let bastion = try #require(list.closeConfirmation(for: "ssh:bastion"))
        #expect(bastion.title == "Disconnect from “bastion”?")
        #expect(bastion.button == "Disconnect")
        #expect(bastion.message.contains("1 SSH tunnel, 1 database session, and 1 PHP run use this connection and end with it."))
        #expect(bastion.message.contains("log in again"))
        // An agent or key login that carries nothing: no question.
        #expect(list.closeConfirmation(for: "ssh:acme") == nil)

        // A password login that carries nothing still asks: reconnecting needs the login.
        let idle = ActiveConnectionList([ActiveConnection(id: "ssh:p", kind: .ssh, title: "p", destination: "p", needsLoginToReconnect: true)])
        let confirmation = try #require(idle.closeConfirmation(for: "ssh:p"))
        #expect(!confirmation.message.contains("use this connection"))
        #expect(confirmation.message.contains("log in again"))

        // One run: singular.
        let one = ActiveConnectionList([
            ActiveConnection(id: "ssh:k", kind: .ssh, title: "k", destination: "k"),
            ActiveConnection(id: "run:x", kind: .phpRun, title: "x", destination: "k", via: ["ssh:k"]),
        ])
        #expect(one.closeConfirmation(for: "ssh:k")?.message == "1 PHP run uses this connection and ends with it.")
    }

    @Test func tunnelCloseAsksOnlyWhileAStatementUsesIt() throws {
        let list = ActiveConnectionList(sample)
        let tunnel = try #require(list.closeConfirmation(for: "tunnel:reports"))
        #expect(tunnel.button == "Close Tunnel")
        #expect(tunnel.message.hasPrefix("A statement is using this tunnel"))
        let unused = ActiveConnectionList([ActiveConnection(id: "tunnel:t", kind: .tunnel, title: "t", destination: "127.0.0.1:1 → db:5432")])
        #expect(unused.closeConfirmation(for: "tunnel:t") == nil)
    }

    @Test func runsStatementsAndClientsNeverAskEvenOnProduction() {
        var items = sample
        for index in items.indices { items[index].environment = .production }
        let list = ActiveConnectionList(items)
        for id in ["run:a", "run:b", "run:sql", "work:schema", "mcp:1"] {
            #expect(list.closeConfirmation(for: id) == nil, "\(id)")
        }
        #expect(list.closeConfirmation(for: "missing") == nil)
        // Production is shown, never asked about.
        #expect(list.items.allSatisfy { $0.isProduction })
        #expect(list.closeConfirmation(for: "ssh:acme") == nil)
    }

    @Test func noSecretsInRowText() {
        let leaky = ActiveConnection(
            id: "work:x", kind: .database,
            title: "CREATE USER 'app'@'%' IDENTIFIED BY 'hunter2'",
            destination: "pgsql:host=db;port=5432;dbname=shop;user=app;password=hunter2",
            owner: "mysql://root:hunter2@db.internal:3306/shop",
            details: ["ALTER ROLE app WITH PASSWORD 'hunter2'", "token=abc123def", "root:hunter2@db:3306", "SET PASSWORD = PASSWORD('hunter2')", "api_key: \"hunter2\""]
        )
        let row = ActiveConnectionList([leaky]).items[0]
        let texts = [row.title, row.destination, row.owner ?? ""] + row.details
        for text in texts {
            #expect(!text.contains("hunter2"), "\(text)")
            #expect(!text.contains("abc123def"), "\(text)")
        }
        // What isn't secret stays.
        #expect(row.destination.contains("host=db;port=5432;dbname=shop;user=app"))
        #expect(row.owner == "mysql://root:•••@db.internal:3306/shop")
        #expect(row.details[2] == "root:•••@db:3306")
    }

    @Test func redactionLeavesOrdinaryTextAlone() {
        for text in ["deploy@bastion", "127.0.0.1:53012 → db.internal:5432", "SELECT SLEEP(60)", "mysql · shop on the default connection of acme", "SELECT password FROM users", "user@host:22"] {
            #expect(ConnectionText.redacted(text) == text, "\(text)")
        }
        #expect(ConnectionText.redacted("WHERE password = 'x'") == "WHERE password = •••")
    }

    @Test func firstLineSkipsTheOpeningTagAndBlankLines() {
        #expect(ConnectionText.firstLine(of: "<?php\n\n  sleep(60);\necho 1;") == "sleep(60);")
        #expect(ConnectionText.firstLine(of: "") == "")
        // Comments say what the code is for; the row shows the code.
        #expect(ConnectionText.firstLine(of: "-- Monthly revenue\nSELECT SLEEP(60);") == "SELECT SLEEP(60);")
        #expect(ConnectionText.firstLine(of: "<?php\n// Waits\n/* more\n * words */\n# note\nsleep(60);") == "sleep(60);")
        #expect(ConnectionText.firstLine(of: "#[Pure]\nfunction f() {}") == "#[Pure]")
        #expect(ConnectionText.firstLine(of: "-- only a comment") == "-- only a comment")
        #expect(ConnectionText.firstLine(of: String(repeating: "x", count: 100), limit: 10) == "xxxxxxxxx…")
    }

    @Test func elapsedIsCompact() {
        #expect(ConnectionText.elapsed(since: at(0), now: at(12)) == "12 s")
        #expect(ConnectionText.elapsed(since: at(0), now: at(185)) == "3 min")
        #expect(ConnectionText.elapsed(since: at(0), now: at(3600)) == "1 h")
        #expect(ConnectionText.elapsed(since: at(0), now: at(3840)) == "1 h 4 min")
        #expect(ConnectionText.elapsed(since: at(0), now: at(2 * 86400 + 3 * 3600)) == "2 d 3 h")
        // A clock that went back never shows a negative time.
        #expect(ConnectionText.elapsed(since: at(10), now: at(0)) == "0 s")
    }

    @Test func kindTexts() {
        #expect(ActiveConnectionKind.database.counted(1) == "1 database session")
        #expect(ActiveConnectionKind.aiClient.counted(3) == "3 AI clients")
        #expect(ActiveConnectionKind.database.sectionNote.contains("Open while a statement runs"))
        #expect(ActiveConnectionKind.allCases.sorted() == [.ssh, .tunnel, .database, .phpRun, .aiClient, .logFollow])
        #expect(ActiveConnectionKind.logFollow.counted(2) == "2 log follows")
        #expect(ConnectionText.list(["a", "b", "c"]) == "a, b, and c")
        #expect(ConnectionText.list(["a", "b"]) == "a and b")
    }

    // MARK: Queued runs (#183)

    private let runA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let runB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let runC = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

    /// One slot: run A holds it since 50; B and C wait since 60 and 61.
    private var slots: RunSlots {
        RunSlots(limit: 1, running: [RunSlots.Entry(runId: runA, tabId: runA, since: at(50))],
                 queued: [RunSlots.Entry(runId: runB, tabId: runB, since: at(60)), RunSlots.Entry(runId: runC, tabId: runC, since: at(61))])
    }

    @Test func slotStatesOfRuns() {
        #expect(slots.state(of: runA) == .running(since: at(50)))
        #expect(slots.state(of: runB) == .queued(position: 1, since: at(60)))
        #expect(slots.state(of: runC) == .queued(position: 2, since: at(61)))
        #expect(slots.state(of: UUID()) == nil)
        #expect(slots.state(of: runB)?.isQueued == true)
        #expect(slots.state(of: runA)?.isQueued == false)
        #expect(RunSlots.none.state(of: runA) == nil)
        #expect(RunSlots.waitingText(running: 4, limit: 4, position: 1) == "4 runs are going, at most 4 at once; next to start. Nothing is opened until it starts.")
        #expect(RunSlots.waitingText(running: 1, limit: 1, position: 2).hasPrefix("1 run is going, at most 1 at once; 2nd in line."))
    }

    @Test func aRunsRowFollowsItsSlot() {
        // The tab says the run started at 40 (when Run was pressed).
        let row = ActiveConnection(id: "run:b", kind: .phpRun, title: "sleep(60);", destination: "bastion", startedAt: at(40), via: ["ssh:bastion"])
        let queued = row.withSlot(slots.state(of: runC))
        #expect(queued.isQueued)
        #expect(queued.queuePosition == 2)
        #expect(queued.startedAt == at(61), "queued since it joined the queue")
        #expect(queued.queueNote == "2nd in line. Waits for a free run slot; nothing is open yet.")
        #expect(queued.closeHelp.hasPrefix("Remove it from the queue"))
        #expect(row.withSlot(slots.state(of: runB)).queueNote?.hasPrefix("Next to start.") == true)
        // Once it gets its slot it runs, and "since" restarts then.
        let running = queued.withSlot(.running(since: at(90)))
        #expect(!running.isQueued)
        #expect(running.queuePosition == nil)
        #expect(running.startedAt == at(90))
        #expect(running.queueNote == nil)
        #expect(running.closeHelp == ActiveConnectionKind.phpRun.closeHelp)
        // The engine doesn't know it (yet, or any more): the row stays as the tab says.
        #expect(row.withSlot(nil) == row)
    }

    private var withQueued: [ActiveConnection] {
        sample + [
            ActiveConnection(id: "run:q2", kind: .phpRun, title: "sleep(5);", destination: "bastion", owner: "Tab “Q2”", startedAt: at(61), via: ["ssh:bastion"], isQueued: true, queuePosition: 2),
            ActiveConnection(id: "run:q1", kind: .database, title: "SELECT 1", destination: "mysql · shop", owner: "Tab “Q1”", startedAt: at(62), via: ["tunnel:reports", "ssh:bastion"], isQueued: true, queuePosition: 1),
        ]
    }

    @Test func queuedRunsAreListedButNotCounted() {
        let list = ActiveConnectionList(withQueued)
        #expect(list.items.count == 10)
        #expect(!list.isEmpty)
        #expect(list.count == 8)
        #expect(list.queuedCount == 2)
        #expect(list.count(of: .phpRun) == 2)
        #expect(list.count(of: .database) == 2)
        #expect(list.summary == "8 active connections, 2 runs queued")
        // Marked within their kind's section, after the active rows, in the order they start.
        let database = list.groups.first { $0.kind == .database }
        #expect(database?.items.map(\.id) == ["work:schema", "run:sql", "run:q1"])
        #expect(list.groups.first { $0.kind == .phpRun }?.items.map(\.id) == ["run:a", "run:b", "run:q2"])
        #expect(database?.activeCount == 2)
        #expect(database?.queuedCount == 1)
        #expect(database?.countText == "2 database sessions, 1 queued")
        // Only queued runs of a kind.
        let onlyQueued = ActiveConnectionList([ActiveConnection(id: "run:x", kind: .phpRun, title: "x", destination: "Sandbox", isQueued: true, queuePosition: 1)])
        #expect(onlyQueued.count == 0)
        #expect(!onlyQueued.isEmpty)
        #expect(onlyQueued.groups.first?.countText == "1 PHP run queued")
        #expect(onlyQueued.summary == "No active connections, 1 run queued")
    }

    @Test func tooltipSaysHowManyAreQueued() {
        let tooltip = ActiveConnectionList(withQueued).tooltip
        #expect(tooltip == "8 active, 2 queued:\n2 SSH connections\n1 SSH tunnel\n2 database sessions, 1 queued\n2 PHP runs, 1 queued\n1 AI client\nQueued runs wait for a free run slot and open nothing until they start.\nClick for the Connection Manager.")
    }

    @Test func queuedRunsDontUseTheirConnectionsYet() throws {
        let list = ActiveConnectionList(withQueued)
        // Neither the SSH connection's nor the tunnel's "used by" counts include them.
        #expect(Set(list.users(of: "ssh:bastion").map(\.id)) == ["run:b", "tunnel:reports", "run:sql"])
        #expect(list.usage(of: "ssh:bastion") == "1 SSH tunnel, 1 database session, and 1 PHP run")
        #expect(list.usage(of: "tunnel:reports") == "1 database session")
        // Close on the SSH connection doesn't say they end with it.
        let bastion = try #require(list.closeConfirmation(for: "ssh:bastion"))
        #expect(bastion.message.contains("1 SSH tunnel, 1 database session, and 1 PHP run use this connection"))
        // A connection used only by queued runs asks nothing on their account.
        let idle = ActiveConnectionList([
            ActiveConnection(id: "ssh:k", kind: .ssh, title: "k", destination: "k"),
            ActiveConnection(id: "run:x", kind: .phpRun, title: "x", destination: "k", via: ["ssh:k"], isQueued: true, queuePosition: 1),
        ])
        #expect(idle.usage(of: "ssh:k") == nil)
        #expect(idle.closeConfirmation(for: "ssh:k") == nil)
        // Closing a queued run never asks, even on production.
        var production = withQueued
        for index in production.indices { production[index].environment = .production }
        #expect(ActiveConnectionList(production).closeConfirmation(for: "run:q2") == nil)
    }

    @Test func ordinalsAndQueuePlaces() {
        #expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101, 111].map(ConnectionText.ordinal) == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "101st", "111th"])
        #expect(ConnectionText.queuePlace(1) == "next to start")
        #expect(ConnectionText.queuePlace(3) == "3rd in line")
    }

    // MARK: Rows from the subsystems

    private let profileId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let connectionId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    private func tunnel(leases: Int, tabs: [ConnectionRows.OwnerTab] = []) -> ConnectionRows.Tunnel {
        ConnectionRows.Tunnel(connectionId: connectionId, connectionName: "Reporting", profileId: profileId, profileName: "bastion",
                              localPort: 53012, remoteHost: "db.internal", remotePort: 5432, openedAt: at(0), lastUsedAt: at(30),
                              leases: leases, environment: .production, tabs: tabs, idleTimeout: .seconds(300))
    }

    @Test func tunnelRowShowsTheForwardTheConnectionAndTheProfile() {
        let row = ConnectionRows.tunnel(tunnel(leases: 0))
        #expect(row.id == "tunnel:\(connectionId)")
        #expect(row.kind == .tunnel)
        #expect(row.title == "Reporting")
        #expect(row.destination == "127.0.0.1:53012 → db.internal:5432 through bastion")
        #expect(row.owner == "Saved connection “Reporting”")
        #expect(row.startedAt == at(0))
        #expect(row.via == ["ssh:\(profileId)"])
        #expect(row.isProduction)
        #expect(row.details.contains("On bastion's shared connection"))
        #expect(row.details.contains { $0.hasPrefix("Last used ") })
        #expect(row.details.contains("Unused; closes after 5 min unused"))
        #expect(row.inUseBy == 0)

        let busy = ConnectionRows.tunnel(tunnel(leases: 2, tabs: [ConnectionRows.OwnerTab(id: profileId, title: "Monthly report")]))
        #expect(busy.details.contains("In use by 2 runs"))
        #expect(busy.owner == "Tab “Monthly report”")
        #expect(busy.ownerTabId == profileId)
        // An IPv6 host keeps its port readable.
        var v6 = tunnel(leases: 0)
        v6.remoteHost = "fd00::5"
        #expect(ConnectionRows.tunnel(v6).destination.hasPrefix("127.0.0.1:53012 → [fd00::5]:5432"))
    }

    @Test func tunnelCloseAsksWhileItsOwnLeasesSayARunUsesIt() throws {
        // A run the list doesn't show (Test Connection) holds it: Close still asks.
        let held = ActiveConnectionList([ConnectionRows.tunnel(tunnel(leases: 1))])
        let confirmation = try #require(held.closeConfirmation(for: "tunnel:\(connectionId)"))
        #expect(confirmation.button == "Close Tunnel")
        #expect(confirmation.title == "Close the tunnel to 127.0.0.1:53012 → db.internal:5432 through bastion?")
        #expect(ActiveConnectionList([ConnectionRows.tunnel(tunnel(leases: 0))]).closeConfirmation(for: "tunnel:\(connectionId)") == nil)
    }

    @Test func masterWithATunnelCountsItAndMentionsItWhenDisconnecting() throws {
        let master = ConnectionRows.ssh(ConnectionRows.SSHMaster(profileId: profileId, name: "bastion", destination: "deploy@bastion.example.com", interactive: false, keepAliveMinutes: 10, environment: .production, openedAt: at(0)))
        let statement = ActiveConnection(id: "run:x", kind: .database, title: "SELECT 1", destination: "pgsql · db.internal:5432/reports", via: ["tunnel:\(connectionId)", "ssh:\(profileId)"])
        let list = ActiveConnectionList([master, ConnectionRows.tunnel(tunnel(leases: 1)), statement])
        #expect(list.usage(of: master.id) == "1 SSH tunnel and 1 database session")
        #expect(list.usage(of: "tunnel:\(connectionId)") == "1 database session")
        let confirmation = try #require(list.closeConfirmation(for: master.id))
        #expect(confirmation.message == "1 SSH tunnel and 1 database session use this connection and end with it.")
        #expect(list.closeConfirmation(for: "tunnel:\(connectionId)")?.message.hasPrefix("A statement is using this tunnel") == true)
    }

    @Test func sshRowSaysHowTheLoginEnds() {
        let automatic = ConnectionRows.ssh(ConnectionRows.SSHMaster(profileId: profileId, name: "acme-app", destination: "acme.example.com", interactive: false, keepAliveMinutes: 10, jumpHost: "gate.example.com"))
        #expect(automatic.id == "ssh:\(profileId)")
        #expect(automatic.details == ["Agent or key login; closes after 10 min unused, or when Runlet quits", "Through gate.example.com"])
        #expect(!automatic.needsLoginToReconnect)
        #expect(automatic.owner == nil)
        let interactive = ConnectionRows.ssh(ConnectionRows.SSHMaster(profileId: profileId, name: "bastion", destination: "deploy@bastion.example.com", interactive: true,
                                                                     tabs: [ConnectionRows.OwnerTab(id: connectionId, title: "A"), ConnectionRows.OwnerTab(id: profileId, title: "B")]))
        #expect(interactive.needsLoginToReconnect)
        #expect(interactive.details.first == "Password or 2FA login (Connect…); stays until you disconnect")
        #expect(interactive.owner == "2 tabs")
        #expect(interactive.ownerTabId == nil)
    }

    @Test func aiClientRowUsesTheNameTheClientReports() {
        let row = ConnectionRows.aiClient(ConnectionRows.AIClient(connectionId: connectionId, name: "Claude Code", version: "2.1", connectedAt: at(5), calls: 1, helperPID: 4242, allowedTargets: ["Laravel Sandbox 12", "lease-api (Docker)"],
                                                                  tab: ConnectionRows.OwnerTab(id: profileId, title: "Claude Code")))
        #expect(row.id == "mcp:\(connectionId)")
        #expect(row.title == "Claude Code")
        #expect(row.owner == "Runs in tab “Claude Code”")
        #expect(row.details == ["1 call", "Version 2.1", "runlet mcp, process 4242", "Runs allowed for this session: Laravel Sandbox 12, lease-api (Docker)"])
        #expect(ActiveConnectionList([row]).closeConfirmation(for: row.id) == nil)
    }
}
