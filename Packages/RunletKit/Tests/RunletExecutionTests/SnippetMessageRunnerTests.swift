import Foundation
import RunletCore
import Testing
@testable import RunletExecution

extension Array where Element == RunEvent {
    /// The snippet's notice, warning, and error cards (#196), in order.
    var snippetMessages: [SnippetMessage] {
        compactMap { if case .snippetMessage(let message) = $0.kind { return message } else { return nil } }
    }

    /// Runlet's own notices (plain messages).
    var plainNotices: [String] {
        compactMap { if case .notice(let message) = $0.kind { return message } else { return nil } }
    }
}

/// `\Runlet\notice()`, `warning()`, and `error()`, and the same methods on `\Runlet\Inspector`
/// (#196), through the real runner with host PHP: cards with the inspector on and off, the
/// calling line, context, a Throwable, bounds, that they never throw or fail the run, that
/// Runlet's own notices keep their plain form, and PHP 7.4.
@Suite(.serialized, .enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct SnippetMessageRunnerTests {
    static let snippet = """
    \\Runlet\\notice('Imported rows', ['skipped' => 3]);
    \\Runlet\\warning('Cache is cold', ['store' => 'redis', 'hits' => [1, 2]]);
    \\Runlet\\error('Sync failed');
    try { throw new \\RuntimeException('boom', 5, new \\LogicException('cause')); } catch (\\Throwable $e) { \\Runlet\\error($e, ['id' => 7]); }
    $inspector = \\Runlet\\Inspector::current();
    $inspector->notice('from the inspector');
    $inspector->warning('inspector warning', ['a' => 1]);
    $inspector->error('inspector error');
    'done'
    """

    static func check(_ events: [RunEvent], php74: Bool = false) {
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.finished?.status == .completed, "an error card never fails the run")
        #expect(events.finished?.reason == "completed")
        #expect(events.result?.value?.scalar == "done")
        let messages = events.snippetMessages
        #expect(messages.map(\.level) == [.notice, .warning, .error, .error, .notice, .warning, .error])
        #expect(messages.map(\.callerSnippetLine) == [1, 2, 3, 4, 6, 7, 8])
        #expect(messages.allSatisfy { $0.user == true })
        #expect(messages.map(\.message) == ["Imported rows", "Cache is cold", "Sync failed", "boom", "from the inspector", "inspector warning", "inspector error"])

        #expect(messages[0].context?.entries?.first?.key == "skipped")
        #expect(messages[0].context?.entries?.first?.value.scalar == "3")
        #expect(messages[1].context?.entries?.map(\.key) == ["store", "hits"])
        #expect(messages[1].context?.entries?.last?.value.count == 2)
        #expect(messages[2].context == nil && messages[2].exception == nil)

        let thrown = messages[3]
        #expect(thrown.exception?.className == "RuntimeException")
        #expect(thrown.exception?.inSnippet == true && thrown.exception?.snippetLine == 4)
        #expect(thrown.exception?.previous?.className == "LogicException")
        #expect(thrown.exception?.previous?.message == "cause")
        #expect(thrown.context?.entries?.first?.value.scalar == "7")
        #expect(events.plainNotices.isEmpty, "\(events.plainNotices)")
    }

    @Test(arguments: [true, false])
    func cardsShowWithTheInspectorOnOrOff(inspector: Bool) async throws {
        let events = try await TestSupport.run(Self.snippet, target: DriverSupport.target(DriverSupport.fixture("plain")), inspector: RunInspectorOptions(enabled: inspector))
        Self.check(events)
        // They are output, not inspector records.
        #expect(events.inspection.sections.isEmpty, "\(events.inspection.sections)")
    }

    @Test func aThrowableShowsWhereItWasThrownAndItsTrace() async throws {
        let events = try await TestSupport.run("""
        function load(int $id) { throw new \\DomainException("No order $id"); }
        try {
            load(42);
        } catch (\\Throwable $e) {
            \\Runlet\\error($e);
        }
        """, target: DriverSupport.target(DriverSupport.fixture("plain")))
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.finished?.status == .completed)
        let message = try #require(events.snippetMessages.first)
        #expect(message.level == .error)
        #expect(message.message == "No order 42")
        #expect(message.callerSnippetLine == 5, "the card is at the line that called error()")
        let exception = try #require(message.exception)
        #expect(exception.className == "DomainException")
        #expect(exception.snippetLine == 1, "thrown inside load()")
        #expect(exception.trace?.first?.function == "load")
        #expect(exception.trace?.first?.snippetLine == 3)
    }

    @Test func outsideTheSnippetTheProjectFileIsTheLocation() async throws {
        let driver = """
        <?php
        class NotingDriver extends \\Runlet\\Driver
        {
            public function bootstrap(string $projectPath): void
            {
                \\Runlet\\warning('Booted without a cache', ['driver' => 'noting']);
            }
        }
        """
        let directory = try DriverSupport.composerProject(drivers: ["NotingDriver.php": driver])
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await TestSupport.run("1", target: DriverSupport.target(directory.path))
        #expect(events.errors.isEmpty, "\(events.errors)")
        let message = try #require(events.snippetMessages.first)
        #expect(message.level == .warning)
        #expect(message.inSnippet == false && message.callerSnippetLine == nil)
        #expect(message.file?.hasSuffix(".runlet/NotingDriver.php") == true, "\(message)")
        #expect(message.line == 6)
        #expect(message.summary(line: nil).hasPrefix("Warning (") && message.summary(line: nil).contains("NotingDriver.php:6): Booted without a cache"))
    }

    @Test func atMost200CardsAndLongMessagesAreClipped() async throws {
        let events = try await TestSupport.run("""
        \\Runlet\\warning(str_repeat('é', 10000));
        for ($i = 1; $i <= 204; $i++) { \\Runlet\\notice("n$i"); }
        \\Runlet\\error('last');
        'done'
        """, target: DriverSupport.target(DriverSupport.fixture("plain")))
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.result?.value?.scalar == "done")
        let messages = events.snippetMessages
        #expect(messages.count == 200)
        #expect(messages.first?.message.utf8.count == 16384, "16 KB of the message, whole characters")
        #expect(messages.first?.omittedBytes == 20000 - 16384)
        #expect(messages.last?.message == "n199")
        #expect(events.plainNotices == ["Runlet left out 6 more cards from \\Runlet\\notice(), warning(), and error(): a run shows at most 200 of them (8 MB in all)."])
    }

    @Test func theyNeverThrowWhateverTheyAreGiven() async throws {
        let events = try await TestSupport.run("""
        class Loud { public function __toString(): string { throw new \\Exception('no'); } }
        class Quiet { public function __toString(): string { return 'quiet'; } }
        $loop = ['a' => 1];
        $loop['self'] = &$loop;
        \\Runlet\\error(null);
        \\Runlet\\error([1, 2, 3]);
        \\Runlet\\error(new \\stdClass());
        \\Runlet\\error(new Loud());
        \\Runlet\\error(new Quiet());
        \\Runlet\\error(1.5);
        \\Runlet\\notice('values', ['closure' => function () {}, 'stream' => STDOUT, 'loop' => $loop, 'object' => new Loud()]);
        'still here'
        """, target: DriverSupport.target(DriverSupport.fixture("plain")), inspector: RunInspectorOptions(enabled: false))
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.result?.value?.scalar == "still here")
        #expect(events.snippetMessages.map(\.message) == ["", "array(3)", "stdClass", "Loud", "quiet", "1.5", "values"])
        #expect(events.snippetMessages.last?.context?.entries?.map(\.key) == ["closure", "stream", "loop", "object"])
    }

    @Test func runletsOwnNoticesKeepTheirPlainForm() async throws {
        let events = try await TestSupport.run("""
        class OwnStatement extends \\PDOStatement { protected function __construct() {} }
        $pdo = new \\PDO('sqlite::memory:');
        $pdo->setAttribute(\\PDO::ATTR_STATEMENT_CLASS, [OwnStatement::class]);
        \\Runlet\\Inspector::current()->watchPdo($pdo, 'scratch')
        """, target: DriverSupport.target(DriverSupport.fixture("plain")))
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.result?.value?.scalar == "false")
        #expect(events.snippetMessages.isEmpty)
        #expect(events.plainNotices == ["Runlet does not record queries on the \"scratch\" PDO connection: it already uses its own statement class (OwnStatement)."])
    }

    /// A saved connection's password (#138) is scrubbed from the cards like from notices and
    /// errors: the message, the context, and a Throwable's cause.
    @Test func secretsAreScrubbedFromTheCards() async throws {
        let directory = try SQLSavedConnectionTests.project()
        defer { try? FileManager.default.removeItem(at: directory) }
        let password = SQLSavedConnectionTests.password
        let events = try await SQLSavedConnectionTests.run("""
        <?php
        \\Runlet\\warning('connecting with \(password)', ['dsn' => 'mysql://u:\(password)@db/x', 'nested' => ['p' => '\(password)']]);
        \\Runlet\\error(new \\RuntimeException('denied for \(password)', 0, new \\LogicException('cause \(password)')));
        \\Runlet\\notice(urlencode('\(password)'));
        """, connection: SQLSavedConnectionTests.connection(), in: directory)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let messages = events.snippetMessages
        #expect(messages.count == 3)
        #expect(messages.first?.message == "connecting with •••")
        #expect(messages.first?.context?.entries?.first?.value.scalar == "mysql://u:•••@db/x")
        #expect(messages[1].exception?.previous?.message == "cause •••")
        for text in events.scannableText {
            #expect(!SQLSavedConnectionTests.leaks(text), "\(text)")
        }
    }

    /// SnippetMessages.php keeps PHP 7.4 syntax: the same cards on the oldest supported PHP.
    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires PHP 7.4"))
    func phpSevenFour() async throws {
        let events = try await TestSupport.run(Self.snippet, target: DriverSupport.target(DriverSupport.fixture("plain"), php: TestSupport.herdPHP74!))
        #expect(events.started?.phpVersion?.hasPrefix("7.4") == true)
        Self.check(events)
    }
}

