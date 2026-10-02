import Foundation

/// A benchmark the run recorded (`benchmark` records in the Benchmarks section): from
/// `Runlet\bench()`, with the full distribution, or from Laravel's `Benchmark::dd()`, with
/// averages only.
public struct BenchmarkRecord: Sendable, Codable, Equatable {
    public struct Histogram: Sendable, Codable, Equatable {
        /// The fastest call; the first bin starts here.
        public var lowNs: Double
        /// p99 (or the slowest call); slower calls are counted in `above`.
        public var highNs: Double
        public var binNs: Double?
        public var counts: [Int]
        public var above: Int

        public init(lowNs: Double, highNs: Double, binNs: Double? = nil, counts: [Int], above: Int = 0) {
            self.lowNs = lowNs
            self.highNs = highNs
            self.binNs = binNs
            self.counts = counts
            self.above = above
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lowNs = try c.decodeIfPresent(Double.self, forKey: .lowNs) ?? 0
            highNs = try c.decodeIfPresent(Double.self, forKey: .highNs) ?? 0
            binNs = try c.decodeIfPresent(Double.self, forKey: .binNs)
            // Bounded for drawing: a runner never sends more than a few dozen bins.
            counts = Array((try c.decodeIfPresent([Int].self, forKey: .counts) ?? []).prefix(256)).map { max(0, $0) }
            above = max(0, try c.decodeIfPresent(Int.self, forKey: .above) ?? 0)
        }

        /// Each bin's height relative to the tallest (0…1), for drawing.
        public var normalized: [Double] {
            let tallest = counts.max() ?? 0
            guard tallest > 0 else { return counts.map { _ in 0 } }
            return counts.map { Double($0) / Double(tallest) }
        }
    }

    public struct Memory: Sendable, Codable, Equatable {
        /// The highest memory use while the timed calls ran, above what was in use before;
        /// nil when PHP can't tell (before 8.2, when the process peak was already higher).
        public var peakBytes: Int?
        /// Memory still held after the timed calls, per call.
        public var perCallBytes: Double?
        /// Memory the cold first call kept.
        public var firstCallBytes: Int?

        public init(peakBytes: Int? = nil, perCallBytes: Double? = nil, firstCallBytes: Int? = nil) {
            self.peakBytes = peakBytes
            self.perCallBytes = perCallBytes
            self.firstCallBytes = firstCallBytes
        }
    }

    /// One measured callable.
    public struct Result: Sendable, Codable, Equatable, Identifiable {
        public var label: String
        public var iterations: Int
        public var requestedIterations: Int?
        public var warmup: Int?
        /// `iterations` (all ran) or `time` (the time budget ended it early).
        public var stoppedBy: String?
        /// The first, cold call.
        public var firstNs: Double?
        public var totalNs: Double?
        public var minNs: Double?
        public var maxNs: Double?
        public var meanNs: Double
        public var medianNs: Double?
        public var p95Ns: Double?
        public var p99Ns: Double?
        public var stddevNs: Double?
        public var opsPerSec: Double?
        public var memory: Memory?
        public var histogram: Histogram?
        /// Mean call time per chunk of calls, in the order they ran.
        public var series: [Double]?
        /// Only the mean is known (Laravel's Benchmark).
        public var averageOnly: Bool

        public var id: String { label }

        public init(label: String, iterations: Int, meanNs: Double, minNs: Double? = nil, maxNs: Double? = nil, medianNs: Double? = nil, p95Ns: Double? = nil, averageOnly: Bool = false) {
            self.label = label
            self.iterations = iterations
            self.meanNs = meanNs
            self.minNs = minNs
            self.maxNs = maxNs
            self.medianNs = medianNs
            self.p95Ns = p95Ns
            self.averageOnly = averageOnly
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? "bench()"
            iterations = max(0, try c.decodeIfPresent(Int.self, forKey: .iterations) ?? 0)
            requestedIterations = try c.decodeIfPresent(Int.self, forKey: .requestedIterations)
            warmup = try c.decodeIfPresent(Int.self, forKey: .warmup)
            stoppedBy = try c.decodeIfPresent(String.self, forKey: .stoppedBy)
            firstNs = try c.decodeIfPresent(Double.self, forKey: .firstNs)
            totalNs = try c.decodeIfPresent(Double.self, forKey: .totalNs)
            minNs = try c.decodeIfPresent(Double.self, forKey: .minNs)
            maxNs = try c.decodeIfPresent(Double.self, forKey: .maxNs)
            meanNs = try c.decodeIfPresent(Double.self, forKey: .meanNs) ?? 0
            medianNs = try c.decodeIfPresent(Double.self, forKey: .medianNs)
            p95Ns = try c.decodeIfPresent(Double.self, forKey: .p95Ns)
            p99Ns = try c.decodeIfPresent(Double.self, forKey: .p99Ns)
            stddevNs = try c.decodeIfPresent(Double.self, forKey: .stddevNs)
            opsPerSec = try c.decodeIfPresent(Double.self, forKey: .opsPerSec)
            memory = try c.decodeIfPresent(Memory.self, forKey: .memory)
            histogram = try c.decodeIfPresent(Histogram.self, forKey: .histogram)
            series = (try c.decodeIfPresent([Double].self, forKey: .series)).map { Array($0.prefix(256)) }
            averageOnly = try c.decodeIfPresent(Bool.self, forKey: .averageOnly) ?? false
        }

        /// The time budget ended the measurement before all requested iterations ran.
        public var stoppedEarly: Bool { stoppedBy == "time" }

