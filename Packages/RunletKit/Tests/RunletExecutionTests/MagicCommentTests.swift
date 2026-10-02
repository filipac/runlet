import Foundation
import RunletCore
import Testing
@testable import RunletExecution

extension Array where Element == RunEvent {
    var inlineProbes: InlineProbesInfo? {
        for event in self { if case .inline(.probes(let info)) = event.kind { return info } }
        return nil
    }

    var inlineHits: [InlineHit] {
        compactMap { if case .inline(.hit(let hit)) = $0.kind { return hit } else { return nil } }
    }

    var noticeMessages: [String] {
        compactMap { if case .notice(let text) = $0.kind { return text } else { return nil } }
    }

    /// The inline values folded the way the editor shows them (snippet lines).
    var inlineValues: InlineValues {
        var values = InlineValues()
        for event in self { if case .inline(let inline) = event.kind { values.apply(inline, editorLine: { $0 }) } }
        return values
    }
}

/// Magic comments (#10) through the real runner: what each form shows, and that adding them
/// never changes what the code does. Each semantics fixture runs twice, with its magic comments
/// and with them removed, and both runs must print, return, and fail the same way.
@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct MagicCommentTests {
    var php: String { TestSupport.php()! }
    var plain: TargetSnapshot { TestSupport.localTarget(TestSupport.fixtures.appendingPathComponent("plain").path, php: php) }

    /// The code without its magic comments (the fixtures keep magic-looking text out of
    /// strings, except where a test says otherwise).
    static func stripped(_ code: String) -> String {
        var text = code.replacingOccurrences(of: #"(?m)//\?[ \t]*$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"/\*\?[^*]*\*/"#, with: "", options: .regularExpression)
        return text
    }

    /// What a run did, comparable across runs: output, result, dumps, and errors (object ids
    /// differ, since probes allocate objects too).
    static func behavior(_ events: [RunEvent]) -> String {
        func clean(_ text: String) -> String { text.replacingOccurrences(of: #"#\d+"#, with: "#", options: .regularExpression) }
        var parts = ["stdout: " + events.stdout, "stderr: " + events.stderr]
        if let result = events.result { parts.append("result: " + (result.value.map { clean($0.plainText()) } ?? "none")) }
        parts += events.dumps.map { "dump@\($0.snippetLine ?? 0): " + clean($0.value.plainText()) }
        parts += events.errors.map { "error: \($0.className ?? "?") \($0.message) @\($0.snippetLine ?? 0)" }
        parts.append("finished: \(events.finished?.status.rawValue ?? "?") \(events.finished?.reason ?? "?")")
        return parts.joined(separator: "\n")
    }

    /// Runs `code` with and without its magic comments, checks they behave the same, and
    /// returns the instrumented run's events.
    func sameBehavior(_ code: String, strictTypes: Bool = false, sourceLocation: Testing.SourceLocation = #_sourceLocation) async throws -> [RunEvent] {
        let instrumented = try await TestSupport.run(code, target: plain, strictTypes: strictTypes)
        let original = try await TestSupport.run(Self.stripped(code), target: plain, strictTypes: strictTypes)
        #expect(Self.behavior(instrumented) == Self.behavior(original), sourceLocation: sourceLocation)
        #expect(original.inlineProbes == nil, sourceLocation: sourceLocation)
        return instrumented
    }

    func summary(_ events: [RunEvent], _ line: Int) -> String? {
        events.inlineValues.summary(onLine: line)?.plainText
    }

    // MARK: Forms

    @Test func eachFormShowsItsValue() async throws {
        let code = """
        $a = 5; //?
        $b = $a * 2 /*?*/ + 1;
        $words = new ArrayObject(['x', 'y', 'z']) /*?->count()*/;
        usleep(2000); /*?.*/
        foreach ([1, 2, 3] as $n) { //?
            $square = $n * $n; //?
        }
        echo "hi\\n"; //?
        $i = 0;
        $i++; //?
        $b //?
        """
        let events = try await sameBehavior(code)
        let probes = try #require(events.inlineProbes)
        #expect(probes.rejected.isEmpty)
        #expect(probes.probes.map(\.line) == [1, 2, 3, 4, 5, 6, 8, 10, 11])
        #expect(probes.probes.map(\.kind) == ["value", "value", "value", "time", "reached", "value", "value", "value", "value"])
        #expect(summary(events, 1) == "5")
        #expect(summary(events, 2) == "10")
        #expect(summary(events, 3) == "3")
        let time = try #require(events.inlineValues.probes(onLine: 4).first?.last?.ms)
        #expect(time >= 1.5)
        #expect(summary(events, 5) == "×3 ✓")
        #expect(summary(events, 6) == "×3 9")
        #expect(summary(events, 8) == "\"hi\\n\"")
        // `$i++; //?` shows the variable after the increment.
        #expect(summary(events, 10) == "1")
        #expect(summary(events, 11) == "11")
        #expect(events.result?.value?.scalar == "11")
        // Every hit carries the time since the snippet started.
        #expect(events.inlineHits.allSatisfy { ($0.t ?? -1) >= 0 })
    }

    @Test func hitsStreamBeforeTheRunFinishes() async throws {
        let events = try await TestSupport.run("for ($i = 0; $i < 3; $i++) { $i; } //?\necho 'after';\n'done'", target: plain)
        let order = events.map(\.kind.typeName)
        let firstInline = try #require(order.firstIndex(of: "inline"))
        #expect(firstInline < (order.firstIndex(of: "stdout") ?? .max))
        #expect(firstInline < (order.firstIndex(of: "result") ?? .max))
        // No magic comments: no probes event and no notice.
        let none = try await TestSupport.run("1 + 1", target: plain)
        #expect(none.inlineProbes == nil && none.inlineHits.isEmpty && none.noticeMessages.isEmpty)
    }

    @Test func loopsAreCappedThenSampledThenCounted() async throws {
        let events = try await TestSupport.run("$sum = 0;\nfor ($k = 0; $k < 2500; $k++) {\n    $sum += $k; //?\n}\n$sum", target: plain)
        let hits = events.inlineHits.filter { $0.line == 3 }
        #expect(hits.filter { $0.sampled != true && $0.final != true }.count == 100)
        #expect(hits.first?.value?.scalar == "0")
        #expect(hits.contains { $0.sampled == true })
        let final = try #require(hits.last)
        #expect(final.final == true && final.hit == 2500 && final.value == nil)
        #expect(events.inlineValues.probes(onLine: 3).first?.hits == 2500)
        #expect(events.result?.value?.scalar == "3123750")
    }

    @Test func projectionsKeepTheChainAndReportErrors() async throws {
        let code = """
        final class Bag implements Countable {
            public function __construct(private array $items) {}
            public function map(callable $f): self { return new self(array_map($f, $this->items)); }
            public function filter(callable $f): self { return new self(array_values(array_filter($this->items, $f))); }
            public function count(): int { return count($this->items); }
            public function all(): array { return $this->items; }
        }
        $result = (new Bag([1, 2, 3, 4]))
            ->map(fn ($n) => $n * 10) /*?->all()*/
            ->filter(fn ($n) => $n > 15) /*?->count()*/
            ->all(); //?
        $broken = new Bag([1]) /*?->nope()*/;
        $result
        """
        let events = try await sameBehavior(code)
        #expect(summary(events, 9) == "[10, 20, 30, 40]")
        #expect(summary(events, 10) == "3")
        #expect(summary(events, 11) == "[20, 30, 40]")
        // A failing projection shows its error; the code keeps running.
        #expect(summary(events, 12)?.hasPrefix("⚠︎ Error: Call to undefined method Bag::nope()") == true)
        #expect(events.errors.isEmpty && events.finished?.status == .completed)
    }

    // MARK: Semantics

    @Test func referencesAreKept() async throws {
        let code = """
        function inc(&$v) { $v++; }
        $x = 1;
        inc($x /*?*/);
        $a = &$x; //?
        $a++;
        $list = [1, 2, 3];
        foreach ($list /*?*/ as &$item) { $item *= 10; } //?
        unset($item);
        $arr = [3, 1, 2];
        sort($arr /*?*/);
        function &pick(array &$from) { return $from[0]; //?
        }
        $first = &pick($arr);
        $first = 99;
        [$x, $list, $arr]
        """
        let events = try await sameBehavior(code)
        #expect(events.inlineProbes?.rejected.isEmpty == true)
        #expect(summary(events, 3) == "1")
        #expect(summary(events, 4) == "2")
        #expect(summary(events, 7) == "[1, 2, 3]  ·  ✓")
        #expect(summary(events, 10) == "[3, 1, 2]")
        #expect(summary(events, 11) == "1")
        #expect(events.result?.value?.compactSummary() == "[3, [10, 20, 30], [99, 2, 3]]")
    }

    @Test func closuresAndArrowFunctions() async throws {
        let code = """
        $k = 3;
        $times = static fn (int $n) => $n * $k /*?*/;
        $add = function (int $n) use (&$k) { //?
            $k += $n; //?
            return $k;
        };
        $times(2);
        $add(4);
        $twice = fn ($f) => $f(1) + $f(2) /*?*/;
        $twice($times) //?
        """
        let events = try await sameBehavior(code)
        #expect(summary(events, 2) == "×3 6")
        #expect(summary(events, 3) == "✓")
        #expect(summary(events, 4) == "7")
        #expect(summary(events, 9) == "9")
        #expect(summary(events, 10) == "9")
    }

    @Test func namedArgumentsAndNullsafeChains() async throws {
        let code = """
        function span(int $start, int $end, int $step = 1) { return range($start, $end, $step); }
        $r = span(end: 6 /*?*/, step: 2, start: 0); //?
        final class Node {
            public ?Node $next = null;
            public function __construct(public int $v) {}
            public function next(): ?Node { return $this->next; }
        }
        $n = new Node(1);
        $n->next = new Node(2);
        $a = $n?->next() /*?->v*/ ?->v; //?
        $b = $n->next()?->next() /*?*/ ?->next()->v; //?
        $c = $n->next()?->next() /*?*/ ->v;
        [$r, $a, $b, $c]
        """
        let events = try await sameBehavior(code)
        #expect(summary(events, 2) == "6  ·  [0, 2, 4, 6]")
        #expect(summary(events, 10) == "2  ·  2")
        // `?->` short-circuits the rest of the chain: the probe shows null, nothing fails.
        #expect(summary(events, 11) == "null  ·  null")
        // Before `->`, a probe would stop the short-circuit: refused, and the code runs as written.
        let rejected = try #require(events.inlineProbes?.rejected.first)
        #expect(rejected.line == 12 && rejected.reason.contains("?->"))
        #expect(events.result?.value?.compactSummary() == "[[0, 2, 4, 6], 2, null, null]")
    }

    @Test func generatorsAndYield() async throws {
        let code = """
        function numbers() {
            for ($i = 1; $i <= 3; $i++) {
                yield $i /*?*/;
            }
            return 'done'; //?
        }
        $g = numbers();
        $out = [];
        foreach ($g as $n) { $out[] = $n * 2; }
        function &refs(array &$items) { foreach ($items as $k => &$v) { yield $k => $v /*?*/; } }
        $data = [1, 2];
        foreach (refs($data) as &$v) { $v *= 100; }
        unset($v);
        [$out, $g->getReturn(), $data]
        """
        let events = try await sameBehavior(code)
        #expect(summary(events, 3) == "×3 3")
        #expect(summary(events, 5) == "\"done\"")
        // By-reference generators still yield references.
        #expect(summary(events, 10) == "×2 2")
        #expect(events.result?.value?.compactSummary() == "[[2, 4, 6], \"done\", [100, 200]]")
    }

    @Test func destructuringAndCompoundAssignments() async throws {
        let code = """
        [$a, [$b, $c]] = [1, [2, 3]]; //?
        ['x' => $x, 'y' => $y] = ['x' => 'X', 'y' => 'Y'] /*?*/;
        list(, $second) = [10, 20]; //?
        $total = 5;
        $total *= 3; //?
        $total .= '!'; //?
        $cfg = [];
        $cfg['name'] ??= 'default'; //?
        $cfg['name'] ??= 'other'; //?
        [$a /*?*/, $b] = [7, 8];
        [$a, $b, $c, $x, $y, $second, $total, $cfg]
        """
        let events = try await sameBehavior(code)
        #expect(summary(events, 1) == "[1, [2, 3]]")
        #expect(summary(events, 2) == "[\"x\" => \"X\", \"y\" => \"Y\"]")
        #expect(summary(events, 3) == "[10, 20]")
        #expect(summary(events, 5) == "15")
        #expect(summary(events, 6) == "\"15!\"")
        #expect(summary(events, 8) == "\"default\"")
        #expect(summary(events, 9) == "\"default\"")
        // A destructuring target is assigned, not read.
        #expect(events.inlineProbes?.rejected.map(\.line) == [10])
    }

    @Test func multiLineExpressionsAndSideEffectsOnce() async throws {
        let code = """
        $calls = 0;
        $next = function () use (&$calls) { return ++$calls; };
        $sum = $next() /*?*/ + $next() /*?*/; //?
        $label = $next() /*?.*/;
        $lengths = array_map(
            fn ($w) => strlen($w), //?
            ['apple', 'kiwi'] /*?*/
        ) /*?*/;
        $list = [
            $next(), //?
            $next(),
        ];
        [$calls, $sum, $lengths, $list]
        """
        let events = try await sameBehavior(code)
        // Each call runs once. `/*?*/` shows the largest expression ending right before it:
        // after the second call, that is the sum.
        let line3 = events.inlineValues.probes(onLine: 3)
        #expect(line3.map { $0.last?.value?.scalar } == ["1", "3", "3"])
        #expect(events.inlineValues.probes(onLine: 4).first?.kind == .time)
        #expect(summary(events, 6) == "×2 4")
        #expect(summary(events, 7) == "[\"apple\", \"kiwi\"]")
        #expect(summary(events, 8) == "[5, 4]")
        #expect(summary(events, 10) == "4")
        #expect(events.result?.value?.compactSummary() == "[5, 3, [5, 4], [4, 5]]")
    }

    @Test func matchTernariesAndInterpolation() async throws {
        let code = """
        $n = 7;
        $size = match (true) {
            $n < 5 => 'small',
            $n < 10 => 'medium' /*?*/,
            default => 'large',
        }; //?
        $parity = $n % 2 === 0 ? 'even' : 'odd' /*?*/;
        $short = $n ?: 'zero' /*?*/;
        $msg = "n is {$n} and {$size}" /*?*/;
        $in = "{$size /*?*/}";
        "$msg, $parity" //?
        """
        let events = try await sameBehavior(code)
        #expect(summary(events, 4) == "\"medium\"")
        #expect(summary(events, 6) == "\"medium\"")
        #expect(summary(events, 7) == "\"odd\"")
        #expect(summary(events, 8) == "7")
        #expect(summary(events, 9) == "\"n is 7 and medium\"")
        // Inside "{$…}" the expression must start with a variable: refused.
        #expect(events.inlineProbes?.rejected.map(\.line) == [10])
        #expect(summary(events, 11) == "\"n is 7 and medium, odd\"")
    }

    @Test func magicTextInStringsHeredocsAndCommentsIsIgnored() async throws {
        let code = """
        $a = '//?';
        $b = "/*?*/";
        $c = <<<EOT
          //? /*?->count()*/ /*?.*/ {$a}
          EOT;
        $d = <<<'EOT'
          //?
          EOT;
        /* //? */
        // //?
        # //?
        /** /*?*/
        ?>
        //? inline /*?*/
        <?php
        [$a, $b, trim($c), trim($d)]
        """
        let events = try await TestSupport.run(code, target: plain)
        #expect(events.inlineProbes == nil && events.inlineHits.isEmpty && events.noticeMessages.isEmpty)
        #expect(events.stdout == "//? inline /*?*/\n")
        #expect(events.result?.value?.entries?.map(\.value.displayString) == ["//?", "/*?*/", "//? /*?->count()*/ /*?.*/ //?", "//?"])
    }

    @Test func invalidPlacementsAreReportedAndTheRunIsUnaffected() async throws {
        let code = """
        const LIMIT = 3 /*?*/;
        function f($x = 1 /*?*/) { return $x; }
        $arr = ['k' => 1];
        $v = $arr['k'] /*?*/ ?? 0;
        $set = isset($arr['q'] /*?*/);
        [$p /*?*/, $q] = [1, 2];
        $obj = new ArrayObject([]);
        $obj->append($p /*?*/);
        $w = 5 /*?->nope(*/;
        $y = /*?*/ 2;
        [LIMIT, f(), $v, $set, $p, $q, count($obj), $w, $y]
        """
        let events = try await sameBehavior(code)
        let rejected = try #require(events.inlineProbes?.rejected)
        #expect(rejected.map(\.line) == [1, 2, 4, 5, 6, 8, 9, 10])
        #expect(rejected.allSatisfy { !$0.reason.isEmpty })
        #expect(events.noticeMessages.contains { $0.contains("can't show 8 magic comments") })
        #expect(events.errors.isEmpty && events.inlineHits.isEmpty)
        // The editor shows a short label on each line (the full reason on hover).
        #expect(rejected.map { $0.label ?? "" } == ["constant expression", "constant expression", "inside isset/empty/??", "inside isset/empty/??", "assigned here", "may be by reference", "not a projection", "nothing to show"])
        #expect(summary(events, 8) == "⚠︎ not shown: may be by reference")
    }

    @Test func worksWithStrictTypesNamespacesAndTrailingComments() async throws {
        let events = try await sameBehavior("namespace App;\nfunction twice(int $n): int { return $n * 2; //?\n}\ntwice(21) //?", strictTypes: true)
        #expect(summary(events, 2) == "42")
        #expect(summary(events, 4) == "42")
        #expect(events.result?.value?.scalar == "42")
        // A comment after the final expression no longer hides the result.
        let trailing = try await TestSupport.run("1 + 1; // the answer", target: plain)
        #expect(trailing.result?.value?.scalar == "2")
        // A mark after the final expression (which becomes the result) still runs.
        let mark = try await sameBehavior("usleep(1000);\n/*?.*/")
        #expect(mark.inlineHits.count == 1 && (mark.inlineHits.first?.ms ?? 0) >= 0.5)
    }

    @Test func runSelectionReportsSelectionLines() async throws {
        // Run Selection sends only the selected code; the app maps its lines back.
        let selection = SourceSelection(startLine: 20, startColumn: 1, utf16Range: NSRangeCodable(location: 400, length: 20))
        let events = try await TestSupport.run("$x = 2;\n$x * 21 //?", target: plain, selection: selection)
        let hit = try #require(events.inlineHits.first)
        #expect(hit.line == 2)
        let target = plain
        let request = RunRequest(tabId: UUID(), documentVersion: 1, target: target, code: "", selection: selection)
        var values = InlineValues()
        for event in events { if case .inline(let inline) = event.kind { values.apply(inline, editorLine: request.editorLine(forSnippetLine:)) } }
        #expect(values.summary(onLine: 21)?.plainText == "42")
    }

    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires Herd's PHP 7.4"))
    func php74() async throws {
        let target = TestSupport.localTarget(TestSupport.fixtures.appendingPathComponent("plain").path, php: TestSupport.herdPHP74!)
        let code = "$f = fn ($n) => $n * 2 /*?*/;\n$items = [1, 2];\nforeach ($items as &$i) { $i = $f($i); } //?\nunset($i);\n$o = new ArrayObject($items) /*?->count()*/;\nusleep(500); /*?.*/\n$items //?"
        let events = try await TestSupport.run(code, target: target)
        #expect(events.errors.isEmpty)
        #expect(events.started?.phpVersion?.hasPrefix("7.4") == true)
        #expect(events.inlineValues.summary(onLine: 1)?.plainText == "×2 4")
        #expect(events.inlineValues.summary(onLine: 5)?.plainText == "2")
        #expect(events.inlineValues.summary(onLine: 7)?.plainText == "[2, 4]")
        #expect(events.result?.value?.compactSummary() == "[2, 4]")
    }
}