/// The same cards on Docker and SSH targets (the runner code is the same everywhere), against
/// the disposable `runlet-fixtures` containers only.
@Suite(.serialized)
struct SnippetMessageRemoteTests {
    @Test(.enabled(if: TestSupport.hasDocker, "requires a running Docker engine"))
    func dockerLaravelAndPHPSevenFourContainers() async throws {
        let docker = try #require(TestSupport.docker)
        let containers = try await docker.runningContainers()
        func target(_ service: String, _ directory: String) throws -> TargetSnapshot {
            let container = try #require(containers.first { $0.composeProject == "runlet-fixtures" && $0.composeService == service }, "start fixtures with scripts/setup-fixtures.sh docker")
            return TargetSnapshot(kind: .docker, label: container.name, targetId: container.id, workingDirectory: directory, phpExecutable: "php", containerId: container.id, containerName: container.name, image: container.image, temporaryDirectory: service == "restricted" ? "/scratch" : "/tmp")
        }
        // Laravel installs its own error handler; the cards don't go through it.
        let laravel = try await TestSupport.run(SnippetMessageRunnerTests.snippet, target: try target("laravel", "/var/www/html"))
        #expect(laravel.started?.framework == "laravel")
        SnippetMessageRunnerTests.check(laravel)
        let restricted = try await TestSupport.run(SnippetMessageRunnerTests.snippet, target: try target("restricted", "/app"))
        #expect(restricted.started?.phpVersion?.hasPrefix("7.4") == true)
        SnippetMessageRunnerTests.check(restricted)
    }

    @Test(.enabled(if: SSHFixture.available, "requires Docker and /usr/bin/ssh"))
    func ssh() async throws {
        let environment = try await SSHFixture.environment()
        let endpoint = environment.endpoint()
        let client = environment.client()
        defer { Task { await client.disconnect(endpoint) } }
        let events = try await TestSupport.run(SnippetMessageRunnerTests.snippet, target: environment.target(endpoint), engine: environment.engine())
        SnippetMessageRunnerTests.check(events)
    }
}
