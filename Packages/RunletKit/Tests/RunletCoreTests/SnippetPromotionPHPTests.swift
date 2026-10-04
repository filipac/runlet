import Foundation
import Testing
@testable import RunletCore

/// Checks promoted snippets (#39) with a local PHP: every generated command and test must
/// pass `php -l`, and generated commands, run against small stand-ins for Laravel's
/// `Command` and `dump()`, must do what the snippet does. Skipped when there is no `php` on
/// this Mac. Nothing here touches a real project.
struct SnippetPromotionPHPTests {
    static let php = ExecutableLocator.resolve("php")

    /// Runs `php -n <arguments>` and returns its exit status, standard output, and errors.
    static func php(_ arguments: [String]) throws -> (status: Int32, output: String, errors: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: php!)
        process.arguments = ["-n", "-d", "display_errors=stderr", "-d", "error_reporting=-1"] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self), String(decoding: errorData, as: UTF8.self))
    }

    static func temporaryFile(_ contents: String, name: String = "promoted") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-promotion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(name).php")
        try Data(contents.utf8).write(to: file)
        return file
    }

    /// Snippets with the constructs most likely to break when code moves into a method.
    static let corpus: [String] = [
        "1 + 1",
        "<?php\n\nuse App\\Models\\User;\n\nUser::query()->where('active', true)->count(); //?",
        #"""
        <?php
        $name = 'World';
        $a = <<<EOT
            Hello {$name} and ${name}
              {$name["x"]} \" ?> //? /* not a comment */
            EOT;
        $b = <<<'NOW'
        raw $name {$name}
        NOW;
        $c = <<<"QUOTED"
        quoted $name
        QUOTED;
        $d = 'multi
        line \' with ?> inside';
        $e = "double {$name} \"quote\" ?>
          next";
        [$a, $b, $c, $d, $e]
        """#,
        "$items = collect([1, 2, 3])\n    ->map(fn ($x) => $x * 2)\n    ->filter(function ($x) use ($items) {\n        return $x > 2;\n    })\n    ->values()",
        "$size = 3;\nmatch (true) {\n    $size > 2 => 'big',\n    default => 'small',\n}",
        "if ($a ?? false):\n    echo 'yes';\nelseif (true):\n    echo 'maybe';\nelse:\n    echo 'no';\nendif;\nforeach ([1] as $i):\n    echo $i;\nendforeach;",
        "#[Tagged]\nfunction tagged() { return 1; }\nfinal class Thing { use Named; public function __toString(): string { return 'x'; } }\ninterface Shape {}\ntrait Named {}\nenum Suit: string { case Hearts = 'H'; }\nconst ANSWER = 42;\ntagged() + ANSWER",
        "namespace Scratch;\nuse App\\Models\\{User, Order as PurchaseOrder};\nuse function App\\helper;\nuse const App\\LIMIT;\n$u = new User();",
        "namespace Scratch {\n    use App\\Models\\User;\n    function inner() { return User::class; }\n    inner();\n}",
        "declare(strict_types=1);\n$x = intdiv(7, 2)",
        "$name = 'x';\n?>\n<p>Hello <?= $name ?></p>\n<?php\n$name . '!'",
        "$name = 'x';\n?>\n<p>Trailing HTML</p>\n",
        "retry:\n$attempts = ($attempts ?? 0) + 1;\nif ($attempts < 3) goto retry;\n$attempts",
        "$$name = 1;\n${'other'} = 2;\n$obj?->property?->method()",
        "# hash comment\n// slash comment\n/* block ?> comment */\n/** doc */\n$x = 1 /*?*/ + 2 /*?->abs()*/; /*?.*/\n$x //?",
        "",
        "   \n  ",
        "<?php",
        "<?php\n// only a comment",
        "$ünïcode = 'ok';\n$ünïcode",
        "static $count = 0;\nglobal $config;\nunset($config);\n$count++",
        "try {\n    throw new RuntimeException('x');\n} catch (RuntimeException $e) {\n    $e->getMessage();\n} finally {\n    $done = true;\n}",
        "do {\n    $i = ($i ?? 0) + 1;\n} while ($i < 3);",
        "return User::first()",
        "$result = 1;\n$result and false",
        "/**\n * @input int $orderId \"Order {ID}\"\n * @input string $reason \"It's \\\"odd\\\" \\\\ $x\" = \"a\\\\b'c\" {a\\\\b'c, \"x}y\"}\n * @input bool $notify = true\n * @input float $rate = 1.5\n * @input string $raw = \"line\\nbreak\"\n * @input int $command\n * @input string $env = \"local\"\n * @input wrong\n */\n$orderId = 5;\n[$orderId, $reason, $notify, $rate, $raw, $command, $env]",
        "$a = 'unterminated",
        "dump($x);\ndd($y)",
        "    $indented = true;\n        $more = 1;\n    $indented",
        "echo 'no semicolon at the end'",
        "function () { return 1; };",
        "Runlet\\bench(fn () => usleep(10));",
    ]

    static let titles = ["Refund order", "It's a \\ \"test\" $x {y} ?> // z", "", "2024: Zählung"]

    /// One case per snippet, so the cases run `php -l` in parallel (#242).
    @Test(.enabled(if: php != nil), arguments: SnippetPromotionPHPTests.corpus.indices)
    func everyGeneratedFileIsValidPHP(index: Int) throws {
        let code = Self.corpus[index]
        for title in Self.titles {
            let source = SnippetPromotion.Source(code: code, contextCode: index % 3 == 0 ? "use App\\Models\\Order;\n" + code : nil, title: title, description: index % 2 == 0 ? "Desc 'with' \\ quotes" : nil, strictTypes: index % 2 == 1)
            let className = SnippetPromotion.className(fromTitle: title)
            let files = [
                SnippetPromotion.artisanCommand(source, className: className, namespace: "App\\Console\\Commands", commandName: SnippetPromotion.commandName(forClass: className)).source,
                SnippetPromotion.artisanCommand(source, className: className, namespace: "App\\Commands", commandName: SnippetPromotion.commandName(forClass: className, flavor: .laravelZero), flavor: .laravelZero).source,
                SnippetPromotion.test(source, style: .pest).source,
                SnippetPromotion.test(source, style: .phpunit, className: className + "Test", namespace: "Tests\\Feature", baseClass: "Tests\\TestCase").source,
                SnippetPromotion.test(source, style: .phpunit, className: className + "Test", namespace: nil).source,
            ]
            for file in files {
                // An unterminated string stays unterminated; everything else must parse.
                if code.contains("'unterminated") { continue }
                let url = try Self.temporaryFile(file)
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                let result = try Self.php(["-l", url.path])
                #expect(result.status == 0, "php -l failed for snippet \(index) titled \(title):\n\(result.output)\(result.errors)\n\(file)")
            }
        }
    }

    /// Stand-ins for Laravel's `Command` and `dump()`, then the generated command's `handle()`
    /// with arguments and options as JSON.
    static let harness = #"""
    <?php
    namespace Illuminate\Console {
        class Command {
            public array $runletArguments = [];
            public array $runletOptions = [];
            public function argument($key) { return $this->runletArguments[$key] ?? null; }
            public function option($key) { return $this->runletOptions[$key] ?? null; }
        }
    }
    namespace {
        function dump(...$values) {
            foreach ($values as $value) { echo 'dump: ', var_export($value, true), "\n"; }
            return $values[0] ?? null;
        }
        require $argv[1];
        $command = new $argv[2]();
        $command->runletArguments = json_decode($argv[3], true);
        $command->runletOptions = json_decode($argv[4], true);
        $command->handle();
    }
    """#

    /// The generated command's output when run with `arguments` and `options`.
    static func runCommand(_ code: String, arguments: String = "{}", options: String = "{}") throws -> String {
        let output = SnippetPromotion.artisanCommand(SnippetPromotion.Source(code: code, title: "Check"), className: "Check", namespace: "App\\Console\\Commands", commandName: "app:check")
        let command = try temporaryFile(output.source, name: "Check")
        let harness = try temporaryFile(Self.harness, name: "harness")
        defer {
            try? FileManager.default.removeItem(at: command.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: harness.deletingLastPathComponent())
        }
        let result = try php([harness.path, command.path, "App\\Console\\Commands\\Check", arguments, options])
        #expect(result.status == 0, "\(result.errors)\n\(output.source)")
        #expect(result.errors.isEmpty, "\(result.errors)\n\(output.source)")
        return result.output
    }

    /// What PHP prints for the snippet's code run directly, with `return` before its result.
    static func runDirectly(_ code: String) throws -> String {
        let file = try temporaryFile("<?php\nfunction dump(...$v) { foreach ($v as $x) { echo 'dump: ', var_export($x, true), \"\\n\"; } return $v[0] ?? null; }\n$runletResult = (function () {\n\(code)\n})();\necho 'dump: ', var_export($runletResult, true), \"\\n\";\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try php([file.path])
        #expect(result.status == 0, "\(result.errors)")
        return result.output
    }

    @Test(.enabled(if: php != nil))
    func commandsKeepStringValues() throws {
        let body = #"""
        $name = 'World';
        $a = <<<EOT
            Hello {$name} and $name
              {$name}s \" ?> //? /* not a comment */
            EOT;
        $b = <<<'NOW'
        raw $name {$name}
          indented
        NOW;
        $d = 'multi
          line \' with ?> inside';
        $e = "double {$name} \"quote\"
        	tab";
        """#
        let direct = try Self.runDirectly(body + "\nreturn [$a, $b, $d, $e];")
        #expect(direct.contains("Hello World"))
        #expect(try Self.runCommand(body + "\n[$a, $b, $d, $e]") == direct)
        // Indented snippets too: the strings' lines keep their exact text.
        let indented = body.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
        #expect(try Self.runCommand(indented + "\n    [$a, $b, $d, $e];") == (try Self.runDirectly(indented + "\nreturn [$a, $b, $d, $e];")))
    }

    @Test(.enabled(if: php != nil))
    func commandsReadInputs() throws {
        let code = #"""
        /**
         * @input int $orderId "Order ID"
         * @input float $amount = 9.5
         * @input string $reason "Reason" = "it's" {it's, other}
         * @input bool $notify = true
         * @input bool $dryRun
         * @input int $limit = 3
         */
        $orderId = 0;
        [$orderId, $amount, $reason, $notify, $dryRun, $limit]
        """#
        #expect(try Self.runCommand(code, arguments: #"{"orderId": "42"}"#, options: #"{"amount": "1.25", "reason": null, "no-notify": true, "dry-run": false}"#)
            == "dump: array (\n  0 => 42,\n  1 => 1.25,\n  2 => 'it\\'s',\n  3 => false,\n  4 => false,\n  5 => 3,\n)\n")
        #expect(try Self.runCommand(code, arguments: #"{"orderId": "7"}"#, options: #"{"reason": "other", "dry-run": true, "limit": "10"}"#)
            == "dump: array (\n  0 => 7,\n  1 => 9.5,\n  2 => 'other',\n  3 => true,\n  4 => true,\n  5 => 10,\n)\n")
    }

    @Test(.enabled(if: php != nil))
    func commandsDeclareFunctionsAndClassesFirst() throws {
        let code = """
        echo twice(2), "\\n";
        $box = new Box(3);
        function twice(int $x): int { return 2 * $x; }
        class Box { public function __construct(public int $size) {} }
        const LIMIT = 10;
        $box->size + LIMIT
        """
        #expect(try Self.runCommand(code) == "4\ndump: 13\n")
    }

    @Test(.enabled(if: php != nil))
    func commandsPrintInlineHTMLAndDumpTheResult() throws {
        #expect(try Self.runCommand("$name = 'x';\n?>\n<p>Hi <?= $name ?></p>\n<?php\n$name . '!'") == "<p>Hi x</p>\ndump: 'x!'\n")
        #expect(try Self.runCommand("$a = 1; //?\n$b = $a * 3 /*?*/ + 1; /*?.*/\n$b //?") == "dump: 4\n")
        #expect(try Self.runCommand("$n = 1;\n$n += 2") == "dump: 3\n")
        #expect(try Self.runCommand("return 5") == "dump: 5\n")
    }
}
