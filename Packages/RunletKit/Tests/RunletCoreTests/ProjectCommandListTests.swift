import Foundation
import Testing
@testable import RunletCore

/// The Commands pane's list model (#320): the pane redraws its list only when this changes, so
/// it must stay equal for everything that doesn't change the rows (another catalog load of the
/// same commands, the REPL or tests launching), and change for what does (the filter, a
/// collapsed group, a command launching).
struct ProjectCommandListTests {
    static func command(_ name: String, group: String? = nil, origin: ProjectCommand.Origin = .driver, source: String = "Laravel") -> ProjectCommand {
        ProjectCommand(name: name, description: "Does \(name)", commandLine: "php artisan \(name)", group: group, origin: origin, source: source)
    }

    static let commands = [
        command("about"), command("migrate", group: nil), command("migrate:status", group: "migrate"), command("migrate:fresh", group: "migrate"),
        command("make:model", group: "make"), command("deploy", origin: .host, source: "biker"),
        ProjectCommand(name: "test", commandLine: "composer run-script test", origin: .composer, source: "Composer"),
    ]

    func catalog(loadedAt: Date = Date(timeIntervalSince1970: 0)) -> ProjectCommandCatalog {
        ProjectCommandCatalog(commands: Self.commands, driverName: "Laravel", loadedAt: loadedAt)
    }

    @Test func sectionsFollowTheCatalogsGroups() {
        let list = ProjectCommandList(catalog: catalog(), search: "", collapsed: [], launching: [])
        let groups = catalog().groups()
        #expect(list.sections.map(\.id) == groups.map(\.id))
        #expect(list.sections.map(\.title) == groups.map(\.title))
        #expect(list.sections.map(\.count) == groups.map(\.commands.count))
        #expect(list.sections.flatMap(\.rows).map(\.id) == groups.flatMap(\.commands).map(\.id))
        #expect(list.sections.filter { !$0.isExpanded }.isEmpty)
        #expect(!list.isSearching)
        #expect(list.command("driver:migrate:status")?.name == "migrate:status")
        #expect(list.command("driver:nope") == nil)
        #expect(list.command(nil) == nil)
    }

    /// A refresh that lists the same commands, or anything else launching, leaves the list
    /// equal, so the pane doesn't redraw its rows.
    @Test func unrelatedChangesLeaveItEqual() {
        let first = ProjectCommandList(catalog: catalog(), search: "", collapsed: ["driver:make"], launching: [])
        let reloaded = ProjectCommandList(catalog: catalog(loadedAt: Date(timeIntervalSince1970: 60)), search: "", collapsed: ["driver:make"], launching: ["repl:sandbox", "tests:sandbox"])
        #expect(first == reloaded)
        // Whitespace only isn't a search.
        #expect(ProjectCommandList(catalog: catalog(), search: "  ", collapsed: ["driver:make"], launching: []) == first)
    }

    @Test func aLaunchChangesOnlyItsRow() {
        let idle = ProjectCommandList(catalog: catalog(), search: "", collapsed: [], launching: [])
        let launching = ProjectCommandList(catalog: catalog(), search: "", collapsed: [], launching: ["driver:about"])
        #expect(idle != launching)
        let changed = zip(idle.sections.flatMap(\.rows), launching.sections.flatMap(\.rows)).filter { $0 != $1 }.map(\.1)
        #expect(changed.map(\.id) == ["driver:about"])
        #expect(changed.first?.isLaunching == true)
    }

    @Test func collapsedGroupsOpenWhileSearching() throws {
        let collapsed = ProjectCommandList(catalog: catalog(), search: "", collapsed: ["driver:migrate"], launching: [])
        let migrate = try #require(collapsed.sections.first { $0.id == "driver:migrate" })
        #expect(!migrate.isExpanded)
        #expect(migrate.count == 2, "a collapsed group still counts its commands")
        #expect(migrate.rows.count == 2, "and keeps its rows, so selection and the context menu find them")
        #expect(collapsed.sections.filter { !$0.isExpanded }.map(\.id) == ["driver:migrate"])

        let searching = ProjectCommandList(catalog: catalog(), search: "status", collapsed: ["driver:migrate"], launching: [])
        #expect(searching.isSearching)
        #expect(searching.sections.map(\.id) == ["driver:migrate"])
        #expect(searching.sections.filter { !$0.isExpanded }.isEmpty)
        #expect(searching.sections.first?.rows.map(\.command.name) == ["migrate:status"])
    }
}
