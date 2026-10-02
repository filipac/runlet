import Foundation
import RunletCore
import Testing
@testable import RunletExecution

/// The runner side of #41: `Runlet\bench()`, Laravel's `Benchmark::dd()`, profiler detection,
/// and Profile Run (Excimer only in the runlet-fixtures `profiler` container).
@Suite(.enabled(if: TestSupport.hasPHP, "requires host PHP"))
struct BenchmarkRunnerTests {
    func plainTarget() throws -> (TargetSnapshot, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runlet-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (TestSupport.localTarget(directory.path, php: TestSupport.php()!), directory)
    }

    func benchmarks(_ events: [RunEvent]) -> [(record: InspectorRecord, benchmark: BenchmarkRecord)] {
        events.inspection.benchmarks.compactMap { record in record.benchmark.map { (record, $0) } }
    }

    @Test func benchRecordsOrderedStatisticsAndReturnsThem() async throws {
        let (target, directory) = try plainTarget()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await TestSupport.run("""
        $r = Runlet\\bench(fn () => array_sum(range(1, 200)), 300, 'sum');
        [$r['label'], $r['iterations'], $r['mean_ms'] > 0, array_keys($r)];
        """, target: target)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let (record, benchmark) = try #require(benchmarks(events).first)
        #expect(record.title == "sum" && record.snippetLine == 1 && record.section == "Benchmarks")
        let result = try #require(benchmark.results.first)
        #expect(result.iterations == 300 && result.stoppedBy == "iterations" && result.warmup == 4)
        let ordered = [result.minNs, result.medianNs, result.p95Ns, result.p99Ns, result.maxNs].compactMap { $0 }
        #expect(ordered.count == 5 && ordered == ordered.sorted(), "min ≤ median ≤ p95 ≤ p99 ≤ max: \(ordered)")
        #expect((result.minNs ?? 0) <= result.meanNs && result.meanNs <= (result.maxNs ?? 0))
        let histogram = try #require(result.histogram)
        #expect(histogram.counts.reduce(0, +) + histogram.above == 300, "every timed call is in a bin or above p99")
        #expect((1...24).contains(histogram.counts.count))
        #expect((result.series?.count ?? 0) <= 48 && (result.series?.count ?? 0) > 0)
        #expect(result.memory?.perCallBytes == 0, "the callable keeps nothing")
        let returned = events.result?.value?.entries?.map { $0.value }
        #expect(returned?[0].scalar == "sum" && returned?[1].scalar == "300" && returned?[2].scalar == "true")
        #expect(returned?[3].entries?.map(\.value.scalar) == ["label", "iterations", "mean_ms", "median_ms", "min_ms", "max_ms", "p95_ms", "ops_per_sec", "memory_peak_bytes", "memory_per_call_bytes"])
    }

    @Test func benchIsBoundedByIterationsAndTime() async throws {
        let (target, directory) = try plainTarget()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await TestSupport.run("""
        Runlet\\bench(fn () => usleep(2000), 1000, 'sleepy', 0.05);
        Runlet\\bench(fn () => null, 500000, 'capped', 0.2);
        Runlet\\bench(fn () => null, 0);
        """, target: target)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let all = benchmarks(events)
        try #require(all.count == 3)
        let sleepy = all[0].benchmark.results[0]
        #expect(sleepy.stoppedEarly && sleepy.iterations >= 1 && sleepy.iterations < 100, "the 50 ms budget stopped it: \(sleepy.iterations)")
        #expect(sleepy.requestedIterations == 1000)
        #expect(all[0].benchmark.budgetMs == 50)
        let capped = all[1].benchmark
        #expect(capped.notes.contains { $0.contains("capped at 100,000") })
        #expect(capped.results[0].iterations <= 100_000)
        #expect(all[2].benchmark.results[0].iterations == 1 && all[2].benchmark.notes.contains { $0.contains("below 1") })
    }

