import Foundation
import RunletCore
import Testing
@testable import RunletLanguage

/// Acceptance scenario 15 (plan.md): Laravel completion with the pinned PHPantom 0.10.0 binary.
///
/// These tests record observed behavior. Where PHPantom does not support a case, the test asserts
/// what it actually returns and says so in a `// Unsupported in PHPantom 0.10.0:` comment, so a
/// PHPantom upgrade that changes the behavior shows up as a failing test. The results are summarised
/// in docs/compatibility.md ("Laravel completion").
///
/// Most cases use `Tests/Fixtures/laravel-app` (a copy of the pinned sandbox template, Laravel 13.34.0,
/// plus `App\Models\Widget` and `App\Services\PriceFormatter`). The fixture has no relations and its
/// only cast matches its column type, so relation and cast cases use a throwaway workspace that
/// links the fixture's `vendor` directory (`ModelWorkspace`).
@Suite(
    .serialized,
    .enabled(if: LanguageTestSupport.hasBinary, "run scripts/fetch-phpantom.sh"),
    .enabled(if: LaravelFixture.hasVendor, "run scripts/setup-fixtures.sh")
)
struct LaravelCompletionTests {
    static var root: URL { LaravelFixture.root }

    // MARK: Helpers

    /// The editor position just after the last character of `text` (UTF-16, like the editor).
    static func endPosition(of text: String) -> LSPPosition {
        TextLineIndex(text).position(at: (text as NSString).length)
    }

    /// Opens a tagless snippet and requests completion at `position` (default: end of the snippet).
    static func complete(
        _ session: LanguageServerSession,
        root: URL = root,
        _ editorText: String,
        at position: LSPPosition? = nil,
        trigger: String?
    ) async throws -> [CompletionItem] {
        let (uri, mapping) = await LanguageTestSupport.open(session, root: root, editorText: editorText)
        let position = position ?? endPosition(of: editorText)
        return try await session.completion(uri: uri, position: mapping.toLSP(position), triggerCharacter: trigger)
    }

    static func hover(_ session: LanguageServerSession, root: URL = root, _ editorText: String, line: Int, character: Int) async throws -> HoverInfo? {
        let (uri, mapping) = await LanguageTestSupport.open(session, root: root, editorText: editorText)
        return try await session.hover(uri: uri, position: mapping.toLSP(LSPPosition(line: line, character: character)))
    }

    static func item(_ label: String, in items: [CompletionItem]) -> CompletionItem? {
        items.first { ($0.label.components(separatedBy: "(").first ?? $0.label) == label }
    }

    // MARK: Facade static calls

    @Test func facadeQueryBuilderChainOffersBuilderMethods() async throws {
        let session = await LanguageTestSupport.session(Self.root)
        defer { Task { await session.stop() } }
        #expect(await session.state.isReady)

        // `DB` is the runtime alias (no `use`), as typed in a scratch tab.
        let items = try await Self.complete(session, "DB::table('widgets')->", trigger: ">")
        let labels = LanguageTestSupport.labels(items)
        for method in ["where", "orderBy", "get", "first", "pluck", "paginate"] {
            #expect(labels.contains(method), "missing \(method)")
        }
        // Query builder (not Eloquent): rows are stdClass.
        #expect(Self.item("get", in: items)?.detail == "Collection<int, stdClass>")

        // The fully qualified facade gives the same result.
        let qualified = LanguageTestSupport.labels(try await Self.complete(session, "\\Illuminate\\Support\\Facades\\DB::table('widgets')->", trigger: ">"))
        #expect(qualified.contains("where") && qualified.contains("orderBy"))
    }

