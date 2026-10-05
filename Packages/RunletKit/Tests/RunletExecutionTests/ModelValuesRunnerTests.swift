import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// Values | Object for Eloquent models (#307), through the real runner and the Laravel fixture:
/// the `modelValues` tree next to the unchanged `value` (Object), its budget and rows, marks,
/// relations, collections, paginators, lists of models, and that no application code runs.
@Suite(.enabled(if: TestSupport.hasPHP && FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("laravel-app/vendor").path), "requires host PHP and scripts/setup-fixtures.sh"))
struct ModelValuesRunnerTests {
    var target: TargetSnapshot { TestSupport.localTarget(TestSupport.fixtures.appendingPathComponent("laravel-app").path, php: TestSupport.php()!) }

    /// A saved widget, made in memory: no database, and no attribute casts while it is filled.
    static let widget = """
    $widget = function (int $i, array $more = []) {
        $model = new App\\Models\\Widget();
        $model->setRawAttributes(['id' => $i, 'name' => "W$i", 'price' => $i * 10] + $more, true);
        $model->exists = true;
        return $model;
    };

    """

    static func entry(_ node: ValueNode?, _ key: String) -> ValueNode.Entry? {
        node?.entries?.first { $0.key == key }
    }

    @Test func aBigCollectionFitsInValuesAndTheTableAgrees() async throws {
        let events = try await TestSupport.run(Self.widget + """
        new Illuminate\\Database\\Eloquent\\Collection(array_map($widget, range(1, 312)))
        """, target: target)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let result = try #require(events.result)
        // Object: the dump as before, its items cut at 200 per level.
        let object = try #require(result.value)
        let items = try #require(Self.entry(object, "items")?.value)
        #expect(items.entries?.count == 200 && items.truncation?.reason == "children" && items.truncation?.omitted == 112)
        #expect(Self.entry(items.entries?.first?.value, "connection") != nil, "the Object tree keeps the model's internals")
        // Values: every row, each one its attributes.
        let values = try #require(result.modelValues)
        #expect(values.collection?.count == 312 && values.collection?.of == "App\\Models\\Widget")
        #expect(values.entries?.count == 312 && values.truncation == nil && values.budgetExceeded == nil)
        #expect(values.entries?.first?.value.model?.key == "1")
        #expect(values.entries?.first?.value.entries?.map(\.key) == ["id", "name", "price"])
        #expect(ValueTable.make(from: values)?.rows.count == 312)
        let objectTable = try #require(ValueTable.make(from: object))
        #expect(objectTable.rows.count == 200 && objectTable.omittedRows == 112)
    }

