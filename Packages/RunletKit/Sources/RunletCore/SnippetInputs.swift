import Foundation

/// A value a parameterised snippet asks for before it opens (#14). Declared in the snippet's
/// leading docblock, one per line:
///
/// ```php
/// /**
///  * @input int $orderId "Order ID"
///  * @input string $reason "Reason" = "duplicate" {duplicate, fraudulent, requested_by_customer}
///  * @input bool $notify "Email the customer" = true
///  */
/// ```
///
/// Syntax: `@input <type> $<name> ["Label"] [= default] [{choice, …}]`. Types are `int`,
/// `float`, `string`, and `bool`; `int`, `float`, and `string` inputs may list choices.
public struct SnippetInput: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case int, float, string, bool
    }

    public var kind: Kind
    /// The PHP variable name, without `$`.
    public var name: String
    /// The label from the declaration, if it has one.
    public var explicitLabel: String?
    /// The value the form starts with; nil leaves an `int` or `float` field empty.
    public var defaultValue: SnippetInputValue?
    /// When not empty, the form offers only these values.
    public var choices: [SnippetInputValue]

    public init(kind: Kind, name: String, label: String? = nil, defaultValue: SnippetInputValue? = nil, choices: [SnippetInputValue] = []) {
        self.kind = kind
        self.name = name
        self.explicitLabel = label
        self.defaultValue = defaultValue
        self.choices = choices
    }

    /// What the form shows: the declared label, or the variable name.
    public var label: String { explicitLabel ?? name }
}

/// A typed input value.
public enum SnippetInputValue: Sendable, Hashable {
    case int(Int)
    case float(Double)
    case string(String)
    case bool(Bool)

    public var kind: SnippetInput.Kind {
        switch self {
        case .int: .int
        case .float: .float
        case .string: .string
        case .bool: .bool
        }
    }

    /// The value as PHP source that evaluates to exactly this value, on one line (see
    /// `SnippetInputs.phpLiteral`).
    public var phpLiteral: String {
        switch self {
        case .int(let value): SnippetInputs.phpInt(value)
        case .float(let value): SnippetInputs.phpFloat(value) ?? "NAN"
        case .string(let value): SnippetInputs.phpString(value)
        case .bool(let value): value ? "true" : "false"
        }
    }

    /// The value as the form's text field shows it.
    public var editableText: String {
        switch self {
        case .int(let value): String(value)
        case .float(let value): value.isFinite ? "\(value)" : ""
        case .string(let value): value
        case .bool(let value): value ? "true" : "false"
        }
    }
}

/// An `@input` line Runlet could not read. The snippet still opens; that input is left out.
public struct SnippetInputProblem: Error, Sendable, Hashable, CustomStringConvertible {
    /// The declaration after `@input`.
    public var declaration: String
    public var message: String

    public init(declaration: String, message: String) {
        self.declaration = declaration
        self.message = message
    }

    public var description: String {
        let declaration = declaration.isEmpty ? "@input" : "@input \(declaration)"
        return "\(declaration): \(message)"
    }
}

/// A snippet's inputs and the declarations that could not be read.
public struct SnippetInputSet: Sendable, Hashable {
    public var inputs: [SnippetInput]
    public var problems: [SnippetInputProblem]

    public init(inputs: [SnippetInput] = [], problems: [SnippetInputProblem] = []) {
        self.inputs = inputs
        self.problems = problems
    }

    public static let none = SnippetInputSet()

    /// No `@input` lines at all: the snippet opens without a form.
    public var isEmpty: Bool { inputs.isEmpty && problems.isEmpty }
}

/// Parsing `@input` declarations, PHP literals for their values, and the code a parameterised
/// snippet opens with. Nothing here runs code.
public enum SnippetInputs {
    // MARK: Declarations

