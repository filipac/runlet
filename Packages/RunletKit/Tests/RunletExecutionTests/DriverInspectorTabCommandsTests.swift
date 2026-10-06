import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// A project driver's inspector tabs: the declaration through the runner, the list command,
/// and the run command line per row.
struct DriverInspectorTabCommandsTests {
    private func tab(list: String, run: String = "work {id}") -> DriverInspectorTab {
        DriverInspectorTab(id: "queues", title: "Queues", listCommand: list, runCommand: run)
    }

    private var environment: [String: String] { ["PATH": "/usr/bin:/bin"] }

    @Test func idsAreQuotedAsOneShellWord() async throws {
        #expect(DriverInspectorTabCommands.runCommandLine("tool work --name={id}", id: "emails") == "tool work --name=emails")
        #expect(DriverInspectorTabCommands.runCommandLine("tool work {id} && echo {id}", id: "a b") == "tool work 'a b' && echo 'a b'")
        #expect(DriverInspectorTabCommands.runCommandLine("tool work {id}", id: "it's") == #"tool work 'it'\''s'"#)
        #expect(DriverInspectorTabCommands.runCommandLine("tool work", id: "x") == "tool work")
        // The shell gets each id back exactly.
        for id in ["emails", "a b", "it's", #"say "hi""#, "$(touch nope)", "back\\slash", "*", ""] {
            let line = DriverInspectorTabCommands.runCommandLine("printf '%s' {id}", id: id)
            let result = try await runCommand(ProcessSpec(executable: "/bin/sh", arguments: ["-c", line], environment: environment, workingDirectory: NSTemporaryDirectory()))
            #expect(String(decoding: result.stdout, as: UTF8.self) == id, "\(line)")
        }
    }

    @Test func theListIsReadFromNoisyOutput() async throws {
        let command = #"echo 'Loading…'; echo '{"note": 1}'; echo '{"items": [{"id": "emails", "title": "emails", "badge": 12}], "message": "1 queue"}'; echo bye"#
        let outcome = await DriverInspectorTabCommands.list(tab(list: command), directory: NSTemporaryDirectory(), environment: environment)
        guard case .listed(let listing) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(listing.items == [.init(id: "emails", title: "emails", badge: "12")])
        #expect(listing.message == "1 queue")
    }