    @Test func cacheFacadeStaticMethods() async throws {
        let session = await LanguageTestSupport.session(Self.root)
        defer { Task { await session.stop() } }
        let items = try await Self.complete(session, "Cache::", trigger: ":")
        let labels = LanguageTestSupport.labels(items)
        #expect(labels.contains("get"))
        #expect(labels.contains("put"))
        #expect(labels.contains("remember"))
        // Hover on a facade call resolves the facade's @method docblock.
        let hover = try await Self.hover(session, "Cache::get('k');", line: 0, character: 8)
        #expect(hover?.markdown.contains("class Cache") == true)
        #expect(hover?.markdown.contains("function get(") == true)
    }

    @Test func strStaticMethods() async throws {
        let session = await LanguageTestSupport.session(Self.root)
        defer { Task { await session.stop() } }
        let labels = LanguageTestSupport.labels(try await Self.complete(session, "Str::", trigger: ":"))
        #expect(labels.contains("slug"))
        #expect(labels.contains("limit"))
        let hover = try await Self.hover(session, "Str::slug('a');", line: 0, character: 6)
        #expect(hover?.markdown.contains("Generate a URL friendly \"slug\"") == true)
    }

    @Test func facadeAccessorReturnTypesChain() async throws {
        let session = await LanguageTestSupport.session(Self.root)
        defer { Task { await session.stop() } }
        #expect(LanguageTestSupport.labels(try await Self.complete(session, "Cache::store()->", trigger: ">")).contains("get"))
        #expect(LanguageTestSupport.labels(try await Self.complete(session, "DB::connection()->", trigger: ">")).contains("table"))
        #expect(LanguageTestSupport.labels(try await Self.complete(session, "Http::get('https://example.test')->", trigger: ">")).contains("json"))
    }

    // MARK: Eloquent scopes and builder chains

    @Test func localScopeIsOfferedAndKeepsTheBuilderChain() async throws {
        let session = await LanguageTestSupport.session(Self.root)
        defer { Task { await session.stop() } }
        // `scopeExpensive` is offered as `expensive()` on the builder and statically on the model.
        let onBuilder = try await Self.complete(session, "App\\Models\\Widget::query()->", trigger: ">")
        #expect(Self.item("expensive", in: onBuilder)?.detail == "Builder<Widget>")
        let staticScope = LanguageTestSupport.labels(try await Self.complete(session, "App\\Models\\Widget::exp", trigger: nil))
        #expect(staticScope.contains("expensive"))

        let afterScope = LanguageTestSupport.labels(try await Self.complete(session, "App\\Models\\Widget::query()->expensive()->", trigger: ">"))
        #expect(afterScope.contains("get"))
        #expect(afterScope.contains("first"))
        #expect(afterScope.contains("where"))

        // The terminal call resolves to the model.
        let row = LanguageTestSupport.labels(try await Self.complete(session, "App\\Models\\Widget::query()->expensive()->get()->first()->", trigger: ">"))
        #expect(row.contains("price") && row.contains("name"))
    }

    @Test func builderChainFromStaticWhere() async throws {
        let session = await LanguageTestSupport.session(Self.root)
        defer { Task { await session.stop() } }
        let items = try await Self.complete(session, "App\\Models\\Widget::where('price', '>', 1)->", trigger: ">")
        let labels = LanguageTestSupport.labels(items)
        #expect(labels.contains("orderBy"))
        #expect(labels.contains("with"))
        #expect(labels.contains("expensive"))
        // Item details show the unsubstituted template (`TModel`); the chain still resolves below.
        #expect(Self.item("first", in: items)?.detail == "TModel|null")

        for chain in [
            "App\\Models\\Widget::where('price', '>', 1)->orderBy('name')->first()->",
            "App\\Models\\Widget::query()->with('x')->where('a', 1)->get()->first()->",
            "App\\Models\\Widget::query()->latest()->paginate()->first()->",
            "App\\Models\\Widget::findOrFail(1)->",
            "App\\Models\\Widget::firstWhere('name', 'x')->",
            "App\\Models\\Widget::create(['name' => 'a'])->",
        ] {
            let labels = LanguageTestSupport.labels(try await Self.complete(session, chain, trigger: ">"))
            #expect(labels.contains("price"), "\(chain)")
        }
        // Dynamic `where{Column}` calls are treated as builder calls.
        #expect(LanguageTestSupport.labels(try await Self.complete(session, "App\\Models\\Widget::whereName('x')->", trigger: ">")).contains("orderBy"))
    }

