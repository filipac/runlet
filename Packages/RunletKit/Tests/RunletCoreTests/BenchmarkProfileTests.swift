import Foundation
import Testing
@testable import RunletCore

/// Benchmark records, profiler detection, Profile Run availability, and the flame-graph model (#41).
struct BenchmarkRecordTests {
    static let runletRecord = """
    {"index":1,"section":"Benchmarks","kind":"benchmark","title":"Doubling","inSnippet":true,"snippetLine":4,"data":{
      "source":"runlet","method":"bench","budgetMs":1000,"overheadNs":41,"php":"8.4.1","notes":["Iterations are capped at 100,000 per callable."],
      "results":[
        {"label":"map","iterations":800,"requestedIterations":1000,"warmup":11,"stoppedBy":"time","firstNs":9000,"totalNs":5000000,
         "minNs":5800,"maxNs":32000,"meanNs":6400,"medianNs":6200,"p95Ns":6700,"p99Ns":7100,"stddevNs":180.5,"opsPerSec":160000,
         "memory":{"peakBytes":20480,"perCallBytes":0,"firstCallBytes":512},
         "histogram":{"lowNs":5800,"highNs":7100,"binNs":54.2,"counts":[0,4,10,2],"above":8},"series":[6300,6200,6250]},
        {"label":"loop","iterations":1000,"meanNs":3200,"medianNs":3100,"minNs":3000,"maxNs":4000,"p95Ns":3300}
      ]}}
    """

    @Test func decodesARunletBenchRecordWithEveryStatistic() throws {
        let record = try JSONDecoder().decode(InspectorRecord.self, from: Data(Self.runletRecord.utf8))
        #expect(record.section == RunInspection.benchmarks)
        let benchmark = try #require(record.benchmark)
        #expect(!benchmark.isLaravel && benchmark.isComparison)
        #expect(benchmark.budgetMs == 1000 && benchmark.overheadNs == 41)
        let map = benchmark.results[0]
        #expect(map.stoppedEarly && map.iterations == 800 && map.requestedIterations == 1000)
        #expect(map.memory?.peakBytes == 20480 && map.memory?.perCallBytes == 0)
        #expect(map.histogram?.counts == [0, 4, 10, 2] && map.histogram?.above == 8)
        #expect(map.series?.count == 3)
        let loop = benchmark.results[1]
        #expect(loop.histogram == nil && loop.memory == nil && !loop.stoppedEarly)
        #expect(loop.operationsPerSecond == 312_500, "derived from the mean when the runner sent none")
    }

    @Test func comparesResultsAgainstTheFastest() throws {
        let benchmark = try #require(try JSONDecoder().decode(InspectorRecord.self, from: Data(Self.runletRecord.utf8)).benchmark)
        #expect(benchmark.fastest?.label == "loop")
        #expect(benchmark.relativeToFastest(benchmark.results[0]) == 2)
        #expect(benchmark.relativeToFastest(benchmark.results[1]) == 1)
        let summary = benchmark.plainSummary
        #expect(summary.contains("map: mean 6.40 µs") && summary.contains("2.00× slower"))
        #expect(summary.contains("loop: mean 3.20 µs") && !summary.split(separator: "\n")[1].contains("slower"))

        let single = BenchmarkRecord(results: [.init(label: "x", iterations: 10, meanNs: 100)])
        #expect(single.relativeToFastest(single.results[0]) == nil, "no comparison for one callable")
    }

    @Test func decodesLaravelAveragesAndUnknownFieldsTolerantly() throws {
        let json = """
        {"index":2,"section":"Benchmarks","kind":"benchmark","title":"Benchmark::dd()","data":{"source":"laravel","method":"Benchmark::dd",
         "results":[{"label":"sha256","iterations":500,"meanNs":26000,"averageOnly":true,"futureField":1}],"notes":[]}}
        """
        let benchmark = try #require(try JSONDecoder().decode(InspectorRecord.self, from: Data(json.utf8)).benchmark)
        #expect(benchmark.isLaravel && !benchmark.isComparison)
        let result = benchmark.results[0]
        #expect(result.averageOnly && result.medianNs == nil && result.p95Ns == nil && result.iterations == 500)
    }

