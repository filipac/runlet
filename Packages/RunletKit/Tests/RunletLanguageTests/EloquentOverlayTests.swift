import Foundation
import Testing
@testable import RunletLanguage

/// The in-memory model copies Runlet opens for PHPantom (#55). Pure text checks; the effect on
/// completion is covered by `LaravelCompletionTests`.
struct EloquentOverlayTests {
    static func model(_ members: String, imports: String = "use Illuminate\\Database\\Eloquent\\Relations\\HasMany;") -> String {
        """
        <?php
        namespace App\\Models;

        use Illuminate\\Database\\Eloquent\\Model;
        \(imports)

        class Post extends Model
        {
        \(members)
        }
        """
    }

    // MARK: Relations

    @Test func nativeRelationReturnTypeIsBlankedWithoutMovingText() throws {
        let source = Self.model("""
            public function comments(): HasMany
            {
                return $this->hasMany(Comment::class);
            }
        """)
        let overlay = try #require(EloquentOverlay.overlay(for: source))
        #expect(overlay.contains("public function comments()         \n"))
        #expect(!overlay.contains(": HasMany"))
        // Same length and line structure: nothing after the return type moves.
        #expect(overlay.utf8.count == source.utf8.count)
        #expect(overlay.components(separatedBy: "\n").count == source.components(separatedBy: "\n").count)
    }

    @Test func everyRelationKindWithAModelArgument() throws {
        for (type, builder) in [("HasOne", "hasOne"), ("HasMany", "hasMany"), ("BelongsTo", "belongsTo"), ("BelongsToMany", "belongsToMany"), ("MorphOne", "morphOne"), ("MorphMany", "morphMany"), ("MorphToMany", "morphToMany"), ("MorphToMany", "morphedByMany"), ("HasManyThrough", "hasManyThrough"), ("HasOneThrough", "hasOneThrough")] {
            let source = Self.model("""
                public function related(): \(type)
                {
                    return $this->\(builder)(\\App\\Models\\Other::class, 'x');
                }
            """, imports: "use Illuminate\\Database\\Eloquent\\Relations\\\(type);")
            let overlay = EloquentOverlay.overlay(for: source)
            #expect(overlay?.contains(": \(type)") == false, "\(builder)")
        }
    }

    @Test func qualifiedReturnTypesAndModifiers() throws {
        let source = Self.model("""
            #[\\Override]
            final public function a(): \\Illuminate\\Database\\Eloquent\\Relations\\BelongsTo { return $this->belongsTo(User::class); }
            public function b() : Relations\\HasOne
            {
                return $this->hasOne(Profile::class)->latestOfMany();
            }
        """)
        let overlay = try #require(EloquentOverlay.overlay(for: source))
        #expect(!overlay.contains("BelongsTo {"))
        #expect(!overlay.contains("Relations\\HasOne"))
        #expect(overlay.contains("$this->belongsTo(User::class)"))
    }

    @Test func relationsPHPantomAlreadyReadsAreLeftAlone() {
        let unchanged = [
            // Generic @return: PHPantom reads the related model from it.
            """
                /** @return HasMany<Comment, $this> */
                public function comments(): HasMany { return $this->hasMany(Comment::class); }
            """,
            // A bare @return tag also wins over body inference; keep the author's declaration.
            """
                /**
                 * Comments.
                 *
                 * @return HasMany
                 */
                public function comments(): HasMany { return $this->hasMany(Comment::class); }
            """,
            // No native return type: PHPantom already infers from the body.
            "    public function comments() { return $this->hasMany(Comment::class); }",
            // No `::class` argument: inference would name no model, so the native type stays.
            "    public function comments(): HasMany { return $this->hasMany($this->commentClass()); }",
            // The body builds a different relation than the method declares.
            "    public function comments(): HasMany { return $this->hasOne(Comment::class); }",
            // Nullable or union return types.
            "    public function comments(): ?HasMany { return $this->hasMany(Comment::class); }",
            "    public function comments(): HasMany|null { return $this->hasMany(Comment::class); }",
            // MorphTo has no related model to infer.
            "    public function commentable(): MorphTo { return $this->morphTo(); }",
            // Abstract and interface methods have no body.
            "    abstract public function comments(): HasMany;",
            // Not a relation type.
            "    public function query(): Builder { return $this->hasMany(Comment::class); }",
        ]
        for members in unchanged {
            #expect(EloquentOverlay.overlay(for: Self.model(members)) == nil, "\(members)")
        }
    }

    @Test func aDocblockWithoutAReturnTagDoesNotBlockTheFix() throws {
        let source = Self.model("""
            /**
             * The post's comments.
             */
            #[Pure]
            public function comments(): HasMany
            {
                return $this->hasMany(Comment::class);
            }
        """)
        #expect(try #require(EloquentOverlay.overlay(for: source)).contains("public function comments()         "))
    }

