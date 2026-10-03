import Foundation
import RunletCore
import Testing
@testable import RunletLanguage

/// Format Code (#36): the Swift wrapper around Mago, with a fake formatter executable.
@Suite struct SnippetFormatterUnitTests {
    // MARK: Scanner

    @Test func scannerSeparatesCodeCommentsAndStrings() {
        let tokens = PHPScanner.tokens("<?php\n$a = \"x //? y\"; //?\n$b = 'it\\'s' /*?*/;\n# note\n#[Attr]\n")
        let comments = tokens.filter(\.isComment).map(\.text)
        #expect(comments == ["//?", "/*?*/", "# note"])
        #expect(tokens.filter { $0.kind == .string }.map(\.text) == ["\"x //? y\"", "'it\\'s'"])
        #expect(tokens.first?.kind == .openTag)
        #expect(tokens.contains { $0.kind == .punctuation && $0.text == "#" })
        let magic = tokens.first { $0.text == "//?" }
        #expect(magic?.line == 1)
    }

    @Test func scannerSkipsHeredocsInterpolationAndInlineHTML() {
        let source = "<?php\n$s = <<<EOT\n  // not a comment {$a['}']}\n  EOT;\n$t = \"{$u[\"k\"]} /* no */\";\necho 1 ?>\n<b>// html</b>\n<?php echo 2; // yes\n"
        let tokens = PHPScanner.tokens(source)
        #expect(tokens.filter(\.isComment).map(\.text) == ["// yes"])
        #expect(tokens.filter { $0.kind == .string }.count == 2)
        #expect(tokens.contains { $0.kind == .closeTag })
        #expect(tokens.contains { $0.kind == .inlineHTML && $0.text.contains("// html") })
        #expect(tokens.last { $0.isComment }?.line == 7)
    }

    // MARK: Snippet shape

    @Test func finalSemicolonIsAddedAfterTheLastCodeTokenAndRemovedAgain() {
        #expect(SnippetFormatter.closingFinalStatement("<?php\nUser::first() //?\n") == "<?php\nUser::first(); //?\n")
        #expect(SnippetFormatter.closingFinalStatement("<?php\nfoo()\n// note\n") == "<?php\nfoo();\n// note\n")
        #expect(SnippetFormatter.closingFinalStatement("<?php\n$a = 1;\n") == nil)
        #expect(SnippetFormatter.closingFinalStatement("<?php\necho 1 ?>\n<b>x</b>") == nil)
        #expect(SnippetFormatter.removingFinalSemicolon("<?php\n\nUser::first(); //?\n") == "<?php\n\nUser::first() //?\n")
        #expect(SnippetFormatter.removingFinalSemicolon("<?php\n\nfoo() /*?->x*/ ;\n") == "<?php\n\nfoo() /*?->x*/\n")
        #expect(SnippetFormatter.removingFinalSemicolon("<?php\n\nif ($a) {\n}\n") == "<?php\n\nif ($a) {\n}\n")
    }

    @Test func syntheticTagAndItsBlankLinesAreRemoved() {
        #expect(SnippetFormatter.removingSyntheticTag("<?php\n\n$a = 1;\n") == "$a = 1;\n")
        #expect(SnippetFormatter.removingSyntheticTag("<?php declare(strict_types=1);\n") == "declare(strict_types=1);\n")
    }

    // MARK: Comment checks

    @Test func magicCommentFormsMatchTheRunner() {
        for comment in ["//?", "//?  ", "/*?*/", "/*? */", "/*?.*/", "/*?->count()*/", "/*??->name*/"] {
            #expect(SnippetFormatter.isMagicComment(comment), "\(comment)")
        }
        for comment in ["//? note", "#?", "// ?", "/* ? */", "/*x*/", "/** @var int $a */"] {
            #expect(!SnippetFormatter.isMagicComment(comment), "\(comment)")
        }
    }