    // MARK: Model attributes and casts

    @Test func modelAttributesFromMigrationWithTypes() async throws {
        let session = await LanguageTestSupport.session(Self.root)
        defer { Task { await session.stop() } }
        let items = try await Self.complete(session, "App\\Models\\Widget::first()->", trigger: ">")
        #expect(Self.item("price", in: items)?.detail == "int")
        #expect(Self.item("name", in: items)?.detail == "string")
        #expect(Self.item("id", in: items)?.detail == "int")
        #expect(Self.item("created_at", in: items)?.detail == "Carbon")

        let price = try #require(try await Self.hover(session, "$w = App\\Models\\Widget::first();\n$w->price;", line: 1, character: 6))
        #expect(price.markdown.contains("`int`"))
        // Unsupported in PHPantom 0.10.0: Widget's `casts()` entry (`'price' => 'integer'`) is not
        // read, because it is the last array entry without a trailing comma (see
        // `castsDefineAttributeTypes`). The `int` type here comes from the migration column.
        #expect(price.markdown.contains("source: database column"))
        #expect(!price.markdown.contains("source: cast"))

        let name = try #require(try await Self.hover(session, "App\\Models\\Widget::first()->name;", line: 0, character: 30))
        #expect(name.markdown.contains("`string`"))

        // A cast that differs from the column type is reported as the cast (sandbox User model).
        let verified = try #require(try await Self.hover(session, "$u = App\\Models\\User::first();\n$u->email_verified_at;", line: 1, character: 6))
        #expect(verified.markdown.contains("`Carbon`"))
        #expect(verified.markdown.contains("source: cast `datetime`"))
    }