    /// The `@input` declarations (the text after `@input`) in the docblocks at the start of
    /// `code`: before any code, after an optional `<?php` tag, whitespace, and other comments.
    public static func declarations(inLeadingCommentsOf code: Substring) -> [String] {
        var text = code
        if text.first == "\u{FEFF}" { text = text.dropFirst() }
        var index = text.startIndex
        func skipWhitespace() {
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
        }
        skipWhitespace()
        if text[index...].hasPrefix("<?php") {
            let after = text.index(index, offsetBy: 5)
            if after == text.endIndex || text[after].isWhitespace { index = after }
        }
        var found: [String] = []
        while true {
            skipWhitespace()
            let remainder = text[index...]
            if remainder.hasPrefix("/*") {
                let bodyStart = text.index(index, offsetBy: 2)
                guard let close = text.range(of: "*/", range: bodyStart..<text.endIndex) else { break }
                if remainder.hasPrefix("/**"), !remainder.hasPrefix("/**/"), text.index(after: bodyStart) <= close.lowerBound {
                    found += declarations(inDocblockBody: text[text.index(after: bodyStart)..<close.lowerBound])
                }
                index = close.upperBound
            } else if remainder.hasPrefix("//") || (remainder.hasPrefix("#") && !remainder.hasPrefix("#[")) {
                index = remainder.firstIndex(where: \.isNewline) ?? text.endIndex
            } else {
                break
            }
        }
        return found
    }

