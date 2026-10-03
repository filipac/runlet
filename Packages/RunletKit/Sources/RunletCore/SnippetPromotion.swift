import Foundation

/// Promote a snippet (#39): the PHP source of an Artisan command class or a Pest or PHPUnit
/// test made from a snippet, for the user to review. Generating it never runs any code; the
/// app writes the result only through a save panel.
///
/// What happens to the snippet's code:
/// - The opening `<?php` tag goes; `use` imports move to the file's import block (with the
///   whole tab's imports when only a selection is promoted); `declare(strict_types=…)` becomes
///   the file's own; a `namespace` statement or block is dropped (the file has its own).
/// - Named functions, classes, interfaces, traits, enums, and constants declared at the top
///   level move out of the method or closure, before it in the file: a snippet declares them
///   before its code runs, wherever they are.
/// - Magic comments (`//?`, `/*?*/`, `/*?->…*/`, `/*?.*/`) are removed: they mean something only
///   in Runlet's editor. Other comments stay.
/// - Parameterised snippets' `@input` declarations (#14) leave the docblock. A command reads
///   them as arguments (no default) and options (a default or choices; `bool` inputs are
///   flags), with typed casts; a test gets each input's default, or a typed empty value and a
///   TODO when it has none.
/// - The snippet's result (the value of its last expression statement, or of a final
///   `return`) is `dump()`ed by a command and assigned to `$result` in a test, with a TODO to
///   assert it. An assignment as the last statement keeps its variable instead.
/// - The code is re-indented into its method or closure. Lines that start inside a string,
///   heredoc, nowdoc, or inline HTML keep their exact text, so no value changes.
public enum SnippetPromotion {
    /// Which framework's console command to write.
    public enum CommandFlavor: String, Sendable, Equatable {
        /// Laravel and Lumen: `Illuminate\Console\Command` in `app/Console/Commands`.
        case laravel
        /// Laravel Zero: `LaravelZero\Framework\Commands\Command` in `app/Commands`.
        case laravelZero

        public var baseClass: String {
            switch self {
            case .laravel: "Illuminate\\Console\\Command"
            case .laravelZero: "LaravelZero\\Framework\\Commands\\Command"
            }
        }

        /// Where commands go, relative to the project.
        public var directory: String {
            switch self {
            case .laravel: "app/Console/Commands"
            case .laravelZero: "app/Commands"
            }
        }

        /// The namespace of `directory` by Laravel's convention (`App\` is `app/`).
        public var defaultNamespace: String {
            switch self {
            case .laravel: "App\\Console\\Commands"
            case .laravelZero: "App\\Commands"
            }
        }

        /// The flavor for a framework id from target facts ("laravel", "lumen",
        /// "laravel-zero"); nil for other frameworks.
        public init?(framework: String?) {
            switch framework {
            case "laravel", "lumen": self = .laravel
            case "laravel-zero": self = .laravelZero
            default: return nil
            }
        }
    }

    /// Which kind of test to write.
    public enum TestStyle: String, Sendable, Equatable {
        /// `test('…', function () { … });`
        case pest
        /// A `TestCase` class with a `test_…` method.
        case phpunit
    }

    /// What to promote.
    public struct Source: Sendable, Equatable {
        /// The snippet's code: a tab's code or selection, or a saved snippet's code.
        public var code: String
        /// The whole tab when `code` is a selection: its `use` imports come along.
        public var contextCode: String?
        /// The tab's title or the snippet's label: the command's description or the test's name.
        public var title: String
        /// A saved snippet's description, preferred for the command's description.
        public var description: String?
        /// Whether runs on the target declare `strict_types=1` (a `declare` in the code wins).
        public var strictTypes: Bool

        public init(code: String, contextCode: String? = nil, title: String, description: String? = nil, strictTypes: Bool = false) {
            self.code = code
            self.contextCode = contextCode
            self.title = title
            self.description = description
            self.strictTypes = strictTypes
        }
    }

    /// A generated file.
    public struct Output: Sendable, Equatable {
        /// The PHP source.
        public var source: String
        /// What the user should look at (also in the file as `// TODO:` comments).
        public var notes: [String]
    }

    // MARK: Generating

    /// An Artisan command class. `commandName` is the signature's name (`app:refund-order`);
    /// `namespace` nil writes none.
    public static func artisanCommand(_ source: Source, className: String, namespace: String?, commandName: String, flavor: CommandFlavor = .laravel) -> Output {
        let inputs = SnippetInputs.parse(code: normalized(source.code))
        let arguments = commandInputs(inputs.inputs)
        var expressions: [String: String] = [:]
        for argument in arguments { expressions[argument.name] = argument.expression }
        let prepared = prepare(source, inputs: inputs, expressions: expressions, extraNotes: [], result: .dump)

        let base = baseClassReference(flavor.baseClass, className: className, imports: prepared.imports)
        var signature = commandName
        if !arguments.isEmpty {
            let indent = String(repeating: " ", count: "    protected $signature = '".count)
            signature += arguments.map { "\n" + indent + $0.token }.joined()
        }
        let description = singleLine(source.description?.isEmpty == false ? source.description! : source.title)

        var lines = header(strictTypes: prepared.strictTypes, namespace: namespace, imports: base.imports) + prepared.declarations
        lines += [
            "class \(className) extends \(base.reference)",
            "{",
            "    /**",
            "     * The name and signature of the console command.",
            "     *",
            "     * @var string",
            "     */",
            "    protected $signature = \(singleQuoted(signature));",
            "",
            "    /**",
            "     * The console command description.",
            "     *",
            "     * @var string",
            "     */",
            "    protected $description = \(singleQuoted(description.isEmpty ? "Generated from a Runlet snippet" : description));",
            "",
            "    /**",
            "     * Execute the console command.",
            "     *",
            "     * Generated by Runlet from a snippet: review it before you run it.",
            "     */",
            "    public function handle()",
            "    {",
        ]
        lines.append(contentsOf: indented(prepared.body, by: "        "))
        lines += ["    }", "}", ""]
        return Output(source: lines.joined(separator: "\n"), notes: prepared.notes)
    }