    @Test func commentsThatKeepTheirPlaceAreAccepted() throws {
        try SnippetFormatter.verifyComments(
            before: "<?php\n$r = $a + $b * $c /*?*/;\n$h = new Foo /*?*/;\n$x //?\n# note\n$y = foo(($a /*?*/));\n",
            after: "<?php\n\n$r = $a + ($b * $c); /*?*/\n$h = new Foo(); /*?*/\n$x; //?\n// note\n$y = foo($a /*?*/);\n",
            lineOffset: 1)
        try SnippetFormatter.verifyComments(
            before: "<?php\nforeach ($a as $v) { //?\n  $v; //?\n} //?\n//?\n$s = \"a\" /*?*/;\n",
            after: "<?php\n\nforeach ($a as $v) { //?\n    $v; //?\n} //?\n//?\n$s = 'a'; /*?*/\n",
            lineOffset: 1)
    }

    @Test func magicCommentsThatWouldShowSomethingElseAreRefused() {
        // Removing the parentheses would make the comment show `$a + $b` instead of `$b`.
        #expect(throws: SnippetFormatError.magicComment(line: 1, comment: "/*?*/")) {
            try SnippetFormatter.verifyComments(before: "<?php\n$r = $a + ($b /*?*/);\n", after: "<?php\n\n$r = $a + $b /*?*/;\n", lineOffset: 1)
        }
        // `#?` is an ordinary comment; Mago would turn it into the magic `//?`.
        #expect(throws: SnippetFormatError.magicComment(line: 2, comment: "#?")) {
            try SnippetFormatter.verifyComments(before: "<?php\n$a = 1;\n$b = 2; #?\n", after: "<?php\n\n$a = 1;\n$b = 2; //?\n", lineOffset: 1)
        }
        // A `//?` of its own line shows ✓ when reached; after code it shows a value.
        #expect(throws: SnippetFormatError.magicComment(line: 2, comment: "//?")) {
            try SnippetFormatter.verifyComments(before: "<?php\n$a = 1;\n//?\n", after: "<?php\n\n$a = 1; //?\n", lineOffset: 1)
        }
        // After a different value.
        #expect(throws: SnippetFormatError.magicComment(line: 1, comment: "//?")) {
            try SnippetFormatter.verifyComments(before: "<?php\n$a = 1; //?\n$b = 2;\n", after: "<?php\n\n$a = 1;\n$b = 2; //?\n", lineOffset: 1)
        }
    }

    @Test func lostOrChangedCommentsAreRefused() {
        #expect(throws: SnippetFormatError.commentChanged(line: 2)) {
            try SnippetFormatter.verifyComments(before: "<?php\n$a = 1;\n// keep me\n", after: "<?php\n\n$a = 1;\n", lineOffset: 1)
        }
        #expect(throws: SnippetFormatError.commentChanged(line: 1)) {
            try SnippetFormatter.verifyComments(before: "<?php\n$a = 1; // one\n", after: "<?php\n\n$a = 1; // two\n", lineOffset: 1)
        }
    }

    // MARK: Options

    @Test func optionsBecomeMagoConfigAndPHPVersion() {
        let options = SnippetFormatter.Options(style: .laravel, quotes: .double, indentWidth: 2, useTabs: true, phpVersion: "8.3.12")
        #expect(options.configTOML.contains("preset = \"laravel\""))
        #expect(options.configTOML.contains("single-quote = false"))
        #expect(options.configTOML.contains("tab-width = 2"))
        #expect(options.configTOML.contains("use-tabs = true"))
        #expect(options.magoPHPVersion == "8.3")
        #expect(SnippetFormatter.Options(phpVersion: nil).magoPHPVersion == "7.4")
        #expect(SnippetFormatter.Options(phpVersion: "5.6").magoPHPVersion == "7.0")
        #expect(SnippetFormatter.Options(phpVersion: "9.1").magoPHPVersion == "8.6")
        #expect(SnippetFormatter.Options(phpVersion: "8.4.0RC1").magoPHPVersion == "8.4")
        var settings = AppSettings()
        settings.tabWidth = 8
        settings.insertSpaces = false
        let fromSettings = SnippetFormatter.Options(settings: settings, phpVersion: nil)
        #expect(fromSettings.style == .per && fromSettings.quotes == .single && fromSettings.indentWidth == 8 && fromSettings.useTabs)
    }

    @Test func parseErrorsBecomeSyntaxErrors() {
        let stderr = " WARN Allowing unsupported PHP versions.\nERROR Failed to parse <stdin>: Expected one of `RightBracket`, found `Semicolon`\n"
        #expect(SnippetFormatter.error(fromStderr: stderr, termination: .exited(2)) == .syntax("Expected one of `RightBracket`, found `Semicolon`"))
        #expect(SnippetFormatter.error(fromStderr: "ERROR Something else broke\n", termination: .exited(1)) == .failed("Something else broke"))
        #expect(SnippetFormatter.error(fromStderr: "", termination: .signaled(9)) == .failed("the formatter exited with status 137"))
    }

    // MARK: Editor edit

    @Test func editReplacesOnlyTheChangedPartAndKeepsTheCaret() {
        let old = "$a=1;\n$b=[1,2];\n$c = 3;\n"
        let new = "$a = 1;\n$b = [1, 2];\n$c = 3;\n"
        let edit = FormattingEdit(old: old, new: new, caret: (old as NSString).range(of: "$c").location + 2)
        #expect(edit.location == 2)
        #expect((new as NSString).substring(from: edit.caret).hasPrefix(" = 3;"))
        let applied = (old as NSString).replacingCharacters(in: NSRange(location: edit.location, length: edit.length), with: edit.replacement)
        #expect(applied == new)
        // Inside the change: after the same code characters.
        let inside = FormattingEdit(old: old, new: new, caret: (old as NSString).range(of: "2]").location)
        #expect((new as NSString).substring(from: inside.caret).hasPrefix("2];"))
        // At the start of an indented token, the caret stays before the token.
        let start = FormattingEdit(old: "if($a){\n$b=1;\n}", new: "if ($a) {\n    $b = 1;\n}", caret: 8)
        #expect(("if ($a) {\n    $b = 1;\n}" as NSString).substring(from: start.caret).hasPrefix("$b = 1;"))
        // Before the change, nothing moves.
        #expect(FormattingEdit(old: old, new: new, caret: 1).caret == 1)
    }

    @Test func editNeverSplitsSurrogatePairs() {
        let edit = FormattingEdit(old: "$a = '😀';", new: "$a = '😁';", caret: 0)
        #expect(!edit.replacement.unicodeScalars.contains("\u{FFFD}"))
        let applied = ("$a = '😀';" as NSString).replacingCharacters(in: NSRange(location: edit.location, length: edit.length), with: edit.replacement)
        #expect(applied == "$a = '😁';")
    }

    // MARK: Fake formatter executable

    private static func fakeFormatter(_ script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-fake-mago-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("mago")
        try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func wrapperSendsTheSnippetWithATagAndAPrivateConfig() async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-fake-mago-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: log) }
        // Echoes its input with `$a=1` spaced out; records arguments, input, config, and environment.
        let fake = try Self.fakeFormatter("""
        input=$(cat)
        config=""
        prev=""
        for arg in "$@"; do
          if [ "$prev" = "--config" ]; then config="$arg"; fi
          prev="$arg"
        done
        { printf 'ARGS %s\\n' "$*"; printf 'CWD %s\\n' "$PWD"; printf 'HOME %s\\n' "$HOME"; printf 'XDG %s\\n' "$XDG_CONFIG_HOME"; printf 'PATH %s\\n' "$PATH"; printf 'INPUT\\n%s\\nEND\\n' "$input"; cat "$config"; } > '\(log.path)'
        printf '<?php\\n\\n%s\\n' "$(printf '%s' "$input" | sed -e '1d' -e 's/\\$a=1/$a = 1/')"
        """)
        let formatter = SnippetFormatter(executable: fake)
        let result = try await formatter.format("$a=1;\n$b = 2; //?\n", options: .init(style: .psr12, phpVersion: "8.2"))
        #expect(result == "$a = 1;\n$b = 2; //?\n")
        let recorded = try String(contentsOf: log, encoding: .utf8)
        #expect(recorded.contains("--colors never --config "))
        #expect(recorded.contains("--no-version-check --no-extensions --threads 1 --allow-unsupported-php-version --php-version 8.2 format --stdin-input"))
        #expect(recorded.contains("INPUT\n<?php\n$a=1;\n$b = 2; //?\nEND"))
        #expect(recorded.contains("preset = \"psr-12\""))
        #expect(recorded.contains("PATH /usr/bin:/bin"))
        // The config and the working directory are a private directory, not the project.
        func value(_ key: String) -> String {
            recorded.split(separator: "\n").first { $0.hasPrefix(key + " ") }.map { String($0.dropFirst(key.count + 1)) } ?? ""
        }
        #expect(value("CWD").contains("runlet-format-"))
        #expect(value("HOME").contains("runlet-format-") && value("HOME") == value("XDG"))
        #expect(!FileManager.default.fileExists(atPath: value("HOME")), "the private directory is removed afterwards")
    }

    @Test func wrapperKeepsTheTextOnSyntaxErrors() async throws {
        let fake = try Self.fakeFormatter("cat >/dev/null\necho 'ERROR Failed to parse <stdin>: Unexpected token `}`' >&2\nexit 2")
        let formatter = SnippetFormatter(executable: fake)
        await #expect(throws: SnippetFormatError.syntax("Unexpected token `}`")) {
            _ = try await formatter.format("$a = ;\n")
        }
    }

    @Test func wrapperStopsAFormatterThatHangs() async throws {
        let fake = try Self.fakeFormatter("cat >/dev/null\nexec sleep 30")
        let formatter = SnippetFormatter(executable: fake, timeout: .milliseconds(300))
        let started = ContinuousClock.now
        await #expect(throws: SnippetFormatError.timedOut) {
            _ = try await formatter.format("$a = 1;\n")
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func missingFormatterAndBlankTextAreHandled() async throws {
        let formatter = SnippetFormatter(executable: URL(fileURLWithPath: "/nonexistent/mago"))
        #expect(try await formatter.format("  \n") == "  \n")
        await #expect(throws: SnippetFormatError.unavailable) {
            _ = try await formatter.format("$a = 1;")
        }
    }

    @Test func wrapperRefusesOutputThatMovesAMagicComment() async throws {
        // A fake formatter that drops the parentheses around `$b /*?*/`.
        let fake = try Self.fakeFormatter("cat >/dev/null\nprintf '<?php\\n\\n$r = $a + $b /*?*/;\\n'")
        let formatter = SnippetFormatter(executable: fake)
        await #expect(throws: SnippetFormatError.magicComment(line: 1, comment: "/*?*/")) {
            _ = try await formatter.format("$r = $a + ($b /*?*/);")
        }
    }
}