    @Test func benchComparesCallablesKeyedLikeTheInput() async throws {
        let (target, directory) = try plainTarget()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await TestSupport.run("""
        $r = Runlet\\bench(['fast' => fn () => 1, 'slow' => fn () => usleep(300), fn () => 2], 20);
        array_keys($r);
        """, target: target)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let benchmark = try #require(benchmarks(events).first?.benchmark)
        #expect(benchmark.results.map(\.label) == ["fast", "slow", "#1"], "integer keys are numbered from 1")
        #expect(benchmark.isComparison && benchmark.fastest?.label != "slow")
        #expect(events.result?.value?.entries?.map(\.value.scalar) == ["fast", "slow", "0"])
    }

    @Test func benchRejectsWhatItCannotMeasure() async throws {
        let (target, directory) = try plainTarget()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await TestSupport.run("Runlet\\bench(['a' => 'no_such_function_here']);", target: target)
        #expect(events.errors.first?.className == "InvalidArgumentException")
        #expect(events.errors.first?.message.contains("not callable") == true)
        #expect(benchmarks(events).isEmpty)
    }

    @Test func percentilesAndHistogramMath() async throws {
        let (target, directory) = try plainTarget()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await TestSupport.run("""
        $p = fn (array $values, float $q) => Runlet\\Benchmark::percentile($values, $q);
        // Apple silicon's timer ticks every 41.67 ns, which hrtime() rounds to 41 or 42.
        $ticks = Runlet\\Benchmark::statistics([1666, 1708, 1750, 1750, 1791, 1833, 1666, 1708]);
        $wide = Runlet\\Benchmark::statistics(range(1000, 100000, 1000));
        [$p([1, 2, 3, 4], 0.5), $p(range(1, 100), 0.95), $p([], 0.5), $p([7], 0.99), $p([1, 9], 2.0),
         $ticks['histogram']['counts'], $ticks['histogram']['binNs'], $ticks['medianNs'],
         count($wide['histogram']['counts']), $wide['histogram']['above'], count($wide['series'])];
        """, target: target)
        #expect(events.errors.isEmpty, "\(events.errors)")
        let values = try #require(events.result?.value?.entries?.map(\.value))
        #expect(values[0].scalar == "2.5")
        #expect(values[1].scalar == "95.05")
        #expect(values[2].scalar == "0" && values[3].scalar == "7" && values[4].scalar == "9", "empty, single, clamped")
        #expect(values[5].entries?.map(\.value.scalar) == ["2", "2", "2", "1", "1"], "one bin per tick, none empty by rounding")
        #expect(Double(values[6].scalar ?? "") .map { abs($0 - 41.75) < 0.5 } == true, "the tick, averaged: \(values[6].scalar ?? "")")
        #expect(values[7].scalar == "1729.0")
        #expect(values[8].scalar == "24" && values[9].scalar == "1", "24 equal bins up to p99; the slowest call is above")
        #expect(values[10].scalar == "48")
    }

    @Test func startedReportsLoadedProfilersAndProfileRunStopsWithoutExcimer() async throws {
        let php = try #require(TestSupport.php())
        let probe = try #require(await PHPDiscovery.profilers(executable: php))
        // A host PHP with Excimer would profile; the Docker suite below covers that.
        guard !probe.canProfile else { return }
        let (target, directory) = try plainTarget()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: nil)
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: target, code: "file_put_contents('ran.txt', 'x'); echo 'ran';")
        request.profile = RunProfileOptions()
        var events: [RunEvent] = []
        for await event in try await engine.start(request) { events.append(event) }
        #expect(events.started?.profilers == probe, "the runner reports what the probe saw")
        let error = try #require(events.errors.first)
        #expect(error.stage == .launch && error.className == "ProfilerUnavailable")
        #expect(error.message.contains("Excimer") && error.message.contains("Nothing ran"))
        #expect(!events.stdout.contains("ran") && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("ran.txt").path), "nothing of the snippet ran")
        #expect(events.bootstrapped == nil, "nor the project's bootstrap")
        #expect(events.finished?.status == .failed)

        // Without Profile Run the same PHP runs normally and still reports its profilers.
        let normal = try await TestSupport.run("1 + 1", target: target)
        #expect(normal.errors.isEmpty && normal.started?.profilers == probe && normal.inspection.profile == nil)
    }

    @Test func scriptSendsProfileOptionsOnlyForRuns() throws {
        let bundle = RunnerBundle(source: Data("<?php\n".utf8))
        func request(_ data: Data) throws -> [String: Any] {
            let text = String(decoding: data, as: UTF8.self)
            let start = try #require(text.range(of: "Runner::main('")?.upperBound)
            let end = try #require(text[start...].range(of: "')")?.lowerBound)
            let json = try #require(Data(base64Encoded: String(text[start..<end])))
            return try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        }
        let profiled = try request(bundle.script(code: "1", nonce: "n", runId: UUID(), profile: RunProfileOptions(periodMs: 2), limits: RunLimits()))
        let profile = try #require(profiled["profile"] as? [String: Any])
        #expect(profile["engine"] as? String == "excimer" && profile["periodMs"] as? Double == 2 && profile["eventType"] as? String == "wall")
        let commands = try request(bundle.script(code: "", nonce: "n", runId: UUID(), mode: .commands, profile: RunProfileOptions(), limits: RunLimits()))
        #expect(commands["profile"] == nil)
        let plain = try request(bundle.script(code: "1", nonce: "n", runId: UUID(), limits: RunLimits()))
        #expect(plain["profile"] == nil)
    }
}

