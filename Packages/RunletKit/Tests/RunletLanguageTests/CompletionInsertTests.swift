import Foundation
import RunletCore
import Testing
@testable import RunletLanguage

/// What the editor inserts for a completion item, without a server.
struct CompletionInsertionTests {
    static func item(_ label: String, kind: Int?, insertText: String?, format: Int? = 2) -> CompletionItem {
        CompletionItem(id: 0, label: label, kind: kind, detail: nil, documentation: nil, sortText: nil, filterText: nil, insertText: insertText, insertTextFormat: format, textEdit: nil, additionalTextEdits: [], deprecated: false, raw: .null)
    }

    static func make(_ item: CompletionItem, following: Character? = nil) -> String {
        let insertion = CompletionInsertion.make(item: item, followingCharacter: following)
        return (insertion.text as NSString).replacingCharacters(in: NSRange(location: insertion.cursor, length: 0), with: "|")
    }

    @Test func callsDropPlaceholderText() {
        let split = Self.item("split($pattern, $limit = ..., $flags = ...)", kind: 2, insertText: "split(${1:\\$pattern})$0")
        #expect(Self.make(split) == "split(|)")
        #expect(CompletionInsertion.make(item: split, followingCharacter: nil) == CompletionInsertion(text: "split()", cursor: 6, showsSignatureHelp: true))
        // Several required parameters leave no separators behind.
        #expect(Self.make(Self.item("replace($search, $replace, $subject)", kind: 2, insertText: "replace(${1:\\$search}, ${2:\\$replace}, ${3:\\$subject})$0")) == "replace(|)")
        // A class after `new` with a required constructor parameter.
        #expect(Self.make(Self.item("DateTimeZone", kind: 7, insertText: "\\DateTimeZone(${1:\\$timezone})$0")) == "\\DateTimeZone(|)")
        // Literal argument text is kept, with the caret at the tab stop.
        #expect(Self.make(Self.item("env($key, $default = ...)", kind: 3, insertText: "env('${1:KEY}')$0")) == "env('|')")
    }

    @Test func caretFollowsTheParameterList() {
        // No parameters: after `)`, no signature help.
        let upper = CompletionInsertion.make(item: Self.item("upper()", kind: 2, insertText: "upper()$0"), followingCharacter: nil)
        #expect(upper == CompletionInsertion(text: "upper()", cursor: 7, showsSignatureHelp: false))
        // Only optional parameters (no tab stop, but the label lists them): inside.
        #expect(Self.make(Self.item("trim($characters = ...)", kind: 2, insertText: "trim()$0")) == "trim(|)")
        // Built-in functions and classes carry no parameter list: inside, flagged as unknown.
        let arrayMap = CompletionInsertion.make(item: Self.item("array_map", kind: 3, insertText: "array_map()$0"), followingCharacter: nil)
        #expect(arrayMap == CompletionInsertion(text: "array_map()", cursor: 10, showsSignatureHelp: true, parametersUnknown: true))
        let formatter = CompletionInsertion.make(item: Self.item("PriceFormatter", kind: 7, insertText: "PriceFormatter()$0"), followingCharacter: nil)
        #expect(formatter.cursor == 15 && formatter.parametersUnknown)
    }

    @Test func existingParenthesisInsertsOnlyTheName() {
        let split = Self.item("split($pattern, $limit = ..., $flags = ...)", kind: 2, insertText: "split(${1:\\$pattern})$0")
        #expect(CompletionInsertion.make(item: split, followingCharacter: "(") == CompletionInsertion(text: "split", cursor: 5, showsSignatureHelp: false))
        #expect(Self.make(Self.item("count()", kind: 2, insertText: "count", format: nil), following: "(") == "count|")
    }

    @Test func nonCallsAreUnchanged() {
        #expect(Self.make(Self.item("name", kind: 10, insertText: "name", format: nil)) == "name|")
        #expect(Self.make(Self.item("$widget", kind: 6, insertText: "$widget", format: nil)) == "$widget|")
        #expect(Self.make(Self.item("DateTimeZone", kind: 7, insertText: "DateTimeZone", format: nil), following: "(") == "DateTimeZone|")
        #expect(Self.make(Self.item("foreach", kind: 14, insertText: "foreach", format: nil)) == "foreach|")
        // Non-name snippets keep their placeholder text.
        #expect(Self.make(Self.item("fn", kind: 15, insertText: "fn(${1:\\$x}) => $0")) == "fn($x) => |")
    }
}

