<?php

declare(strict_types=1);

/*
 * Runlet benchmarks: Runlet\bench() and the benchmark records behind Runlet's benchmark card,
 * including Laravel's Benchmark::dd() (issue #41). Declared by the runner after the run
 * inspector (Inspector.php). See docs/drivers.md, "Benchmarks".
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace Runlet;

/**
 * Measures callables and records the results in the run inspector's "Benchmarks" section,
 * which Runlet shows as a card: min, mean, median, p95, max, operations per second, the
 * iterations that ran, memory, and the distribution of call times.
 *
 * Every measurement is bounded: at most MAX_ITERATIONS calls per callable, and it stops
 * early when a callable used up its time budget (the card then says how many calls ran).
 * Before measuring, each callable is called once cold and warmed up with a few more calls.
 */
final class Benchmark
{
    public const SECTION = 'Benchmarks';
    public const MAX_ITERATIONS = 100000;
    public const MAX_CALLABLES = 20;
    public const DEFAULT_ITERATIONS = 1000;
    /** Seconds each callable may use, when the call does not say. */
    public const DEFAULT_SECONDS = 1.0;
    public const MAX_SECONDS = 60.0;
    private const HISTOGRAM_BINS = 24;
    private const SERIES_POINTS = 48;
    private const MAX_WARMUP = 10;

    /** @var int The process's real peak memory before a benchmark reset it (PHP 8.2+). */
    private static $peakBeforeReset = 0;

    /**
     * Runs Runlet\bench(): see that function.
     *
     * @param mixed $subject a callable, or an array of callables keyed by label
     * @return array<int|string, mixed>
     */
    public static function bench($subject, int $iterations, ?string $label, ?float $seconds): array
    {
        $single = !is_array($subject) || is_callable($subject);
        $callables = $single ? [$label ?? 'bench()' => $subject] : $subject;
        if ($callables === []) {
            throw new \InvalidArgumentException('Runlet\bench() needs a callable, or an array of callables to compare.');
        }
        if (count($callables) > self::MAX_CALLABLES) {
            throw new \InvalidArgumentException('Runlet\bench() compares up to ' . self::MAX_CALLABLES . ' callables at a time; it got ' . count($callables) . '.');
        }
        foreach ($callables as $key => $callable) {
            if (!is_callable($callable)) {
                throw new \InvalidArgumentException('Runlet\bench(): "' . $key . '" is not callable.');
            }
        }

        $notes = [];
        $requested = $iterations;
        if ($iterations < 1) {
            $iterations = 1;
            $notes[] = 'Iterations below 1 count as 1.';
        } elseif ($iterations > self::MAX_ITERATIONS) {
            $iterations = self::MAX_ITERATIONS;
            $notes[] = 'Iterations are capped at ' . number_format(self::MAX_ITERATIONS) . ' per callable.';
        }
        $budget = $seconds ?? self::DEFAULT_SECONDS;
        if (!is_finite($budget) || $budget <= 0) {
            $budget = self::DEFAULT_SECONDS;
        } elseif ($budget > self::MAX_SECONDS) {
            $budget = self::MAX_SECONDS;
            $notes[] = 'The time budget is capped at ' . (int) self::MAX_SECONDS . ' s per callable.';
        }
        $budgetNs = (int) ($budget * 1e9);
        $overhead = self::timerOverhead();

        $results = [];
        $returned = [];
        foreach ($callables as $key => $callable) {
            $name = $single ? ($label ?? 'bench()') : (is_int($key) ? '#' . ($key + 1) : (string) $key);
            $result = self::measure($callable, $name, $iterations, $requested, $budgetNs);
            $results[] = $result;
            $returned[$key] = self::summary($result);
        }

        $title = $label ?? ($single ? 'bench()' : 'bench(): ' . count($callables) . ' callables');
        self::record($title, [
            'source' => 'runlet',
            'method' => 'bench',
            'results' => $results,
            'budgetMs' => round($budget * 1000, 3),
            'overheadNs' => $overhead,
            'php' => PHP_VERSION,
            'notes' => $notes,
        ]);

        return $single ? reset($returned) : $returned;
    }