    /// The `@input` lines of a docblock's body (between `/**` and `*/`).
    public static func declarations(inDocblockBody body: Substring) -> [String] {
        body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).compactMap { rawLine in
            declaration(inDocblockLine: rawLine)
        }
    }

    /// The text after `@input` when a docblock line is an `@input` line.
    static func declaration(inDocblockLine rawLine: Substring) -> String? {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("*") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
        guard line.hasPrefix("@input") else { return nil }
        let rest = line.dropFirst(6)
        guard rest.isEmpty || rest.first!.isWhitespace else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// The inputs declared in `code`'s leading docblocks (a personal snippet's code).
    public static func parse(code: String) -> SnippetInputSet {
        parse(declarations: declarations(inLeadingCommentsOf: Substring(code)))
    }

    /// Parses declarations in order. A declaration that can't be read, or that repeats a
    /// variable, becomes a problem and is left out.
    public static func parse(declarations: [String]) -> SnippetInputSet {
        var set = SnippetInputSet()
        var names = Set<String>()
        for declaration in declarations {
            switch parseDeclaration(declaration) {
            case .success(let input):
                if names.insert(input.name).inserted {
                    set.inputs.append(input)
                } else {
                    set.problems.append(SnippetInputProblem(declaration: declaration, message: "$\(input.name) is declared more than once; only the first declaration is used."))
                }
            case .failure(let problem):
                set.problems.append(problem)
            }
        }
        return set
    }

    /// One declaration: `<type> $<name> ["Label"] [= default] [{choice, …}]`.
    public static func parseDeclaration(_ declaration: String) -> Result<SnippetInput, SnippetInputProblem> {
        func fail(_ message: String) -> Result<SnippetInput, SnippetInputProblem> {
            .failure(SnippetInputProblem(declaration: declaration, message: message))
        }
        let example = "Write it like @input int $userId \"User ID\"."
        var scanner = DeclarationScanner(declaration)
        scanner.skipSpaces()
        let typeWord = scanner.word(stoppingAt: [])
        if typeWord.isEmpty { return fail("It needs a type and a variable. \(example)") }
        if typeWord.hasPrefix("$") { return fail("The type is missing before \(typeWord). \(example)") }
        guard let kind = SnippetInput.Kind(rawValue: typeWord.lowercased()) else {
            return fail("“\(typeWord)” is not an input type. Use int, float, string, or bool.")
        }

        scanner.skipSpaces()
        let nameWord = scanner.word(stoppingAt: ["\"", "'", "=", "{"])
        if nameWord.isEmpty { return fail("The variable is missing after \(kind.rawValue). \(example)") }
        guard nameWord.hasPrefix("$") else { return fail("The variable needs a $, like $\(nameWord).") }
        let name = String(nameWord.dropFirst())
        guard isValidVariableName(name) else { return fail("“\(nameWord)” is not a valid PHP variable name.") }
        guard name != "this", name != "GLOBALS" else { return fail("$\(name) can't be an input.") }

        var label: String?
        scanner.skipSpaces()
        if let quote = scanner.peek, quote == "\"" || quote == "'" {
            guard let text = scanner.quoted() else { return fail("The label's closing quote is missing.") }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            label = trimmed.isEmpty ? nil : trimmed
        }

        var defaultValue: SnippetInputValue?
        scanner.skipSpaces()
        if scanner.peek == "=" {
            scanner.advance()
            scanner.skipSpaces()
            let text: String
            if let quote = scanner.peek, quote == "\"" || quote == "'" {
                guard let quoted = scanner.quoted() else { return fail("The default's closing quote is missing.") }
                text = quoted
            } else {
                text = scanner.word(stoppingAt: ["{"])
                if text.isEmpty { return fail("“=” needs a default value after it.") }
            }
            switch kind.parse(text) {
            case .success(let value): defaultValue = value
            case .failure(let error): return fail("The default “\(text)” doesn't fit \(kind.rawValue): \(error.message)")
            }
        }

        var choices: [SnippetInputValue] = []
        scanner.skipSpaces()
        if scanner.peek == "{" {
            guard kind != .bool else { return fail("bool inputs can't list choices.") }
            scanner.advance()
            guard let items = scanner.choiceItems() else { return fail("The choice list's closing } is missing.") }
            let texts = items.filter { !$0.isEmpty }
            guard !texts.isEmpty else { return fail("The choice list is empty. List values like {paid, shipped}.") }
            for text in texts {
                switch kind.parse(text) {
                case .success(let value):
                    if !choices.contains(value) { choices.append(value) }
                case .failure(let error):
                    return fail("The choice “\(text)” doesn't fit \(kind.rawValue): \(error.message)")
                }
            }
            if let defaultValue {
                guard choices.contains(defaultValue) else { return fail("The default \(defaultValue.phpLiteral) is not one of the choices.") }
            } else {
                defaultValue = choices[0]
            }
        }

        scanner.skipSpaces()
        if !scanner.atEnd {
            let rest = scanner.rest
            if label == nil, defaultValue == nil, choices.isEmpty {
                return fail("Unexpected “\(rest)”. Put the label in double quotes, like \"User ID\".")
            }
            return fail("Unexpected “\(rest)” at the end.")
        }
        return .success(SnippetInput(kind: kind, name: name, label: label, defaultValue: defaultValue, choices: choices))
    }

    /// A PHP variable name (without `$`): a letter, underscore, or non-ASCII character, then
    /// those or digits.
    public static func isValidVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        func isStart(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || scalar == "_" || scalar.value >= 0x80
        }
        return isStart(first) && name.unicodeScalars.dropFirst().allSatisfy { isStart($0) || ("0"..."9").contains($0) }
    }

    // MARK: PHP literals

    /// An int as `var_export` writes it. `PHP_INT_MIN` can't be written as one literal
    /// (`-9223372036854775808` is minus a float), so it is `-9223372036854775807-1`.
    public static func phpInt(_ value: Int) -> String {
        value == Int.min ? "\(Int.min + 1)-1" : String(value)
    }

    /// A finite float as `var_export` writes it (PHP's `serialize_precision = -1`): the
    /// shortest digits that read back as the same float, always with a `.` or an exponent,
    /// e.g. `1.0`, `0.1`, `1.0E+25`, `-0.0`. Nil for infinity and NaN.
    public static func phpFloat(_ value: Double) -> String? {
        guard value.isFinite else { return nil }
        // Swift's description has the same shortest round-trip digits as PHP's zend_dtoa
        // mode 0; only the layout differs, so it is laid out again like php_gcvt.
        var text = Substring("\(value)")
        let negative = text.first == "-"
        if negative { text = text.dropFirst() }
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: e)...]) ?? 0
            text = text[..<e]
        }
        let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let whole = parts[0]
        let fraction = parts.count > 1 ? parts[1] : ""
        var digits = Array(whole + fraction)
        // The value is 0.<digits> × 10^point.
        var point = whole.count + exponent
        while digits.first == "0" {
            digits.removeFirst()
            point -= 1
        }
        while digits.last == "0" { digits.removeLast() }
        if digits.isEmpty {
            digits = ["0"]
            point = 1
        }

        var out = negative ? "-" : ""
        let precision = 17
        if point < 0 ? point < -3 : point > precision {
            let power = point - 1
            out.append(digits[0])
            out += "."
            out += digits.count > 1 ? String(digits[1...]) : "0"
            out += power < 0 ? "E-" : "E+"
            out += String(abs(power))
        } else if point < 0 {
            out += "0." + String(repeating: "0", count: -point) + String(digits)
        } else {
            for i in 0..<point { out.append(i < digits.count ? digits[i] : "0") }
            if digits.count > point {
                if point == 0 { out += "0" }
                out += "." + String(digits[point...])
            }
        }
        if !out.contains("."), !out.contains("E") { out += ".0" }
        return out
    }

    /// A string as PHP source on one line, evaluating to exactly `value`.
    ///
    /// Text without control characters is single-quoted as `var_export` writes it (only `\`
    /// and `'` are escaped; `$` and everything else, including Unicode, stay as they are).
    /// Text with control characters (newlines, tabs, NUL, …), line or paragraph separators,
    /// or invisible bidirectional marks is double-quoted instead, with `\\`, `\"`, `\$`, and
    /// escapes such as `\n`, `\x00`, and `\u{202E}`, so the value stays on one visible line.
    public static func phpString(_ value: String) -> String {
        let scalars = value.unicodeScalars
        guard scalars.contains(where: needsEscape) else {
            var out = "'"
            for scalar in scalars {
                if scalar == "\\" || scalar == "'" { out += "\\" }
                out.unicodeScalars.append(scalar)
            }
            return out + "'"
        }
        var out = "\""
        for scalar in scalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "$": out += "\\$"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{0B}": out += "\\v"
            case "\u{0C}": out += "\\f"
            case "\u{1B}": out += "\\e"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += "\\x" + hex(scalar.value, width: 2)
                } else if needsEscape(scalar) {
                    out += "\\u{" + hex(scalar.value, width: 1) + "}"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Characters a single-quoted literal would show raw but that break or hide the line:
    /// C0 and C1 controls, DEL, line and paragraph separators, bidirectional controls, and
    /// the byte order mark.
    static func needsEscape(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: true
        case 0x2028, 0x2029: true
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: true
        case 0xFEFF: true
        default: false
        }
    }

    private static func hex(_ value: UInt32, width: Int) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    // MARK: Opening

    /// The code a parameterised snippet opens with: one `$name = <literal>;` line per input.
    ///
    /// - An assignment to an input in the snippet's opening lines (before its first other
    ///   statement, after `<?php`, comments, docblocks, `declare`, `namespace`, and `use`) is a
    ///   placeholder: its value is replaced in place, so the variable isn't assigned twice.
    /// - The other inputs go in one block, after the opening tag, docblocks, `declare`,
    ///   `namespace`, and `use` lines, and before the first other line, with a blank line
    ///   after it. Each value is on its own line, so the rest of the code moves down by a fixed
    ///   number of lines and errors point at the lines shown in the tab.
    /// - Inputs without a value in `values` are left out.
    public static func code(_ code: String, inputs: [SnippetInput], values: [String: SnippetInputValue]) -> String {
        self.code(code, inputs: inputs, expressions: values.mapValues(\.phpLiteral))
    }

    /// The same, with any one-line PHP expression per input instead of a literal, such as
    /// `(int) $this->argument('orderId')` when a snippet becomes an Artisan command (#39).
    public static func code(_ code: String, inputs: [SnippetInput], expressions: [String: String]) -> String {
        let assigned = inputs.filter { expressions[$0.name] != nil }
        guard !assigned.isEmpty else { return code }
        var lines = code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : code.components(separatedBy: "\n")
        let (lastStructural, placeholders) = openingLayout(&lines, names: Set(assigned.map(\.name)))

        for (line, name) in placeholders {
            guard let expression = expressions[name] else { continue }
            lines[line] = replacingPlaceholder(lines[line], with: expression)
        }
        let header = assigned.filter { !placeholders.values.contains($0.name) }.map { "$\($0.name) = \(expressions[$0.name]!);" }
        guard !header.isEmpty else { return lines.joined(separator: "\n") }

        var position = lastStructural + 1
        while position < lines.count, lines[position].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { position += 1 }
        var block = header
        if position < lines.count { block.append("") }
        lines.insert(contentsOf: block, at: position)
        return lines.joined(separator: "\n")
    }

    /// The inputs among `names` that have a placeholder assignment in the snippet's opening
    /// lines (see `code(_:inputs:values:)`).
    static func placeholderNames(in code: String, names: Set<String>) -> Set<String> {
        guard !names.isEmpty else { return [] }
        var lines = code.components(separatedBy: "\n")
        return Set(openingLayout(&lines, names: names).placeholders.values)
    }

    /// Reads the snippet's opening lines: the index of the last structural line (the opening
    /// tag, a docblock, `declare`, `namespace`, or `use`; -1 for none) and the placeholder
    /// assignments to `names` (line index → name). An opening tag with code after it is split
    /// onto a line of its own in `lines`.
    private static func openingLayout(_ lines: inout [String], names: Set<String>) -> (lastStructural: Int, placeholders: [Int: String]) {
        var lastStructural = -1
        var placeholders: [Int: String] = [:]
        var seenCode = false
        var inComment = false
        var commentIsDocblock = false
        var index = 0
        scan: while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\r")))
            defer { index += 1 }
            if inComment {
                guard let close = line.range(of: "*/") else { continue }
                inComment = false
                guard line[close.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty else { break scan }
                if commentIsDocblock { lastStructural = index }
                continue
            }
            if line.isEmpty { continue }
            if !seenCode, line.hasPrefix("<?php") {
                seenCode = true
                let after = line.dropFirst(5)
                if after.isEmpty || isComment(after.trimmingCharacters(in: .whitespaces)) {
                    lastStructural = index
                    continue
                }
                if after.first!.isWhitespace {
                    // `<?php` with code after it: the tag gets a line of its own.
                    let indent = lines[index].prefix { $0.isWhitespace }
                    lines[index] = String(indent) + "<?php"
                    lines.insert(after.trimmingCharacters(in: .whitespaces), at: index + 1)
                    lastStructural = index
                    continue
                }
                break scan
            }
            seenCode = true
            if isComment(line) { continue }
            if line.hasPrefix("/*") {
                let isDocblock = line.hasPrefix("/**") && !line.hasPrefix("/**/")
                if let close = line.range(of: "*/", range: line.index(line.startIndex, offsetBy: 2)..<line.endIndex) {
                    guard line[close.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty else { break scan }
                    if isDocblock { lastStructural = index }
                } else {
                    inComment = true
                    commentIsDocblock = isDocblock
                }
                continue
            }
            if line.range(of: structuralPattern, options: [.regularExpression, .caseInsensitive]) != nil {
                lastStructural = index
                continue
            }
            if let name = placeholderName(line), names.contains(name), !placeholders.values.contains(name) {
                placeholders[index] = name
                continue
            }
            break scan
        }
        return (lastStructural, placeholders)
    }

    /// `declare(…);`, `namespace …;`, or `use …;` on one line, optionally with a trailing comment.
    private static let structuralPattern = #"^(declare\s*\(.*\)\s*;|namespace\s+[^;{]+;|use\s+[^;]+;)\s*((//|#).*)?$"#

    private static func isComment(_ line: String) -> Bool {
        line.hasPrefix("//") || (line.hasPrefix("#") && !line.hasPrefix("#["))
    }

    /// `$name = <expression without ;>;` with an optional trailing comment.
    private static let placeholderPattern = #"^\$([A-Za-z_\x{80}-\x{10FFFF}][A-Za-z0-9_\x{80}-\x{10FFFF}]*)\s*=(?![=>])\s*[^;]*;\s*((//|#).*)?$"#

    static func placeholderName(_ line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: placeholderPattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    /// The placeholder line with its value replaced, keeping indentation and any comment.
    private static func replacingPlaceholder(_ line: String, with literal: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?s)^(\s*\$[^\s=]+\s*=\s*)([^;]*?)(\s*;.*)$"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let head = Range(match.range(at: 1), in: line), let tail = Range(match.range(at: 3), in: line) else { return line }
        return String(line[head]) + literal + String(line[tail])
    }
}

