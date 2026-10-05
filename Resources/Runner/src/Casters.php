<?php

declare(strict_types=1);

/*
 * Driver casters (#6): a project's driver declares how its own types show in Runlet's output.
 *
 * Runlet never calls a value's methods to show it (no getters, __toString, __debugInfo, or
 * JSON serialization; see ValueNormalizer). A driver's casters() is the explicit exception:
 * trusted driver code, declared per class or interface, that runs only while a value of that
 * type is serialized for a result, a dump, a magic comment, or a run-inspector record.
 *
 * A cast object keeps its class and reference, and gets a `cast` field:
 *
 *     {"type": "object", "className": "Acme\\Money", "referenceId": "12", "summary": "€12.50",
 *      "count": 2, "entries": [{"key": "amount", "keyType": "field", "value": …}, …],
 *      "cast": {"by": "AcmeApiDriver", "type": "Acme\\Priced", "raw": {…the object as Runlet sees it…}}}
 *
 * `type` is the class or interface the caster is declared for, when it isn't the object's
 * own class. When the caster can't show the object (it threw, returned the object itself, or
 * the value's casters ran out of time), the node is the object as Runlet shows it without
 * that caster, and `cast.error` says why.
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace Runlet;

/**
 * What a caster returns to show a summary line and fields together:
 *
 *     Money::class => fn (Money $money) => new \Runlet\Cast($money->format(), [
 *         'amount' => $money->amount(),
 *         'currency' => $money->currency(),
 *     ]),
 */
final class Cast
{
    /** @var string */
    public $summary;
    /** @var array<mixed> */
    public $fields;

    /** @param array<mixed> $fields */
    public function __construct(string $summary, array $fields = [])
    {
        $this->summary = $summary;
        $this->fields = $fields;
    }
}

namespace RunletRunner;

/** The booted driver's casters, and how each object finds its own. */
final class Casters
{
    /** Each value's casters together get this long; then its other objects show as usual. */
    public const SECONDS_PER_VALUE = 1.0;
    /** A summary line is cut at this many bytes. */
    public const MAX_SUMMARY_BYTES = 1000;
    /** A caster's error is cut at this many bytes. */
    public const MAX_ERROR_BYTES = 300;

    /** @var array<string, array{name: string, caster: callable}> Lowercased name => the declared name and its caster. */
    private static $casters = [];
    /** @var array<string, array{name: string, caster: callable}|null> Class => its caster, once looked up. */
    private static $matches = [];
    /** @var string The driver's name, shown with each cast value. */
    private static $driver = '';
    /** @var int Casters running now: values they dump or record show as Runlet sees them. */
    private static $running = 0;

    /**
     * Reads the booted driver's casters() once per run, before the snippet. A failing
     * casters() is a notice, and values show as Runlet sees them; invalid entries are skipped
     * with a notice.
     */
    public static function load(\Runlet\Driver $driver, string $driverName): void
    {
        self::$casters = [];
        self::$matches = [];
        self::$driver = $driverName;
        try {
            $declared = Runner::callBootedDriver('casters()', static function () use ($driver): array {
                return $driver->casters();
            });
        } catch (\Throwable $error) {
            $message = $error instanceof DriverFailure ? $error->getMessage() : $driverName . ' failed in casters(): ' . $error->getMessage();
            Channel::emit('notice', ['message' => $message . ' Values show as Runlet sees them.']);

            return;
        }
        $skipped = [];
        foreach ($declared as $name => $caster) {
            $class = is_string($name) ? ltrim(trim($name), '\\') : '';
            if ($class === '' || !is_callable($caster)) {
                $skipped[] = is_string($name) ? ($name === '' ? '""' : $name) : '#' . $name;
                continue;
            }
            self::$casters[strtolower($class)] = ['name' => $class, 'caster' => $caster];
        }
        if ($skipped !== []) {
            Channel::emit('notice', ['message' => $driverName . ': casters() returned entries Runlet skipped, because each needs a class or interface name and a callable: ' . implode(', ', array_slice($skipped, 0, 10)) . (count($skipped) > 10 ? ' (' . (count($skipped) - 10) . ' more)' : '') . '.']);
        }
        if (self::$casters !== []) {
            $names = array_column(self::$casters, 'name');
            Runner::log('casters', $driverName . ' shows ' . count($names) . ' type' . (count($names) === 1 ? '' : 's') . ' with its casters', implode(', ', $names));
        }
    }

    /** Whether casters apply now: the driver declared some, and none is running. */
    public static function active(): bool
    {
        return self::$casters !== [] && self::$running === 0;
    }

    public static function driverName(): string
    {
        return self::$driver;
    }