    @Test func boundsWhatItDecodes() throws {
        let counts = (0..<400).map { $0 % 3 == 0 ? -5 : $0 }
        let json = "{\"lowNs\":1,\"highNs\":2,\"counts\":\(counts),\"above\":-3}"
        let histogram = try JSONDecoder().decode(BenchmarkRecord.Histogram.self, from: Data(json.utf8))
        #expect(histogram.counts.count == 256, "at most 256 bins")
        #expect(histogram.counts.allSatisfy { $0 >= 0 } && histogram.above == 0)
        let normalized = histogram.normalized
        #expect(normalized.allSatisfy { $0 >= 0 && $0 <= 1 } && normalized.contains(1))
        #expect(BenchmarkRecord.Histogram(lowNs: 0, highNs: 0, counts: [0, 0]).normalized == [0, 0])
    }

    @Test func formatsDurationsThroughputAndBytes() {
        #expect(BenchmarkFormat.duration(ns: 850) == "850 ns")
        #expect(BenchmarkFormat.duration(ns: 999.7) == "1.00 µs", "rounds up into the next unit")
        #expect(BenchmarkFormat.duration(ns: 1_234) == "1.23 µs")
        #expect(BenchmarkFormat.duration(ns: 45_600_000) == "45.6 ms")
        #expect(BenchmarkFormat.duration(ns: 1_200_000_000) == "1.20 s")
        #expect(BenchmarkFormat.duration(ns: .nan) == "—")
        #expect(BenchmarkFormat.operations(1_234_567) == "1.23M ops/s")
        #expect(BenchmarkFormat.operations(48_300) == "48.3K ops/s")
        #expect(BenchmarkFormat.operations(812) == "812 ops/s")
        #expect(BenchmarkFormat.operations(0) == "— ops/s")
        #expect(BenchmarkFormat.bytes(512) == "512 B")
        #expect(BenchmarkFormat.bytes(12_288) == "12.0 KB")
        #expect(BenchmarkFormat.bytes(-2048) == "−2.00 KB")
        #expect(BenchmarkFormat.relative(1.001) == "fastest")
        #expect(BenchmarkFormat.relative(2.4) == "2.40× slower")
    }
}

struct ProfilerDetectionTests {
    @Test func parsesTheProbeOutputAfterLoginNoise() {
        let output = "Welcome to the server\n{\"excimer\":\"1.2.6\",\"spx\":null}\n"
        let profilers = PHPProfilers.parse(output)
        #expect(profilers == PHPProfilers(excimer: "1.2.6"))
        #expect(profilers?.canProfile == true && profilers?.summary == "Excimer 1.2.6")
        #expect(PHPProfilers.parse("PHP Warning: something\n") == nil)
        #expect(PHPProfilers.parse("{\"excimer\":null,\"spx\":null}")?.isEmpty == true)
    }

