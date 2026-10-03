import Foundation
import Testing
@testable import RunletCore

/// Cross-checks the PHP literals of parameterised snippets (#14) with a local PHP: every
/// literal must read back as exactly the value it was made from, and ints, floats, booleans,
/// and strings without control characters must be spelled exactly as `var_export` spells them.
/// Skipped when there is no `php` on this Mac.
struct SnippetInputsPHPTests {
    static let php = ExecutableLocator.resolve("php")

    /// A small deterministic generator, so a failure can be reproduced.
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// One evaluated value: PHP's type, a canonical form, and `var_export`'s text.
    struct Evaluated {
        var type: String
        var canonical: String
        var varExport: String
    }

    /// The PHP code printing `$x`'s type, canonical form (exact bytes or bits), and
    /// `var_export` text (base64), tab-separated, after `$label`.
    static let printer = #"""
    function runlet_print($label, $x) {
        $t = gettype($x);
        switch ($t) {
            case 'string': $c = bin2hex($x); break;
            case 'integer': $c = (string) $x; break;
            case 'double': $c = bin2hex(pack('E', $x)); break;
            case 'boolean': $c = $x ? '1' : '0'; break;
            default: $c = '?';
        }
        echo $label, "\t", $t, "\t", $c, "\t", base64_encode(var_export($x, true)), "\n";
    }
    """#

    /// Runs a PHP program (`php -n`, no ini files) and returns its standard output.
    static func run(_ program: String) throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-inputs-\(UUID().uuidString).php")
        try Data(program.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: php!)
        process.arguments = ["-n", "-d", "display_errors=stderr", file.path]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(errorText)")
        #expect(errorText.isEmpty, "\(errorText)")
        return String(decoding: data, as: UTF8.self)
    }

    static func parse(_ output: String) -> [String: Evaluated] {
        var results: [String: Evaluated] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4 else { continue }
            let export = Data(base64Encoded: fields[3]).map { String(decoding: $0, as: UTF8.self) } ?? "?"
            results[fields[0]] = Evaluated(type: fields[1], canonical: fields[2], varExport: export)
        }
        return results
    }

    /// What PHP should report for a value.
    static func expected(_ value: SnippetInputValue) -> (type: String, canonical: String) {
        switch value {
        case .int(let int): ("integer", String(int))
        case .float(let double):
            ("double", String(repeating: "0", count: 16 - String(double.bitPattern, radix: 16).count) + String(double.bitPattern, radix: 16))
        case .string(let string): ("string", Data(string.utf8).map { String(format: "%02x", $0) }.joined())
        case .bool(let bool): ("boolean", bool ? "1" : "0")
        }
    }

    // MARK: Values

    static func values() -> [SnippetInputValue] {
        var random = SplitMix64(state: 0x5EED_0014)
        var values: [SnippetInputValue] = []

        values += [0, 1, -1, 42, Int.max, Int.min, Int.min + 1, Int.max - 1, 1 << 53, -(1 << 53) - 1].map(SnippetInputValue.int)
        values += (0..<400).map { _ in .int(Int(bitPattern: UInt(random.next()))) }
        values += (0..<200).map { _ in .int(Int.random(in: -100_000...100_000, using: &random)) }

        var floats: [Double] = [
            0, -0.0, 1, -1, 0.1, 0.2, 0.3, 0.1 + 0.2, 1.5, 1e-5, 1e-4, 1e-3, 1e15, 1e16, 1e17, 1e21, 1e22, 1e23,
            123456789012345678, 9007199254740992, 9007199254740993, 5e-324, 2.2250738585072014e-308,
            .leastNonzeroMagnitude, .leastNormalMagnitude, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
            .pi, -.pi, M_E, 1.0 / 3.0, 2.0 / 3.0, 100, 0.5, 0.25, 1234567.0, 9.999999999999999e22,
        ]
        for exponent in -330...308 {
            let power = pow(10.0, Double(exponent))
            if power.isFinite, power != 0 { floats += [power, power.nextUp, power.nextDown, 1.5 * power, -7.25 * power] }
        }
        for exponent in -1074...1023 where exponent % 7 == 0 {
            floats.append(pow(2.0, Double(exponent)))
        }
        while floats.count < 6000 {
            let double = Double(bitPattern: random.next())
            if double.isFinite { floats.append(double) }
        }
        for _ in 0..<1500 {
            let digits = Double(Int.random(in: -99_999_999...99_999_999, using: &random))
            floats.append(digits / pow(10.0, Double(Int.random(in: 0...12, using: &random))))
        }
        values += floats.filter(\.isFinite).map(SnippetInputValue.float)

        let strings: [String] = [
            "", "plain", "it's", #"C:\path\"#, #"\'"#, #"\\"#, "'", "\\", "$x {$y} ${z}", #"say "hi""#, "Zoë 🎉 中文",
            "e\u{301}\\\u{301}", "a\nb", "a\r\nb\tc", "a\0b", "\0" + "1", "\0" + "777", "\u{0B}\u{0C}\u{1B}\u{07}\u{7F}",
            "$x\n", "{$x}\n", "\"\\\n'", "line\u{2028}sep\u{2029}", "\u{85}", "abc\u{202E}def", "\u{FEFF}bom", "\u{200F}",
            "\\x41\n", "\\u{41}\n", "\\101\n", "?>", "<?php echo 1; ?>\n", "*/", "\"\"\"", "\u{10FFFF}", "\u{E000}",
            String(repeating: "long ", count: 400), "trailing\\", "trailing\\\n",
        ]
        values += strings.map(SnippetInputValue.string)
        let pools: [ClosedRange<UInt32>] = [0x20...0x7E, 0x20...0x7E, 0x00...0x1F, 0x7F...0xA0, 0xA1...0x24F, 0x300...0x36F, 0x400...0x4FF,
                                           0x2000...0x206F, 0x4E00...0x4E80, 0xFEFF...0xFEFF, 0x1F600...0x1F64F, 0x10000...0x10FFFF]
        let specials: [Unicode.Scalar] = ["'", "\\", "\"", "$", "{", "}", "\n", "\0", "x", "0", "u"]
        for _ in 0..<800 {
            var scalars = String.UnicodeScalarView()
            for _ in 0..<Int.random(in: 0...16, using: &random) {
                if Bool.random(using: &random) {
                    scalars.append(specials.randomElement(using: &random)!)
                } else {
                    let pool = pools.randomElement(using: &random)!
                    if let scalar = Unicode.Scalar(UInt32.random(in: pool, using: &random)) { scalars.append(scalar) }
                }
            }
            values.append(.string(String(scalars)))
        }
        values += [.bool(true), .bool(false)]
        return values
    }

    // MARK: Tests

    @Test(.enabled(if: php != nil, "needs a local php"))
    func literalsReadBackExactlyAndMatchVarExport() throws {
        let values = Self.values()
        var program = "<?php\n" + Self.printer + "\n"
        for (index, value) in values.enumerated() {
            program += "runlet_print('\(index)', \(value.phpLiteral));\n"
        }
        let results = Self.parse(try Self.run(program))
        #expect(results.count == values.count)
        var checked = (exact: 0, sameValue: 0)
        for (index, value) in values.enumerated() {
            guard let result = results[String(index)] else {
                Issue.record("No result for \(value) (\(value.phpLiteral))")
                continue
            }
            let expected = Self.expected(value)
            #expect(result.type == expected.type, "\(value.phpLiteral)")
            #expect(result.canonical == expected.canonical, "\(value.phpLiteral)")
            if case .string(let string) = value, string.unicodeScalars.contains(where: SnippetInputs.needsEscape) {
                // Spelled differently from var_export (one line, double-quoted), same value.
                checked.sameValue += 1
            } else {
                #expect(result.varExport == value.phpLiteral, "\(value)")
                checked.exact += 1
            }
        }
        #expect(checked.exact > 8000)
        #expect(checked.sameValue > 300)
    }

    @Test(.enabled(if: php != nil, "needs a local php"))
    func openedCodeRunsWithTheValues() throws {
        let inputs = SnippetInputs.parse(declarations: [
            #"int $orderId "Order ID""#,
            #"float $amount"#,
            #"string $reason "Reason""#,
            #"bool $notify = true"#,
            #"string $note"#,
        ]).inputs
        let values: [String: SnippetInputValue] = [
            "orderId": .int(Int.min),
            "amount": .float(0.1 + 0.2),
            "reason": .string("o'neil \\ $HOME {$x}\n\0\u{202E}é"),
            "notify": .bool(false),
            "note": .string("placeholder replaced"),
        ]
        let snippet = """
        /**
         * @input int $orderId "Order ID"
         */
        $note = 'from the snippet'; // a placeholder
        runlet_print('orderId', $orderId);
        runlet_print('amount', $amount);
        runlet_print('reason', $reason);
        runlet_print('notify', $notify);
        runlet_print('note', $note);
        echo "line\\t", __LINE__, "\\t\\t\\n";
        """
        let opened = SnippetInputs.code(snippet, inputs: inputs, values: values)
        #expect(opened.components(separatedBy: "\n").count == snippet.components(separatedBy: "\n").count + 5)
        // The tab's code is what runs: `__LINE__` is the line shown in the tab (after `<?php`).
        let lines = opened.components(separatedBy: "\n")
        let echoLine = try #require(lines.firstIndex { $0.hasPrefix("echo \"line") }) + 1
        let program = "<?php " + Self.printer.replacingOccurrences(of: "\n", with: " ") + "\n" + opened
        let output = try Self.run(program)
        let results = Self.parse(output)
        for (name, value) in values {
            let expected = Self.expected(value)
            #expect(results[name]?.type == expected.type, "\(name)")
            #expect(results[name]?.canonical == expected.canonical, "\(name)")
        }
        #expect(output.contains("line\t\(echoLine + 1)\t"))
    }
}