@Suite(.enabled(if: TestSupport.hasPHP && FileManager.default.fileExists(atPath: TestSupport.fixtures.appendingPathComponent("laravel-app/vendor/autoload.php").path), "requires host PHP and the laravel-app fixture"))
struct LaravelBenchmarkTests {
    @Test func benchmarkDdIsRecordedAsABenchmarkCard() async throws {
        let events = try await TestSupport.run("""
        Illuminate\\Support\\Benchmark::dd(['first' => fn () => usleep(100), 'second' => fn () => usleep(300)], 3);
        """, target: DriverSupport.target(DriverSupport.fixture("laravel-app")))
        #expect(events.errors.isEmpty, "\(events.errors)")
        let record = try #require(events.inspection.benchmarks.first)
        #expect(record.title == "Benchmark::dd()" && record.snippetLine == 1)
        let benchmark = try #require(record.benchmark)
        #expect(benchmark.isLaravel && benchmark.method == "Benchmark::dd")
        #expect(benchmark.results.map(\.label) == ["first", "second"])
        #expect(benchmark.results.allSatisfy { $0.averageOnly && $0.iterations == 3 && $0.meanNs >= 100_000 })
        #expect(benchmark.results[1].meanNs > benchmark.results[0].meanNs)
        // Laravel's own dump is still shown, and the run still ends like dd().
        #expect(events.dumps.first?.isDD == true)
        #expect(events.finished?.reason == "dd")
    }

    @Test func aSingleClosureAndOtherDumpsAreLeftAlone() async throws {
        let events = try await TestSupport.run("""
        dump(['first' => '1.000ms']);
        Illuminate\\Support\\Benchmark::dd(fn () => usleep(50));
        """, target: DriverSupport.target(DriverSupport.fixture("laravel-app")))
        let records = events.inspection.benchmarks
        #expect(records.count == 1, "the plain dump of a similar array is not a benchmark")
        #expect(records.first?.benchmark?.results.map(\.label) == ["Benchmark::dd()"])
        #expect(records.first?.benchmark?.results.first?.iterations == 1)
    }
}

enum ProfilerFixture {
    /// The runlet-fixtures `profiler` container's ID, found by its Compose labels only.
    static func container() async -> String? {
        guard let docker = TestSupport.docker,
              let output = try? await docker.run(["ps", "-q", "--no-trunc", "--filter", "label=com.docker.compose.project=runlet-fixtures", "--filter", "label=com.docker.compose.service=profiler"]) else { return nil }
        return String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init)
    }
}