    @Test func castsDefineAttributeTypes() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.remove() }
        let session = await LanguageTestSupport.session(workspace.root)
        defer { Task { await session.stop() } }

        func attributeHover(_ model: String, _ attribute: String) async throws -> String? {
            try await Self.hover(session, root: workspace.root, "$m = App\\Models\\\(model)::first();\n$m->\(attribute);", line: 1, character: 5)?.markdown
        }
        // `casts()` method with a trailing comma: every entry is read.
        for (attribute, type, cast) in [("is_active", "bool", "boolean"), ("meta", "array", "array"), ("released_at", "Carbon", "datetime"), ("amount", "float", "decimal:2"), ("label", "int", "integer")] {
            let markdown = try await attributeHover("Gadget", attribute)
            #expect(markdown?.contains("`\(type)`") == true, "\(attribute)")
            #expect(markdown?.contains("source: cast `\(cast)`") == true, "\(attribute)")
        }
        let items = try await Self.complete(session, root: workspace.root, "App\\Models\\Gadget::first()->", trigger: ">")
        #expect(Self.item("is_active", in: items)?.detail == "bool")
        #expect(Self.item("meta", in: items)?.detail == "array")

        // `$casts` property: every entry is read, including the last one without a trailing comma.
        #expect(try await attributeHover("Gizmo", "p_one")?.contains("`bool`") == true)
        #expect(try await attributeHover("Gizmo", "p_two")?.contains("`bool`") == true)
        // `casts()` method without a trailing comma.
        #expect(try await attributeHover("Gizmo", "m_one")?.contains("`bool`") == true)
        // Unsupported in PHPantom 0.10.0: the last entry of a `casts()` return array is ignored when
        // it has no trailing comma (single-line or multi-line). The attribute is then unknown.
        #expect(try await attributeHover("Gizmo", "m_two") == nil)
        let gizmo = LanguageTestSupport.labels(try await Self.complete(session, root: workspace.root, "App\\Models\\Gizmo::first()->", trigger: ">"))
        #expect(gizmo.contains("m_one") && !gizmo.contains("m_two"))
    }

    // MARK: Relations

    @Test func relationsResolveTheRelatedModel() async throws {
        let workspace = try ModelWorkspace()
        defer { workspace.remove() }
        let session = await LanguageTestSupport.session(workspace.root)
        defer { Task { await session.stop() } }

        // `Part` is recognisable by its `gadget` relation property.
        for chain in [
            "App\\Models\\Gadget::first()->partsGeneric->first()->", // @return HasMany<Part, $this>
            "App\\Models\\Gadget::first()->partsInferred->first()->", // no return type; inferred from hasMany(Part::class)
            "App\\Models\\Gadget::with('partsGeneric')->first()->partsGeneric->first()->",
        ] {
            let labels = LanguageTestSupport.labels(try await Self.complete(session, root: workspace.root, chain, trigger: ">"))
            #expect(labels.contains("gadget"), "\(chain)")
        }
        // belongsTo without a return type resolves to the parent model (and its casts).
        let parent = try await Self.complete(session, root: workspace.root, "App\\Models\\Part::first()->gadget->", trigger: ">")
        #expect(Self.item("is_active", in: parent)?.detail == "bool")

        // The relation method itself is a builder for the related model.
        let builder = LanguageTestSupport.labels(try await Self.complete(session, root: workspace.root, "App\\Models\\Gadget::first()->partsGeneric()->", trigger: ">"))
        #expect(builder.contains("where") && builder.contains("get") && builder.contains("first"))

        // Unsupported in PHPantom 0.10.0: a relation declared with only the native return type
        // (`parts(): HasMany`, as generated by `make:model` and shown in the Laravel docs) loses the
        // related model: the property is `Collection<Model>`, so Part's members are not offered.
        let native = try #require(try await Self.hover(session, root: workspace.root, "$p = App\\Models\\Gadget::first()->parts;\n$p;", line: 1, character: 1))
        #expect(native.markdown.contains("Collection<Model>"))
        let nativeElement = LanguageTestSupport.labels(try await Self.complete(session, root: workspace.root, "App\\Models\\Gadget::first()->parts->first()->", trigger: ">"))
        #expect(nativeElement.contains("save"))
        #expect(!nativeElement.contains("gadget"))
    }

    // MARK: Collection element types

    @Test func eloquentCollectionElementType() async throws {
        let session = await LanguageTestSupport.session(Self.root)
        defer { Task { await session.stop() } }
        let items = try await Self.complete(session, "App\\Models\\Widget::all()->first()->", trigger: ">")
        #expect(Self.item("price", in: items)?.detail == "int")
        #expect(LanguageTestSupport.labels(items).contains("name"))

        let all = try #require(try await Self.hover(session, "$items = App\\Models\\Widget::all();\n$items;", line: 1, character: 2))
        #expect(all.markdown.contains("Collection<int, Widget>"))

        for chain in [
            "App\\Models\\Widget::all()->filter(fn ($w) => $w->price > 1)->first()->",
            "App\\Models\\Widget::all()->sortBy('price')->values()->first()->",
            "App\\Models\\Widget::cursor()->first()->",
            "App\\Models\\Widget::lazy()->first()->",
        ] {
            #expect(LanguageTestSupport.labels(try await Self.complete(session, chain, trigger: ">")).contains("price"), "\(chain)")
        }
        // Closure parameters and foreach variables get the element type.
        let arrow = LanguageTestSupport.labels(try await Self.complete(session, "App\\Models\\Widget::all()->map(fn ($w) => $w->", trigger: ">"))
        #expect(arrow.contains("price"))
        let closureText = "App\\Models\\Widget::all()->each(function ($w) { $w-> });"
        let closure = LanguageTestSupport.labels(try await Self.complete(session, closureText, at: LSPPosition(line: 0, character: 52), trigger: ">"))
        #expect(closure.contains("price"))
        let loop = LanguageTestSupport.labels(try await Self.complete(session, "foreach (App\\Models\\Widget::all() as $w) {\n    $w->\n}", at: LSPPosition(line: 1, character: 8), trigger: ">"))
        #expect(loop.contains("price"))

        // Unsupported in PHPantom 0.10.0: `keyBy()` loses the element type (it degrades to the
        // base Model), so the model's attributes are not offered after it.
        let keyed = LanguageTestSupport.labels(try await Self.complete(session, "App\\Models\\Widget::all()->keyBy('id')->first()->", trigger: ">"))
        #expect(keyed.contains("save"))
        #expect(!keyed.contains("price"))
    }

    @Test func collectHelperElementType() async throws {
        let session = await LanguageTestSupport.session(Self.root)
        defer { Task { await session.stop() } }
        let items = try await Self.complete(session, "collect([new App\\Services\\PriceFormatter])->first()->", trigger: ">")
        #expect(LanguageTestSupport.labels(items) == ["format"])
        #expect(Self.item("format", in: items)?.detail == "string")
        let hover = try #require(try await Self.hover(session, "$f = collect([new App\\Services\\PriceFormatter])->first();\n$f;", line: 1, character: 1))
        #expect(hover.markdown.contains("PriceFormatter|null"))
    }

    // MARK: Helper functions

    @Test func containerHelpersResolveClassStrings() async throws {
        let session = await LanguageTestSupport.session(Self.root)
        defer { Task { await session.stop() } }
        #expect(LanguageTestSupport.labels(try await Self.complete(session, "app(App\\Services\\PriceFormatter::class)->", trigger: ">")) == ["format"])
        #expect(LanguageTestSupport.labels(try await Self.complete(session, "resolve(App\\Services\\PriceFormatter::class)->", trigger: ">")) == ["format"])
        // Other helpers with declared return types.
        #expect(LanguageTestSupport.labels(try await Self.complete(session, "str('a')->", trigger: ">")).contains("slug"))
        #expect(LanguageTestSupport.labels(try await Self.complete(session, "now()->", trigger: ">")).contains("format"))
        let user = LanguageTestSupport.labels(try await Self.complete(session, "auth()->user()->", trigger: ">"))
        #expect(user.contains("email"))
    }

    @Test func configKeyCompletion() async throws {
        let session = await LanguageTestSupport.session(Self.root)
        defer { Task { await session.stop() } }
        let labels = try await Self.complete(session, "config('app.", trigger: nil).map(\.label)
        #expect(labels.contains("app.name"))
        #expect(labels.contains("app.timezone"))
        #expect(labels.contains("app.maintenance.driver"))
        #expect(labels.allSatisfy { $0.hasPrefix("app.") })

        // All config files are offered after `config('`.
        let all = try await Self.complete(session, "config('", trigger: nil).map(\.label)
        #expect(all.contains("database.default"))
        #expect(all.contains("cache.default"))
    }

    // MARK: Signature help

    @Test func strLimitSignatureHelp() async throws {
        let session = await LanguageTestSupport.session(Self.root)
        defer { Task { await session.stop() } }
        let editorText = "Str::limit('abc', "
        let (uri, mapping) = await LanguageTestSupport.open(session, root: Self.root, editorText: editorText)
        let help = try #require(try await session.signatureHelp(uri: uri, position: mapping.toLSP(Self.endPosition(of: editorText))))
        let signature = try #require(help.signatures.first)
        #expect(signature.label.contains("$limit = 100"))
        #expect(signature.label.hasSuffix(": string"))
        #expect(signature.parameterRanges.count == 4)
        // Parameter types come from the docblock.
        #expect(signature.parameterDocs.map { $0 ?? "" } == ["`string`", "`int`", "`string`", "`bool`"])
        #expect(help.activeParameter == 1)

        // Hover on the call gives the method summary.
        let hover = try await Self.hover(session, "Str::limit('a');", line: 0, character: 6)
        #expect(hover?.markdown.contains("Limit the number of characters in a string.") == true)
    }

    // MARK: Dynamically registered members

    @Test func macros() async throws {
        let session = await LanguageTestSupport.session(Self.root)
        defer { Task { await session.stop() } }
        // A macro registered in the same snippet is offered.
        let inline = LanguageTestSupport.labels(try await Self.complete(session, "Illuminate\\Support\\Collection::macro('shout', fn () => 1);\ncollect()->sh", trigger: nil))
        #expect(inline.contains("shout"))

        let workspace = try ModelWorkspace()
        defer { workspace.remove() }
        let projectSession = await LanguageTestSupport.session(workspace.root)
        defer { Task { await projectSession.stop() } }
        // Unsupported in PHPantom 0.10.0: a macro registered elsewhere in the project (here in
        // AppServiceProvider::boot) is not offered; only the class's declared members are.
        let fromProvider = LanguageTestSupport.labels(try await Self.complete(projectSession, root: workspace.root, "collect()->wh", trigger: nil))
        #expect(fromProvider.contains("where"))
        #expect(!fromProvider.contains("whisper"))
    }
}

