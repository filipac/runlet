import Foundation
import RunletCore
import Testing
@testable import RunletExecution

@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct LocalRunTests {
    var php: String { TestSupport.php()! }
    var plain: TargetSnapshot { TestSupport.localTarget(TestSupport.fixtures.appendingPathComponent("plain").path, php: php) }

    @Test func finalExpressionAndEcho() async throws {
        let events = try await TestSupport.run("$a = [1, 2, 3];\necho \"hi\\n\";\narray_sum($a) * 2", target: plain)
        #expect(events.stdout == "hi\n")
        #expect(events.result?.value?.scalar == "12")
        #expect(events.finished?.status == .completed)
        // Exactly one terminal event, and it is last.
        #expect(events.filter { if case .finished = $0.kind { true } else { false } }.count == 1)
        if case .finished = events.last?.kind {} else { Issue.record("finished is not last") }
        #expect(events.map(\.sequence) == Array(1...events.count))
    }

    @Test func resultSemantics() async throws {
        #expect(try await TestSupport.run("$value = 42;", target: plain).result?.value?.scalar == "42")
        #expect(try await TestSupport.run("return 'x';", target: plain).result?.value?.scalar == "x")
        let noResult = try await TestSupport.run("if (true) { $y = 1; }", target: plain).result
        #expect(noResult?.hasValue == false)
        let null = try await TestSupport.run("null", target: plain).result
        #expect(null?.hasValue == true && null?.value?.type == .null)
        // Omitted final semicolon, trailing comment.
        #expect(try await TestSupport.run("1 + 1 // done", target: plain).result?.value?.scalar == "2")
    }

    @Test func plainDirectoryIncludesRelativeFiles() async throws {
        let events = try await TestSupport.run("require 'helpers.php';\nfixture_greeting('Runlet')", target: plain)
        #expect(events.result?.value?.scalar == "Hello, Runlet!")
        #expect(events.started?.framework == "plain")
    }

    @Test func composerAutoloader() async throws {
        let target = TestSupport.localTarget(TestSupport.fixtures.appendingPathComponent("composer").path, php: php)
        let events = try await TestSupport.run("(new Acme\\Greeter('Hi'))->greet('Ana')", target: target)
        #expect(events.started?.framework == "composer")
        #expect(events.result?.value?.scalar == "Hi, Ana!")
    }

    @Test func missingVendorIsReportedAsBootstrapError() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-novendor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"require":{"monolog/monolog":"^3"}}"#.utf8).write(to: directory.appendingPathComponent("composer.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await TestSupport.run("1", target: TestSupport.localTarget(directory.path, php: php))
        #expect(events.errors.first?.stage == .bootstrap)
        #expect(events.errors.first?.message.contains("composer install") == true)
        #expect(events.finished?.status == .failed)
    }

    @Test func dumpsKeepExecutionOrderAndDDTerminates() async throws {
        let events = try await TestSupport.run("dump(1, 'two');\necho 'between';\ndd(['x' => 3]);\necho 'never';", target: plain)
        #expect(events.dumps.map(\.index) == [1, 2, 3])
        #expect(events.dumps.last?.isDD == true)
        #expect(events.dumps.last?.snippetLine == 3)
        #expect(events.stdout == "between")
        #expect(events.finished?.status == .completed)
        #expect(events.finished?.reason == "dd")
        // The echo sits between the second and third dump in the event order.
        let kinds = events.compactMap { event -> String? in
            switch event.kind {
            case .dump(let d): "dump\(d.index)"
            case .stdout: "stdout"
            default: nil
            }
        }
        #expect(kinds == ["dump1", "dump2", "stdout", "dump3"])
    }

    @Test func parseErrorMapsToLineAndRecovers() async throws {
        let failed = try await TestSupport.run("$a = 1;\n$b = ;\n", target: plain)
        #expect(failed.errors.first?.stage == .parse)
        #expect(failed.errors.first?.snippetLine == 2)
        #expect(failed.finished?.status == .failed)
        let fixed = try await TestSupport.run("$a = 1;\n$b = 2;\n$a + $b", target: plain)
        #expect(fixed.result?.value?.scalar == "3")
    }

    @Test func runtimeErrorInSelectionMapsToEditorLine() async throws {
        let selection = SourceSelection(startLine: 10, startColumn: 1, utf16Range: .init(location: 0, length: 0))
        let request = RunRequest(tabId: UUID(), documentVersion: 1, target: plain, code: "$x = 1;\nthrow new RuntimeException('boom');", selection: selection)
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
        var events: [RunEvent] = []
        for await event in try await engine.start(request) { events.append(event) }
        let error = try #require(events.errors.first)
        #expect(error.stage == .execute)
        #expect(error.className == "RuntimeException")
        #expect(error.snippetLine == 2)
        #expect(request.editorLine(forSnippetLine: error.snippetLine!) == 11)
        // Columns shift only on the selection's first line.
        let midLine = RunRequest(tabId: UUID(), documentVersion: 1, target: plain, code: "x", selection: SourceSelection(startLine: 3, startColumn: 9, utf16Range: .init(location: 0, length: 0)))
        #expect(midLine.editorColumn(forSnippetLine: 1, column: 5) == 13)
        #expect(midLine.editorColumn(forSnippetLine: 2, column: 5) == 5)
    }

    @Test func exitCodeIsReported() async throws {
        let events = try await TestSupport.run("echo 'x'; exit(3);", target: plain)
        #expect(events.stdout == "x")
        #expect(events.finished?.reason == "exit")
        #expect(events.finished?.exitCode == 3)
        #expect(events.finished?.status == .failed)
    }

    @Test func fatalErrorIsReported() async throws {
        let events = try await TestSupport.run("ini_set('memory_limit', '16M');\n$a = str_repeat('x', 64 * 1024 * 1024);", target: plain)
        #expect(events.errors.first?.className == "FatalError")
        #expect(events.errors.first?.snippetLine == 2)
        #expect(events.finished?.reason == "fatal")
    }

    @Test func strictTypesNamespacesAndDeclarations() async throws {
        let strict = try await TestSupport.run("declare(strict_types=1);\nfunction g(int $i) { return $i; }\ng('5')", target: plain)
        #expect(strict.errors.first?.className == "TypeError")
        let namespaced = try await TestSupport.run("namespace App { class A { function v() { return 3; } } }\nnamespace { (new App\\A)->v(); }", target: plain)
        #expect(namespaced.result?.value?.scalar == "3")
        let unbraced = try await TestSupport.run("namespace Foo;\nfunction bar() { return __NAMESPACE__; }\nbar()", target: plain)
        #expect(unbraced.result?.value?.scalar == "Foo")
    }

    @Test func outputRobustness() async throws {
        let code = """
        $o = new stdClass; $o->self = $o; $o->list = range(1, 500);
        $a = ['k' => 1]; $a['ref'] = &$a;
        fwrite(STDERR, "to stderr\\n");
        echo "\\x1eRL1:fake:2:{}\\n\\xff\\xfe";
        dump("bad \\xff utf8", "ünïcödé ✓");
        [$o, $a]
        """
        let events = try await TestSupport.run(code, target: plain)
        #expect(events.finished?.status == .completed)
        #expect(events.stderr.contains("to stderr"))
        #expect(events.stdout.contains("RL1:fake"))
        #expect(events.dumps[0].value.encoding == "base64")
        #expect(events.dumps[1].value.scalar == "ünïcödé ✓")
        let value = try #require(events.result?.value)
        let object = try #require(value.entries?.first?.value)
        #expect(object.entries?.first { $0.key == "self" }?.value.repeated == true)
        let list = try #require(object.entries?.first { $0.key == "list" }?.value)
        #expect(list.count == 500)
        #expect(list.entries?.count == 200)
        #expect(list.truncation?.omitted == 300)
    }

    @Test func largeOutputIsBoundedWithoutDeadlock() async throws {
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil, limits: {
            var limits = RunLimits()
            limits.maxRawOutputBytes = 1024 * 1024
            return limits
        }())
        let events = try await TestSupport.run("for ($i = 0; $i < 4000; $i++) { echo str_repeat('x', 1024); }\n'done'", target: plain, engine: engine)
        #expect(events.result?.value?.scalar == "done")
        #expect(events.stdout.utf8.count == 1024 * 1024)
        #expect(events.finished?.truncation != nil)
    }

    @Test func secondRunInSameTabIsRejectedButOtherTabsRunConcurrently() async throws {
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
        let tab = UUID()
        let first = try await engine.start(RunRequest(tabId: tab, documentVersion: 1, target: plain, code: "usleep(300000); 1"))
        await #expect(throws: ExecutionError.tabBusy) {
            _ = try await engine.start(RunRequest(tabId: tab, documentVersion: 2, target: plain, code: "2"))
        }
        let other = try await engine.start(RunRequest(tabId: UUID(), documentVersion: 1, target: plain, code: "'other'"))
        var otherEvents: [RunEvent] = []
        for await event in other { otherEvents.append(event) }
        var firstEvents: [RunEvent] = []
        for await event in first { firstEvents.append(event) }
        #expect(otherEvents.result?.value?.scalar == "'other'".trimmingCharacters(in: CharacterSet(charactersIn: "'")))
        #expect(firstEvents.result?.value?.scalar == "1")
        #expect(firstEvents.allSatisfy { $0.runId == firstEvents[0].runId })
    }

    @Test func stopTerminatesLocalRunAndChildren() async throws {
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-child-\(UUID().uuidString)").path
        let request = RunRequest(tabId: UUID(), documentVersion: 1, target: plain, code: "exec('sleep 30 > /dev/null 2>&1 & echo $! > \(marker)');\necho 'started';\nsleep(30);")
        let stream = try await engine.start(request)
        var events: [RunEvent] = []
        let clock = ContinuousClock()
        var stopStarted: ContinuousClock.Instant?
        for await event in stream {
            events.append(event)
            if case .stdout = event.kind, stopStarted == nil {
                stopStarted = clock.now
                Task { _ = await engine.cancel(runId: request.runId) }
            }
        }
        let stopDuration = clock.now - stopStarted!
        #expect(events.finished?.status == .cancelled)
        #expect(stopDuration < .seconds(5))
        // The background `sleep` started by the snippet shares the process group and is gone too.
        if let pidText = try? String(contentsOfFile: marker, encoding: .utf8), let childPid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            try await Task.sleep(for: .milliseconds(200))
            #expect(kill(childPid, 0) != 0, "snippet child process should have been terminated")
        }
        try? FileManager.default.removeItem(atPath: marker)
    }

    @Test func launchFailureProducesSingleFinished() async throws {
        let target = TestSupport.localTarget("/nonexistent/runlet", php: php)
        let events = try await TestSupport.run("1", target: target)
        #expect(events.errors.first?.stage == .launch)
        #expect(events.finished?.reason == "launch-failed")
        #expect(events.count == 2)
    }

    @Test(.enabled(if: TestSupport.herdPHP74 != nil, "requires PHP 7.4"))
    func runsOnPHP74() async throws {
        let target = TestSupport.localTarget(TestSupport.fixtures.appendingPathComponent("composer").path, php: TestSupport.herdPHP74!)
        let events = try await TestSupport.run("$g = new Acme\\Greeter();\ndump(PHP_VERSION);\n$g->greet('7.4')", target: target)
        #expect(events.started?.phpVersion?.hasPrefix("7.4") == true)
        #expect(events.result?.value?.scalar == "Hello, 7.4!")
    }
}