/// Profile Run with Excimer, in the runlet-fixtures `profiler` service (PHP 8.4 with Excimer
/// and SPX; see Tests/Fixtures/docker/profiler). Finds it by its Compose labels only, so no
/// other container is listed.
@Suite(
    .serialized,
    .enabled(if: TestSupport.hasDocker, "requires a running Docker engine"),
    .enabled("requires the runlet-fixtures profiler service (docker compose -p runlet-fixtures -f Tests/Fixtures/docker/compose.yml up -d profiler)") {
        await ProfilerFixture.container() != nil
    }
)
struct ProfileRunDockerTests {
    static func profilerContainer() async -> String? { await ProfilerFixture.container() }

    func target(_ id: String) -> TargetSnapshot {
        TargetSnapshot(kind: .docker, label: "profiler", targetId: id, workingDirectory: "/var/www/html", phpExecutable: "php", containerId: id, containerName: "runlet-fixtures-profiler-1", temporaryDirectory: "/tmp")
    }

    @Test func probeDetectsExcimerAndSPX() async throws {
        let id = try #require(await Self.profilerContainer())
        let probe = await TestSupport.docker!.probe(containerId: id, phpExecutable: "php", user: nil, workingDirectory: "/var/www/html", temporaryDirectory: "/tmp", extraCandidates: [])
        #expect(probe.profilers?.canProfile == true && probe.profilers?.spx != nil, "\(String(describing: probe.profilers))")
    }

    @Test func profileRunSamplesTheSnippetIntoBoundedCollapsedStacks() async throws {
        let id = try #require(await Self.profilerContainer())
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: TestSupport.docker)
        var request = RunRequest(tabId: UUID(), documentVersion: 1, target: target(id), code: """
        function busy(int $n): int { $s = 0; for ($i = 0; $i < $n; $i++) { $s += $i % 7; } return $s; }
        $spin = function () { return busy(3000000); };
        busy(4000000);
        $spin();
        usleep(30000);
        'done'
        """)
        request.profile = RunProfileOptions()
        var events: [RunEvent] = []
        for await event in try await engine.start(request) { events.append(event) }
        #expect(events.errors.isEmpty, "\(events.errors)")
        #expect(events.result?.value?.scalar == "done")
        #expect(events.started?.profilers?.excimer != nil)
        let profile = try #require(events.inspection.profile)
        #expect(profile.engine == "excimer" && profile.eventType == "wall" && profile.periodMs == 1)
        #expect(profile.samples >= 20, "\(profile.samples) samples")
        let graph = FlameGraph(collapsed: profile.collapsed)
        #expect(graph.totalSamples == profile.samples, "every sample is in the collapsed stacks")
        let roots = Set(graph.root.children.map { graph.nodes[$0].name })
        #expect(roots.isSubset(of: ["snippet:3", "snippet:4", "snippet:5", "snippet:6", "[other stacks]"]), "the runner's own frames are trimmed: \(roots)")
        #expect(roots.contains("snippet:3") && roots.contains("snippet:4"))
        #expect(graph.nodes.contains { $0.name == "{closure:snippet:2}" }, "closures are named by their snippet line")
        #expect(profile.frames["busy"]?.inSnippet == true && profile.frames["busy"]?.line == 1)
        let sleptOn = graph.root.children.filter { ["snippet:5", "snippet:6"].contains(graph.nodes[$0].name) }.reduce(0) { $0 + graph.nodes[$1].value }
        #expect(sleptOn >= 20, "usleep(30 ms) is wall time on the snippet's line: \(sleptOn) samples")
    }

    @Test func profileIsSentWhenTheSnippetExitsOrFails() async throws {
        let id = try #require(await Self.profilerContainer())
        // Held for the whole loop: an engine that goes away never launches its runs.
        let engine = ExecutionEngine(bundle: TestSupport.bundle, docker: TestSupport.docker)
        for code in ["for ($i = 0; $i < 3000000; $i++) {} exit(0);", "for ($i = 0; $i < 3000000; $i++) {} throw new RuntimeException('boom');"] {
            var request = RunRequest(tabId: UUID(), documentVersion: 1, target: target(id), code: code)
            request.profile = RunProfileOptions()
            var events: [RunEvent] = []
            for await event in try await engine.start(request) { events.append(event) }
            #expect(events.inspection.profile != nil, "a profile for: \(code)")
        }
    }
}
