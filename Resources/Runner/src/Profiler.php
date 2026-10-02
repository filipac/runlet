<?php

declare(strict_types=1);

/*
 * Runlet Profile Run: samples the snippet with the Excimer extension and reports the samples
 * as collapsed stacks for Runlet's flame graph (issue #41). Declared by the runner before
 * Runner.php. See docs/architecture.md, "Profile Run".
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace RunletRunner;

/**
 * One Profile Run's sampling profiler. Excimer (https://www.mediawiki.org/wiki/Excimer)
 * interrupts PHP every period and records the call stack. Only the snippet is profiled, not
 * the application's bootstrap, and the result is bounded: at most MAX_STACKS distinct stacks
 * (the rest are folded into "[other stacks]") of at most MAX_DEPTH frames each.
 *
 * SPX is detected but not used: it profiles only processes started with SPX_ENABLED=1 and
 * writes its reports to files in spx.data_dir (or stderr), with no API that hands the data to
 * the running script.
 */
final class Profiler
{
    public const SECTION = 'Profile';
    public const MAX_STACKS = 4000;
    public const MAX_DEPTH = 200;
    /** Distinct stacks kept while sampling, before the final cut to MAX_STACKS. */
    private const MAX_COLLECTED = 30000;
    private const MAX_COLLAPSED_BYTES = 2097152;
    private const FLUSH_ENTRIES = 2000;
    public const OTHER = '[other stacks]';
    public const DEEPER = '[deeper frames]';

    /** @var \ExcimerProfiler */
    private $excimer;
    /** @var string wall or cpu */
    private $eventType;
    /** @var float */
    private $periodMs;
    /** @var int */
    private $startedAt;
    /** @var int|null */
    private $stoppedAt;
    /** @var string */
    private $workingDirectory;
    /** @var array<string, int> collapsed stack => samples */
    private $stacks = [];
    /** @var array<string, array{file: string|null, inSnippet: bool, lines: array<int, int>}> */
    private $frames = [];
    /** @var int */
    private $samples = 0;
    /** @var int Samples outside the snippet (the runner's own code around it). */
    private $outside = 0;
    /** @var int Samples taken while this profiler aggregated its log. */
    private $overhead = 0;
    /** @var int */
    private $deep = 0;
    /** @var bool */
    private $collapsedOverflow = false;

    /**
     * The profiler extensions this PHP loads, with their versions.
     *
     * @return array<string, string>
     */
    public static function loaded(): array
    {
        $loaded = [];
        foreach (['excimer', 'spx'] as $extension) {
            if (extension_loaded($extension)) {
                $version = phpversion($extension);
                $loaded[$extension] = is_string($version) ? $version : '';
            }
        }

        return $loaded;
    }

    /** Why this PHP can't profile a run, or null when it can. */
    public static function unavailableReason(): ?string
    {
        if (class_exists('ExcimerProfiler', false)) {
            return null;
        }
        $php = 'PHP ' . PHP_VERSION . ' (' . PHP_BINARY . ')';
        if (extension_loaded('spx')) {
            return 'Profile Run uses the Excimer extension. ' . $php . ' loads SPX, which Runlet can\'t read profiles from (SPX writes them to files in spx.data_dir and only profiles processes started with SPX_ENABLED=1). Install Excimer to profile here. Nothing ran.';
        }

        return 'Profile Run needs the Excimer extension, and ' . $php . ' doesn\'t load it. Install it (pecl install excimer, or the php-excimer package) and run again. Nothing ran.';
    }

    /** @param array<string, mixed> $options `periodMs` (default 1) and `eventType` (`wall` or `cpu`) */
    public static function start(array $options, string $workingDirectory): self
    {
        $profiler = new self();
        $profiler->workingDirectory = rtrim($workingDirectory, '/');
        $period = isset($options['periodMs']) && is_numeric($options['periodMs']) ? (float) $options['periodMs'] : 1.0;
        $profiler->periodMs = max(0.1, min(1000.0, $period));
        $cpu = ($options['eventType'] ?? 'wall') === 'cpu' && defined('EXCIMER_CPU') && PHP_OS_FAMILY !== 'Darwin';
        $profiler->eventType = $cpu ? 'cpu' : 'wall';

        $excimer = new \ExcimerProfiler();
        $excimer->setPeriod($profiler->periodMs / 1000);
        $excimer->setEventType($cpu ? EXCIMER_CPU : EXCIMER_REAL);
        $excimer->setFlushCallback(static function ($log) use ($profiler): void {
            $profiler->collect($log);
        }, self::FLUSH_ENTRIES);
        $profiler->excimer = $excimer;
        $profiler->startedAt = hrtime(true);
        $excimer->start();

        return $profiler;
    }

    /** Stops sampling; safe to call more than once. */
    public function stop(): void
    {
        if ($this->stoppedAt !== null) {
            return;
        }
        $this->excimer->stop();
        $this->stoppedAt = hrtime(true);
        $this->collect($this->excimer->getLog());
    }

