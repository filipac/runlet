import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// Driver casters (#6) through the real runner: a project driver's `casters()` shows its own
/// types in results, dumps, magic comments, and inspector records, and Runlet still shows
/// everything else (and anything a caster can't show) without calling the value's methods.
@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct DriverCasterTests {
    var customDriver: String { DriverSupport.fixture("custom-driver") }

    /// A project with one driver whose `casters()` body is `casters`, after `classes`.
    static func project(classes: String = "", casters: String) throws -> URL {
        try DriverSupport.composerProject(drivers: [
            "CastingDriver.php": """
            <?php
            \(classes)
            class CastingDriver extends \\Runlet\\Driver
            {
                public function bootstrap(string $projectPath): void {}

                public function casters(): array
                {
                    \(casters)
                }
            }
            """,
        ])
    }

    static func run(_ code: String, in project: URL) async throws -> [RunEvent] {
        try await TestSupport.run(code, target: DriverSupport.target(project.path))
    }

    @Test func theFixtureDriverShowsItsValueObjects() async throws {
        let events = try await TestSupport.run("""
        class Deposit extends Acme\\Money {}
        $rent = new Acme\\Money(125000, 'EUR');
        dump(new Acme\\EmailAddress('Ada@Example.com'));
        [$rent, new Deposit(50000, 'EUR'), new DateTimeImmutable('2026-10-06 12:00:00', new DateTimeZone('UTC'))]
        """, target: DriverSupport.target(customDriver))
        #expect(events.errors.isEmpty, "\(events.errors)")
        let items = try #require(events.result?.value?.entries).map(\.value)

        // A summary line and fields; the raw object keeps the private properties.
        let rent = items[0]
        #expect(rent.className == "Acme\\Money" && rent.referenceId != nil)
        #expect(rent.summary == "1,250.00 EUR")
        #expect(rent.entries?.map(\.key) == ["cents", "currency"])
        #expect(rent.entries?.map(\.keyType) == ["field", "field"])
        #expect(rent.cast?.by == "AcmeApiDriver" && rent.cast?.type == nil && rent.cast?.error == nil)
        let raw = try #require(rent.cast?.raw)
        #expect(raw.className == "Acme\\Money" && raw.cast == nil && raw.summary == nil)
        #expect(raw.entries?.map { "\($0.visibility ?? "") \($0.key)" } == ["private cents", "private currency"])

        // A subclass gets its parent's caster, and says which.
        #expect(items[1].className == "Deposit" && items[1].summary == "500.00 EUR")
        #expect(items[1].cast?.type == "Acme\\Money")
        // Types without a caster show as before.
        #expect(items[2].cast == nil && items[2].summary?.hasPrefix("2026-10-06 12:00:00") == true)

        // dump() too, with a plain string as the summary line.
        let email = try #require(events.dumps.first?.value)
        #expect(email.summary == "ada@example.com" && email.entries == nil && email.cast?.raw?.entries?.first?.key == "value")
        #expect(events.logs.contains { $0.source == "casters" && $0.detail == "Acme\\Money, Acme\\EmailAddress" }, "\(events.logs)")
    }

    @Test func theMostSpecificCasterWins() async throws {
        let project = try Self.project(classes: """
        interface Labelled { public function label(): string; }
        interface Coded {}
        abstract class Item implements Labelled, Coded { public function label(): string { return static::class; } }
        class Gear extends Item {}
        class Sprocket extends Gear {}
        class Chain extends Item {}
        final class Pedal implements Coded {}
        final class Bell implements Labelled, Coded { public function label(): string { return 'ring'; } }
        final class Horn implements Labelled { public function label(): string { return 'honk'; } }
        """, casters: """
        return [
            'Coded' => fn ($value) => 'coded',
            '\\\\Labelled' => fn (Labelled $value) => 'labelled ' . $value->label(),
            'gear' => fn (Gear $gear) => 'gear ' . get_class($gear),
            'Item' => fn (Item $item) => null,
        ];
        """)
        defer { try? FileManager.default.removeItem(at: project) }
        let events = try await Self.run("[new Gear, new Sprocket, new Chain, new Pedal, new Bell, new Horn]", in: project)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let items = try #require(events.result?.value?.entries).map(\.value)
        // The class itself (names match without case), then its parents…
        #expect(items[0].summary == "gear Gear" && items[0].cast?.type == nil)
        #expect(items[1].summary == "gear Sprocket" && items[1].cast?.type == "gear")
        // …and a caster that returns null leaves the value to Runlet: no interface caster then.
        #expect(items[2].cast == nil && items[2].summary == nil)
        // Interfaces last, in the order the driver declared them; a leading backslash is fine.
        #expect(items[3].summary == "coded" && items[3].cast?.type == "Coded")
        #expect(items[4].summary == "coded")
        #expect(items[5].summary == "labelled honk" && items[5].cast?.type == "Labelled")
    }

    @Test func aThrowingCasterLeavesTheObjectAsRunletShowsIt() async throws {
        let project = try Self.project(classes: """
        class Rate { private $pair = 'EURUSD'; public $quote; public function __construct($quote = null) { $this->quote = $quote; } }
        class Quote { public $bid = 1.08; }
        """, casters: """
        return [
            Rate::class => function (Rate $rate) { throw new RuntimeException("Rates unavailable\\nretry later"); },
            Quote::class => fn (Quote $quote) => 'bid ' . $quote->bid,
        ];
        """)
        defer { try? FileManager.default.removeItem(at: project) }
        let events = try await Self.run("[new Rate(new Quote), 'after']", in: project)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.finished?.status == .completed)
        let rate = try #require(events.result?.value?.entries?.first?.value)
        #expect(rate.cast?.error == "RuntimeException: Rates unavailable retry later")
        #expect(rate.cast?.raw == nil && rate.summary == nil)
        #expect(rate.entries?.map(\.key) == ["pair", "quote"])
        // Objects inside it still get their casters.
        #expect(rate.entries?.last?.value.summary == "bid 1.08")
        #expect(events.result?.value?.entries?.last?.value.scalar == "after")
    }

    @Test func castersThatFailToLoadOrDeclareNonsenseAreNotices() async throws {
        let failing = try Self.project(casters: "throw new LogicException('no casters today');")
        defer { try? FileManager.default.removeItem(at: failing) }
        let events = try await Self.run("new ArrayObject([1])", in: failing)
        #expect(events.noticeMessages.contains { $0.contains("failed in casters(): no casters today") && $0.contains("Values show as Runlet sees them") }, "\(events.noticeMessages)")
        #expect(events.result?.value?.className == "ArrayObject" && events.result?.value?.cast == nil)

        let nonsense = try Self.project(casters: "return ['' => 'strlen', 0 => fn () => 1, 'Foo' => 'no_such_function', 'ArrayObject' => fn ($a) => $a->count()];")
        defer { try? FileManager.default.removeItem(at: nonsense) }
        let skipped = try await Self.run("new ArrayObject([1, 2])", in: nonsense)
        #expect(skipped.noticeMessages.contains { $0.contains("skipped") && $0.contains("\"\", #0, Foo") }, "\(skipped.noticeMessages)")
        #expect(skipped.result?.value?.summary == "2")
    }

    @Test func recursionIsGuarded() async throws {
        let project = try Self.project(classes: """
        class Node { public $id; public function __construct($id) { $this->id = $id; } }
        class Mirror { public $x = 1; }
        class Wrapper { public $inner; public function __construct($inner) { $this->inner = $inner; } }
        class Chatty { public $n = 3; }
        """, casters: """
        return [
            Mirror::class => fn (Mirror $mirror) => $mirror,
            Node::class => fn (Node $node) => ['id' => $node->id, 'self' => $node, 'next' => new Node($node->id + 1)],
            Wrapper::class => fn (Wrapper $wrapper) => $wrapper->inner,
            // A caster that dumps (a cast type, even) while the result is being shown.
            Chatty::class => function (Chatty $chatty) { dump(new Mirror, ['n' => $chatty->n]); return 'chatty'; },
        ];
        """)
        defer { try? FileManager.default.removeItem(at: project) }
        let events = try await Self.run("$m = new Mirror; [$m, new Node(1), new Wrapper($m), new Chatty, 'end']", in: project)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let items = try #require(events.result?.value?.entries).map(\.value)
        #expect(items.count == 5)

        // Returning the object itself: shown as Runlet sees it, with a note.
        #expect(items[0].cast?.error == "the caster returned the object itself" && items[0].entries?.first?.key == "x")
        // The object inside its own fields is "see above"; new objects stop at the depth limit.
        let node = items[1]
        #expect(node.entries?.map(\.key) == ["id", "self", "next"])
        #expect(node.entries?[1].value.repeated == true)
        var depth = 0
        var next: ValueNode? = node
        while let current = next, current.cast != nil, current.truncation == nil {
            depth += 1
            next = current.entries?.first { $0.key == "next" }?.value
        }
        #expect(depth == 7, "nodes below the depth limit: \(depth)")
        #expect(next?.truncation?.reason == "depth")
        // Another object is shown as the one field it is; here the mirror shown above.
        #expect(items[2].entries?.first?.key == "value" && items[2].entries?.first?.value.repeated == true)
        // A dump inside a caster shows as Runlet sees it, and the result around it is intact.
        #expect(items[3].summary == "chatty")
        #expect(items[4].scalar == "end")
        let dumped = events.dumps.map(\.value)
        #expect(dumped.count == 2 && dumped[0].className == "Mirror" && dumped[0].cast == nil)
    }

    @Test func castValuesStayWithinTheBudget() async throws {
        let props = (1...40).map { "public $p\($0) = \($0);" }.joined(separator: " ")
        let project = try Self.project(classes: """
        class Bulky { \(props) }
        class Wide { public $n; public function __construct($n) { $this->n = $n; } }
        """, casters: """
        return [
            Bulky::class => fn (Bulky $bulky) => 'bulky',
            Wide::class => fn (Wide $wide) => range(1, 150),
        ];
        """)
        defer { try? FileManager.default.removeItem(at: project) }

        // Raw objects get at most a quarter of the node budget, and never cut the cast values.
        let bulky = try await Self.run("array_map(fn ($i) => new Bulky, range(1, 200))", in: project)
        let items = try #require(bulky.result?.value?.entries).map(\.value)
        #expect(items.count == 200 && items.allSatisfy { $0.summary == "bulky" && $0.cast?.by == "CastingDriver" })
        let withRaw = items.filter { $0.cast?.raw != nil }.count
        #expect(withRaw > 100 && withRaw < 130, "raw objects: \(withRaw)")
        #expect(items.last?.cast?.raw == nil && items.last?.cast?.help.contains("left out") == true)
        #expect(bulky.result?.value?.budgetExceeded == nil)

        // A caster's fields count against the budget like any value: 200 × 150 fields > 20,000.
        let wide = try await Self.run("array_map(fn ($i) => new Wide($i), range(1, 200))", in: project)
        let value = try #require(wide.result?.value)
        #expect(value.budgetExceeded == true)
        let rows = value.entries ?? []
        #expect(rows.first?.value.entries?.count == 150 && rows.first?.value.entries?.first?.keyType == "int")
        #expect(rows.count < 200 || rows.contains { $0.value.truncation?.reason == "budget" })
    }

    @Test func slowCastersStopForTheRestOfTheValue() async throws {
        let project = try Self.project(classes: "class Slow { public $n; public function __construct($n) { $this->n = $n; } }", casters: """
        return [Slow::class => function (Slow $slow) { usleep(400000); return 'slow ' . $slow->n; }];
        """)
        defer { try? FileManager.default.removeItem(at: project) }
        let events = try await Self.run("$list = [new Slow(1), new Slow(2), new Slow(3), new Slow(4)];\ndump(new Slow(5));\n$list", in: project)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let items = try #require(events.result?.value?.entries).map(\.value)
        // 3 × 0.4 s passes the second: the fourth shows as Runlet sees it, with the reason.
        #expect(items.prefix(3).map(\.summary) == ["slow 1", "slow 2", "slow 3"])
        #expect(items[3].summary == nil && items[3].cast?.error == "the casters took more than 1 s for this value")
        #expect(items[3].entries?.first?.key == "n")
        // Each value gets its own second.
        #expect(events.dumps.first?.value.summary == "slow 5")
    }

    @Test func castersApplyToMagicCommentsAndInspectorRecords() async throws {
        let events = try await TestSupport.run("""
        $rent = new Acme\\Money(99900, 'EUR'); //?
        \\Runlet\\Inspector::current()->record('Billing', 'rent', ['rent' => $rent]);
        \\Runlet\\notice('Charged', ['rent' => $rent]);
        null
        """, target: DriverSupport.target(customDriver))
        #expect(events.errors.isEmpty, "\(events.errors)")
        let hit = try #require(events.inlineHits.first { $0.line == 1 })
        #expect(hit.value?.summary == "999.00 EUR" && hit.value?.cast?.by == "AcmeApiDriver")
        #expect(events.inlineValues.summary(onLine: 1)?.plainText == "Money 999.00 EUR")
        #expect(events.snippetMessages.first?.context?.entries?.first?.value.summary == "999.00 EUR")

        let record = try #require(events.inspection.records(in: "Billing").first)
        guard case .value(let payload) = record.content else { Issue.record("expected a value record"); return }
        #expect(payload.entries?.first?.value.summary == "999.00 EUR")
        #expect(payload.entries?.first?.value.cast?.raw != nil)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("eloquent-app/vendor/autoload.php").path), "requires scripts/setup-fixtures.sh"))
    func aCasterForModelsWinsOverRunletsOwnView() async throws {
        let autoload = TestSupport.fixtures.appendingPathComponent("eloquent-app/vendor/autoload.php").path
        let project = try Self.project(classes: """
        require_once '\(autoload)';
        class Widget extends Illuminate\\Database\\Eloquent\\Model { protected $guarded = []; }
        """, casters: """
        return [
            Illuminate\\Database\\Eloquent\\Model::class => fn ($model) => new \\Runlet\\Cast(class_basename($model) . ' #' . $model->getKey(), $model->getAttributes()),
        ];
        """)
        defer { try? FileManager.default.removeItem(at: project) }
        let events = try await Self.run("collect([(new Widget)->forceFill(['id' => 7, 'name' => 'Sprocket'])])", in: project)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let collection = try #require(events.result?.value)
        #expect(collection.className == "Illuminate\\Support\\Collection" && collection.cast == nil)
        let widget = try #require(collection.entries?.first { $0.key == "items" }?.value.entries?.first?.value)
        #expect(widget.summary == "Widget #7" && widget.cast?.type == "Illuminate\\Database\\Eloquent\\Model")
        #expect(widget.entries?.map(\.key) == ["id", "name"])
        #expect(widget.cast?.raw?.entries?.contains { $0.key == "attributes" && $0.visibility == "protected" } == true)
        // The table shows the caster's fields.
        let table = try #require(ValueTable.make(from: collection))
        #expect(table.columns == ["id", "name"] && table.rows.first?.map(\.text) == ["7", "Sprocket"])
    }

    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires PHP 7.4"))
    func castersWorkOnPHP74() async throws {
        let events = try await TestSupport.run("class Deposit extends Acme\\Money {}\n[new Deposit(50000, 'EUR'), PHP_VERSION]", target: DriverSupport.target(customDriver, php: TestSupport.herdPHP74!))
        #expect(events.result?.value?.entries?.last?.value.scalar?.hasPrefix("7.4") == true, "\(events.errors)")
        let deposit = try #require(events.result?.value?.entries?.first?.value)
        #expect(deposit.summary == "500.00 EUR" && deposit.cast?.type == "Acme\\Money" && deposit.cast?.raw != nil)
    }
}