    @Test func badJSONIsAnErrorWithStderr() async throws {
        let outcome = await DriverInspectorTabCommands.list(tab(list: #"echo 'Fatal: no database' >&2; echo '{"items": [oops'"#), directory: NSTemporaryDirectory(), environment: environment)
        guard case .failed(let message, let output) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(message.contains("printed no list"), "\(message)")
        #expect(output == "Fatal: no database")
    }

    @Test func aFailingCommandSaysHowItEnded() async throws {
        let outcome = await DriverInspectorTabCommands.list(tab(list: "echo 'tool: command not found' >&2; exit 127"), directory: NSTemporaryDirectory(), environment: environment)
        #expect(outcome == .failed(message: "“echo 'tool: command not found' >&2; exit 127” exited with code 127 without printing a list.", output: "tool: command not found"))
        // Without stderr, the start of the output.
        let silent = await DriverInspectorTabCommands.list(tab(list: "echo 'not a list'"), directory: NSTemporaryDirectory(), environment: environment)
        guard case .failed(_, let output) = silent else {
            Issue.record("\(silent)")
            return
        }
        #expect(output == "not a list")
    }
}

/// `inspectorTabs()` through the runner: declared with the project's commands, before
/// bootstrap; invalid entries are skipped with a notice.
@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct DriverInspectorTabDeclarationTests {
    static let driver = #"""
    <?php
    class TabsDriver extends \Runlet\Driver
    {
        public function canBootstrap(string $projectPath): bool { return true; }
        public function bootstrap(string $projectPath): void { require $projectPath . '/vendor/autoload.php'; }
        public function inspectorTabs(): array
        {
            return [
                ['id' => 'queues', 'title' => 'Queues', 'icon' => 'tray.full', 'list' => 'tool queues', 'run' => 'tool work --name={id}', 'empty' => 'Nothing pending.'],
                ['id' => 'jobs', 'title' => ' Jobs ', 'list' => 'tool jobs', 'run' => 'tool job {id}', 'icon' => 42],
                ['id' => 'queues', 'title' => 'Again', 'list' => 'a', 'run' => 'b'],
                ['title' => 'No id', 'list' => 'a', 'run' => 'b'],
                ['id' => 'norun', 'title' => 'No run', 'list' => 'a'],
                'text',
            ];
        }
    }
    """#

    @Test func driverDeclaresItsTabs() async throws {
        let project = try DriverSupport.composerProject(drivers: ["TabsDriver.php": Self.driver])
        defer { try? FileManager.default.removeItem(at: project) }
        let catalog = try await CommandsSupport.list(project.path)
        #expect(catalog.errors.isEmpty, "\(catalog.errors)")
        #expect(catalog.inspectorTabsDeclared)
        #expect(catalog.inspectorTabs == [
            DriverInspectorTab(id: "queues", title: "Queues", icon: "tray.full", listCommand: "tool queues", runCommand: "tool work --name={id}", emptyText: "Nothing pending."),
            DriverInspectorTab(id: "jobs", title: "Jobs", icon: "42", listCommand: "tool jobs", runCommand: "tool job {id}"),
        ])
        let notice = try #require(catalog.notices.first { $0.contains("inspector tabs that Runlet skipped") }, "\(catalog.notices)")
        #expect(notice.contains("queues (the id is used twice)"))
        #expect(notice.contains("#3 (no id)"))
        #expect(notice.contains("norun (no run)"))
        #expect(notice.contains("#5 (not an array)"))
    }

    @Test func tabsAreDeclaredEvenWhenBootstrapFails() async throws {
        let failing = Self.driver.replacingOccurrences(of: "require $projectPath . '/vendor/autoload.php';", with: "throw new \\RuntimeException('database is down');")
        let project = try DriverSupport.composerProject(drivers: ["TabsDriver.php": failing])
        defer { try? FileManager.default.removeItem(at: project) }
        let catalog = try await CommandsSupport.list(project.path)
        #expect(!catalog.driverListed)
        #expect(catalog.inspectorTabsDeclared)
        #expect(catalog.inspectorTabs.map(\.id) == ["queues", "jobs"])
    }

    @Test func driversWithoutTabsDeclareNone() async throws {
        let catalog = try await CommandsSupport.list(DriverSupport.fixture("custom-driver"))
        #expect(catalog.inspectorTabsDeclared)
        #expect(catalog.inspectorTabs.isEmpty)
    }

    @Test func failingInspectorTabsIsANotice() async throws {
        let driver = Self.driver.replacingOccurrences(of: "inspectorTabs(): array\n    {", with: "inspectorTabs(): array\n    {\n        throw new \\LogicException('nope');")
        let project = try DriverSupport.composerProject(drivers: ["TabsDriver.php": driver])
        defer { try? FileManager.default.removeItem(at: project) }
        let catalog = try await CommandsSupport.list(project.path)
        #expect(!catalog.inspectorTabsDeclared)
        #expect(catalog.notices.contains { $0.contains("inspectorTabs() failed") && $0.contains("nope") }, "\(catalog.notices)")
        #expect(catalog.driverListed)
    }
}

/// A tab whose `list` is a PHP callable: the runner boots the project and calls it, and reads
/// only strings and numbers from what it returns.
@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct DriverInspectorTabCallableTests {
    static func driver(tabs: String, bootstrap: String = "require $projectPath . '/vendor/autoload.php';", methods: String = "") -> String {
        """
        <?php
        class TabsDriver extends \\Runlet\\Driver
        {
            public function canBootstrap(string $projectPath): bool { return true; }
            public function bootstrap(string $projectPath): void { \(bootstrap) }
            public function inspectorTabs(): array
            {
                return [\(tabs)];
            }
            public static function staticRows(): array { return [['id' => 'from-static']]; }
            \(methods)
        }
        """
    }

    private func list(_ tab: String, driver: String) async throws -> DriverInspectorTabCommands.Outcome {
        let project = try DriverSupport.composerProject(drivers: ["TabsDriver.php": driver])
        defer { try? FileManager.default.removeItem(at: project) }
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
        return try await engine.listDriverInspectorTab(tab, title: "Rows", target: DriverSupport.target(project.path))
    }

    private func listing(_ outcome: DriverInspectorTabCommands.Outcome) -> DriverInspectorTabListing? {
        if case .listed(let listing) = outcome { return listing }
        Issue.record("\(outcome)")
        return nil
    }

    @Test func listKindsAreDeclared() async throws {
        let driver = Self.driver(tabs: """
            ['id' => 'closure', 'title' => 'A', 'list' => function () { return []; }, 'run' => 'r {id}'],
            ['id' => 'method', 'title' => 'B', 'list' => [$this, 'rows'], 'run' => 'r {id}'],
            ['id' => 'static', 'title' => 'C', 'list' => 'TabsDriver::staticRows', 'run' => 'r {id}'],
            ['id' => 'host', 'title' => 'D', 'list' => 'date', 'run' => 'r {id}'],
            ['id' => 'nothing', 'title' => 'E', 'list' => [$this, 'missing'], 'run' => 'r {id}'],
            """, methods: "public function rows(): array { return []; }")
        let project = try DriverSupport.composerProject(drivers: ["TabsDriver.php": driver])
        defer { try? FileManager.default.removeItem(at: project) }
        let catalog = try await CommandsSupport.list(project.path)
        #expect(catalog.inspectorTabs.map(\.id) == ["closure", "method", "static", "host"])
        #expect(catalog.inspectorTabs.map(\.list) == [.driver, .driver, .driver, .host(command: "date")])
        #expect(catalog.notices.contains { $0.contains("nothing (no list: not a command or a callable)") }, "\(catalog.notices)")
    }

    @Test func aClosureReturnsTheFullShape() async throws {
        let driver = Self.driver(tabs: """
            ['id' => 'rows', 'title' => 'Rows', 'run' => 'r {id}', 'list' => function () {
                echo "noise on stdout\\n";
                var_dump(['dumped' => true]);
                fwrite(STDERR, "noise on stderr\\n");
                return ['items' => [['id' => 'emails', 'subtitle' => '12 pending', 'badge' => 12], ['id' => 7, 'title' => 'Seven', 'badge' => 1.5]], 'message' => '13 jobs'];
            }],
            """)
        let listing = try #require(listing(try await list("rows", driver: driver)))
        #expect(listing.items == [.init(id: "emails", title: "emails", subtitle: "12 pending", badge: "12"), .init(id: "7", title: "Seven", badge: "1.5")])
        #expect(listing.message == "13 jobs")
        #expect(listing.notices.isEmpty, "\(listing.notices)")
    }

    @Test func aMethodReturnsJustTheItems() async throws {
        let driver = Self.driver(tabs: "['id' => 'rows', 'title' => 'Rows', 'run' => 'r {id}', 'list' => [$this, 'rows']],",
                                 methods: "public function rows(): array { return [['id' => 'a', 'title' => 'A'], ['id' => 'b']]; }")
        let listing = try #require(listing(try await list("rows", driver: driver)))
        #expect(listing.items.map(\.id) == ["a", "b"])
        #expect(listing.message == nil)
        let viaStatic = try #require(self.listing(try await list("rows", driver: Self.driver(tabs: "['id' => 'rows', 'title' => 'Rows', 'run' => 'r {id}', 'list' => 'TabsDriver::staticRows'],"))))
        #expect(viaStatic.items.map(\.id) == ["from-static"])
    }

    @Test func valuesThatArentTextOrNumbersAreLeftOut() async throws {
        let driver = Self.driver(tabs: """
            ['id' => 'rows', 'title' => 'Rows', 'run' => 'r {id}', 'list' => function () {
                $loud = new class { public function __toString(): string { throw new \\LogicException('never called'); } };
                return ['items' => [
                    ['id' => 'a', 'title' => ['nested'], 'subtitle' => $loud, 'badge' => true],
                    ['title' => 'no id'], 'text', ['id' => $loud], ['id' => 'a'],
                ], 'message' => $loud];
            }],
            """)
        let listing = try #require(listing(try await list("rows", driver: driver)))
        #expect(listing.items == [.init(id: "a", title: "a", badge: "yes")])
        #expect(listing.message == nil)
        let notices = listing.notices.joined(separator: "\n")
        #expect(notices.contains("a.title (array)"), "\(notices)")
        #expect(notices.contains("a.subtitle (class@anonymous"), "\(notices)")
        #expect(notices.contains("item 2 (no id)") && notices.contains("item 3 (string)") && notices.contains("item 4 (no id)") && notices.contains("a (the id is used twice)"), "\(notices)")
        #expect(notices.contains("the message is class@anonymous"), "\(notices)")
    }

    @Test func aResultThatIsntAnArrayIsAnError() async throws {
        let outcome = try await list("rows", driver: Self.driver(tabs: "['id' => 'rows', 'title' => 'Rows', 'run' => 'r {id}', 'list' => function () { return 'oops'; }],"))
        guard case .failed(let message, _) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(message.contains("returned string, not an array of items"), "\(message)")
    }

    @Test func anExceptionShowsItsFirstLineAndWhere() async throws {
        let driver = Self.driver(tabs: """
            ['id' => 'rows', 'title' => 'Rows', 'run' => 'r {id}', 'list' => function () {
                throw new \\RuntimeException("The table is locked.\\nSecond line.");
            }],
            """)
        let outcome = try await list("rows", driver: driver)
        guard case .failed(let message, let output) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(message == "Could not list Rows: The table is locked.")
        #expect(output?.hasPrefix("RuntimeException at .runlet/TabsDriver.php:") == true, "\(output ?? "-")")
    }

    @Test func aBootFailureIsShownToo() async throws {
        let driver = Self.driver(tabs: "['id' => 'rows', 'title' => 'Rows', 'run' => 'r {id}', 'list' => function () { return []; }],",
                                 bootstrap: "throw new \\RuntimeException('database is down');")
        let outcome = try await list("rows", driver: driver)
        guard case .failed(let message, _) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(message.hasPrefix("Could not boot the application to list Rows: ") && message.contains("database is down"), "\(message)")
    }

    @Test func aTabWithoutACallableIsAnError() async throws {
        let outcome = try await list("other", driver: Self.driver(tabs: "['id' => 'rows', 'title' => 'Rows', 'run' => 'r {id}', 'list' => 'date'],"))
        guard case .failed(let message, _) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(message.contains("declares no inspector tab \"other\" whose list is a PHP callable"), "\(message)")
    }
}