extension SnippetInput.Kind {
    public struct ParseError: Error, Sendable, Hashable {
        public var message: String
    }

    /// Reads typed text as a value of this kind (a form field, a default, or a choice).
    /// Whitespace around numbers is ignored; strings are kept as typed.
    public func parse(_ text: String) -> Result<SnippetInputValue, ParseError> {
        switch self {
        case .string:
            return .success(.string(text))
        case .bool:
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1", "yes", "on": return .success(.bool(true))
            case "false", "0", "no", "off": return .success(.bool(false))
            default: return .failure(ParseError(message: "Use true or false."))
            }
        case .int:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return .failure(ParseError(message: "Enter a whole number.")) }
            guard trimmed.range(of: #"^[+-]?[0-9]+(_[0-9]+)*$"#, options: .regularExpression) != nil else {
                return .failure(ParseError(message: "Enter a whole number, like 42."))
            }
            guard let value = Int(trimmed.replacingOccurrences(of: "_", with: "")) else {
                return .failure(ParseError(message: "Too large: an int is from \(Int.min) to \(Int.max)."))
            }
            return .success(.int(value))
        case .float:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return .failure(ParseError(message: "Enter a number.")) }
            guard trimmed.range(of: #"^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else {
                if trimmed.range(of: #"^[+-]?[0-9]+,[0-9]+$"#, options: .regularExpression) != nil {
                    return .failure(ParseError(message: "Use a dot for decimals, like 1.5."))
                }
                return .failure(ParseError(message: "Enter a number, like 1.5."))
            }
            guard let value = Double(trimmed), value.isFinite else {
                return .failure(ParseError(message: "Too large for a float."))
            }
            return .success(.float(value))
        }
    }
}

