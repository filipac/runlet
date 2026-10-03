import Foundation
import Testing
@testable import RunletCore

/// Parameterised snippets (#14): `@input` declarations, the form's values, PHP literals, and
/// the code a snippet opens with.
struct SnippetInputsTests {
    private func input(_ declaration: String) -> SnippetInput? {
        try? SnippetInputs.parseDeclaration(declaration).get()
    }

    private func problem(_ declaration: String) -> String? {
        if case .failure(let problem) = SnippetInputs.parseDeclaration(declaration) { return problem.message }
        return nil
    }

    // MARK: Declarations

    @Test func readsTypesNamesLabelsAndDefaults() {
        #expect(input(#"int $userId "User ID""#) == SnippetInput(kind: .int, name: "userId", label: "User ID"))
        #expect(input("string $email") == SnippetInput(kind: .string, name: "email"))
        #expect(input("string $email")?.label == "email")
        #expect(input(#"int $limit "Limit" = 10"#) == SnippetInput(kind: .int, name: "limit", label: "Limit", defaultValue: .int(10)))
        #expect(input("float $rate = 1.5") == SnippetInput(kind: .float, name: "rate", defaultValue: .float(1.5)))
        #expect(input("float $rate = -2") == SnippetInput(kind: .float, name: "rate", defaultValue: .float(-2)))
        #expect(input(#"bool $notify "Notify the customer" = true"#) == SnippetInput(kind: .bool, name: "notify", label: "Notify the customer", defaultValue: .bool(true)))
        #expect(input("bool $dryRun") == SnippetInput(kind: .bool, name: "dryRun"))
        #expect(input("Int $n")?.kind == .int)
        #expect(input("  string   $s   'Single quoted'   =   'it\\'s'  ") == SnippetInput(kind: .string, name: "s", label: "Single quoted", defaultValue: .string("it's")))
        #expect(input(#"string $s "Say \"hi\" \\ bye" = "a\\b""#) == SnippetInput(kind: .string, name: "s", label: #"Say "hi" \ bye"#, defaultValue: .string(#"a\b"#)))
        #expect(input("string $status = paid") == SnippetInput(kind: .string, name: "status", defaultValue: .string("paid")))
        #expect(input(#"string $s = """#) == SnippetInput(kind: .string, name: "s", defaultValue: .string("")))
        #expect(input("string $ünïcode_1") == SnippetInput(kind: .string, name: "ünïcode_1"))
        #expect(input(#"int $x """#) == SnippetInput(kind: .int, name: "x"))
        #expect(input(#"int $x"Tight"=3"#) == SnippetInput(kind: .int, name: "x", label: "Tight", defaultValue: .int(3)))
    }

