import AppKit
import RunletCore
import SwiftUI

/// The benchmark card (#41): `Runlet\bench()` and Laravel's `Benchmark::dd()`, in the output
/// where the call ran and in the Benchmarks section. One callable gets a stats grid, its
/// distribution, and its times in run order; several get a side-by-side comparison.
struct BenchmarkCard: View {
    let record: InspectorRecord
    let benchmark: BenchmarkRecord
    let tab: TabModel

    init?(record: InspectorRecord, tab: TabModel) {
        guard let benchmark = record.benchmark else { return nil }
        self.record = record
        self.benchmark = benchmark
        self.tab = tab
    }

    var body: some View {
        let line = tab.editorLine(of: record)
        Card(title: benchmark.isLaravel ? "Laravel Benchmark" : "Benchmark", subtitle: line.map { "line \($0)" }, tint: .indigo,
             copyText: (record.title.map { $0 + "\n" } ?? "") + benchmark.plainSummary,
             onTapSubtitle: line.map { line in { tab.editor.goTo(line: line) } }) {
            VStack(alignment: .leading, spacing: 10) {
                if let title = record.title {
                    Text(title).font(.callout.weight(.semibold)).textSelection(.enabled)
                }
                if benchmark.isComparison {
                    BenchmarkComparison(benchmark: benchmark)
                } else if let result = benchmark.results.first {
                    BenchmarkSingleResult(result: result, benchmark: benchmark)
                }
                BenchmarkNotes(benchmark: benchmark)
            }
            .padding(.top, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("benchmark-card")
    }
}

/// One callable: the stats grid, then the distribution and the run-order sparkline.
private struct BenchmarkSingleResult: View {
    let result: BenchmarkRecord.Result
    let benchmark: BenchmarkRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BenchmarkStatsGrid(result: result)
            if let histogram = result.histogram, !histogram.counts.isEmpty {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Distribution").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        BenchmarkHistogram(histogram: histogram, median: result.medianNs, p95: result.p95Ns)
                            .frame(height: 58)
                        HStack {
                            Text(BenchmarkFormat.duration(ns: histogram.lowNs))
                            Spacer()
                            Text(BenchmarkFormat.duration(ns: histogram.highNs))
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        if histogram.above > 0 {
                            Text("\(histogram.above.formatted()) slower call\(histogram.above == 1 ? "" : "s") not shown (beyond p99 or far from the rest), up to \(BenchmarkFormat.duration(ns: result.maxNs ?? histogram.highNs))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(minWidth: 180, maxWidth: .infinity)
                    if let series = result.series, series.count > 2 {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("In run order").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            BenchmarkSparkline(values: series)
                                .frame(height: 58)
                            HStack {
                                Text("first")
                                Spacer()
                                Text("last")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .frame(minWidth: 120, maxWidth: 220)
                    }
                }
            }
        }
    }
}

/// Mean, median, p95, min, max, ops/s, then iterations, spread, the cold call, and memory.
private struct BenchmarkStatsGrid: View {
    let result: BenchmarkRecord.Result

    var body: some View {
        let tiles = primary + secondary
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 160), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(tiles, id: \.label) { tile in
                StatTile(label: tile.label, value: tile.value, emphasized: tile.emphasized, help: tile.help)
            }
        }
    }

    private struct Tile {
        var label: String
        var value: String
        var emphasized = false
        var help: String?
    }

    private var primary: [Tile] {
        var tiles = [Tile(label: "Mean", value: BenchmarkFormat.duration(ns: result.meanNs), emphasized: true)]
        if let median = result.medianNs { tiles.append(Tile(label: "Median", value: BenchmarkFormat.duration(ns: median), emphasized: true)) }
        if let p95 = result.p95Ns { tiles.append(Tile(label: "p95", value: BenchmarkFormat.duration(ns: p95), emphasized: true, help: "95% of calls were at least this fast")) }
        if let min = result.minNs { tiles.append(Tile(label: "Min", value: BenchmarkFormat.duration(ns: min))) }
        if let max = result.maxNs { tiles.append(Tile(label: "Max", value: BenchmarkFormat.duration(ns: max))) }
        if let ops = result.operationsPerSecond { tiles.append(Tile(label: "Throughput", value: BenchmarkFormat.operations(ops))) }
        return tiles
    }

    private var secondary: [Tile] {
        var tiles: [Tile] = []
        var iterations = result.iterations.formatted()
        if result.stoppedEarly, let requested = result.requestedIterations { iterations += " of \(requested.formatted())" }
        tiles.append(Tile(label: "Iterations", value: iterations,
                          help: (result.warmup.map { "After \($0) warm-up call\($0 == 1 ? "" : "s"), the first one cold." } ?? "") + (result.stoppedEarly ? " The time budget ended the measurement early." : "")))
        if let stddev = result.stddevNs { tiles.append(Tile(label: "Std dev", value: "± " + BenchmarkFormat.duration(ns: stddev))) }
        if let first = result.firstNs { tiles.append(Tile(label: "First call", value: BenchmarkFormat.duration(ns: first), help: "The cold first call, before the warm-up (not counted in the statistics)")) }
        if let memory = result.memory {
            if let peak = memory.peakBytes {
                tiles.append(Tile(label: "Peak memory", value: BenchmarkFormat.bytes(Double(peak)), help: "The highest memory use while the timed calls ran, above what was in use before them"))
            }
            if let perCall = memory.perCallBytes {
                tiles.append(Tile(label: "Kept per call", value: BenchmarkFormat.bytes(perCall), help: "Memory still in use after the timed calls, per call (0 B when the callable keeps nothing)"))
            }
        }
        if result.averageOnly {
            tiles = [Tile(label: "Iterations", value: result.iterations.formatted())]
        }
        return tiles
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    var emphasized = false
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.system(emphasized ? .title3 : .callout, design: .rounded).weight(emphasized ? .semibold : .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.07)))
        .help(help ?? "")
    }
}