/// The input form's state: what each field holds, and the values it makes.
public struct SnippetInputForm: Sendable, Equatable {
    public let inputs: [SnippetInput]
    /// Text of `int`, `float`, and `string` fields without choices.
    public var texts: [String: String]
    /// `bool` checkboxes.
    public var flags: [String: Bool]
    /// The chosen index of inputs with choices.
    public var selections: [String: Int]

    /// Every field starts at its default.
    public init(inputs: [SnippetInput]) {
        self.inputs = inputs
        var texts: [String: String] = [:]
        var flags: [String: Bool] = [:]
        var selections: [String: Int] = [:]
        for input in inputs {
            if !input.choices.isEmpty {
                selections[input.name] = input.defaultValue.flatMap { input.choices.firstIndex(of: $0) } ?? 0
            } else if input.kind == .bool {
                if case .bool(let value) = input.defaultValue { flags[input.name] = value } else { flags[input.name] = false }
            } else {
                texts[input.name] = input.defaultValue?.editableText ?? ""
            }
        }
        self.texts = texts
        self.flags = flags
        self.selections = selections
    }

    /// The field's value, or why it isn't valid.
    public func value(of input: SnippetInput) -> Result<SnippetInputValue, SnippetInput.Kind.ParseError> {
        if !input.choices.isEmpty {
            let index = selections[input.name] ?? 0
            return input.choices.indices.contains(index) ? .success(input.choices[index]) : .failure(.init(message: "Choose a value."))
        }
        if input.kind == .bool { return .success(.bool(flags[input.name] ?? false)) }
        return input.kind.parse(texts[input.name] ?? "")
    }