    @Test func readsChoiceLists() {
        let status = input(#"string $status "Status" = "paid" {paid,shipped,refunded}"#)
        #expect(status == SnippetInput(kind: .string, name: "status", label: "Status", defaultValue: .string("paid"), choices: [.string("paid"), .string("shipped"), .string("refunded")]))

        // Without a default, the first choice; quoted choices keep commas, braces, and spaces.
        let quoted = input(#"string $s { a , "on hold", 'x,}y' }"#)
        #expect(quoted?.choices == [.string("a"), .string("on hold"), .string("x,}y")])
        #expect(quoted?.defaultValue == .string("a"))

        let numbers = input("int $n = 2 {1, 2, 3, 2}")
        #expect(numbers?.choices == [.int(1), .int(2), .int(3)])
        #expect(numbers?.defaultValue == .int(2))
        #expect(input("float $f {0.5, 1}")?.choices == [.float(0.5), .float(1)])
    }

    @Test func explainsInvalidDeclarations() {
        #expect(problem("")?.contains("needs a type and a variable") == true)
        #expect(problem("$userId")?.contains("type is missing before $userId") == true)
        #expect(problem("integer $x")?.contains("“integer” is not an input type. Use int, float, string, or bool.") == true)
        #expect(problem("array $x")?.contains("not an input type") == true)
        #expect(problem("int")?.contains("variable is missing") == true)
        #expect(problem("int userId")?.contains("needs a $, like $userId") == true)
        #expect(problem("int $1abc")?.contains("not a valid PHP variable name") == true)
        #expect(problem("int $")?.contains("not a valid PHP variable name") == true)
        #expect(problem("int $a-b")?.contains("not a valid PHP variable name") == true)
        #expect(problem("int $this")?.contains("$this can't be an input") == true)
        #expect(problem("int $GLOBALS")?.contains("can't be an input") == true)
        #expect(problem(#"int $x "unterminated"#)?.contains("label's closing quote") == true)
        #expect(problem(#"int $x = "5"#)?.contains("default's closing quote") == true)
        #expect(problem("int $x =")?.contains("needs a default value") == true)
        #expect(problem("int $x = abc")?.contains("default “abc” doesn't fit int") == true)
        #expect(problem("int $x = 1.5")?.contains("doesn't fit int") == true)
        #expect(problem("bool $x = maybe")?.contains("Use true or false") == true)
        #expect(problem("float $x = inf")?.contains("doesn't fit float") == true)
        #expect(problem("bool $x {true, false}")?.contains("bool inputs can't list choices") == true)
        #expect(problem("string $x {}")?.contains("choice list is empty") == true)
        #expect(problem("string $x { , }")?.contains("choice list is empty") == true)
        #expect(problem("string $x {a, b")?.contains("closing } is missing") == true)
        #expect(problem(#"string $s = "z" {a,b}"#)?.contains("default 'z' is not one of the choices") == true)
        #expect(problem("int $n {1, two}")?.contains("choice “two” doesn't fit int") == true)
        #expect(problem("int $x User ID")?.contains("Put the label in double quotes") == true)
        #expect(problem(#"int $x "X" = 1 extra"#)?.contains("Unexpected “extra” at the end") == true)
        #expect(problem(#"string $x {a} "late label""#)?.contains("Unexpected") == true)
    }

    @Test func repeatedVariablesAndBadLinesBecomeProblems() {
        let set = SnippetInputs.parse(declarations: ["int $a", "string $b", "float $a", "nope $c", "string $B"])
        #expect(set.inputs.map(\.name) == ["a", "b", "B"])
        #expect(set.problems.count == 2)
        #expect(set.problems[0].description == "@input float $a: $a is declared more than once; only the first declaration is used.")
        #expect(set.problems[1].declaration == "nope $c")
        #expect(SnippetInputProblem(declaration: "", message: "m").description == "@input: m")
        #expect(SnippetInputs.parse(declarations: []).isEmpty)
    }

    @Test func readsLeadingDocblocksOnly() {
        let code = """
        <?php
        // A runbook
        /**
         * Refund an order.
         * @input int $orderId "Order ID"
         * @inputs not-an-input
         * @input
         * @label ignored here
         */
        # another comment
        /* @input int $notInDocblock */
        /** @input string $reason = "duplicate" */
        $order = Order::find($orderId);
        /** @input int $afterCode */
        """
        #expect(SnippetInputs.declarations(inLeadingCommentsOf: Substring(code)) == [#"int $orderId "Order ID""#, "", #"string $reason = "duplicate""#])
        let set = SnippetInputs.parse(code: code)
        #expect(set.inputs.map(\.name) == ["orderId", "reason"])
        #expect(set.problems.map(\.declaration) == [""])

        #expect(SnippetInputs.parse(code: "echo 1;\n/** @input int $x */").isEmpty)
        #expect(SnippetInputs.parse(code: "<?phpx /** @input int $x */").isEmpty)
        #expect(SnippetInputs.parse(code: "#[Attr]\n/** @input int $x */").isEmpty)
        #expect(SnippetInputs.parse(code: "\u{FEFF}/** @input int $x */").inputs.map(\.name) == ["x"])
        #expect(SnippetInputs.parse(code: "/** @input int $x*/").inputs.map(\.name) == ["x"])
        #expect(SnippetInputs.parse(code: "/**/ /***/ /** */").isEmpty)
        #expect(SnippetInputs.parse(code: "/** @input int $x").isEmpty)
        #expect(SnippetInputs.parse(code: "").isEmpty)
    }

    @Test func personalSnippetsReadTheirCode() {
        let snippet = Snippet(label: "Find", code: "/**\n * @input int $userId \"User ID\"\n */\nUser::find($userId);")
        #expect(snippet.inputs.inputs == [SnippetInput(kind: .int, name: "userId", label: "User ID")])
        #expect(Snippet(label: "Plain", code: "User::first();").inputs.isEmpty)
    }

    // MARK: Project snippets

    private func project(_ contents: String) -> ProjectSnippet {
        ProjectSnippets.parse(contents, fileURL: URL(fileURLWithPath: "/project/.runlet/snippets/refund.php"))
    }

    @Test func projectMetadataDocblockDeclaresInputs() {
        let snippet = project("""
        <?php
        /**
         * @label Refund order
         * @description Refunds an order
         *   and tells the customer.
         * @input int $orderId "Order ID"
         * @input string $reason "Reason" = "duplicate" {duplicate, fraudulent}
         * @input bogus
         */

        Order::findOrFail($orderId)->refund($reason);

        """)
        #expect(snippet.label == "Refund order")
        #expect(snippet.description == "Refunds an order and tells the customer.")
        #expect(snippet.code == "Order::findOrFail($orderId)->refund($reason);")
        #expect(snippet.inputs.inputs.map(\.name) == ["orderId", "reason"])
        #expect(snippet.inputs.problems.map(\.declaration) == ["bogus"])
        #expect(snippet.metadataInputDeclarations == [#"int $orderId "Order ID""#, #"string $reason "Reason" = "duplicate" {duplicate, fraudulent}"#, "bogus"])

        // A personal copy keeps the declarations in a docblock of its own and reads the same inputs.
        let copy = Snippet(label: snippet.label, code: snippet.personalCode)
        #expect(copy.code.hasPrefix("/**\n * @input int $orderId \"Order ID\"\n"))
        #expect(copy.code.hasSuffix(" */\nOrder::findOrFail($orderId)->refund($reason);"))
        #expect(copy.inputs == snippet.inputs)
    }

    @Test func inputOnlyDocblockIsMetadata() {
        let snippet = project("<?php\n/** @input int $id */\necho $id;")
        #expect(snippet.label == "refund")
        #expect(snippet.code == "echo $id;")
        #expect(snippet.inputs.inputs.map(\.name) == ["id"])
    }

    @Test func laterLeadingDocblocksAlsoDeclareInputs() {
        // Save Snippet ▸ Project writes its own label docblock above code that has one.
        let file = ProjectSnippets.fileContents(label: "Find user", description: nil, code: "<?php\n/**\n * @input int $userId\n */\nUser::find($userId);")
        let snippet = project(file)
        #expect(snippet.label == "Find user")
        #expect(snippet.code == "/**\n * @input int $userId\n */\nUser::find($userId);")
        #expect(snippet.inputs.inputs.map(\.name) == ["userId"])
        #expect(snippet.metadataInputDeclarations.isEmpty)
        #expect(snippet.personalCode == snippet.code)
    }

    @Test func snippetsWithoutInputsAreUnchanged() {
        let snippet = project("<?php\n/**\n * @label Recent users\n */\n\nUser::latest()->take(10)->get();\n")
        #expect(snippet.inputs.isEmpty)
        #expect(snippet.metadataInputDeclarations.isEmpty)
        #expect(snippet.personalCode == snippet.code)
        #expect(snippet.code == "User::latest()->take(10)->get();")
        #expect(SnippetInputs.code(snippet.code, inputs: [], values: [:]) == snippet.code)
    }

    // MARK: Typed text

    @Test func parsesIntegers() throws {
        let int = SnippetInput.Kind.int
        #expect(try int.parse("42").get() == .int(42))
        #expect(try int.parse(" -7 ").get() == .int(-7))
        #expect(try int.parse("+3").get() == .int(3))
        #expect(try int.parse("1_000_000").get() == .int(1_000_000))
        #expect(try int.parse("007").get() == .int(7))
        #expect(try int.parse("9223372036854775807").get() == .int(Int.max))
        #expect(try int.parse("-9223372036854775808").get() == .int(Int.min))
        for bad in ["", " ", "1.5", "0x1A", "1e3", "1__0", "_1", "1_", "--1", "one", "4 2", "١٢"] {
            #expect((try? int.parse(bad).get()) == nil, "\(bad)")
        }
        #expect(int.parse("9223372036854775808").failureMessage?.contains("Too large") == true)
        #expect(int.parse("-9223372036854775809").failureMessage?.contains("Too large") == true)
        #expect(int.parse("abc").failureMessage == "Enter a whole number, like 42.")
    }

    @Test func parsesFloats() throws {
        let float = SnippetInput.Kind.float
        #expect(try float.parse("1.5").get() == .float(1.5))
        #expect(try float.parse("1.").get() == .float(1))
        #expect(try float.parse(".5").get() == .float(0.5))
        #expect(try float.parse("-0.0").get() == .float(-0.0))
        #expect(try float.parse("42").get() == .float(42))
        #expect(try float.parse("1e10").get() == .float(1e10))
        #expect(try float.parse(" 2.5E-3 ").get() == .float(0.0025))
        #expect(try float.parse("1e-400").get() == .float(0))
        for bad in ["", "inf", "-INF", "nan", "NaN", "infinity", "0x1p3", "1.2.3", "e5", ".", "1e", "1,5", "abc"] {
            #expect((try? float.parse(bad).get()) == nil, "\(bad)")
        }
        #expect(float.parse("1e400").failureMessage == "Too large for a float.")
        #expect(float.parse("-1e309").failureMessage == "Too large for a float.")
        #expect(float.parse("1,5").failureMessage == "Use a dot for decimals, like 1.5.")
    }

    @Test func parsesBooleansAndStrings() throws {
        for yes in ["true", "TRUE", "1", "yes", "on", " true "] { #expect(try SnippetInput.Kind.bool.parse(yes).get() == .bool(true)) }
        for no in ["false", "False", "0", "no", "off"] { #expect(try SnippetInput.Kind.bool.parse(no).get() == .bool(false)) }
        #expect((try? SnippetInput.Kind.bool.parse("maybe").get()) == nil)
        #expect(try SnippetInput.Kind.string.parse("  kept as typed \n").get() == .string("  kept as typed \n"))
    }

    // MARK: Literals

    @Test func intLiteralsMatchVarExport() {
        #expect(SnippetInputValue.int(0).phpLiteral == "0")
        #expect(SnippetInputValue.int(-1).phpLiteral == "-1")
        #expect(SnippetInputValue.int(Int.max).phpLiteral == "9223372036854775807")
        #expect(SnippetInputValue.int(Int.min).phpLiteral == "-9223372036854775807-1")
        #expect(SnippetInputValue.int(Int.min + 1).phpLiteral == "-9223372036854775807")
    }

    @Test func floatLiteralsMatchVarExport() {
        // Expected texts are PHP 8.4's var_export output.
        let cases: [(Double, String)] = [
            (1, "1.0"), (0.1, "0.1"), (1e100, "1.0E+100"), (-0.0, "-0.0"), (0, "0.0"),
            (1e-5, "1.0E-5"), (0.0001, "0.0001"), (0.001, "0.001"), (1e16, "10000000000000000.0"),
            (1e17, "1.0E+17"), (123456789012345678, "1.2345678901234568E+17"), (5e-324, "5.0E-324"),
            (.greatestFiniteMagnitude, "1.7976931348623157E+308"), (1e15, "1000000000000000.0"),
            (0.1 + 0.2, "0.30000000000000004"), (-1.5e-7, "-1.5E-7"), (1.5, "1.5"), (-2, "-2.0"),
            (123.456, "123.456"), (2.5e-3, "0.0025"), (1234567.0, "1234567.0"), (1.25e20, "1.25E+20"),
            (.leastNormalMagnitude, "2.2250738585072014E-308"), (9007199254740993, "9007199254740992.0"),
        ]
        for (value, expected) in cases {
            #expect(SnippetInputs.phpFloat(value) == expected, "\(value)")
        }
        #expect(SnippetInputs.phpFloat(.infinity) == nil)
        #expect(SnippetInputs.phpFloat(-.infinity) == nil)
        #expect(SnippetInputs.phpFloat(.nan) == nil)
    }

    @Test func stringLiteralsEscape() {
        let cases: [(String, String)] = [
            ("", "''"),
            ("plain", "'plain'"),
            ("it's", #"'it\'s'"#),
            (#"C:\path\"#, #"'C:\\path\\'"#),
            (#"\'"#, #"'\\\''"#),
            ("$x {$y} ${z}", "'$x {$y} ${z}'"),
            (#"say "hi""#, #"'say "hi"'"#),
            ("Zoë 🎉 中文", "'Zoë 🎉 中文'"),
            ("e\u{301}\\\u{301}", "'e\u{301}\\\\\u{301}'"),
            ("a\nb", #""a\nb""#),
            ("a\r\nb\tc", #""a\r\nb\tc""#),
            ("a\0b", #""a\x00b""#),
            ("\0" + "1", #""\x001""#),
            ("\u{0B}\u{0C}\u{1B}\u{07}\u{7F}", #""\v\f\e\x07\x7F""#),
            ("$x\n", #""\$x\n""#),
            ("{$x}\n", #""{\$x}\n""#),
            ("\"\\\n'", #""\"\\\n'""#),
            ("line\u{2028}sep\u{2029}", #""line\u{2028}sep\u{2029}""#),
            ("\u{85}", #""\u{85}""#),
            ("abc\u{202E}def", #""abc\u{202E}def""#),
            ("\u{FEFF}bom", #""\u{FEFF}bom""#),
            ("\u{200F}", #""\u{200F}""#),
        ]
        for (value, expected) in cases {
            #expect(SnippetInputs.phpString(value) == expected, "\(value.debugDescription)")
            #expect(!SnippetInputs.phpString(value).contains("\n"))
        }
        #expect(SnippetInputValue.bool(true).phpLiteral == "true")
        #expect(SnippetInputValue.bool(false).phpLiteral == "false")
    }

    // MARK: Opening

    private let id = SnippetInput(kind: .int, name: "userId")
    private let email = SnippetInput(kind: .string, name: "email")

    @Test func headerGoesAboveTheCode() {
        let code = SnippetInputs.code("User::find($userId);", inputs: [id, email], values: ["userId": .int(42), "email": .string("a@b.test")])
        #expect(code == "$userId = 42;\n$email = 'a@b.test';\n\nUser::find($userId);")
        #expect(SnippetInputs.code("", inputs: [id], values: ["userId": .int(1)]) == "$userId = 1;")
        #expect(SnippetInputs.code("\n\n", inputs: [id], values: ["userId": .int(1)]) == "$userId = 1;")
        // Inputs without a value (declarations that could not be read) are left out.
        #expect(SnippetInputs.code("echo 1;", inputs: [id, email], values: ["email": .string("x")]) == "$email = 'x';\n\necho 1;")
        #expect(SnippetInputs.code("echo 1;", inputs: [id], values: [:]) == "echo 1;")
    }

    @Test func headerGoesAfterTheTagDocblockAndImports() {
        let personal = """
        <?php
        declare(strict_types=1);
        namespace Ops;
        /**
         * @input int $userId "User ID"
         */

        use App\\Models\\User; // models
        use function Illuminate\\Support\\now;

        // Look the user up
        User::find($userId);
        """
        #expect(SnippetInputs.code(personal, inputs: [id], values: ["userId": .int(7)]) == """
        <?php
        declare(strict_types=1);
        namespace Ops;
        /**
         * @input int $userId "User ID"
         */

        use App\\Models\\User; // models
        use function Illuminate\\Support\\now;

        $userId = 7;

        // Look the user up
        User::find($userId);
        """)

        // A plain block comment describes the code below it: the values go above it.
        #expect(SnippetInputs.code("/*\n * Notes\n */\necho $userId;", inputs: [id], values: ["userId": .int(1)]) == "$userId = 1;\n\n/*\n * Notes\n */\necho $userId;")
        // A tag with code after it gets a line of its own.
        #expect(SnippetInputs.code("<?php echo $userId;", inputs: [id], values: ["userId": .int(1)]) == "<?php\n$userId = 1;\n\necho $userId;")
        #expect(SnippetInputs.code("<?php // note\necho $userId;", inputs: [id], values: ["userId": .int(1)]) == "<?php // note\n$userId = 1;\n\necho $userId;")
        // A multi-line use stops the opening lines; values may come before imports in PHP.
        #expect(SnippetInputs.code("use App\\{\n  A,\n};\nA::x($userId);", inputs: [id], values: ["userId": .int(1)]) == "$userId = 1;\n\nuse App\\{\n  A,\n};\nA::x($userId);")
    }

    @Test func placeholderAssignmentsAreReplacedInPlace() {
        let code = """
        use App\\Models\\Order;

        $orderId = 0; // change me
          $email = 'someone@example.test';
        $order = Order::findOrFail($orderId);
        $email = 'not a placeholder';
        """
        let opened = SnippetInputs.code(code, inputs: [SnippetInput(kind: .int, name: "orderId"), email, SnippetInput(kind: .bool, name: "notify")],
                                        values: ["orderId": .int(1042), "email": .string("o'neil@example.test"), "notify": .bool(true)])
        #expect(opened == """
        use App\\Models\\Order;

        $notify = true;

        $orderId = 1042; // change me
          $email = 'o\\'neil@example.test';
        $order = Order::findOrFail($orderId);
        $email = 'not a placeholder';
        """)

        // All placeholders: nothing is added, so line numbers match the snippet's.
        let all = SnippetInputs.code("$userId = null;\r\nUser::find($userId);", inputs: [id], values: ["userId": .int(5)])
        #expect(all == "$userId = 5;\r\nUser::find($userId);")

        // Assignments after other code, compound assignments, and comparisons are code.
        #expect(SnippetInputs.code("echo 1;\n$userId = 0;", inputs: [id], values: ["userId": .int(5)]) == "$userId = 5;\n\necho 1;\n$userId = 0;")
        #expect(SnippetInputs.code("$userId .= 'x';", inputs: [id], values: ["userId": .int(5)]) == "$userId = 5;\n\n$userId .= 'x';")
        #expect(SnippetInputs.code("$userId == 1;", inputs: [id], values: ["userId": .int(5)]) == "$userId = 5;\n\n$userId == 1;")
        #expect(SnippetInputs.code("$userId = function () {\n};", inputs: [id], values: ["userId": .int(5)]) == "$userId = 5;\n\n$userId = function () {\n};")
        // Strings with comment markers stay intact.
        #expect(SnippetInputs.code("$email = 'http://x#y'; # note", inputs: [email], values: ["email": .string("z")]) == "$email = 'z'; # note")
    }

    @Test func placeholderNames() {
        #expect(SnippetInputs.placeholderName("$a = 1;") == "a")
        #expect(SnippetInputs.placeholderName("$_x9=null ; // c") == "_x9")
        #expect(SnippetInputs.placeholderName("$ü = 'x';") == "ü")
        #expect(SnippetInputs.placeholderName("$a = 1") == nil)
        #expect(SnippetInputs.placeholderName("$a = 1; echo 2;") == nil)
        #expect(SnippetInputs.placeholderName("$a => 1;") == nil)
        #expect(SnippetInputs.placeholderName("$a->b = 1;") == nil)
        #expect(SnippetInputs.placeholderName("$a['k'] = 1;") == nil)
    }

    // MARK: Form

    @Test func formStartsAtDefaultsAndValidates() {
        let inputs = SnippetInputs.parse(declarations: [
            #"int $orderId "Order ID""#,
            #"float $amount = 9.5"#,
            #"string $reason "Reason" = "duplicate" {duplicate, fraudulent}"#,
            #"bool $notify = true"#,
            #"string $note"#,
        ]).inputs
        var form = SnippetInputForm(inputs: inputs)
        #expect(form.texts == ["orderId": "", "amount": "9.5", "note": ""])
        #expect(form.flags == ["notify": true])
        #expect(form.selections == ["reason": 0])
        #expect(!form.isValid)
        #expect(form.error(for: inputs[0]) == "Enter a whole number.")
        #expect(form.assignments.first == "$orderId = …;")
        #expect(form.code(for: "x();") == nil)

        do { let changed = form.set("orderId", to: "1042"); #expect(changed) }
        do { let changed = form.set("reason", to: "fraudulent"); #expect(changed) }
        do { let changed = form.set("notify", to: "false"); #expect(changed) }
        do { let changed = form.set("note", to: "it's done\n"); #expect(changed) }
        do { let changed = form.set("reason", to: "unknown"); #expect(!changed) }
        do { let changed = form.set("missing", to: "1"); #expect(!changed) }
        do { let changed = form.set("notify", to: "maybe"); #expect(!changed) }
        #expect(form.isValid)
        #expect(form.values == ["orderId": .int(1042), "amount": .float(9.5), "reason": .string("fraudulent"), "notify": .bool(false), "note": .string("it's done\n")])
        #expect(form.assignments == ["$orderId = 1042;", "$amount = 9.5;", "$reason = 'fraudulent';", "$notify = false;", #"$note = "it's done\n";"#])
        #expect(form.code(for: "refund($orderId);") == "$orderId = 1042;\n$amount = 9.5;\n$reason = 'fraudulent';\n$notify = false;\n$note = \"it's done\\n\";\n\nrefund($orderId);")

        do { let changed = form.set("amount", to: "1,5"); #expect(changed) }
        #expect(form.error(for: inputs[1]) == "Use a dot for decimals, like 1.5.")
        #expect(form.values == nil)
    }
}

extension Result where Failure == SnippetInput.Kind.ParseError {
    var failureMessage: String? {
        if case .failure(let error) = self { return error.message }
        return nil
    }
}