enum LaravelFixture {
    static var root: URL { LanguageTestSupport.fixtures.appendingPathComponent("laravel-app") }
    static var hasVendor: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("vendor/laravel/framework").path)
    }
}

/// A throwaway Laravel-shaped project for model shapes the fixture lacks. Its `vendor` is a symlink
/// to the fixture's, so nothing is installed or copied.
struct ModelWorkspace {
    let root: URL

    init() throws {
        let fm = FileManager.default
        root = LanguageTestSupport.tempDirectory()
        try #"{"require":{"laravel/framework":"^13.0"},"autoload":{"psr-4":{"App\\":"app/"}}}"#
            .write(to: root.appendingPathComponent("composer.json"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: root.appendingPathComponent("vendor"), withDestinationURL: LaravelFixture.root.appendingPathComponent("vendor"))
        try fm.createDirectory(at: root.appendingPathComponent("app/Models"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("app/Providers"), withIntermediateDirectories: true)
        try write("app/Models/Gadget.php", #"""
        <?php
        namespace App\Models;

        use Illuminate\Database\Eloquent\Model;
        use Illuminate\Database\Eloquent\Relations\HasMany;

        class Gadget extends Model
        {
            protected function casts(): array
            {
                return [
                    'is_active' => 'boolean',
                    'meta' => 'array',
                    'released_at' => 'datetime',
                    'amount' => 'decimal:2',
                    'label' => 'integer',
                ];
            }

            public function parts(): HasMany
            {
                return $this->hasMany(Part::class);
            }

            /** @return HasMany<Part, $this> */
            public function partsGeneric(): HasMany
            {
                return $this->hasMany(Part::class);
            }

            public function partsInferred()
            {
                return $this->hasMany(Part::class);
            }
        }
        """#)
        try write("app/Models/Part.php", #"""
        <?php
        namespace App\Models;

        use Illuminate\Database\Eloquent\Model;

        class Part extends Model
        {
            public function gadget()
            {
                return $this->belongsTo(Gadget::class);
            }
        }
        """#)
        try write("app/Models/Gizmo.php", #"""
        <?php
        namespace App\Models;

        use Illuminate\Database\Eloquent\Model;

        class Gizmo extends Model
        {
            protected $casts = ['p_one' => 'boolean', 'p_two' => 'boolean'];

            protected function casts(): array
            {
                return ['m_one' => 'boolean', 'm_two' => 'boolean'];
            }
        }
        """#)
        try write("app/Providers/AppServiceProvider.php", #"""
        <?php
        namespace App\Providers;

        use Illuminate\Support\Collection;
        use Illuminate\Support\ServiceProvider;

        class AppServiceProvider extends ServiceProvider
        {
            public function boot(): void
            {
                Collection::macro('whisper', fn () => $this->map(fn ($value) => strtolower($value)));
            }
        }
        """#)
    }

    private func write(_ path: String, _ contents: String) throws {
        try contents.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