    /// Why the field isn't valid, or nil.
    public func error(for input: SnippetInput) -> String? {
        if case .failure(let error) = value(of: input) { return error.message }
        return nil
    }

    /// Every value, or nil while a field isn't valid.
    public var values: [String: SnippetInputValue]? {
        var values: [String: SnippetInputValue] = [:]
        for input in inputs {
            guard case .success(let value) = value(of: input) else { return nil }
            values[input.name] = value
        }
        return values
    }

    public var isValid: Bool { values != nil }

    /// The lines the form adds (or the placeholders it fills), for the form's preview.
    public var assignments: [String] {
        inputs.map { input in
            switch value(of: input) {
            case .success(let value): "$\(input.name) = \(value.phpLiteral);"
            case .failure: "$\(input.name) = …;"
            }
        }
    }

    /// Sets a field from text, as typing would: a text field takes it as is, a checkbox
    /// reads true or false, and a choice list picks the choice spelled that way. False when
    /// there is no such input or choice.
    @discardableResult
    public mutating func set(_ name: String, to text: String) -> Bool {
        guard let input = inputs.first(where: { $0.name == name }) else { return false }
        if !input.choices.isEmpty {
            guard let index = input.choices.firstIndex(where: { $0.editableText == text }) else { return false }
            selections[name] = index
        } else if input.kind == .bool {
            guard case .success(.bool(let value)) = input.kind.parse(text) else { return false }
            flags[name] = value
        } else {
            texts[name] = text
        }
        return true
    }