    @Test func rowsTheBudgetCutsAreLeftOutWholeAndCounted() async throws {
        var limits = RunLimits()
        limits.maxNodes = 400
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, limits: limits)
        let events = try await TestSupport.run(Self.widget + """
        new Illuminate\\Database\\Eloquent\\Collection(array_map($widget, range(1, 312)))
        """, target: target, engine: engine)
        let values = try #require(events.result?.modelValues)
        let rows = try #require(values.entries)
        #expect(rows.count > 50 && rows.count < 312, "\(rows.count) rows")
        #expect(values.truncation?.reason == "budget" && values.truncation?.omitted == 312 - rows.count)
        // No row is half there: each has its three attributes.
        #expect(rows.allSatisfy { $0.value.entries?.count == 3 && $0.value.truncation == nil })
        // The Table counts the same rows and the same omitted ones.
        let table = try #require(ValueTable.make(from: values))
        #expect(table.rows.count == rows.count && table.omittedRows == values.truncation?.omitted)
    }

    @Test func noApplicationCodeRunsToShowAModel() async throws {
        let events = try await TestSupport.run("""
        class P307Exploding extends Illuminate\\Database\\Eloquent\\Model
        {
            protected $table = 'widgets';
            protected $hidden = ['secret'];
            protected $appends = ['boom'];
            protected function casts(): array { return ['price' => 'integer']; }
            public function getNameAttribute($value) { throw new RuntimeException('accessor ran'); }
            public function getBoomAttribute() { throw new RuntimeException('appended accessor ran'); }
            public function getAttribute($key) { throw new RuntimeException('getAttribute ran'); }
            public function toArray() { throw new RuntimeException('toArray ran'); }
            public function jsonSerialize(): mixed { throw new RuntimeException('jsonSerialize ran'); }
            public function __get($key) { throw new RuntimeException('__get ran'); }
            public function __toString(): string { throw new RuntimeException('__toString ran'); }
        }
        $model = new P307Exploding();
        $model->setRawAttributes(['id' => 3, 'name' => 'gear', 'price' => '12', 'secret' => 's'], true);
        $model->exists = true;
        dump($model);
        new Illuminate\\Database\\Eloquent\\Collection([$model])
        """, target: target)
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(!(events.stdout + events.stderr).contains(" ran"), "\(events.stdout) \(events.stderr)")
        let dumped = try #require(events.dumps.first?.modelValues)
        #expect(dumped.model?.key == "3" && dumped.model?.exists == true && dumped.model?.dirty == nil)
        // Raw values: the accessor and the cast are not applied.
        #expect(Self.entry(dumped, "name")?.value.scalar == "gear")
        #expect(Self.entry(dumped, "price")?.value.type == .string && Self.entry(dumped, "price")?.value.scalar == "12")
        #expect(Self.entry(dumped, "secret")?.hidden == true)
        #expect(Self.entry(dumped, "boom") == nil, "appended accessors aren't values the model holds")
        let listed = try #require(events.result?.modelValues)
        #expect(listed.collection?.of == "P307Exploding" && listed.entries?.first?.value.entries?.count == 4)
    }

    @Test func changedNewHiddenAndRelatedModels() async throws {
        let events = try await TestSupport.run(Self.widget + """
        $gear = $widget(1);
        $gear->name = 'Sprocket';          // changed
        $gear->price = '10';               // the same number, written differently: not changed
        $gear->colour = 'red';             // added
        $owner = new App\\Models\\User();
        $owner->setRawAttributes(['id' => 5, 'name' => 'Alice', 'password' => 'not-a-hash', 'remember_token' => 't'], true);
        $owner->exists = true;
        $gear->setRelation('owner', $owner);
        $owner->setRelation('widgets', new Illuminate\\Database\\Eloquent\\Collection([$gear]));
        $new = new App\\Models\\Widget(['name' => 'Flywheel']);
        $narrow = $widget(2)->setVisible(['name']);
        [$gear, $new, $narrow]
        """, target: target)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let values = try #require(events.result?.modelValues)
        #expect(values.type == .array && values.entries?.count == 3)
        let gear = try #require(values.entries?[0].value)
        #expect(gear.model == ValueNode.ModelInfo(key: "1", keyName: "id", exists: true, dirty: 2))
        let name = try #require(Self.entry(gear, "name"))
        #expect(name.dirty == true && name.original?.scalar == "W1" && name.value.scalar == "Sprocket")
        #expect(Self.entry(gear, "price")?.dirty == nil)
        #expect(Self.entry(gear, "colour")?.dirty == true && Self.entry(gear, "colour")?.original == nil)
        // A loaded relation, in Values form too; the way back is the same model.
        let owner = try #require(Self.entry(gear, "owner"))
        #expect(owner.keyType == "relation" && owner.value.model?.key == "5")
        #expect(Self.entry(owner.value, "password")?.hidden == true && Self.entry(owner.value, "remember_token")?.hidden == true)
        let back = try #require(Self.entry(owner.value, "widgets")?.value)
        #expect(back.collection?.count == 1 && back.entries?.first?.value.repeated == true)
        // A new model: not saved, and nothing marked as changed.
        let new = try #require(values.entries?[1].value)
        #expect(new.model?.exists == false && new.model?.dirty == nil && new.model?.key == nil)
        #expect(new.entries?.allSatisfy { $0.dirty == nil } == true)
        // $visible leaves the other attributes out of its array: they're marked hidden.
        let narrow = try #require(values.entries?[2].value)
        #expect(Self.entry(narrow, "name")?.hidden == nil && Self.entry(narrow, "price")?.hidden == true)
        // The Object tree is the full dump.
        #expect(Self.entry(events.result?.value?.entries?.first?.value, "attributes") != nil)
    }

    @Test func collectionsPaginatorsAndValuesWithoutModels() async throws {
        let events = try await TestSupport.run(Self.widget + """
        use Illuminate\\Pagination\\{CursorPaginator, LengthAwarePaginator, Paginator};
        dump(collect([$widget(1), $widget(2)]));
        dump(collect([1, 2, 3]));
        dump(new LengthAwarePaginator([$widget(1), $widget(2)], 312, 2, 3));
        dump(new Paginator([$widget(1), $widget(2), $widget(3)], 2, 1));
        dump(new CursorPaginator([$widget(1), $widget(2), $widget(3)], 2));
        dump(new Illuminate\\Database\\Eloquent\\Collection());
        dump(['count' => 3, 'when' => now()]);
        ['plain' => [1, 2], 'nested' => ['widget' => $widget(9)]]
        """, target: target)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let dumps = events.dumps
        try #require(dumps.count == 7)
        #expect(dumps[0].modelValues?.collection == ValueNode.CollectionInfo(count: 2, of: "App\\Models\\Widget"))
        #expect(dumps[0].modelValues?.className == "Illuminate\\Support\\Collection")
        // Without a model, one tree: the dump as before.
        #expect(dumps[1].modelValues == nil && dumps[6].modelValues == nil)
        let page = try #require(dumps[2].modelValues)
        #expect(page.collection == ValueNode.CollectionInfo(count: 2, of: "App\\Models\\Widget", total: 312, page: 3, lastPage: 156, perPage: 2, items: "Illuminate\\Support\\Collection"))
        #expect(page.modelTitle == "LengthAwarePaginator<Widget> · 2 of 312 · page 3 of 156")
        #expect(page.entries?.count == 2 && page.entries?.first?.value.model?.key == "1")
        #expect(dumps[3].modelValues?.collection?.page == 1 && dumps[3].modelValues?.collection?.hasMore == true && dumps[3].modelValues?.entries?.count == 2)
        #expect(dumps[4].modelValues?.collection?.hasMore == true && dumps[4].modelValues?.collection?.count == 2)
        #expect(dumps[5].modelValues?.collection?.count == 0 && dumps[5].modelValues?.entries == [])
        // A model deep in an array is in Values form; the rest of the array is as it was.
        let nested = try #require(events.result?.modelValues)
        #expect(Self.entry(Self.entry(nested, "nested")?.value, "widget")?.value.model?.key == "9")
        #expect(Self.entry(nested, "plain")?.value.entries?.count == 2)
    }

    @Test(.enabled(if: Self.phpHasMongoDB, "requires PHP's mongodb extension"))
    func mongoStyleModels() async throws {
        // laravel-mongodb's shapes without a server: an ObjectId key, embedded documents,
        // BSON and Carbon dates.
        let events = try await TestSupport.run("""
        use MongoDB\\BSON\\{ObjectId, UTCDateTime};
        class P307Pair extends Illuminate\\Database\\Eloquent\\Model
        {
            protected $primaryKey = '_id';
            protected $keyType = 'string';
            public $incrementing = false;
            public function getSymbolAttribute($value) { throw new RuntimeException('accessor ran'); }
        }
        $pairs = new Illuminate\\Database\\Eloquent\\Collection();
        foreach (range(1, 3) as $i) {
            $pair = new P307Pair();
            $pair->setRawAttributes([
                '_id' => new ObjectId(sprintf('66f1a2b3c4d5e6f70819%04x', $i)),
                'symbol' => "P$i",
                'firstToken' => ['address' => "0x$i", 'decimals' => 18, 'tags' => ['a', 'b']],
                'seenAt' => new UTCDateTime(1700000000000 + $i),
                'updated_at' => Carbon\\Carbon::parse('2026-01-01 10:00:00', 'UTC'),
            ], true);
            $pair->exists = true;
            $pairs->push($pair);
        }
        // A changed embedded document, and the same ObjectId in a new instance (not a change).
        $pairs[0]->setRawAttributes(['firstToken' => ['address' => '0xCHANGED', 'decimals' => 18, 'tags' => ['a', 'b']]] + $pairs[0]->getAttributes());
        $pairs[1]->setRawAttributes(['_id' => new ObjectId(sprintf('66f1a2b3c4d5e6f70819%04x', 2))] + $pairs[1]->getAttributes());
        $pairs
        """, target: target)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let values = try #require(events.result?.modelValues)
        let first = try #require(values.entries?.first?.value)
        #expect(first.model == ValueNode.ModelInfo(key: "66f1a2b3c4d5e6f708190001", keyName: "_id", exists: true, dirty: 1))
        #expect(first.modelTitle == "P307Pair #66f1a2b3…")
        #expect(Self.entry(first, "firstToken")?.dirty == true)
        #expect(Self.entry(first, "firstToken")?.original.flatMap { Self.entry($0, "address")?.value.scalar } == "0x1")
        // Embedded documents stay browsable; BSON values render as in the Object view.
        let token = try #require(Self.entry(first, "firstToken")?.value)
        #expect(Self.entry(token, "tags")?.value.entries?.count == 2)
        #expect(Self.entry(first, "_id")?.value.className == "MongoDB\\BSON\\ObjectId")
        #expect(Self.entry(Self.entry(first, "seenAt")?.value, "milliseconds")?.value.scalar == "1700000000001")
        // A date is its moment, without Carbon's settings.
        let updated = try #require(Self.entry(first, "updated_at")?.value)
        #expect(updated.summary?.hasPrefix("2026-01-01 10:00:00") == true && updated.entries == nil)
        #expect(values.entries?[1].value.model?.dirty == nil)
        #expect(Self.entry(first, "symbol")?.value.scalar == "P1")
    }

    static let phpHasMongoDB: Bool = {
        guard let php = TestSupport.php(), let result = try? TestProcess.runBlocking([php, "-r", "echo extension_loaded('mongodb') ? 'yes' : 'no';"], step: "php mongodb", within: .seconds(10)) else { return false }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
    }()
}