    /// A Pest test file (`test('<title>', function () { … });`), or a PHPUnit test class
    /// extending `baseClass` (`Tests\TestCase`, or `PHPUnit\Framework\TestCase`) with one
    /// `test_<title>` method. `className` and `namespace` are for PHPUnit only.
    public static func test(_ source: Source, style: TestStyle, className: String = "SnippetTest", namespace: String? = nil, baseClass: String = "PHPUnit\\Framework\\TestCase") -> Output {
        let code = normalized(source.code)
        let inputs = SnippetInputs.parse(code: code)
        let placeholders = SnippetInputs.placeholderNames(in: code, names: Set(inputs.inputs.filter { $0.defaultValue == nil }.map(\.name)))
        var expressions: [String: String] = [:]
        var notes: [String] = []
        for input in inputs.inputs {
            if let value = input.defaultValue {
                expressions[input.name] = value.phpLiteral
            } else if !placeholders.contains(input.name) {
                expressions[input.name] = emptyLiteral(input.kind)
                notes.append("Choose a test value for $\(input.name) (\(input.label)): its input has no default.")
            }
        }
        let prepared = prepare(source, inputs: inputs, expressions: expressions, extraNotes: notes, result: .test(style))

        switch style {
        case .pest:
            var lines = header(strictTypes: prepared.strictTypes, namespace: nil, imports: prepared.imports) + prepared.declarations
            let title = singleLine(source.title)
            lines.append("test(\(singleQuoted(title.isEmpty ? "snippet" : title)), function () {")
            lines.append(contentsOf: indented(prepared.body, by: "    "))
            lines += ["});", ""]
            return Output(source: lines.joined(separator: "\n"), notes: prepared.notes)
        case .phpunit:
            let base = baseClassReference(baseClass, className: className, imports: prepared.imports)
            var lines = header(strictTypes: prepared.strictTypes, namespace: namespace, imports: base.imports) + prepared.declarations
            lines += [
                "class \(className) extends \(base.reference)",
                "{",
                "    public function \(testMethodName(fromTitle: source.title))()",
                "    {",
            ]
            lines.append(contentsOf: indented(prepared.body, by: "        "))
            lines += ["    }", "}", ""]
            return Output(source: lines.joined(separator: "\n"), notes: prepared.notes)
        }
    }

    /// The `use` import of `code` that already takes the name `className`, which the
    /// generated class can't also have; nil when there is none.
    public static func conflictingImport(className: String, code: String, contextCode: String? = nil) -> String? {
        let imports = importStatements(in: normalized(code)) + (contextCode.map { importStatements(in: normalized($0)) } ?? [])
        return imports.first { classAliases(ofImport: $0).contains(className.lowercased()) }
    }

    // MARK: Command inputs

    /// One `@input` as a command argument or option.
    struct CommandInput: Equatable {
        /// The variable, without `$`.
        var name: String
        /// Its part of the signature: `{orderId : Order ID}` or `{--reason= : Reason …}`.
        var token: String
        /// The code that reads it: `(int) $this->argument('orderId')`.
        var expression: String
    }

    /// Option names the console application already has.
    private static let reservedOptions: Set<String> = ["help", "quiet", "verbose", "version", "ansi", "no-ansi", "interaction", "no-interaction", "env", "silent"]