    /**
     * Laravel's Benchmark::dd() dumps the average time of each callable ("1.234ms") and
     * exits. Runlet's dump handler calls this for that dump, so it also shows as a benchmark
     * card. Only the averages are known: Laravel measures nothing else.
     *
     * @param mixed $value what Benchmark::dd() dumped
     * @param array<int, mixed> $arguments Benchmark::dd()'s arguments (callables, iterations)
     */
    public static function recordLaravelDump($value, array $arguments): void
    {
        $iterations = isset($arguments[1]) && is_int($arguments[1]) ? max(1, $arguments[1]) : 1;
        $averages = is_array($value) ? $value : ['Benchmark::dd()' => $value];
        $results = [];
        foreach ($averages as $key => $average) {
            if (count($results) >= self::MAX_CALLABLES) {
                break;
            }
            $ms = self::laravelMilliseconds($average);
            if ($ms === null) {
                return;
            }
            $results[] = [
                'label' => is_int($key) ? '#' . ($key + 1) : (string) $key,
                'iterations' => $iterations,
                'meanNs' => round($ms * 1e6, 1),
                'averageOnly' => true,
            ];
        }
        if ($results === []) {
            return;
        }
        self::record('Benchmark::dd()', [
            'source' => 'laravel',
            'method' => 'Benchmark::dd',
            'results' => $results,
            'php' => PHP_VERSION,
            'notes' => ["Laravel's Benchmark reports the mean only (to the microsecond). Runlet\\bench() takes the same arguments and adds min, median, p95, memory, and the distribution."],
        ]);
    }

    /**
     * The real peak memory of this process, counting what a benchmark's
     * memory_reset_peak_usage() call hid.
     *
     * @internal
     */
    public static function realPeakMemory(): int
    {
        return max(self::$peakBeforeReset, memory_get_peak_usage(true));
    }

    /**
     * The p-quantile (0…1) of sorted values, interpolated linearly between the closest ranks.
     *
     * @internal
     * @param array<int, int|float> $sorted ascending
     */
    public static function percentile(array $sorted, float $p)
    {
        $count = count($sorted);
        if ($count === 0) {
            return 0;
        }
        $position = max(0.0, min(1.0, $p)) * ($count - 1);
        $lower = (int) floor($position);
        $upper = (int) ceil($position);
        if ($lower === $upper) {
            return $sorted[$lower];
        }

        return $sorted[$lower] + ($sorted[$upper] - $sorted[$lower]) * ($position - $lower);
    }

    /**
     * Statistics over call times in nanoseconds, in the order they ran: min, max, mean,
     * median, p95, p99, standard deviation, a histogram from min to p99 (slower calls are
     * counted in `above`), and up to SERIES_POINTS chunk means in run order.
     *
     * @internal
     * @param array<int, int> $samples
     * @return array<string, mixed>
     */
    public static function statistics(array $samples): array
    {
        $count = count($samples);
        if ($count === 0) {
            return ['minNs' => 0, 'maxNs' => 0, 'meanNs' => 0.0, 'medianNs' => 0.0, 'p95Ns' => 0.0, 'p99Ns' => 0.0, 'stddevNs' => 0.0, 'totalNs' => 0];
        }
        $sorted = $samples;
        sort($sorted);
        $total = array_sum($samples);
        $mean = $total / $count;
        $squares = 0.0;
        foreach ($samples as $sample) {
            $squares += ($sample - $mean) ** 2;
        }
        $p99 = self::percentile($sorted, 0.99);
        $stats = [
            'totalNs' => $total,
            'minNs' => $sorted[0],
            'maxNs' => $sorted[$count - 1],
            'meanNs' => round($mean, 1),
            'medianNs' => round((float) self::percentile($sorted, 0.5), 1),
            'p95Ns' => round((float) self::percentile($sorted, 0.95), 1),
            'p99Ns' => round((float) $p99, 1),
            'stddevNs' => round($count > 1 ? sqrt($squares / ($count - 1)) : 0.0, 1),
        ];

        $stats['histogram'] = self::histogram($sorted, (float) $p99);

        $points = min(self::SERIES_POINTS, $count);
        $series = [];
        for ($point = 0; $point < $points; $point++) {
            $from = intdiv($point * $count, $points);
            $to = intdiv(($point + 1) * $count, $points);
            $series[] = round(array_sum(array_slice($samples, $from, $to - $from)) / max(1, $to - $from), 1);
        }
        $stats['series'] = $series;

        return $stats;
    }