/// Accepting PHPantom 0.10.0 completions exactly as `EditorController.accept` applies them.
@Suite(
    .serialized,
    .enabled(if: LanguageTestSupport.hasBinary, "run scripts/fetch-phpantom.sh"),
    .enabled(if: LaravelFixture.hasVendor, "run scripts/setup-fixtures.sh")
)
struct CompletionInsertTests {
    struct Accepted {
        /// The resulting editor text with `|` at the caret.
        var marked: String
        var text: String
        var caret: Int
        var insertion: CompletionInsertion
    }

    /// Requests completion at `|` in `input`, accepts the item named `name`, and applies the main
    /// edit plus import edits the way the editor does.
    static func accept(_ name: String, in input: String, session: LanguageServerSession) async throws -> Accepted {
        let cursor = (input as NSString).range(of: "|").location
        let editorText = (input as NSString).replacingCharacters(in: NSRange(location: cursor, length: 1), with: "")
        let (uri, mapping) = await LanguageTestSupport.open(session, root: LaravelFixture.root, editorText: editorText)
        let index = TextLineIndex(editorText)
        // PHPantom may still be indexing the fixture right after it starts: ask again briefly.
        var items = try await session.completion(uri: uri, position: mapping.toLSP(index.position(at: cursor)), triggerCharacter: nil)
        for _ in 0..<15 where !items.contains(where: { ($0.label.components(separatedBy: "(").first ?? $0.label) == name }) {
            try await Task.sleep(for: .milliseconds(200))
            items = try await session.completion(uri: uri, position: mapping.toLSP(index.position(at: cursor)), triggerCharacter: nil)
        }
        let item = try #require(items.first { ($0.label.components(separatedBy: "(").first ?? $0.label) == name }, "no \(name) in \(items.map(\.label))")

        // The editor's anchor: identifier characters (and a leading `$`) before the cursor.
        let string = editorText as NSString
        var anchor = cursor
        while anchor > 0 {
            let character = string.character(at: anchor - 1)
            let isIdentifier = (character >= 48 && character <= 57) || (character >= 65 && character <= 90) || (character >= 97 && character <= 122) || character == 95 || character > 127
            if isIdentifier { anchor -= 1 } else { if character == 36 { anchor -= 1 }; break }
        }
        var mainRange = NSRange(location: anchor, length: cursor - anchor)
        if let edit = item.textEdit {
            let mapped = index.nsRange(of: mapping.toEditor(edit.range))
            let start = min(mapped.location, anchor)
            mainRange = NSRange(location: start, length: max(cursor, NSMaxRange(mapped)) - start)
        }
        let following = NSMaxRange(mainRange) < string.length ? string.substring(with: NSRange(location: NSMaxRange(mainRange), length: 1)).first : nil
        let insertion = CompletionInsertion.make(item: item, followingCharacter: following)
        var edits: [(range: NSRange, text: String, isMain: Bool)] = [(mainRange, insertion.text, true)]
        for additional in item.additionalTextEdits {
            let range = index.nsRange(of: mapping.toEditor(additional.range))
            if NSIntersectionRange(range, mainRange).length == 0 { edits.append((range, additional.newText, false)) }
        }
        edits.sort { $0.range.location > $1.range.location }
        var text = string
        var mainLocation = mainRange.location
        for edit in edits {
            text = text.replacingCharacters(in: edit.range, with: edit.text) as NSString
            if !edit.isMain, edit.range.location <= mainRange.location {
                mainLocation += (edit.text as NSString).length - edit.range.length
            }
        }
        let caret = mainLocation + insertion.cursor
        let marked = text.replacingCharacters(in: NSRange(location: caret, length: 0), with: "|")
        return Accepted(marked: marked, text: text as String, caret: caret, insertion: insertion)
    }

    /// Parameter count of the signature at the caret of an accepted call.
    static func parameterCount(_ accepted: Accepted, session: LanguageServerSession) async throws -> Int? {
        let (uri, mapping) = await LanguageTestSupport.open(session, root: LaravelFixture.root, editorText: accepted.text)
        let position = TextLineIndex(accepted.text).position(at: accepted.caret)
        var help = try await session.signatureHelp(uri: uri, position: mapping.toLSP(position))
        // As for completion, the server may still be indexing: ask again briefly.
        for _ in 0..<15 where help.map({ !$0.signatures.indices.contains($0.activeSignature) }) ?? true {
            try await Task.sleep(for: .milliseconds(200))
            help = try await session.signatureHelp(uri: uri, position: mapping.toLSP(position))
        }
        guard let help, help.signatures.indices.contains(help.activeSignature) else { return nil }
        return help.signatures[help.activeSignature].parameterRanges.count
    }