    /// Inputs without a default become required arguments (`{orderId : Order ID}`); inputs
    /// with a default or choices become options read with their default (`{--reason= : …}`,
    /// `$this->option('reason') ?? 'duplicate'`); `bool` inputs become flags (`--notify`, or
    /// `--no-notify` when they default to true). `int` and `float` values are cast.
    static func commandInputs(_ inputs: [SnippetInput]) -> [CommandInput] {
        var usedOptions = reservedOptions
        var usedArguments: Set<String> = ["command"]
        func unique(_ base: String, in used: inout Set<String>) -> String {
            var name = base
            var number = 2
            while used.contains(name.lowercased()) {
                name = "\(base)-\(number)"
                number += 1
            }
            used.insert(name.lowercased())
            return name
        }
        func describe(_ text: String) -> String {
            // `{` and `}` delimit the signature's parts; line breaks would split it.
            singleLine(text).replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")")
        }
        func cast(_ kind: SnippetInput.Kind) -> String {
            switch kind {
            case .int: "(int) "
            case .float: "(float) "
            case .string, .bool: ""
            }
        }
        return inputs.enumerated().map { index, input in
            let kebabName = kebab(input.name).isEmpty ? "input-\(index + 1)" : kebab(input.name)
            if input.kind == .bool {
                if case .bool(true) = input.defaultValue {
                    let option = unique("no-" + kebabName, in: &usedOptions)
                    return CommandInput(name: input.name, token: "{--\(option) : \(describe("Turn off: " + input.label))}", expression: "! $this->option(\(singleQuoted(option)))")
                }
                let option = unique(kebabName, in: &usedOptions)
                return CommandInput(name: input.name, token: "{--\(option) : \(describe(input.label))}", expression: "(bool) $this->option(\(singleQuoted(option)))")
            }
            guard let value = input.defaultValue else {
                let argument = unique(SnippetInputs.isValidVariableName(input.name) ? input.name : kebabName, in: &usedArguments)
                return CommandInput(name: input.name, token: "{\(argument) : \(describe(input.label))}", expression: "\(cast(input.kind))$this->argument(\(singleQuoted(argument)))")
            }
            let option = unique(kebabName, in: &usedOptions)
            var details = input.choices.isEmpty ? "" : "one of " + input.choices.map(\.editableText).joined(separator: ", ") + "; "
            details += "default: " + value.editableText
            let read = "$this->option(\(singleQuoted(option))) ?? \(value.phpLiteral)"
            return CommandInput(name: input.name, token: "{--\(option)= : \(describe("\(input.label) (\(details))"))}", expression: input.kind == .string ? read : "\(cast(input.kind))(\(read))")
        }
    }

    // MARK: Preparing the code

    enum ResultHandling: Equatable {
        /// A command dumps the result.
        case dump
        /// A test assigns it to `$result` and asks for an assertion.
        case test(TestStyle)
    }

    struct Prepared {
        /// The code without the opening tag, imports, `declare`, and `namespace`, not indented.
        var body: String
        var imports: [String]
        /// Top-level declarations, each followed by a blank line, for before the class or test.
        var declarations: [String]
        var strictTypes: Bool
        var notes: [String]
    }

    static func normalized(_ code: String) -> String {
        var code = code
        if code.first == "\u{FEFF}" { code.removeFirst() }
        return code.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func prepare(_ source: Source, inputs: SnippetInputSet, expressions: [String: String], extraNotes: [String], result: ResultHandling) -> Prepared {
        var notes = inputs.problems.map { "Runlet couldn't read \($0.declaration.isEmpty ? "@input" : "@input " + $0.declaration): \($0.message)" }
        notes += extraNotes
        var code = strippingInputDeclarations(normalized(source.code))
        code = SnippetInputs.code(code, inputs: inputs.inputs, expressions: expressions)
        code = removingMagicComments(code)
        var structure = restructure(code, result: result)
        notes += structure.notes
        if let contextCode = source.contextCode {
            let known = Set(structure.imports)
            structure.imports += importStatements(in: normalized(contextCode)).filter { !known.contains($0) }
        }
        var body = structure.body
        if !notes.isEmpty {
            body = notes.map { "// TODO: " + commentText($0) }.joined(separator: "\n") + (body.isEmpty ? "" : "\n\n" + body)
        }
        let declarations = structure.declarations.flatMap { indented($0, by: "") + [""] }
        return Prepared(body: body, imports: structure.imports, declarations: declarations, strictTypes: structure.strictTypes ?? source.strictTypes, notes: notes)
    }

    /// The code without `@input` lines in its leading docblocks; a docblock left with nothing
    /// else is removed.
    static func strippingInputDeclarations(_ code: String) -> String {
        var edits: [(Range<String.Index>, String)] = []
        var index = code.startIndex
        func skipWhitespace() {
            while index < code.endIndex, code[index].isWhitespace { index = code.index(after: index) }
        }
        skipWhitespace()
        if code[index...].hasPrefix("<?php") {
            let after = code.index(index, offsetBy: 5)
            if after == code.endIndex || code[after].isWhitespace { index = after }
        }
        while true {
            skipWhitespace()
            let remainder = code[index...]
            if remainder.hasPrefix("/*") {
                guard let close = code.range(of: "*/", range: code.index(index, offsetBy: 2)..<code.endIndex) else { break }
                if remainder.hasPrefix("/**"), !remainder.hasPrefix("/**/") {
                    let bodyStart = code.index(index, offsetBy: 3)
                    let lines = code[bodyStart..<close.lowerBound].split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                    var kept = lines.filter { SnippetInputs.declaration(inDocblockLine: $0) == nil }
                    if kept.count != lines.count {
                        func isBlank(_ line: Substring) -> Bool { line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "*"))).isEmpty }
                        // Blank ` *` lines left before the closing `*/` (the last line) go too.
                        while kept.count > 2, isBlank(kept[kept.count - 2]) { kept.remove(at: kept.count - 2) }
                        edits.append((index..<close.upperBound, kept.allSatisfy(isBlank) ? "" : "/**" + kept.joined(separator: "\n") + "*/"))
                    }
                }
                index = close.upperBound
            } else if remainder.hasPrefix("//") || (remainder.hasPrefix("#") && !remainder.hasPrefix("#[")) {
                index = remainder.firstIndex(where: \.isNewline) ?? code.endIndex
            } else {
                break
            }
        }
        var result = code
        for (range, replacement) in edits.reversed() { result.replaceSubrange(range, with: replacement) }
        return result
    }

    /// Whether a comment is a magic comment (the runner's `MagicComments::form`).
    static func isMagicComment(_ text: String) -> Bool {
        if text.hasPrefix("//?") { return text.dropFirst(3).allSatisfy { $0 == " " || $0 == "\t" } }
        guard text.hasPrefix("/*?"), text.hasSuffix("*/"), text.count >= 5 else { return false }
        let inner = text.dropFirst(3).dropLast(2)
        if inner.allSatisfy(\.isWhitespace) { return true }
        if inner.hasPrefix("."), inner.dropFirst().allSatisfy(\.isWhitespace) { return true }
        return inner.hasPrefix("->") || inner.hasPrefix("?->")
    }

    /// The code without magic comments: with the spaces before them, or their whole line
    /// when nothing else is on it.
    static func removingMagicComments(_ code: String) -> String {
        guard code.contains("//?") || code.contains("/*?") else { return code }
        let scan = PHPCodeScan(code)
        let bytes = scan.bytes
        let edits: [Edit] = scan.comments.filter { isMagicComment(scan.text($0)) }.map { comment in
            let lineStart = (bytes[..<comment.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 }) ?? 0
            let lineEnd = bytes[comment.upperBound...].firstIndex(of: 0x0A) ?? bytes.count
            let blankBefore = bytes[lineStart..<comment.lowerBound].allSatisfy(isHorizontalSpace)
            let blankAfter = bytes[comment.upperBound..<lineEnd].allSatisfy(isHorizontalSpace)
            if blankBefore, blankAfter { return Edit(range: lineStart..<min(lineEnd + 1, bytes.count), text: "") }
            if !blankBefore {
                var start = comment.lowerBound
                while start > lineStart, isHorizontalSpace(bytes[start - 1]) { start -= 1 }
                return Edit(range: start..<comment.upperBound, text: "")
            }
            var end = comment.upperBound
            while end < lineEnd, isHorizontalSpace(bytes[end]) { end += 1 }
            return Edit(range: comment.lowerBound..<end, text: "")
        }
        return apply(edits, to: bytes)
    }

    struct Structure {
        var body: String
        var imports: [String]
        var declarations: [String]
        var strictTypes: Bool?
        var notes: [String]
    }

    /// Lifts imports, `declare(strict_types)`, and `namespace` out of the code, removes the
    /// opening tag, and turns the result into a dump or an assignment.
    static func restructure(_ code: String, result: ResultHandling) -> Structure {
        var code = code
        var notes: [String] = []
        // A `namespace Name { … }` block: its contents stay, without the block.
        for _ in 0..<16 {
            let scan = PHPCodeScan(code)
            let statements = scan.statements(from: scan.tokens.first?.kind == .openTag ? 1 : 0)
            guard let block = statements.first(where: { $0.end == .brace && scan.keyword(scan.tokens[$0.tokens.lowerBound]) == "namespace" }),
                  let open = block.tokens.first(where: { scan.isSymbol(scan.tokens[$0], "{") }) else { break }
            let name = scan.tokens[block.tokens.lowerBound + 1..<open].map { scan.text($0) }.joined()
            notes.append(name.isEmpty ? "Runlet removed the snippet's namespace block." : "Runlet removed the snippet's namespace \(name): the class has its own.")
            let last = scan.tokens[block.tokens.upperBound - 1].range
            code = apply([Edit(range: scan.tokens[block.tokens.lowerBound].range.lowerBound..<scan.tokens[open].range.upperBound, text: ""), Edit(range: last, text: "")], to: scan.bytes)
        }

        let scan = PHPCodeScan(code)
        let bytes = scan.bytes
        var edits: [Edit] = []
        var imports: [String] = []
        var declarations: [String] = []
        var strictTypes: Bool?
        let start = scan.tokens.first?.kind == .openTag ? 1 : 0
        if start == 1 { edits.append(Edit(range: scan.tokens[0].range, text: "")) }
        let statements = scan.statements(from: start)
        for statement in statements where statement.end != .markup {
            let first = scan.tokens[statement.tokens.lowerBound]
            if scan.isDeclaration(statement) {
                // From the start of its line when it starts the line, so it dedents as a whole.
                let range = scan.range(of: statement)
                let lineStart = (bytes[..<range.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 }) ?? 0
                let start = bytes[lineStart..<range.lowerBound].allSatisfy(isHorizontalSpace) ? lineStart : range.lowerBound
                declarations.append(scan.text(start..<range.upperBound))
                edits.append(removal(of: scan.range(of: statement), in: bytes))
                continue
            }
            switch scan.keyword(first) {
            case "use":
                imports.append(importText(statement, scan: scan))
                edits.append(removal(of: scan.range(of: statement), in: bytes))
            case "declare":
                let body = scan.tokens[scan.body(of: statement)].map { scan.text($0).lowercased() }.joined()
                if body == "declare(strict_types=1)" || body == "declare(strict_types=0)" {
                    strictTypes = body.hasSuffix("1)")
                    edits.append(removal(of: scan.range(of: statement), in: bytes))
                }
            case "namespace" where statement.end == .semicolon:
                let name = scan.tokens[statement.tokens.lowerBound + 1..<statement.tokens.upperBound - 1].map { scan.text($0) }.joined()
                notes.append("Runlet removed the snippet's namespace \(name): the class has its own.")
                edits.append(removal(of: scan.range(of: statement), in: bytes))
            default:
                break
            }
        }
        if !scan.isComplete {
            notes.append("A string, comment, or heredoc in the snippet doesn't end: check the generated code.")
        }
        if scan.tokens.contains(where: { $0.kind == .word && isRunletHelper(scan.text($0)) }) {
            notes.append("Runlet's own helpers (such as Runlet\\bench()) exist only when Runlet runs code: replace them.")
        }

        var tail = ""
        let last = statements.last { !($0.end == .markup && scan.tokens[$0.tokens.lowerBound].kind == .openTag) }
        let resultVariable = Self.resultVariable(avoiding: scan)
        var variable: String?
        // Runlet accepts a missing final `;`; the generated code gets one.
        var unterminated = last?.end == PHPCodeScan.Statement.End.none
        if let last, last.end != .markup {
            let body = scan.body(of: last)
            let firstToken = scan.tokens[body.lowerBound]
            let isReturn = scan.keyword(firstToken) == "return" && body.count > 1
            if (scan.isExpressionStatement(last) || isReturn), !isOutputCall(scan, isReturn ? body.lowerBound + 1..<body.upperBound : body) {
                let expression = isReturn ? body.lowerBound + 1..<body.upperBound : body
                let exprStart = scan.tokens[expression.lowerBound].range.lowerBound
                let exprEnd = scan.tokens[expression.upperBound - 1].range.upperBound
                let missingSemicolon = unterminated
                unterminated = false
                if !isReturn, let assigned = scan.assignedVariable(last) {
                    variable = assigned
                    if missingSemicolon { edits.append(Edit(range: exprEnd..<exprEnd, text: ";")) }
                    if result == .dump { tail = "\ndump(\(assigned));" }
                } else {
                    let prefixRange = isReturn ? firstToken.range.lowerBound..<exprStart : exprStart..<exprStart
                    switch result {
                    case .dump:
                        edits.append(Edit(range: prefixRange, text: "dump("))
                        edits.append(Edit(range: exprEnd..<exprEnd, text: missingSemicolon ? ");" : ")"))
                    case .test:
                        let needsParentheses = scan.tokens[expression].contains { ["and", "or", "xor"].contains(scan.keyword($0) ?? "") }
                        edits.append(Edit(range: prefixRange, text: "\(resultVariable) = " + (needsParentheses ? "(" : "")))
                        edits.append(Edit(range: exprEnd..<exprEnd, text: (needsParentheses ? ")" : "") + (missingSemicolon ? ";" : "")))
                        variable = resultVariable
                    }
                }
            }
        }
        if unterminated, let last {
            let end = scan.tokens[last.tokens.upperBound - 1].range.upperBound
            edits.append(Edit(range: end..<end, text: ";"))
        }
        if case .test(let style) = result {
            if let variable {
                let example = style == .pest ? "expect(\(variable))->toBe(...);" : "$this->assertSame(..., \(variable));"
                tail = "\n\n// TODO: Assert the snippet's result, for example: \(example)"
            } else {
                tail = "\n\n// TODO: Add assertions. Runlet generated this test from a snippet."
            }
        }
        // Code that ends in inline HTML goes back to PHP before the method or closure ends.
        if let final = scan.tokens.last, final.kind == .inlineHTML || final.kind == .closeTag {
            tail = "\n<?php" + tail
        }
        // Dedented before the lines added at column 0.
        let body = indented(trimmingBlankLines(apply(edits, to: bytes)), by: "").joined(separator: "\n") + tail
        return Structure(body: trimmingBlankLines(body), imports: imports, declarations: declarations, strictTypes: strictTypes, notes: notes)
    }

    /// `$result`, or `$result2`, … when the snippet already uses that variable.
    private static func resultVariable(avoiding scan: PHPCodeScan) -> String {
        let used = Set(scan.tokens.filter { $0.kind == .variable }.map { scan.text($0) })
        var name = "$result"
        var number = 2
        while used.contains(name) {
            name = "$result\(number)"
            number += 1
        }
        return name
    }

    /// A call that prints its own output (`dump(…)`, `dd(…)`, `var_dump(…)`, …): the last
    /// statement is left as it is.
    private static func isOutputCall(_ scan: PHPCodeScan, _ tokens: Range<Int>) -> Bool {
        guard tokens.count >= 3, let name = scan.keyword(scan.tokens[tokens.lowerBound]),
              ["dump", "dd", "var_dump", "print_r", "printf", "var_export", "\\dump", "\\dd", "\\var_dump", "\\print_r", "\\printf", "\\var_export"].contains(name),
              scan.isSymbol(scan.tokens[tokens.lowerBound + 1], "("), scan.isSymbol(scan.tokens[tokens.upperBound - 1], ")") else { return false }
        // The call's parentheses enclose everything after the name.
        var depth = 0
        for index in tokens.lowerBound + 1..<tokens.upperBound {
            let token = scan.tokens[index]
            if scan.isSymbol(token, "(") || scan.isSymbol(token, "[") || scan.isSymbol(token, "{") { depth += 1 }
            if scan.isSymbol(token, ")") || scan.isSymbol(token, "]") || scan.isSymbol(token, "}") { depth -= 1 }
            if depth == 0, index != tokens.upperBound - 1 { return false }
        }
        return true
    }

    private static func isRunletHelper(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("runlet\\") || lower.hasPrefix("\\runlet\\")
    }

    // MARK: Imports

    /// The `use` statements at the top level of `code`, normalized.
    static func importStatements(in code: String) -> [String] {
        let scan = PHPCodeScan(code)
        return scan.statements(from: scan.tokens.first?.kind == .openTag ? 1 : 0).compactMap { statement in
            statement.end == .semicolon && scan.keyword(scan.tokens[statement.tokens.lowerBound]) == "use" ? importText(statement, scan: scan) : nil
        }
    }

    /// An import on one line, as `use A\B, C\{D, E as F};`, without a leading `\`.
    static func importText(_ statement: PHPCodeScan.Statement, scan: PHPCodeScan) -> String {
        var out = ""
        var previous: PHPCodeScan.Token?
        var strippedSlash = false
        for index in scan.body(of: statement) {
            let token = scan.tokens[index]
            var text = scan.text(token)
            if let previous, (previous.kind == .word && token.kind == .word) || scan.isSymbol(previous, ",") { out += " " }
            if token.kind == .word, !strippedSlash, index > statement.tokens.lowerBound, !["function", "const"].contains(text.lowercased()) {
                strippedSlash = true
                if text.hasPrefix("\\") { text.removeFirst() }
            }
            out += text
            previous = token
        }
        return out + ";"
    }

    /// The class names (lower case) an import makes available: `use A\B;` gives `b`, `use
    /// A\B as C;` gives `c`, and groups give each of theirs. Function and constant imports
    /// give none.
    static func classAliases(ofImport text: String) -> [String] {
        let scan = PHPCodeScan(text)
        var words = scan.tokens.map { scan.text($0) }
        guard words.first?.lowercased() == "use" else { return [] }
        words.removeFirst()
        if words.last == ";" { words.removeLast() }
        if ["function", "const"].contains(words.first?.lowercased() ?? "") { return [] }
        var aliases: [String] = []
        // Each clause: Name [as Alias], or Prefix\{Name [as Alias], …}.
        var clause: [String] = []
        var inGroup = false
        func finish() {
            defer { clause = [] }
            var items = clause
            if ["function", "const"].contains(items.first?.lowercased() ?? "") { return }
            if let as_ = items.firstIndex(where: { $0.lowercased() == "as" }), as_ + 1 < items.count {
                aliases.append(items[as_ + 1].lowercased())
                return
            }
            items = items.filter { $0 != "\\" }
            if let name = items.last { aliases.append((name.split(separator: "\\").last.map(String.init) ?? name).lowercased()) }
        }
        for word in words {
            switch word {
            case "{": inGroup = true; clause = []
            case "}": finish(); inGroup = false
            case ",": finish()
            default: clause.append(word)
            }
        }
        if !clause.isEmpty, !inGroup { finish() }
        return aliases.filter { !$0.isEmpty }
    }

    /// How the generated class refers to its base class, and the imports: the base class is
    /// imported unless the snippet's imports or the class's own name already take its name.
    static func baseClassReference(_ baseClass: String, className: String, imports: [String]) -> (reference: String, imports: [String]) {
        let shortName = baseClass.split(separator: "\\").last.map(String.init) ?? baseClass
        let own = "use \(baseClass);"
        let taken = imports.contains { $0 != own && classAliases(ofImport: $0).contains(shortName.lowercased()) }
        if taken || className.lowercased() == shortName.lowercased() {
            return ("\\" + baseClass, imports.filter { $0 != own })
        }
        return (shortName, imports.contains(own) ? imports : imports + [own])
    }

    /// `<?php`, `declare`, `namespace`, and the sorted imports (classes, then functions, then
    /// constants), each followed by a blank line.
    static func header(strictTypes: Bool, namespace: String?, imports: [String]) -> [String] {
        var lines = ["<?php", ""]
        if strictTypes { lines += ["declare(strict_types=1);", ""] }
        if let namespace, !namespace.isEmpty { lines += ["namespace \(namespace);", ""] }
        var seen = Set<String>()
        let unique = imports.filter { seen.insert($0).inserted }
        func group(_ text: String) -> Int {
            let lower = text.lowercased()
            return lower.hasPrefix("use function ") ? 1 : (lower.hasPrefix("use const ") ? 2 : 0)
        }
        let sorted = unique.sorted { group($0) != group($1) ? group($0) < group($1) : $0.lowercased() < $1.lowercased() }
        if !sorted.isEmpty { lines += sorted + [""] }
        return lines
    }

    // MARK: Text

    struct Edit {
        var range: Range<Int>
        var text: String
    }

    static func isHorizontalSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }

    /// Applies edits to `bytes` from the back. Overlapping deletions are merged.
    static func apply(_ edits: [Edit], to bytes: [UInt8]) -> String {
        var result = bytes
        var lowest = Int.max
        for edit in edits.sorted(by: { ($0.range.lowerBound, $0.range.upperBound) > ($1.range.lowerBound, $1.range.upperBound) }) {
            let upper = min(edit.range.upperBound, lowest)
            let lower = min(edit.range.lowerBound, upper)
            result.replaceSubrange(lower..<upper, with: Array(edit.text.utf8))
            lowest = lower
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// Removes a statement: its whole line when nothing else is on it, else the statement and
    /// the spaces after it.
    static func removal(of range: Range<Int>, in bytes: [UInt8]) -> Edit {
        let lineStart = (bytes[..<range.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 }) ?? 0
        let lineEnd = bytes[range.upperBound...].firstIndex(of: 0x0A) ?? bytes.count
        if bytes[lineStart..<range.lowerBound].allSatisfy(isHorizontalSpace), bytes[range.upperBound..<lineEnd].allSatisfy(isHorizontalSpace) {
            return Edit(range: lineStart..<min(lineEnd + 1, bytes.count), text: "")
        }
        var end = range.upperBound
        while end < lineEnd, isHorizontalSpace(bytes[end]) { end += 1 }
        return Edit(range: range.lowerBound..<end, text: "")
    }

    /// Without blank lines at the start and the end (and trailing spaces on the last line).
    static func trimmingBlankLines(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first, first.allSatisfy({ $0 == " " || $0 == "\t" }) { lines.removeFirst() }
        while let last = lines.last, last.allSatisfy({ $0 == " " || $0 == "\t" }) { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// The code's lines with their common indentation replaced by `indent`. Lines that start
    /// inside a string, heredoc, nowdoc, or inline HTML stay exactly as they are; other blank
    /// lines become empty.
    static func indented(_ code: String, by indent: String) -> [String] {
        guard !code.isEmpty else { return [] }
        let scan = PHPCodeScan(code)
        let bytes = scan.bytes
        var lines: [(start: Int, bytes: ArraySlice<UInt8>)] = []
        var lineStart = 0
        for (index, byte) in bytes.enumerated() where byte == 0x0A {
            lines.append((lineStart, bytes[lineStart..<index]))
            lineStart = index + 1
        }
        lines.append((lineStart, bytes[lineStart..<bytes.count]))
        let html = scan.tokens.filter { $0.kind == .inlineHTML }.map(\.range)
        // A line that starts outside PHP (`<?php` after `?>`): spaces before the tag are output.
        let reopened = scan.tokens.filter { $0.kind == .openTag }.map(\.range.lowerBound)
        func isFrozen(_ start: Int) -> Bool {
            scan.isInsideLiteral(start) || html.contains { $0.contains(start) }
                || reopened.contains { $0 >= start && bytes[start..<$0].allSatisfy(isHorizontalSpace) }
        }
        func leading(_ line: ArraySlice<UInt8>) -> ArraySlice<UInt8> { line.prefix(while: isHorizontalSpace) }
        var common: ArraySlice<UInt8>?
        for line in lines where !isFrozen(line.start) && !line.bytes.allSatisfy(isHorizontalSpace) {
            let prefix = leading(line.bytes)
            guard let current = common else {
                common = prefix
                continue
            }
            common = current.prefix(zip(current, prefix).prefix { $0 == $1 }.count)
        }
        let dedent = common?.count ?? 0
        var output: [String] = []
        for line in lines {
            if isFrozen(line.start) {
                output.append(String(decoding: line.bytes, as: UTF8.self))
            } else if line.bytes.allSatisfy(isHorizontalSpace) {
                // One blank line at most between code.
                if output.last != "" { output.append("") }
            } else {
                output.append(indent + String(decoding: line.bytes.dropFirst(dedent), as: UTF8.self))
            }
        }
        return output
    }

    /// Text on one line: control characters and line breaks become spaces, runs of spaces one.
    static func singleLine(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || scalar == "\u{2028}" || scalar == "\u{2029}" ? " " : Character(scalar)
        }
        return String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Text for a `//` comment: one line, and no `?>` (which would end PHP mode).
    static func commentText(_ text: String) -> String {
        singleLine(text).replacingOccurrences(of: "?>", with: "? >")
    }

    /// A single-quoted PHP string; only `\` and `'` are escaped, so line breaks stay as they are.
    static func singleQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    static func emptyLiteral(_ kind: SnippetInput.Kind) -> String {
        switch kind {
        case .int: "0"
        case .float: "0.0"
        case .string: "''"
        case .bool: "false"
        }
    }

    // MARK: Names

    /// Words of a title in ASCII: "Refund order #42" → ["Refund", "order", "42"].
    static func words(_ title: String) -> [String] {
        var text = (title as NSString).pathExtension.lowercased() == "php" ? (title as NSString).deletingPathExtension : title
        text = text.applyingTransform(.toLatin, reverse: false) ?? text
        text = text.applyingTransform(.stripDiacritics, reverse: false) ?? text
        return text.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init)
    }

    /// A class name for a title: "refund order" → "RefundOrder", with `suffix` once
    /// ("RefundOrderTest"). Titles without letters give "Snippet"; a leading digit gets
    /// "Snippet" in front.
    public static func className(fromTitle title: String, suffix: String = "") -> String {
        var name = words(title).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        if name.isEmpty || name == suffix { name = "Snippet" }
        if let first = name.first, first.isNumber { name = "Snippet" + name }
        if !suffix.isEmpty, !name.hasSuffix(suffix) { name += suffix }
        if isReservedWord(name) { name += suffix.isEmpty ? "Command" : "" }
        return name
    }

    /// kebab-case for a class or variable name: "RefundOrder" → "refund-order", "HTTPReport"
    /// → "http-report", "order_id" → "order-id".
    public static func kebab(_ name: String) -> String {
        let characters = Array(name)
        var out = ""
        for (index, character) in characters.enumerated() {
            guard character.isASCII, character.isLetter || character.isNumber else {
                if !out.isEmpty, out.last != "-" { out += "-" }
                continue
            }
            if character.isUppercase, index > 0, out.last != "-", !out.isEmpty {
                let previous = characters[index - 1]
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && (next?.isLowercase ?? false)) { out += "-" }
            }
            out += character.lowercased()
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// The signature's name for a command class: `app:refund-order` (Laravel's `make:command`
    /// convention), or `refund-order` for Laravel Zero.
    public static func commandName(forClass className: String, flavor: CommandFlavor = .laravel) -> String {
        let name = kebab(className).isEmpty ? "snippet" : kebab(className)
        return flavor == .laravel ? "app:" + name : name
    }

    /// `test_refund_order` for "Refund order".
    public static func testMethodName(fromTitle title: String) -> String {
        let name = words(title).map { $0.lowercased() }.joined(separator: "_")
        return "test_" + (name.isEmpty ? "snippet" : name)
    }

    /// PHP's reserved words, which can't name a class.
    private static let reservedWords: Set<String> = [
        "abstract", "and", "array", "as", "bool", "break", "callable", "case", "catch", "class", "clone", "const",
        "continue", "declare", "default", "die", "do", "echo", "else", "elseif", "empty", "enddeclare", "endfor",
        "endforeach", "endif", "endswitch", "endwhile", "eval", "exit", "extends", "false", "final", "finally",
        "float", "fn", "for", "foreach", "function", "global", "goto", "if", "implements", "include", "include_once",
        "instanceof", "insteadof", "int", "interface", "isset", "iterable", "list", "match", "mixed", "namespace",
        "never", "new", "null", "object", "or", "parent", "print", "private", "protected", "public", "readonly",
        "require", "require_once", "return", "self", "static", "string", "switch", "throw", "trait", "true", "try",
        "unset", "use", "var", "void", "while", "xor", "yield", "__halt_compiler",
    ]

    static func isReservedWord(_ name: String) -> Bool { reservedWords.contains(name.lowercased()) }

    /// Whether `name` can name the generated class: an ASCII PHP identifier that isn't a
    /// reserved word.
    public static func isValidClassName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !isReservedWord(name) else { return false }
        func isStart(_ scalar: Unicode.Scalar) -> Bool { ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || scalar == "_" }
        return isStart(first) && name.unicodeScalars.dropFirst().allSatisfy { isStart($0) || ("0"..."9").contains($0) }
    }
}

// MARK: - Project layout

extension SnippetPromotion {
    /// What decides where a promoted file goes and what it looks like: the project's PSR-4
    /// autoload folders, whether it uses Pest, and its base test case. Read from files only.
    public struct ProjectLayout: Sendable, Equatable {
        public struct Mapping: Sendable, Equatable {
            /// `App\` (with the trailing backslash, as composer.json writes it).
            public var prefix: String
            /// `app` (relative, without `./` or a trailing `/`; empty for the project folder).
            public var path: String

            public init(prefix: String, path: String) {
                self.prefix = prefix
                self.path = path
            }
        }

        public var psr4: [Mapping]
        public var usesPest: Bool
        /// `tests/TestCase.php` exists (Laravel's base test case).
        public var hasTestCase: Bool

        public init(psr4: [Mapping] = [], usesPest: Bool = false, hasTestCase: Bool = false) {
            self.psr4 = psr4
            self.usesPest = usesPest
            self.hasTestCase = hasTestCase
        }

        /// From composer.json's `autoload` and `autoload-dev` PSR-4 maps, and Pest in its
        /// `require` or `require-dev`.
        public init(composerJSON: Data?, hasPestFiles: Bool = false, hasTestCase: Bool = false) {
            var mappings: [Mapping] = []
            var pest = hasPestFiles
            if let composerJSON, let root = try? JSONSerialization.jsonObject(with: composerJSON) as? [String: Any] {
                for section in ["autoload", "autoload-dev"] {
                    guard let map = (root[section] as? [String: Any])?["psr-4"] as? [String: Any] else { continue }
                    for (prefix, value) in map.sorted(by: { $0.key < $1.key }) {
                        let paths = (value as? [String]) ?? (value as? String).map { [$0] } ?? []
                        mappings += paths.map { Mapping(prefix: prefix, path: Self.normalizedPath($0)) }
                    }
                }
                for section in ["require", "require-dev"] where (root[section] as? [String: Any])?["pestphp/pest"] != nil {
                    pest = true
                }
            }
            self.init(psr4: mappings, usesPest: pest, hasTestCase: hasTestCase)
        }

        /// Reads `composer.json`, `vendor/pestphp/pest`, `tests/Pest.php`, and
        /// `tests/TestCase.php` in the project folder.
        public static func read(projectRoot: URL) -> ProjectLayout {
            let manager = FileManager.default
            func exists(_ path: String) -> Bool { manager.fileExists(atPath: projectRoot.appendingPathComponent(path).path) }
            let composer = projectRoot.appendingPathComponent("composer.json")
            let size = (try? manager.attributesOfItem(atPath: composer.path)[.size] as? Int) ?? 0
            let data = size < 2_000_000 ? try? Data(contentsOf: composer) : nil
            return ProjectLayout(composerJSON: data, hasPestFiles: exists("vendor/pestphp/pest") || exists("tests/Pest.php"), hasTestCase: exists("tests/TestCase.php"))
        }

        static func normalizedPath(_ path: String) -> String {
            var path = path.trimmingCharacters(in: .whitespaces)
            while path.hasPrefix("./") { path.removeFirst(2) }
            while path.hasSuffix("/") { path.removeLast() }
            return path == "." ? "" : path
        }

        /// The namespace PSR-4 gives a folder (relative to the project): the longest matching
        /// folder's prefix plus the remaining folder names. Nil when no mapping covers it or a
        /// folder name isn't a valid namespace part; empty for the global namespace.
        public func namespace(forDirectory directory: String) -> String? {
            let directory = Self.normalizedPath(directory)
            let matches = psr4.filter { mapping in
                mapping.path.isEmpty || directory == mapping.path || directory.hasPrefix(mapping.path + "/")
            }
            guard let best = matches.max(by: { $0.path.count < $1.path.count }) else { return nil }
            let rest = best.path.isEmpty ? directory : String(directory.dropFirst(best.path.count))
            let parts = rest.split(separator: "/").map(String.init)
            guard parts.allSatisfy(SnippetPromotion.isValidClassName) else { return nil }
            var prefix = best.prefix
            while prefix.hasSuffix("\\") { prefix.removeLast() }
            return ([prefix].filter { !$0.isEmpty } + parts).joined(separator: "\\")
        }

        /// The base class of PHPUnit tests: the project's `Tests\TestCase` (in the namespace
        /// of `tests/`), else PHPUnit's own.
        public var testBaseClass: String {
            guard hasTestCase else { return "PHPUnit\\Framework\\TestCase" }
            let namespace = self.namespace(forDirectory: "tests") ?? "Tests"
            return namespace.isEmpty ? "TestCase" : namespace + "\\TestCase"
        }

        /// Pest, when the project uses it; else PHPUnit.
        public var testStyle: TestStyle { usesPest ? .pest : .phpunit }
    }

    /// The folder of `file` relative to `projectRoot` ("" for the project folder itself), or
    /// nil when it is outside. Symbolic links are resolved on both sides.
    public static func relativeDirectory(of file: URL, in projectRoot: URL) -> String? {
        let root = projectRoot.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let folder = file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard folder.count >= root.count, Array(folder.prefix(root.count)) == root else { return nil }
        return folder.dropFirst(root.count).joined(separator: "/")
    }
}