    @Test func readsTheRunnersStartedFrame() throws {
        let none = try JSONDecoder().decode(StartedInfo.self, from: Data(#"{"phpVersion":"8.4.1","profilers":{}}"#.utf8))
        #expect(none.profilers == PHPProfilers(), "an empty object: checked, nothing loaded")
        let both = try JSONDecoder().decode(StartedInfo.self, from: Data(#"{"profilers":{"excimer":"","spx":"0.4.22"}}"#.utf8))
        #expect(both.profilers?.summary == "Excimer · SPX 0.4.22", "loaded without a version")
        let old = try JSONDecoder().decode(StartedInfo.self, from: Data(#"{"phpVersion":"8.4.1"}"#.utf8))
        #expect(old.profilers == nil, "older runners don't say")
    }

    @Test func profileRunAvailabilityExplainsWhyItIsOff() {
        #expect(ProfileRunAvailability.evaluate(nil, php: "this container's PHP") == .unchecked)
        #expect(ProfileRunAvailability.evaluate(nil, php: "x").isEnabled, "unknown: the run checks first")
        #expect(ProfileRunAvailability.evaluate(PHPProfilers(excimer: "1.2.6"), php: "x") == .ready("Excimer 1.2.6"))

        let none = ProfileRunAvailability.evaluate(PHPProfilers(), php: "PHP 8.4.25 (Herd)")
        #expect(!none.isEnabled)
        #expect(none.reason == "Profile Run needs the Excimer extension, which PHP 8.4.25 (Herd) doesn't load.")

        let spx = ProfileRunAvailability.evaluate(PHPProfilers(spx: "0.4.22"), php: "the PHP on app.example.com")
        #expect(!spx.isEnabled)
        #expect(spx.reason?.contains("loads SPX only") == true && spx.reason?.contains("the PHP on app.example.com") == true)
        #expect(ProfileRunAvailability.ready("Excimer").reason == nil)
    }

    @Test func runRequestsCarryProfileOptionsAndOldOnesDecode() throws {
        let target = TargetSnapshot(kind: .local, label: "t", targetId: "t", workingDirectory: "/tmp", phpExecutable: "php")
        let request = RunRequest(tabId: UUID(), documentVersion: 1, target: target, code: "1", profile: RunProfileOptions())
        let decoded = try JSONDecoder().decode(RunRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.profile == RunProfileOptions(engine: "excimer", periodMs: 1, eventType: "wall"))

        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        object["profile"] = nil
        let old = try JSONDecoder().decode(RunRequest.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.profile == nil)
    }
}

struct FlameGraphTests {
    static let collapsed = """
    snippet:3;slugs;Str::slug 6
    snippet:3;slugs;Str::slug;ASCII::to_ascii 2
    snippet:3;slugs 1
    snippet:5;fib;fib;fib 3
    snippet:7 2
    not a stack line
    bad;count x
    """

    @Test func buildsATreeWithInclusiveAndSelfSamples() {
        let graph = FlameGraph(collapsed: Self.collapsed)
        #expect(graph.totalSamples == 14)
        #expect(graph.truncation.malformedLines == 2)
        let top = graph.root.children.map { graph.nodes[$0].name }
        #expect(top == ["snippet:3", "snippet:5", "snippet:7"], "largest first")
        let slugs = graph.nodes.first { $0.name == "slugs" }!
        #expect(slugs.value == 9 && slugs.selfValue == 1 && slugs.depth == 2)
        let slug = graph.nodes.first { $0.name == "Str::slug" }!
        #expect(slug.value == 8 && slug.selfValue == 6)
        #expect(graph.nodes.first { $0.name == "snippet:7" }!.selfValue == 2)
        #expect(graph.depth == 4)
        #expect(graph.path(to: slug.id).map { graph.nodes[$0].name } == ["all", "snippet:3", "slugs", "Str::slug"])
    }

    @Test func offsetsLayOutSiblingsSideBySide() {
        let graph = FlameGraph(collapsed: Self.collapsed)
        let placements = graph.placements()
        func placement(_ name: String) -> FlameGraph.Placement { placements.first { graph.nodes[$0.node].name == name }! }
        #expect(placement("all").x == 0 && placement("all").width == 1)
        #expect(placement("snippet:3").x == 0 && abs(placement("snippet:3").width - 9.0 / 14) < 1e-9)
        #expect(abs(placement("snippet:5").x - 9.0 / 14) < 1e-9)
        #expect(abs(placement("snippet:7").x - 12.0 / 14) < 1e-9)
    }

    @Test func zoomScalesTheSubtreeAndKeepsAncestorsFullWidth() {
        let graph = FlameGraph(collapsed: Self.collapsed)
        let slugs = graph.nodes.first { $0.name == "slugs" }!.id
        let placements = graph.placements(focus: slugs)
        let names = Set(placements.map { graph.nodes[$0.node].name })
        #expect(names == ["all", "snippet:3", "slugs", "Str::slug", "ASCII::to_ascii"], "only the focus, its subtree, and its ancestors")
        let ancestors = placements.filter { $0.depth < 2 }
        #expect(ancestors.allSatisfy { $0.x == 0 && $0.width == 1 })
        let focus = placements.first { $0.node == slugs }!
        #expect(focus.x == 0 && focus.width == 1)
        let slug = placements.first { graph.nodes[$0.node].name == "Str::slug" }!
        #expect(abs(slug.width - 8.0 / 9) < 1e-9)
        let pruned = graph.placements(focus: slugs, minimumWidth: 0.5)
        #expect(!pruned.contains { graph.nodes[$0.node].name == "ASCII::to_ascii" }, "narrow frames are left out")
        #expect(graph.isAncestor(0, of: slugs) && !graph.isAncestor(slugs, of: 0))
    }

    @Test func searchCountsNestedMatchesOnce() {
        let graph = FlameGraph(collapsed: Self.collapsed)
        let fib = graph.matches("FIB")
        #expect(fib.count == 3, "case-insensitive")
        #expect(graph.matchedSamples(fib) == 3, "recursive frames are counted once")
        #expect(graph.matchedSamples(graph.matches("slug")) == 9, "slugs contains Str::slug")
        #expect(graph.matches("  ").isEmpty && graph.matches("nothing").isEmpty)
    }

    @Test func hottestFunctionsByOwnSamples() {
        let graph = FlameGraph(collapsed: Self.collapsed)
        let hottest = graph.hottestFunctions(limit: 3)
        #expect(hottest.map(\.name) == ["Str::slug", "fib", "ASCII::to_ascii"])
        #expect(hottest[0].selfSamples == 6 && hottest[0].totalSamples == 8)
        #expect(hottest[1].selfSamples == 3 && hottest[1].totalSamples == 3, "recursion counted once")
    }

    @Test func truncatesDepthAndNodes() {
        let deep = (1...10).map { "f\($0)" }.joined(separator: ";") + " 4\nother 1"
        let graph = FlameGraph(collapsed: deep, maxDepth: 5)
        #expect(graph.depth == 5)
        #expect(graph.truncation.depthSamples == 4)
        #expect(graph.nodes.contains { $0.name == FlameGraph.deeperName && $0.depth == 5 })
        #expect(graph.totalSamples == 5)

        let wide = (1...50).map { "root;leaf\($0) 1" }.joined(separator: "\n")
        let capped = FlameGraph(collapsed: wide, maxNodes: 10)
        #expect(capped.nodes.count == 10)
        #expect(capped.truncation.nodeSamples == 42, "50 leaves, 8 kept")
        #expect(capped.totalSamples == 50, "no sample is lost: the rest stay on their parent")
        #expect(capped.nodes.first { $0.name == "root" }!.selfValue == 42)
    }

    @Test func decodesAProfileRecord() throws {
        let json = """
        {"index":3,"section":"Profile","kind":"profile","title":"Profile","data":{"engine":"excimer","version":"1.2.6","eventType":"wall","periodMs":1,
         "samples":12,"durationMs":12.4,"outsideSamples":0,"maxStacks":4000,"maxDepth":200,"collapsed":"snippet:2;slugs 12",
         "frames":{"snippet:2":{"line":2,"inSnippet":true},"slugs":{"line":5,"file":"/var/www/html/app/Slugs.php"}},
         "truncated":{"stacks":3,"foldedSamples":4},"php":"8.4.26"}}
        """
        let record = try JSONDecoder().decode(InspectorRecord.self, from: Data(json.utf8))
        let profile = try #require(record.profile)
        #expect(profile.samples == 12 && profile.frames["slugs"]?.file == "/var/www/html/app/Slugs.php")
        #expect(profile.frames["snippet:2"]?.inSnippet == true)
        #expect(profile.truncated?.isEmpty == false)
        #expect(profile.engineSummary == "Excimer 1.2.6 · wall time · 1 ms period")
        var inspection = RunInspection()
        inspection.apply(.record(record))
        #expect(inspection.profile == profile && inspection.sections == [RunInspection.profile])
    }
}