        /// Operations per second from the mean when the runner sent none.
        public var operationsPerSecond: Double? {
            if let opsPerSec { return opsPerSec }
            return meanNs > 0 ? 1e9 / meanNs : nil
        }
    }

    /// `runlet` (`Runlet\bench()`) or `laravel` (`Benchmark::dd()`).
    public var source: String
    public var method: String?
    public var results: [Result]
    /// Time budget per callable, in milliseconds.
    public var budgetMs: Double?
    /// The median time of an empty call: the floor every measured call includes.
    public var overheadNs: Double?
    public var php: String?
    public var notes: [String]

    public init(source: String = "runlet", method: String? = "bench", results: [Result], budgetMs: Double? = nil, overheadNs: Double? = nil, notes: [String] = []) {
        self.source = source
        self.method = method
        self.results = results
        self.budgetMs = budgetMs
        self.overheadNs = overheadNs
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "runlet"
        method = try c.decodeIfPresent(String.self, forKey: .method)
        results = Array((try c.decodeIfPresent([Result].self, forKey: .results) ?? []).prefix(50))
        budgetMs = try c.decodeIfPresent(Double.self, forKey: .budgetMs)
        overheadNs = try c.decodeIfPresent(Double.self, forKey: .overheadNs)
        php = try c.decodeIfPresent(String.self, forKey: .php)
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
    }

    public var isLaravel: Bool { source == "laravel" }

    /// Several callables measured side by side.
    public var isComparison: Bool { results.count > 1 }

    /// The result with the lowest mean (the comparison's baseline).
    public var fastest: Result? {
        results.filter { $0.meanNs > 0 }.min { $0.meanNs < $1.meanNs }
    }

    /// How many times slower than the fastest a result is (1 for the fastest); nil without a comparison.
    public func relativeToFastest(_ result: Result) -> Double? {
        guard isComparison, let fastest, fastest.meanNs > 0, result.meanNs > 0 else { return nil }
        return result.meanNs / fastest.meanNs
    }

    /// One line per result, for Copy Output and Markdown.
    public var plainSummary: String {
        results.map { result in
            var parts = ["\(result.label): mean \(BenchmarkFormat.duration(ns: result.meanNs))"]
            if let median = result.medianNs { parts.append("median \(BenchmarkFormat.duration(ns: median))") }
            if let p95 = result.p95Ns { parts.append("p95 \(BenchmarkFormat.duration(ns: p95))") }
            if let min = result.minNs, let max = result.maxNs { parts.append("min \(BenchmarkFormat.duration(ns: min)), max \(BenchmarkFormat.duration(ns: max))") }
            if let ops = result.operationsPerSecond { parts.append(BenchmarkFormat.operations(ops)) }
            parts.append("\(result.iterations.formatted()) iteration\(result.iterations == 1 ? "" : "s")")
            if let relative = relativeToFastest(result), relative > 1.005 { parts.append(BenchmarkFormat.relative(relative)) }
            return parts.joined(separator: ", ")
        }.joined(separator: "\n")
    }
}

/// Number formatting for benchmark cards (always with a unit, three significant digits).
public enum BenchmarkFormat {
    /// "850 ns", "1.23 µs", "45.6 ms", "1.20 s".
    public static func duration(ns: Double) -> String {
        guard ns.isFinite else { return "—" }
        let value = abs(ns)
        switch value {
        case ..<999.5: return "\(significant(ns)) ns"
        case ..<999_500: return "\(significant(ns / 1_000)) µs"
        case ..<999_500_000: return "\(significant(ns / 1_000_000)) ms"
        default: return "\(significant(ns / 1_000_000_000)) s"
        }
    }

    /// "1.2M ops/s", "48.3K ops/s", "812 ops/s", "0.50 ops/s".
    public static func operations(_ perSecond: Double) -> String {
        guard perSecond.isFinite, perSecond > 0 else { return "— ops/s" }
        switch perSecond {
        case 1_000_000_000...: return "\(significant(perSecond / 1_000_000_000))G ops/s"
        case 1_000_000...: return "\(significant(perSecond / 1_000_000))M ops/s"
        case 10_000...: return "\(significant(perSecond / 1_000))K ops/s"
        default: return "\(significant(perSecond)) ops/s"
        }
    }

    /// "512 B", "12.0 KB", "3.40 MB"; signed for memory that was released.
    public static func bytes(_ bytes: Double) -> String {
        guard bytes.isFinite else { return "—" }
        let sign = bytes < 0 ? "−" : ""
        let value = abs(bytes)
        switch value {
        case ..<1024: return "\(sign)\(Int(value.rounded())) B"
        case ..<(1024 * 1024): return "\(sign)\(significant(value / 1024)) KB"
        case ..<(1024 * 1024 * 1024): return "\(sign)\(significant(value / 1024 / 1024)) MB"
        default: return "\(sign)\(significant(value / 1024 / 1024 / 1024)) GB"
        }
    }

    /// "2.4× slower", or "fastest" for the baseline.
    public static func relative(_ factor: Double) -> String {
        guard factor.isFinite else { return "" }
        return factor < 1.005 ? "fastest" : "\(significant(factor))× slower"
    }

    /// Three significant digits without exponent notation: 1.23, 12.3, 123, 1234.
    public static func significant(_ value: Double) -> String {
        let magnitude = abs(value)
        let decimals: Int
        switch magnitude {
        case 0: decimals = 0
        case ..<1: decimals = 2
        case ..<10: decimals = 2
        case ..<100: decimals = 1
        default: decimals = 0
        }
        return String(format: "%.\(decimals)f", value)
    }
}