/// Values mode on real laravel-mongodb models (#307), live: a scratch Laravel app with
/// `mongodb/laravel-mongodb` whose `mongodb` connection reaches the fixture, named by
/// `RUNLET_TEST_LARAVEL_MONGODB` (see `MongoLaravelLiveTests`). Skipped without it.
@Suite(.serialized, .live(.mongo), .enabled(if: TestSupport.hasPHP && LiveServers.laravelMongo != nil,
                                            "set RUNLET_TEST_LARAVEL_MONGODB to a Laravel app with mongodb/laravel-mongodb whose mongodb connection reaches the fixture"))
struct ModelValuesMongoLiveTests {
    @Test func loadedDocumentsShowTheirValues() async throws {
        let project = try #require(LiveServers.laravelMongo)
        let collection = "p307_pairs_" + UUID().uuidString.prefix(8).lowercased()
        let events = try await TestSupport.run("""
        class P307LivePair extends MongoDB\\Laravel\\Eloquent\\Model
        {
            protected $connection = 'mongodb';
            protected $table = '\(collection)';
            protected $guarded = [];
            protected $hidden = ['secret'];
        }
        try {
            foreach (range(1, 312) as $i) {
                P307LivePair::create(['symbol' => "S$i", 'secret' => 'x', 'firstToken' => ['address' => "0x$i", 'tags' => ['a', 'b']], 'secondToken' => ['address' => "0y$i"]]);
            }
            $pairs = P307LivePair::orderBy('symbol')->get();
            $pairs[0]->symbol = 'CHANGED';
            dump($pairs);
        } finally {
            DB::connection('mongodb')->getDatabase()->dropCollection('\(collection)');
        }
        """, target: DriverSupport.target(project))
        #expect(events.errors.isEmpty, "\(events.errors)")
        let dump = try #require(events.dumps.first)
        let values = try #require(dump.modelValues)
        #expect(values.collection?.count == 312 && values.entries?.count == 312 && values.truncation == nil)
        let first = try #require(values.entries?.first?.value)
        #expect(first.model?.exists == true && first.model?.dirty == 1)
        #expect(first.model?.key?.count == 24 && first.model?.key?.allSatisfy(\.isHexDigit) == true, "\(String(describing: first.model))")
        #expect(first.entries?.first { $0.key == "secret" }?.hidden == true)
        #expect(first.entries?.first { $0.key == "firstToken" }?.value.entries?.count == 2)
        // The Object tree spends its budget on the models' internals: fewer rows.
        let objectRows = ValueTable.make(from: dump.value)?.rows.count ?? 0
        #expect(objectRows < 312, "\(objectRows)")
    }
}