    @Test func methodsWithParametersPutTheCaretInsideEmptyParentheses() async throws {
        let session = await LanguageTestSupport.session(LaravelFixture.root)
        defer { Task { await session.stop() } }

        // The reported case: PHPantom sends `split(${1:\$pattern})$0`.
        let split = try await Self.accept("split", in: "Str::of('x')->spl|", session: session)
        #expect(split.marked == "Str::of('x')->split(|)")
        #expect(split.insertion.showsSignatureHelp && !split.insertion.parametersUnknown)
        #expect(try await Self.parameterCount(split, session: session) == 3)

        #expect(try await Self.accept("slug", in: "Str::sl|", session: session).marked == "Str::slug(|)")
        #expect(try await Self.accept("replace", in: "Str::repl|", session: session).marked == "Str::replace(|)")
        // Only optional parameters: PHPantom sends `trim()$0`; the label lists `$characters`.
        #expect(try await Self.accept("trim", in: "Str::of('x')->tri|", session: session).marked == "Str::of('x')->trim(|)")
    }

    @Test func methodsWithoutParametersPutTheCaretAfterTheCall() async throws {
        let session = await LanguageTestSupport.session(LaravelFixture.root)
        defer { Task { await session.stop() } }

        let count = try await Self.accept("count", in: "collect([1])->cou|", session: session)
        #expect(count.marked == "collect([1])->count()|")
        #expect(!count.insertion.showsSignatureHelp)
        #expect(try await Self.accept("upper", in: "Str::of('x')->upp|", session: session).marked == "Str::of('x')->upper()|")
    }

    @Test func functionsAndConstructorsResolveTheirParametersThroughSignatureHelp() async throws {
        let session = await LanguageTestSupport.session(LaravelFixture.root)
        defer { Task { await session.stop() } }

        // Built-in functions come as `array_map()$0` with no parameter list in the label.
        let arrayMap = try await Self.accept("array_map", in: "array_ma|", session: session)
        #expect(arrayMap.marked == "array_map(|)")
        #expect(arrayMap.insertion.parametersUnknown)
        #expect(try await Self.parameterCount(arrayMap, session: session) == 3) // the caret stays inside

        let time = try await Self.accept("time", in: "$t = time|", session: session)
        #expect(time.marked == "$t = time(|)")
        #expect(try await Self.parameterCount(time, session: session) == 0) // the editor steps past `)`

        // A required constructor parameter is a tab stop: known, caret inside.
        let zone = try await Self.accept("DateTimeZone", in: "new DateTimeZ|", session: session)
        #expect(zone.marked == "new DateTimeZone(|)")
        #expect(!zone.insertion.parametersUnknown)

        // A class without a constructor keeps its import; signature help reports no parameters.
        let formatter = try await Self.accept("PriceFormatter", in: "$price = 5;\n$f = new PriceForm|", session: session)
        #expect(formatter.marked == "use App\\Services\\PriceFormatter;\n$price = 5;\n$f = new PriceFormatter(|)")
        #expect(formatter.insertion.parametersUnknown)
        #expect(try await Self.parameterCount(formatter, session: session) == 0)
    }

    @Test func existingParenthesesAreReused() async throws {
        let session = await LanguageTestSupport.session(LaravelFixture.root)
        defer { Task { await session.stop() } }

        let count = try await Self.accept("count", in: "collect([1])->cou|('x')", session: session)
        #expect(count.marked == "collect([1])->count|('x')")
        #expect(try await Self.accept("split", in: "Str::of('x')->spl|($p)", session: session).marked == "Str::of('x')->split|($p)")
    }

    @Test func propertiesAndVariablesAreUnchanged() async throws {
        let session = await LanguageTestSupport.session(LaravelFixture.root)
        defer { Task { await session.stop() } }

        #expect(try await Self.accept("name", in: "$w = App\\Models\\Widget::first();\n$w->na|", session: session).marked == "$w = App\\Models\\Widget::first();\n$w->name|")
        // PHPantom sends a textEdit covering the typed `$wid`.
        #expect(try await Self.accept("$widget", in: "$widget = 1;\n$wid|", session: session).marked == "$widget = 1;\n$widget|")
    }
}