    /**
     * Call times from the fastest to p99 in up to HISTOGRAM_BINS equal bins (slower calls are
     * counted in `above`). Timers tick in steps (about 42 ns on Apple silicon), so when the
     * range spans fewer ticks than bins, each bin is one tick and none stays empty by rounding.
     *
     * @param array<int, int> $sorted ascending
     * @return array<string, mixed>
     */
    private static function histogram(array $sorted, float $p99): array
    {
        $count = count($sorted);
        $low = $sorted[0];
        $high = $p99 > $low ? $p99 : (float) $sorted[$count - 1];
        $step = 0;
        for ($i = 1; $i < $count; $i++) {
            $difference = $sorted[$i] - $sorted[$i - 1];
            if ($difference > 0 && ($step === 0 || $difference < $step)) {
                $step = $difference;
            }
        }
        $ticks = $step > 0 ? (int) round(($high - $low) / $step) + 1 : 1;
        $perTick = $step > 0 && $ticks <= self::HISTOGRAM_BINS;
        $binCount = $perTick ? $ticks : self::HISTOGRAM_BINS;
        $width = $perTick ? (float) $step : ($high - $low) / $binCount;
        $bins = array_fill(0, $binCount, 0);
        $above = 0;
        foreach ($sorted as $sample) {
            if ($sample > $high + ($perTick ? $step / 2 : 0)) {
                $above++;
                continue;
            }
            if ($width <= 0) {
                $bin = 0;
            } else {
                $bin = $perTick ? (int) round(($sample - $low) / $width) : (int) floor(($sample - $low) / $width);
            }
            $bins[max(0, min($binCount - 1, $bin))]++;
        }

        return ['lowNs' => $low, 'highNs' => round($high, 1), 'binNs' => round($width, 1), 'counts' => $bins, 'above' => $above];
    }

    /**
     * One callable: a cold call, a warm-up, then up to $iterations timed calls within the
     * budget, with memory measured around the timed calls.
     *
     * @return array<string, mixed>
     */
    private static function measure(callable $callable, string $label, int $iterations, int $requested, int $budgetNs): array
    {
        gc_collect_cycles();
        $before = memory_get_usage();
        $started = hrtime(true);
        $callable();
        $firstNs = hrtime(true) - $started;
        $firstBytes = memory_get_usage() - $before;

        // Warm-up: up to 1% of the iterations (at most 10) within a tenth of the budget.
        $warmup = 1;
        $warmTarget = min(self::MAX_WARMUP, intdiv($iterations, 100));
        $warmStarted = hrtime(true);
        while ($warmup <= $warmTarget && $firstNs < $budgetNs / 10 && hrtime(true) - $warmStarted < $budgetNs / 10) {
            $callable();
            $warmup++;
        }

        // The samples are preallocated, so they don't count as the callable's memory.
        $samples = new \SplFixedArray($iterations);
        gc_collect_cycles();
        $resetsPeak = function_exists('memory_reset_peak_usage');
        if ($resetsPeak) {
            self::$peakBeforeReset = max(self::$peakBeforeReset, memory_get_peak_usage(true));
            memory_reset_peak_usage();
        }
        $peakBefore = memory_get_peak_usage();
        $baseline = memory_get_usage();

        $count = 0;
        $stoppedBy = 'iterations';
        $start = hrtime(true);
        while ($count < $iterations) {
            $callStarted = hrtime(true);
            $callable();
            $ended = hrtime(true);
            $samples[$count++] = $ended - $callStarted;
            if ($ended - $start >= $budgetNs && $count < $iterations) {
                $stoppedBy = 'time';
                break;
            }
        }
        $retained = memory_get_usage() - $baseline;
        $peak = memory_get_peak_usage();

        $samples->setSize($count);
        $result = ['label' => $label, 'iterations' => $count, 'requestedIterations' => $requested, 'warmup' => $warmup, 'stoppedBy' => $stoppedBy, 'firstNs' => $firstNs]
            + self::statistics($samples->toArray());
        $mean = (float) $result['meanNs'];
        $result['opsPerSec'] = $mean > 0 ? round(1e9 / $mean, 2) : null;
        $result['memory'] = [
            // The highest memory use while the timed calls ran, above what was in use before.
            'peakBytes' => $resetsPeak || $peak > $peakBefore ? max(0, $peak - $baseline) : null,
            // Memory still held after the calls, per call (0 when the callable keeps nothing).
            'perCallBytes' => round($retained / max(1, $count), 1),
            'firstCallBytes' => $firstBytes,
        ];

        return $result;
    }