    /**
     * The `profile` record: collapsed stacks (root first, "frame;frame;frame count" per
     * line), what each frame name stands for, and what the bounds left out.
     *
     * @return array<string, mixed>
     */
    public function record(): array
    {
        $this->stop();
        arsort($this->stacks);
        $lines = [];
        $bytes = 0;
        $kept = 0;
        $folded = 0;
        $foldedStacks = 0;
        $used = [];
        foreach ($this->stacks as $stack => $count) {
            $stack = (string) $stack;
            if ($stack === self::OTHER || $kept >= self::MAX_STACKS || $bytes + strlen($stack) + 12 > self::MAX_COLLAPSED_BYTES) {
                $folded += $count;
                $foldedStacks += $stack === self::OTHER ? 0 : 1;
                continue;
            }
            $kept++;
            $lines[] = $stack . ' ' . $count;
            $bytes += strlen($stack) + 12;
            foreach (explode(';', $stack) as $name) {
                $used[$name] = true;
            }
        }
        if ($folded > 0) {
            $lines[] = self::OTHER . ' ' . $folded;
        }

        $frames = [];
        foreach ($used as $name => $true) {
            $frame = $this->frames[$name] ?? null;
            if ($frame === null) {
                continue;
            }
            arsort($frame['lines']);
            $entry = ['line' => (int) key($frame['lines'])];
            if ($frame['inSnippet']) {
                $entry['inSnippet'] = true;
            } elseif ($frame['file'] !== null) {
                $entry['file'] = $frame['file'];
            }
            $frames[(string) $name] = $entry;
        }

        $truncated = [];
        if ($foldedStacks > 0 || $this->collapsedOverflow) {
            $truncated['stacks'] = $foldedStacks;
            $truncated['foldedSamples'] = $folded;
        }
        if ($this->deep > 0) {
            $truncated['deepSamples'] = $this->deep;
        }

        return [
            'engine' => 'excimer',
            'version' => (string) phpversion('excimer'),
            'eventType' => $this->eventType,
            'periodMs' => $this->periodMs,
            'samples' => $this->samples,
            'durationMs' => round((($this->stoppedAt ?? hrtime(true)) - $this->startedAt) / 1e6, 3),
            'outsideSamples' => $this->outside + $this->overhead,
            'maxStacks' => self::MAX_STACKS,
            'maxDepth' => self::MAX_DEPTH,
            'collapsed' => implode("\n", $lines),
            'frames' => (object) $frames,
            'truncated' => (object) $truncated,
            'php' => PHP_VERSION,
        ];
    }

    /** Adds a log's samples to the collapsed stacks (also Excimer's flush callback). */
    private function collect(\ExcimerLog $log): void
    {
        foreach ($log as $entry) {
            $count = (int) $entry->getEventCount();
            if ($count <= 0) {
                continue;
            }
            $trace = $entry->getTrace();
            // Innermost frame first; the snippet is what Runner::evaluate() evaluates.
            $evaluate = null;
            foreach ($trace as $index => $frame) {
                $class = $frame['class'] ?? '';
                if ($class === __CLASS__) {
                    $this->overhead += $count;
                    continue 2;
                }
                if ($class === Runner::class && ($frame['function'] ?? '') === 'evaluate') {
                    $evaluate = $index;
                    break;
                }
            }
            if ($evaluate === null || $evaluate === 0) {
                $this->outside += $count;
                continue;
            }
            $this->samples += $count;
            $names = [];
            for ($index = $evaluate - 1; $index >= 0; $index--) {
                if (count($names) >= self::MAX_DEPTH - 1 && $index > 0) {
                    $names[] = self::DEEPER;
                    $this->deep += $count;
                    break;
                }
                $names[] = $this->frameName($trace[$index], $index === $evaluate - 1, $count);
            }
            $stack = implode(';', $names);
            if (!isset($this->stacks[$stack]) && count($this->stacks) >= self::MAX_COLLECTED) {
                $stack = self::OTHER;
                $this->collapsedOverflow = true;
            }
            $this->stacks[$stack] = ($this->stacks[$stack] ?? 0) + $count;
        }
    }

    /**
     * A frame's name in the collapsed stacks: `snippet:<line>` for the snippet's own lines,
     * `Class::method`, `function`, `{closure:<file>:<line>}`, or an included file's path.
     *
     * @param array<string, mixed> $frame
     */
    private function frameName(array $frame, bool $snippetRoot, int $count): string
    {
        $file = isset($frame['file']) && is_string($frame['file']) ? $frame['file'] : '';
        $line = isset($frame['line']) && is_int($frame['line']) ? $frame['line'] : 0;
        $inSnippet = $file !== '' && Runner::isSnippetFile($file);
        $function = isset($frame['function']) && is_string($frame['function']) ? $frame['function'] : '';
        $class = isset($frame['class']) && is_string($frame['class']) ? \Runlet\Inspector::className($frame['class']) : '';
        if ($snippetRoot && $function === '') {
            $name = 'snippet:' . $line;
        } elseif ($function !== '' && strpos($function, '{closure') === 0) {
            $where = $inSnippet ? 'snippet' : basename($file);
            $name = '{closure:' . $where . ':' . (int) ($frame['closure_line'] ?? $line) . '}';
        } elseif ($function !== '') {
            $name = ($class !== '' ? $class . '::' : '') . $function;
        } elseif (substr($file, -13) === "eval()'d code") {
            $name = $inSnippet ? 'snippet:' . $line : "eval()'d code";
        } else {
            $name = $this->relative($file);
        }
        $name = str_replace([';', "\n", "\r"], [',', ' ', ' '], $name);
        if (!isset($this->frames[$name])) {
            $this->frames[$name] = ['file' => $inSnippet || $file === '' ? null : $file, 'inSnippet' => $inSnippet, 'lines' => []];
        }
        $lines = &$this->frames[$name]['lines'];
        if (isset($lines[$line]) || count($lines) < 64) {
            $lines[$line] = ($lines[$line] ?? 0) + $count;
        }

        return $name;
    }

    private function relative(string $file): string
    {
        if ($file === '') {
            return '{main}';
        }
        $prefix = $this->workingDirectory . '/';

        return $this->workingDirectory !== '' && strpos($file, $prefix) === 0 ? substr($file, strlen($prefix)) : $file;
    }
}
