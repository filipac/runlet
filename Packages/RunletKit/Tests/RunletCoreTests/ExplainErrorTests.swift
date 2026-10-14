import Foundation
import Testing
@testable import RunletCore

/// Explain or Fix This Error (#44): what is asked, how the answer is read, and the diff of a
/// proposed fix.
struct ExplainErrorTests {
    static let code = """
    <?php

    $user = User::where('email', 'alice@example.com')->first();
    echo $user->name;
    """

    static func error() -> RunErrorInfo {
        var error = RunErrorInfo(stage: .execute, className: "ErrorException", message: "Attempt to read property \"name\" on null")
        error.inSnippet = true
        error.snippetLine = 4
        var vendor = RunErrorInfo.Frame()
        vendor.function = "Illuminate\\Foundation\\Bootstrap\\HandleExceptions->handleError"
        vendor.file = "/var/www/html/vendor/laravel/framework/src/Illuminate/Foundation/Bootstrap/HandleExceptions.php"
        vendor.line = 255
        var own = RunErrorInfo.Frame()
        own.inSnippet = true
        own.snippetLine = 4
        error.trace = [vendor, own]
        error.previous = RunErrorInfo.Previous(className: "RuntimeException", message: "Earlier")
        return error
    }

    @Test func theErrorAsTheModelReadsIt() {
        let text = ExplainErrorPrompt.errorText(Self.error(), line: 4) { path in
            path.replacingOccurrences(of: "/var/www/html/", with: "")
        }
        #expect(text == """
        ErrorException: Attempt to read property "name" on null
        On line 4 of the tab's code.
        Caused by RuntimeException: Earlier
        Stack trace:
        #0 Illuminate\\Foundation\\Bootstrap\\HandleExceptions->handleError (vendor/laravel/framework/src/Illuminate/Foundation/Bootstrap/HandleExceptions.php:255)
        #1 {main} (the tab's code, line 4)
        """)
        var thrown = RunErrorInfo(stage: .execute, className: "DomainException", message: "Negative")
        thrown.file = "/Users/someone/shop/app/Totals.php"
        thrown.line = 21
        #expect(ExplainErrorPrompt.errorText(thrown, line: nil) { _ in "app/Totals.php" } == "DomainException: Negative\nThrown in app/Totals.php on line 21.")
        #expect(ExplainErrorPrompt.errorText(thrown, line: 8) { _ in "app/Totals.php" } == "DomainException: Negative\nThrown in app/Totals.php on line 21, from line 8 of the tab's code.")
        var many = RunErrorInfo(stage: .execute, message: "Deep")
        many.trace = Array(repeating: RunErrorInfo.Frame(), count: 20)
        let deep = ExplainErrorPrompt.errorText(many, line: nil) { $0 }
        #expect(deep.hasPrefix("Error: Deep"))
        #expect(deep.contains("#11 {main}"))
        #expect(!deep.contains("#12"))
        #expect(deep.hasSuffix("… 8 more frames"))
    }

    @Test func theDisclosureSendsTheErrorAndCodeAndOffersTheSource() {
        let excerpt = SourceExcerpt(lines: [SourceExcerpt.Line(number: 20, text: "if ($cents < 0) {"), SourceExcerpt.Line(number: 21, text: "    throw new DomainException();"), SourceExcerpt.Line(number: 22, text: "}")], focusLine: 21)
        let input = ExplainErrorInput(language: .php, error: "DomainException: Negative", code: Self.code, line: 4,
                                      frameSource: FrameSourceExcerpt(path: "app/Totals.php", line: 21, excerpt: excerpt))
        let disclosure = ExplainErrorPrompt.disclosure(input, provider: .anthropic, model: "claude-opus-5-5")
        #expect(disclosure.parts.map(\.id) == ["error", "code", "source"])
        #expect(disclosure.parts.map(\.isIncluded) == [true, true, false])
        #expect(disclosure.parts[1].title == "The tab's PHP code")
        #expect(disclosure.parts[1].text == Self.code)
        #expect(disclosure.parts[2].text == """
        app/Totals.php, around line 21:
          20 | if ($cents < 0) {
        > 21 |     throw new DomainException();
          22 | }
        """)
        #expect(disclosure.message == "## The error\n\nDomainException: Negative\n\n## The tab's PHP code\n\n" + Self.code)
        #expect(disclosure.effort == .medium)
        #expect(disclosure.maxOutputTokens == ExplainErrorPrompt.maxOutputTokens)
        #expect(disclosure.instructions.contains("```runlet-fix"))
        #expect(disclosure.instructions.contains("Runlet never runs your code"))
        #expect(ExplainErrorPrompt.instructions(language: .sql).contains("SQL code"))
        let noSource = ExplainErrorPrompt.disclosure(ExplainErrorInput(language: .php, error: "E", code: "x"), provider: .openai, model: "gpt-6-astra")
        #expect(noSource.parts.map(\.id) == ["error", "code"])
        #expect(noSource.provider == .openai)
    }

    @Test func theAnswerSplitsIntoTextCodeAndTheFix() {
        let answer = AIAnswer.parse("""
        `$user` is `null`: no user has that email.

        Check it first:

        ```php
        if ($user === null) { … }
        ```

        ```runlet-fix
        <?php

        $user = User::where('email', 'alice@example.com')->firstOrFail();
        echo $user->name;
        ```
        """)
        #expect(answer.blocks == [
            .text("`$user` is `null`: no user has that email.\n\nCheck it first:"),
            .code(language: "php", "if ($user === null) { … }", isOpen: false),
        ])
        #expect(answer.fix == "<?php\n\n$user = User::where('email', 'alice@example.com')->firstOrFail();\necho $user->name;")
        #expect(!answer.isWritingFix)
    }

    @Test func aStreamedAnswerShowsOpenBlocks() {
        let code = AIAnswer.parse("Try this:\n\n```php\n$a = 1;")
        #expect(code.blocks == [.text("Try this:"), .code(language: "php", "$a = 1;", isOpen: true)])
        let fix = AIAnswer.parse("Here's the fix.\n\n```runlet-fix\n<?php\n$a")
        #expect(fix.blocks == [.text("Here's the fix.")])
        #expect(fix.fix == nil)
        #expect(fix.isWritingFix)
        // Tildes, longer fences, and a shorter "fence" inside the code.
        let tildes = AIAnswer.parse("~~~~ runlet-fix\n<?php\n~~~\necho 1;\n~~~~\nDone.")
        #expect(tildes.fix == "<?php\n~~~\necho 1;")
        #expect(tildes.blocks == [.text("Done.")])
        #expect(AIAnswer.parse("Plain only.") == AIAnswer(blocks: [.text("Plain only.")], fix: nil))
        #expect(AIAnswer.parse("").blocks.isEmpty)
    }

    @Test func diffOfAFix() {
        let old = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj"
        let new = "a\nb\nc\nd\nE\nf\ng\nh\ni\nj\nk"
        #expect(LineDiff.changes(from: old, to: new) == [.same("a"), .same("b"), .same("c"), .same("d"), .removed("e"), .added("E"), .same("f"), .same("g"), .same("h"), .same("i"), .same("j"), .added("k")])
        let rows = LineDiff.rows(from: old, to: new, context: 1)
        #expect(rows == [
            .gap(3), .line(.same("d"), old: 4, new: 4), .line(.removed("e"), old: 5, new: nil), .line(.added("E"), old: nil, new: 5),
            .line(.same("f"), old: 6, new: 6), .gap(3), .line(.same("j"), old: 10, new: 10), .line(.added("k"), old: nil, new: 11),
        ])
        #expect(LineDiff.rows(from: old, to: old).isEmpty)
        #expect(LineDiff.changes(from: "", to: "x") == [.removed(""), .added("x")])
    }
}