/// Bars of call counts from the fastest call to p99, with median and p95 markers.
struct BenchmarkHistogram: View {
    let histogram: BenchmarkRecord.Histogram
    var median: Double?
    var p95: Double?
    var compact = false

    var body: some View {
        Canvas { context, size in
            // Nothing to draw at zero size: a zero-length stroke trips Metal validation in Xcode runs (#85).
            guard size.width >= 1, size.height >= 1 else { return }
            let heights = histogram.normalized
            guard !heights.isEmpty else { return }
            let gap: CGFloat = heights.count > 30 || compact ? 1 : 2
            let slot = size.width / CGFloat(heights.count)
            // Few bins (a coarse timer) stay slim bars instead of blocks.
            let width = max(1, heights.count <= 10 && !compact ? min(slot - gap, 30) : slot - gap)
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(baseline, with: .color(Color.indigo.opacity(0.25)), lineWidth: 1)
            for (index, height) in heights.enumerated() where height > 0 {
                let barHeight = max(1.5, CGFloat(height) * size.height)
                let rect = CGRect(x: CGFloat(index) * slot + (slot - width) / 2, y: size.height - barHeight, width: width, height: barHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: min(2, width / 3)), with: .color(Color.indigo.opacity(0.75)))
            }
            guard !compact else { return }
            let span = histogram.highNs - histogram.lowNs
            let bin = histogram.binNs ?? span / Double(heights.count)
            // One bin per timer tick centers each bin on its time; otherwise bins start at theirs.
            let perTick = bin > 0 && abs(bin * Double(heights.count - 1) - span) < bin / 2
            for (value, color) in [(median, Color.green), (p95, Color.orange)] {
                guard let value, span > 0, bin > 0, value >= histogram.lowNs, value <= histogram.highNs else { continue }
                let x = min(size.width - 1, CGFloat((value - histogram.lowNs) / bin) * slot + (perTick ? slot / 2 : 0))
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
            }
        }
        .accessibilityLabel("Distribution of call times")
        .help(compact ? "" : "Calls by duration, fastest on the left. Green: median · Orange: p95")
    }
}

/// Mean call time per chunk of calls, in the order they ran (drift, warm-up, GC pauses).
struct BenchmarkSparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            // Nothing to draw at zero size: a zero-length stroke trips Metal validation in Xcode runs (#85).
            guard size.width >= 1, size.height >= 1 else { return }
            guard values.count > 1, let low = values.min(), let high = values.max() else { return }
            let span = high > low ? high - low : 1
            var path = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: CGFloat(index) / CGFloat(values.count - 1) * size.width,
                                    y: size.height - 2 - CGFloat((value - low) / span) * (size.height - 4))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            var fill = path
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(Color.indigo.opacity(0.12)))
            context.stroke(path, with: .color(Color.indigo), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .help("Mean call time over the run, in chunks of calls: drift, warm-up, or pauses show here")
        .accessibilityLabel("Call times in run order")
    }
}

/// Several callables: bars of their mean times (the fastest in green), then a table.
private struct BenchmarkComparison: View {
    let benchmark: BenchmarkRecord