@Suite(.enabled(if: TestSupport.hasPHP && FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("laravel-app/vendor").path), "requires host PHP and scripts/setup-fixtures.sh"))
struct LocalLaravelTests {
    var target: TargetSnapshot { TestSupport.localTarget(TestSupport.fixtures.appendingPathComponent("laravel-app").path, php: TestSupport.php()!) }

    @Test func bootstrapsLaravelAndQueriesModels() async throws {
        let events = try await TestSupport.run("app(App\\Services\\PriceFormatter::class)->format(App\\Models\\Widget::expensive()->sum('price'))", target: target)
        #expect(events.started?.framework == "laravel")
        #expect(events.bootstrapped?.frameworkVersion == "13.34.0")
        #expect(events.result?.value?.scalar == "$14.50")
    }

    @Test func collectionsHelpersValidationAndViews() async throws {
        let events = try await TestSupport.run("""
        dump(collect([1, 2, 3])->map(fn ($n) => $n * 2)->sum());
        dump(validator(['a' => ''], ['a' => 'required'])->errors()->first('a'));
        dump(Str::slug('Runlet Sandbox'));
        Blade::render('Hello {{ $name }}', ['name' => 'Runlet'])
        """, target: target)
        #expect(events.dumps.map { $0.value.scalar } == ["12", "The a field is required.", "runlet-sandbox"])
        #expect(events.result?.value?.scalar == "Hello Runlet")
        #expect(events.finished?.status == .completed, "\(events.errors)")
    }

    @Test func applicationSourceEditsAppearOnNextRun() async throws {
        let file = TestSupport.fixtures.appendingPathComponent("laravel-app/app/Services/EditProbe.php")
        defer { try? FileManager.default.removeItem(at: file) }
        try "<?php namespace App\\Services; class EditProbe { public static function v() { return 1; } }".write(to: file, atomically: true, encoding: .utf8)
        #expect(try await TestSupport.run("App\\Services\\EditProbe::v()", target: target).result?.value?.scalar == "1")
        try "<?php namespace App\\Services; class EditProbe { public static function v() { return 2; } }".write(to: file, atomically: true, encoding: .utf8)
        #expect(try await TestSupport.run("App\\Services\\EditProbe::v()", target: target).result?.value?.scalar == "2")
    }
}