/// Format Code (#36) with the real bundled Mago (`Resources/Formatter/mago`, from
/// `scripts/fetch-mago.sh`); skipped when it's missing.
@Suite(.enabled(if: MagoSupport.hasBinary, "Resources/Formatter/mago is missing; run scripts/fetch-mago.sh"))
struct SnippetFormatterMagoTests {
    let formatter = SnippetFormatter(executable: MagoSupport.binary)

    @Test func formatsATaglessFragment() async throws {
        let result = try await formatter.format("$users=[1,2,3];\nforeach($users as $u){echo $u;}\n$name=\"Ada\";\n")
        #expect(result == "$users = [1, 2, 3];\nforeach ($users as $u) {\n    echo $u;\n}\n$name = 'Ada';\n")
    }

    @Test func keepsTheLastExpressionWithoutASemicolon() async throws {
        #expect(try await formatter.format("collect([1,2])->map(fn($v)=>$v*2)") == "collect([1, 2])->map(fn($v) => $v * 2)")
        #expect(try await formatter.format("$x=1;\nUser::first() /*?->name*/\n") == "$x = 1;\nUser::first() /*?->name*/\n")
        #expect(try await formatter.format("$a=1;\n$a //?") == "$a = 1;\n$a //?")
        #expect(try await formatter.format("foo( 1 )\n// note\n") == "foo(1)\n\n// note\n")
    }