    /// The snippet's code with the values (see `SnippetInputs.code`); nil while a field
    /// isn't valid.
    public func code(for code: String) -> String? {
        values.map { SnippetInputs.code(code, inputs: inputs, values: $0) }
    }
}

/// Reads one `@input` declaration.
private struct DeclarationScanner {
    private let characters: [Character]
    private var index = 0

    init(_ text: String) { characters = Array(text) }

    var atEnd: Bool { index >= characters.count }
    var peek: Character? { atEnd ? nil : characters[index] }
    var rest: String { String(characters[index...]) }

    mutating func advance() { index += 1 }

    mutating func skipSpaces() {
        while let character = peek, character.isWhitespace { index += 1 }
    }

    /// Characters up to whitespace or one of `stops`.
    mutating func word(stoppingAt stops: Set<Character>) -> String {
        var word = ""
        while let character = peek, !character.isWhitespace, !stops.contains(character) {
            word.append(character)
            index += 1
        }
        return word
    }

    /// A string in the quote at `peek`; `\` escapes the quote and itself. Nil when it never closes.
    mutating func quoted() -> String? {
        guard let quote = peek else { return nil }
        index += 1
        var text = ""
        while let character = peek {
            index += 1
            if character == quote { return text }
            if character == "\\", let next = peek, next == quote || next == "\\" {
                text.append(next)
                index += 1
            } else {
                text.append(character)
            }
        }
        return nil
    }

    /// The items of `{a, "b, c", d}` after its `{`, through the closing `}`. Bare items are
    /// trimmed; quoted ones are kept as written. Nil when the list never closes.
    mutating func choiceItems() -> [String]? {
        var items: [String] = []
        while true {
            skipSpaces()
            guard let character = peek else { return nil }
            var item: String
            if character == "\"" || character == "'" {
                guard let quoted = quoted() else { return nil }
                item = quoted
                skipSpaces()
            } else {
                item = ""
                while let next = peek, next != ",", next != "}" {
                    item.append(next)
                    index += 1
                }
                item = item.trimmingCharacters(in: .whitespaces)
            }
            guard let separator = peek else { return nil }
            index += 1
            if separator == "}" {
                items.append(item)
                return items
            }
            guard separator == "," else { return nil }
            items.append(item)
        }
    }
}

extension Snippet {
    /// The `@input` declarations in the docblocks at the start of the code (#14). SQL
    /// snippets (#130) have no inputs.
    public var inputs: SnippetInputSet { tabLanguage == .sql ? .none : SnippetInputs.parse(code: code) }
}

extension SnippetInputValue {
    /// The value as JSON for MCP clients.
    public var json: MCPJSON {
        switch self {
        case .int(let value): .int(value)
        case .float(let value): .double(value)
        case .string(let value): .string(value)
        case .bool(let value): .bool(value)
        }
    }
}

extension MCPCatalog {
    /// What `get_snippet` adds for a parameterised snippet (#14): `inputs` (name, type, and
    /// the label, default, and choices when declared) and `input_problems` (declarations
    /// that could not be read). Empty for snippets without `@input` lines.
    public static func snippetInputs(_ set: SnippetInputSet) -> [String: MCPJSON] {
        var fields: [String: MCPJSON] = [:]
        if !set.inputs.isEmpty {
            fields["inputs"] = .array(set.inputs.map { input in
                var object: [String: MCPJSON] = ["name": .string(input.name), "type": .string(input.kind.rawValue)]
                if let label = input.explicitLabel { object["label"] = .string(label) }
                if let value = input.defaultValue { object["default"] = value.json }
                if !input.choices.isEmpty { object["choices"] = .array(input.choices.map(\.json)) }
                return .object(object)
            })
        }
        if !set.problems.isEmpty {
            fields["input_problems"] = .array(set.problems.map { .string($0.description) })
        }
        return fields
    }
}