    var body: some View {
        let slowest = benchmark.results.map(\.meanNs).max() ?? 1
        let fastestLabel = benchmark.fastest?.label
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(benchmark.results) { result in
                    let isFastest = result.label == fastestLabel
                    HStack(spacing: 8) {
                        Text(result.label)
                            .font(.callout.weight(isFastest ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 120, alignment: .leading)
                            .help(result.label)
                        GeometryReader { proxy in
                            let fraction = slowest > 0 ? result.meanNs / slowest : 0
                            RoundedRectangle(cornerRadius: 3)
                                .fill(isFastest ? Color.green.opacity(0.75) : Color.indigo.opacity(0.6))
                                .frame(width: max(3, proxy.size.width * fraction))
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 14)
                        Text(BenchmarkFormat.duration(ns: result.meanNs))
                            .font(.callout.monospacedDigit().weight(.medium))
                            .frame(width: 74, alignment: .trailing)
                        Text(benchmark.relativeToFastest(result).map(BenchmarkFormat.relative) ?? "")
                            .font(.caption)
                            .foregroundStyle(isFastest ? Color.green : Color.secondary)
                            .frame(width: 82, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if !benchmark.isLaravel {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text("Median")
                        Text("p95")
                        Text("Min")
                        Text("Max")
                        Text("Throughput")
                        Text("Iterations")
                        Text("Kept/call")
                        Text("Distribution").gridColumnAlignment(.leading)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(benchmark.results) { result in
                        GridRow {
                            Text(result.label).lineLimit(1).truncationMode(.middle).frame(maxWidth: 120, alignment: .leading)
                            Text(result.medianNs.map { BenchmarkFormat.duration(ns: $0) } ?? "—")
                            Text(result.p95Ns.map { BenchmarkFormat.duration(ns: $0) } ?? "—")
                            Text(result.minNs.map { BenchmarkFormat.duration(ns: $0) } ?? "—")
                            Text(result.maxNs.map { BenchmarkFormat.duration(ns: $0) } ?? "—")
                            Text(result.operationsPerSecond.map(BenchmarkFormat.operations) ?? "—")
                            Text(result.iterations.formatted() + (result.stoppedEarly ? "*" : ""))
                                .help(result.stoppedEarly ? "The time budget ended this measurement early" : "")
                            Text(result.memory?.perCallBytes.map(BenchmarkFormat.bytes) ?? "—")
                            Group {
                                if let histogram = result.histogram {
                                    BenchmarkHistogram(histogram: histogram, compact: true).frame(width: 90, height: 16)
                                } else {
                                    Text("")
                                }
                            }
                        }
                        .font(.caption.monospacedDigit())
                    }
                }
                .textSelection(.enabled)
            } else {
                Text("\(benchmark.results.first?.iterations.formatted() ?? "1") iteration\(benchmark.results.first?.iterations == 1 ? "" : "s") each")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Early stops, capped arguments, Laravel's limits, and the timer floor.
private struct BenchmarkNotes: View {
    let benchmark: BenchmarkRecord

    var body: some View {
        let lines = notes
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var notes: [String] {
        var notes: [String] = []
        let budget = benchmark.budgetMs.map { BenchmarkFormat.duration(ns: $0 * 1_000_000) } ?? "its time budget"
        for result in benchmark.results where result.stoppedEarly {
            let who = benchmark.isComparison ? "\(result.label): " : ""
            notes.append("\(who)stopped after \(budget): \(result.iterations.formatted()) of \(result.requestedIterations?.formatted() ?? "?") iterations ran. Pass more seconds as bench()'s fourth argument to measure longer.")
        }
        notes += benchmark.notes
        if let overhead = benchmark.overheadNs, overhead > 0, let fastest = benchmark.results.compactMap(\.minNs).min(), fastest < overhead * 10 {
            notes.append("An empty call measures \(BenchmarkFormat.duration(ns: overhead)) here: times this short are mostly the timer itself.")
        }
        return notes
    }
}

/// The Benchmarks section: every benchmark of the run, in order.
struct BenchmarksSectionView: View {
    let tab: TabModel

    var body: some View {
        let records = tab.inspection.benchmarks
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if records.isEmpty {
                    ContentUnavailableView("No benchmarks", systemImage: "stopwatch", description: Text("Call Runlet\\bench(fn () => …) in a snippet to measure it."))
                        .frame(maxWidth: .infinity)
                }
                ForEach(records) { record in
                    BenchmarkCard(record: record, tab: tab)
                }
                OmittedRecordsNote(limit: tab.inspection.omitted(in: RunInspection.benchmarks))
            }
            .padding(10)
        }
        .accessibilityIdentifier("benchmarks-list")
    }
}