    @Test func keepsMagicCommentsWhereTheyWere() async throws {
        let snippet = """
        $users = User::query()->where("active",1)->get(); //?
        $total=0;
        foreach($users as $u){ //?
        $total += $u->score; //?
        } //?
        //?
        $total /*?*/ * 2;
        $q = User::query()
            ->where("a", 1) //?
            ->get();
        $list = [
          1, //?
          2,
        ];
        $t = $a * $b /*?*/ + 1;
        /*?.*/
        collect([1,2,3])->map(fn($v)=>$v*2)/*?->count()*/
        """
        let expected = """
        $users = User::query()->where('active', 1)->get(); //?
        $total = 0;
        foreach ($users as $u) { //?
            $total += $u->score; //?
        } //?
        //?
        $total /*?*/ * 2;
        $q = User::query()
            ->where('a', 1) //?
            ->get();
        $list = [
            1, //?
            2,
        ];
        $t = ($a * $b /*?*/) + 1;
        /*?.*/
        collect([1, 2, 3])->map(fn($v) => $v * 2) /*?->count()*/
        """
        #expect(try await formatter.format(snippet) == expected)
    }

    @Test func refusesToMoveAMagicCommentOutOfParentheses() async throws {
        let snippet = "$a = 1;\n$b = 2;\n$r = $a + ($b /*?*/);\n"
        await #expect(throws: SnippetFormatError.magicComment(line: 3, comment: "/*?*/")) {
            _ = try await formatter.format(snippet)
        }
        // `#?` is an ordinary comment, and stays one (`// ?`).
        #expect(try await formatter.format("$a=1; #?\n") == "$a = 1; // ?\n")
    }

    @Test func syntaxErrorsLeaveTheTextAlone() async throws {
        await #expect(throws: SnippetFormatError.syntax("Expected one of `RightBracket`, found `Semicolon`")) {
            _ = try await formatter.format("$a = 1;\n$b = [1, 2;\n$c = 3;\n")
        }
        do {
            _ = try await formatter.format("$a = \"unterminated;\n")
            Issue.record("expected a syntax error")
        } catch let error as SnippetFormatError {
            guard case .syntax = error else { Issue.record("\(error)"); return }
            #expect(error.description.hasPrefix("The code has a syntax error"))
        }
    }

    @Test func isIdempotent() async throws {
        let snippets = [
            "$a=[1,2,3];\nforeach($a as $v){echo $v;}\n",
            "User::where('a',1)->get() //?",
            "<?php\nnamespace App;\nclass A{public function b(){return 1;}}\n(new A)->b()",
            "$s = <<<EOT\n  hello {$a}\n  EOT;\n$t = 1 + 2 /*?*/;\n# hash\n",
            "if($a){ //?\n$b=1;}else{$b=2;} //?\n$b",
        ]
        for snippet in snippets {
            let once = try await formatter.format(snippet)
            let twice = try await formatter.format(once)
            #expect(once == twice, "\(snippet)")
        }
    }

    @Test func keepsAnOpeningTagAndTheTextsEnding() async throws {
        #expect(try await formatter.format("<?php\n$a=1;\n") == "<?php\n\n$a = 1;\n")
        #expect(try await formatter.format("$a=1;") == "$a = 1;")
        #expect(try await formatter.format("$a = 1;\n") == "$a = 1;\n")
    }

    @Test func followsStyleQuotesIndentationAndPHPVersion() async throws {
        let snippet = "$f = fn($x)=>!$x;\n$s = 'a';\nif($a){$b=1;}\n"
        let laravel = try await formatter.format(snippet, options: .init(style: .laravel, quotes: .double, indentWidth: 2))
        #expect(laravel == "$f = fn ($x) => ! $x;\n$s = \"a\";\nif ($a) {\n  $b = 1;\n}\n")
        let tabs = try await formatter.format("if($a){$b=1;}", options: .init(useTabs: true))
        #expect(tabs == "if ($a) {\n\t$b = 1;\n}")
        // Parameter lists get a trailing comma only from PHP 8.0.
        let long = "function f(string $parameterNumberOne, string $parameterNumberTwo, string $parameterNumberThreeXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX) {}"
        #expect(try await formatter.format(long, options: .init(phpVersion: "7.4.33")).contains("$parameterNumberThreeXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX\n)"))
        #expect(try await formatter.format(long, options: .init(phpVersion: "8.3")).contains("$parameterNumberThreeXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX,\n)"))
    }
}

enum MagoSupport {
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("plan.md").path) { return url }
        }
        fatalError("repository root not found")
    }()

    static var binary: URL { repoRoot.appendingPathComponent("Resources/Formatter/mago") }
    static var hasBinary: Bool { FileManager.default.isExecutableFile(atPath: binary.path) }
}