    /**
     * The caster for an object: its own class first, then its parent classes, then the
     * interfaces it implements, in the order the driver declared them. Nothing is autoloaded.
     *
     * @return array{name: string, caster: callable}|null
     */
    public static function find(object $value): ?array
    {
        $class = get_class($value);
        if (array_key_exists($class, self::$matches)) {
            return self::$matches[$class];
        }
        $match = null;
        $parents = class_parents($value);
        foreach (array_merge([$class], $parents === false ? [] : array_values($parents)) as $name) {
            if (isset(self::$casters[strtolower($name)])) {
                $match = self::$casters[strtolower($name)];
                break;
            }
        }
        if ($match === null) {
            foreach (self::$casters as $entry) {
                $name = $entry['name'];
                if ($value instanceof $name) {
                    $match = $entry;
                    break;
                }
            }
        }

        return self::$matches[$class] = $match;
    }

    /**
     * Runs one caster: its result, or the error it threw, and the seconds it took.
     *
     * @return array{0: mixed, 1: string|null, 2: float}
     */
    public static function call(callable $caster, object $value): array
    {
        $started = microtime(true);
        self::$running++;
        try {
            $result = $caster($value);
            $error = null;
        } catch (\Throwable $thrown) {
            $result = null;
            $short = strrchr(get_class($thrown), '\\');
            $text = ($short === false ? get_class($thrown) : substr($short, 1)) . ': ' . str_replace(["\r\n", "\n", "\r"], ' ', $thrown->getMessage());
            [$error, $omitted] = \Runlet\Inspector::clip($text, self::MAX_ERROR_BYTES);
            $error .= $omitted > 0 ? '…' : '';
        } finally {
            self::$running--;
        }

        return [$result, $error, microtime(true) - $started];
    }
}

/**
 * ValueNormalizer's side of driver casters (#6): the cast node, its raw object, and the
 * fallbacks. A trait, so it works within the normalizer's own limits and budgets.
 */
trait CastsObjects
{
    /** @var bool Inside a raw object (Show Raw): no casters below it. */
    private $castsOff = false;
    /** @var int|null The object being shown without its caster (the caster failed). */
    private $castSkip;
    /** @var float Seconds the casters used for the value being normalized. */
    private $castSeconds = 0.0;
    /** @var int Nodes the value's raw objects may still use. */
    private $rawNodesLeft = 0;
    /** @var int Bytes the value's raw objects may still use. */
    private $rawBytesLeft = 0;
    /**
     * @var array<int, array{0: mixed, 1: string|null}>|null #307: while a value that holds
     * Eloquent models is walked twice (its Values tree, then its Object tree), each object's
     * caster result by object, so the second walk casts nothing again.
     */
    private $castResults;
    /** @var bool #307: the value's second walk: its casters' time goes on from the first. */
    private $castsContinue = false;

    /**
     * The object as the driver's caster shows it, or null when no caster applies (or the
     * caster returned null) and the normalizer goes on as usual.
     *
     * @param array<string, mixed> $node The object's node so far: id, type, className, referenceId.
     * @return array<string, mixed>|null
     */
    private function castObject(array $node, object $value, int $depth): ?array
    {
        if ($this->castsOff || !Casters::active()) {
            return null;
        }
        $objectId = spl_object_id($value);
        if ($this->castSkip === $objectId) {
            return null;
        }
        if (count($this->seenObjects) === 1) {
            // The value's first object (normalize() starts each value with none seen): a new
            // time limit (not for a value's second walk, #307), and a quarter of the walk's
            // budget for raw objects.
            if (!$this->castsContinue) {
                $this->castSeconds = 0.0;
            }
            $this->rawNodesLeft = intdiv($this->maxNodes, 4);
            $this->rawBytesLeft = intdiv($this->maxBytes, 4);
        }
        $match = Casters::find($value);
        if ($match === null) {
            return null;
        }
        $cast = ['by' => Casters::driverName()];
        if (strcasecmp($match['name'], get_class($value)) !== 0) {
            $cast['type'] = $match['name'];
        }
        if ($this->castResults !== null && array_key_exists($objectId, $this->castResults)) {
            // #307: cast in the value's first walk already.
            [$result, $error] = $this->castResults[$objectId];
        } else {
            if ($this->castSeconds >= Casters::SECONDS_PER_VALUE) {
                return $this->uncast($node, $value, $depth, $cast + ['error' => 'the casters took more than ' . Casters::SECONDS_PER_VALUE . ' s for this value']);
            }

            // A caster may dump or record values itself, which can reach this normalizer again
            // and start it over: put its state back afterwards.
            $state = get_object_vars($this);
            [$result, $error, $seconds] = Casters::call($match['caster'], $value);
            foreach ($state as $name => $saved) {
                $this->$name = $saved;
            }
            $this->castSeconds += $seconds;
            if ($this->castResults !== null) {
                $this->castResults[$objectId] = [$result, $error];
            }
        }

        if ($error !== null) {
            return $this->uncast($node, $value, $depth, $cast + ['error' => $error]);
        }
        if ($result === null) {
            return null;
        }
        if ($result === $value) {
            return $this->uncast($node, $value, $depth, $cast + ['error' => 'the caster returned the object itself']);
        }

        $summary = null;
        $fields = null;
        if ($result instanceof \Runlet\Cast) {
            $summary = $result->summary;
            $fields = $result->fields === [] ? null : $result->fields;
        } elseif (is_array($result)) {
            $fields = $result;
        } elseif (is_string($result)) {
            $summary = $result;
        } elseif (is_int($result)) {
            $summary = (string) $result;
        } elseif (is_float($result)) {
            $summary = self::floatString($result);
        } elseif (is_bool($result)) {
            $summary = $result ? 'true' : 'false';
        } else {
            // Another object or a resource: shown as the one field it is.
            $fields = ['value' => $result];
        }

        if ($summary !== null) {
            [$text, $omitted] = \Runlet\Inspector::clip($summary, min(Casters::MAX_SUMMARY_BYTES, max(0, $this->maxBytes - $this->bytes)));
            $node['summary'] = $text . ($omitted > 0 ? '…' : '');
            $this->bytes += strlen($node['summary']);
        }
        if ($fields !== null) {
            $node = $this->castFields($node, $fields, $depth);
        }
        $this->bytes += strlen($cast['by']) + strlen($cast['type'] ?? '');
        if ($depth < $this->maxDepth && ($raw = $this->rawObject($value, $depth)) !== null) {
            $cast['raw'] = $raw;
        }
        $node['cast'] = $cast;

        return $node;
    }