    @Test func codeInsideCommentsStringsAndHeredocsIsIgnored() {
        let source = Self.model("""
            // public function a(): HasMany { return $this->hasMany(A::class); }
            /* public function b(): HasMany { return $this->hasMany(B::class); } */
            public string $example = 'public function c(): HasMany { return $this->hasMany(C::class); }';
            public function sql(): string
            {
                return <<<SQL
                    public function d(): HasMany { return $this->hasMany(D::class); }
                    SQL;
            }
        """)
        #expect(EloquentOverlay.overlay(for: source) == nil)
    }

    @Test func unterminatedInputIsNotChanged() {
        #expect(EloquentOverlay.overlay(for: "<?php\nclass A { public function a(): HasMany { return $this->hasMany(B::class); } /* open") == nil)
        #expect(EloquentOverlay.overlay(for: "<?php\nclass A { public function a(): HasMany { return $this->hasMany(B::class); } $s = 'open") == nil)
    }

    // MARK: Casts

    @Test func castsMethodGetsATrailingComma() throws {
        let single = Self.model("""
            protected function casts(): array
            {
                return ['is_active' => 'boolean', 'meta' => 'array'];
            }
        """)
        #expect(try #require(EloquentOverlay.overlay(for: single)).contains("['is_active' => 'boolean', 'meta' => 'array',];"))

        let multi = Self.model("""
            protected function casts(): array
            {
                return [
                    'is_active' => 'boolean',
                    'status' => Status::class // backed enum
                ];
            }
        """)
        let overlay = try #require(EloquentOverlay.overlay(for: multi))
        #expect(overlay.contains("'status' => Status::class, // backed enum\n"))

        let merged = Self.model("""
            protected function casts(): array
            {
                return array_merge(parent::casts(), ['a' => 'integer', 'b' => AsCollection::of(Tag::class)]);
            }
        """)
        #expect(try #require(EloquentOverlay.overlay(for: merged)).contains("'b' => AsCollection::of(Tag::class),]"))
    }

    @Test func castsThatPHPantomAlreadyReadsAreLeftAlone() {
        for members in [
            "    protected function casts(): array { return ['a' => 'boolean',]; }",
            "    protected function casts(): array { return [\n        'a' => 'boolean',\n    ]; }",
            "    protected function casts(): array { return []; }",
            // The property form is read correctly, with or without a trailing comma.
            "    protected $casts = ['a' => 'boolean', 'b' => 'boolean'];",
        ] {
            #expect(EloquentOverlay.overlay(for: Self.model(members)) == nil, "\(members)")
        }
        // A comma inside a string is not a trailing comma.
        let commaInString = Self.model("    protected function casts(): array { return ['a' => 'decimal:2', 'b' => 'x,']; }")
        #expect(EloquentOverlay.overlay(for: commaInString)?.contains("'b' => 'x,',]") == true)
    }

    @Test func bothFixesInOneFile() throws {
        let source = Self.model("""
            protected function casts(): array
            {
                return ['a' => 'boolean'];
            }

            public function comments(): HasMany
            {
                return $this->hasMany(Comment::class);
            }
        """)
        let overlay = try #require(EloquentOverlay.overlay(for: source))
        #expect(overlay.contains("['a' => 'boolean',]"))
        #expect(overlay.contains("public function comments()         \n"))
    }

    // MARK: Project scan

    @Test func projectScanReadsAutoloadDirectoriesOnlyAndWritesNothing() throws {
        let root = LanguageTestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let relation = Self.model("    public function comments(): HasMany { return $this->hasMany(Comment::class); }")
        try write("composer.json", #"{"autoload":{"psr-4":{"App\\":"app/","Domain\\":"src/Domain"}}}"#)
        try write("app/Models/Post.php", relation)
        try write("app/Models/Plain.php", "<?php\nnamespace App\\Models;\nclass Plain {}\n")
        try write("src/Domain/Post.php", relation)
        try write("app/node_modules/x/Post.php", relation)
        try write("vendor/acme/Post.php", relation)
        try write("lib/Post.php", relation)
        let before = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("app/Models").path).sorted()

        let documents = EloquentOverlay.documents(root: root)
        let uris = Set(documents.map(\.uri))
        #expect(uris == [
            root.appendingPathComponent("app/Models/Post.php").absoluteString,
            root.appendingPathComponent("src/Domain/Post.php").absoluteString,
        ])
        // The project is unchanged on disk.
        #expect(try String(contentsOf: root.appendingPathComponent("app/Models/Post.php"), encoding: .utf8) == relation)
        #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("app/Models").path).sorted() == before)

        var limits = EloquentOverlay.Limits()
        limits.maxDocuments = 1
        #expect(EloquentOverlay.documents(root: root, limits: limits).count == 1)
    }

    @Test func sourceDirectoriesFallBackToAppAndStayInsideTheRoot() throws {
        let root = LanguageTestSupport.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(EloquentOverlay.sourceDirectories(root: root) == ["app"])
        try #"{"autoload":{"psr-4":{"A\\":"../outside","B\\":"/abs","C\\":"vendor/x","D\\":["app/","app/Models"]}}}"#
            .write(to: root.appendingPathComponent("composer.json"), atomically: true, encoding: .utf8)
        #expect(EloquentOverlay.sourceDirectories(root: root) == ["app"])
    }
}