    /**
     * What a bench() call returns per callable: times in milliseconds, like Laravel's Benchmark.
     *
     * @param array<string, mixed> $result
     * @return array<string, mixed>
     */
    private static function summary(array $result): array
    {
        $ms = static function ($ns): float {
            return round((float) $ns / 1e6, 6);
        };

        return [
            'label' => $result['label'],
            'iterations' => $result['iterations'],
            'mean_ms' => $ms($result['meanNs']),
            'median_ms' => $ms($result['medianNs']),
            'min_ms' => $ms($result['minNs']),
            'max_ms' => $ms($result['maxNs']),
            'p95_ms' => $ms($result['p95Ns']),
            'ops_per_sec' => $result['opsPerSec'],
            'memory_peak_bytes' => $result['memory']['peakBytes'],
            'memory_per_call_bytes' => $result['memory']['perCallBytes'],
        ];
    }

    /** The median time of an empty call: the floor every measured call includes. */
    private static function timerOverhead(): float
    {
        $noop = static function (): void {
        };
        $samples = [];
        for ($i = 0; $i < 201; $i++) {
            $started = hrtime(true);
            $noop();
            $samples[] = hrtime(true) - $started;
        }
        sort($samples);

        return (float) $samples[100];
    }

    /** "1,234.567ms" (number_format()) as milliseconds, or null when it is something else. */
    private static function laravelMilliseconds($average): ?float
    {
        if (is_int($average) || is_float($average)) {
            return (float) $average;
        }
        if (!is_string($average) || !preg_match('/^\s*(-?[0-9][0-9,]*(?:\.[0-9]+)?)\s*ms\s*$/', $average, $match)) {
            return null;
        }

        return (float) str_replace(',', '', $match[1]);
    }

    /** @param array<string, mixed> $data */
    private static function record(string $title, array $data): void
    {
        $inspector = Inspector::current();
        if ($inspector !== null) {
            $inspector->measurement(self::SECTION, 'benchmark', $title, $data);
        }
    }
}

/**
 * Measures $callables and shows the result as a benchmark card in Runlet's output (and in the
 * Benchmarks section): min, mean, median, p95, max, operations per second, memory, and the
 * distribution of call times.
 *
 *     Runlet\bench(fn () => collect(range(1, 1000))->sum());
 *     Runlet\bench(['map' => fn () => array_map(...), 'loop' => fn () => ...], 500);
 *
 * Pass an array of callables, keyed by label, to compare them side by side. Each callable is
 * called once cold and warmed up, then up to $iterations times (at most 100,000) until it has
 * used $seconds (1 s by default, at most 60 s); the card says when the time budget ended it
 * early. Takes the same arguments as Laravel's Benchmark::measure().
 *
 * @param callable|array<int|string, callable> $callables
 * @param int $iterations timed calls per callable (1–100,000)
 * @param string|null $label the card's title
 * @param float|null $seconds time budget per callable, in seconds
 * @return array<int|string, mixed> times in milliseconds (`mean_ms`, `median_ms`, `min_ms`,
 *         `max_ms`, `p95_ms`), `ops_per_sec`, `iterations`, and memory; keyed like
 *         $callables when it is an array of callables
 */
function bench($callables, int $iterations = Benchmark::DEFAULT_ITERATIONS, ?string $label = null, ?float $seconds = null): array
{
    return Benchmark::bench($callables, $iterations, $label, $seconds);
}
