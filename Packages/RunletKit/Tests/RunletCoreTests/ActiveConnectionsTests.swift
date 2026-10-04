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
        #expect(tunnel.button == "Cancel Tunnel")
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
        #expect(ActiveConnectionKind.allCases.sorted() == [.ssh, .tunnel, .database, .phpRun, .aiClient])
        #expect(ConnectionText.list(["a", "b", "c"]) == "a, b, and c")
        #expect(ConnectionText.list(["a", "b"]) == "a and b")
    }
}