    /**
     * A caster's fields as the object's entries (`keyType` "field", or "int" for list keys),
     * each encoded as usual, under the same limits as properties.
     *
     * @param array<string, mixed> $node
     * @param array<mixed> $fields
     * @return array<string, mixed>
     */
    private function castFields(array $node, array $fields, int $depth): array
    {
        $count = count($fields);
        $node['count'] = $count;
        if ($count === 0) {
            $node['entries'] = [];

            return $node;
        }
        if ($depth >= $this->maxDepth) {
            $node['truncation'] = ['reason' => 'depth', 'omitted' => $count];

            return $node;
        }
        $entries = [];
        $shown = 0;
        foreach ($fields as $key => $field) {
            if ($shown >= $this->maxChildren || $this->overBudget()) {
                break;
            }
            $shown++;
            $entries[] = [
                'key' => is_int($key) ? (string) $key : $this->keyString((string) $key),
                'keyType' => is_int($key) ? 'int' : 'field',
                'value' => $this->node($field, $depth + 1),
            ];
        }
        $node['entries'] = $entries;
        if ($shown < $count) {
            $node['truncation'] = ['reason' => $this->budgetExceeded ? 'budget' : 'children', 'omitted' => $count - $shown];
        }

        return $node;
    }

    /**
     * The object as Runlet shows it without casters (Show Raw), with no casters below it
     * either, in what is left of the value's raw budget; null when that is used up.
     *
     * @return array<string, mixed>|null
     */
    private function rawObject(object $value, int $depth): ?array
    {
        if ($this->rawNodesLeft <= 0 || $this->rawBytesLeft <= 0 || $this->nodes >= $this->maxNodes || $this->bytes >= $this->maxBytes) {
            return null;
        }
        $nodes = $this->nodes;
        $bytes = $this->bytes;
        $saved = [$this->seenObjects, $this->maxNodes, $this->maxBytes, $this->budgetExceeded];
        // Objects first met in the raw object still show in full where the cast value has them.
        unset($this->seenObjects[spl_object_id($value)]);
        $this->maxNodes = min($this->maxNodes, $nodes + $this->rawNodesLeft);
        $this->maxBytes = min($this->maxBytes, $bytes + $this->rawBytesLeft);
        $this->castsOff = true;
        try {
            $raw = $this->node($value, $depth);
        } finally {
            [$this->seenObjects, $this->maxNodes, $this->maxBytes, $this->budgetExceeded] = $saved;
            $this->castsOff = false;
        }
        $this->rawNodesLeft -= $this->nodes - $nodes;
        $this->rawBytesLeft -= $this->bytes - $bytes;

        return $raw;
    }

    /**
     * The object as Runlet shows it without its caster, with the reason in `cast.error`.
     * Objects inside it still get their own casters.
     *
     * @param array<string, mixed> $node
     * @param array{by: string, type?: string, error: string} $cast
     * @return array<string, mixed>
     */
    private function uncast(array $node, object $value, int $depth, array $cast): array
    {
        $objectId = spl_object_id($value);
        $skip = $this->castSkip;
        $this->castSkip = $objectId;
        unset($this->seenObjects[$objectId]);
        try {
            $plain = $this->objectNode($node['id'], $value, $depth);
        } finally {
            $this->castSkip = $skip;
        }
        $this->bytes += strlen($cast['by']) + strlen($cast['type'] ?? '') + strlen($cast['error']);
        $plain['cast'] = $cast;

        return $plain;
    }
}
