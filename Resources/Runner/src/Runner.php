<?php

declare(strict_types=1);

/*
 * Runlet PHP runner.
 *
 * Executed once per run by a fresh PHP CLI process (local or `docker exec`). The
 * whole bundle (this file plus a namespace-scoped copy of nikic/php-parser) is
 * streamed to `php` on stdin, followed by a call to Runner::main() carrying the
 * base64-encoded request. Nothing is written into the user's project or container.
 *
 * Machine events are written to stdout as nonce-framed records:
 *
 *     "\x1e" . "RL1:" . <nonce> . ":" . <byte length> . ":" . <json> . "\n"
 *
 * Everything else on stdout/stderr is the application's own raw output. The
 * nonce is random per run, so snippet output cannot forge or corrupt a frame.
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace RunletRunner;

final class NoResult
{
    /** @var NoResult|null */
    private static $instance;

    public static function instance(): self
    {
        if (self::$instance === null) {
            self::$instance = new self();
        }

        return self::$instance;
    }
}

final class Channel
{
    /** @var resource */
    private static $stream;
    /** @var string */
    private static $nonce = '';

    public static function open(string $nonce): void
    {
        self::$nonce = $nonce;
        $stream = fopen('php://stdout', 'wb');
        if ($stream === false) {
            throw new \RuntimeException('Runlet runner could not open stdout');
        }
        self::$stream = $stream;
    }

    /** @param array<string, mixed> $payload */
    public static function emit(string $type, array $payload): void
    {
        $json = json_encode(
            ['type' => $type, 'payload' => $payload],
            JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRESERVE_ZERO_FRACTION | JSON_PARTIAL_OUTPUT_ON_ERROR
        );
        if ($json === false) {
            $json = json_encode(['type' => 'error', 'payload' => [
                'stage' => 'transport',
                'message' => 'Runlet could not encode a ' . $type . ' event: ' . json_last_error_msg(),
            ]]);
        }
        $frame = "\x1eRL1:" . self::$nonce . ':' . strlen((string) $json) . ':' . $json . "\n";
        $length = strlen($frame);
        $written = 0;
        while ($written < $length) {
            $result = @fwrite(self::$stream, substr($frame, $written));
            if ($result === false || $result === 0) {
                return;
            }
            $written += $result;
        }
        @fflush(self::$stream);
    }
}

/**
 * Converts arbitrary PHP values into bounded ValueNode trees without invoking
 * user code: no getters, __toString, __debugInfo, __get, or JSON serialization.
 */
final class ValueNormalizer
{
    /** @var int */
    private $maxDepth;
    /** @var int */
    private $maxChildren;
    /** @var int */
    private $maxStringBytes;
    /** @var int */
    private $maxNodes;
    /** @var int */
    private $maxBytes;

    /** @var int */
    private $nextId = 1;
    /** @var int */
    private $nodes = 0;
    /** @var int */
    private $bytes = 0;
    /** @var array<int, true> */
    private $seenObjects = [];
    /** @var array<string, true> */
    private $activeReferences = [];
    /** @var bool */
    private $budgetExceeded = false;

    /** @param array<string, int> $limits */
    public function __construct(array $limits)
    {
        $this->maxDepth = (int) ($limits['maxDepth'] ?? 8);
        $this->maxChildren = (int) ($limits['maxChildren'] ?? 200);
        $this->maxStringBytes = (int) ($limits['maxStringBytes'] ?? 65536);
        $this->maxNodes = (int) ($limits['maxNodes'] ?? 20000);
        $this->maxBytes = (int) ($limits['maxValueBytes'] ?? 2097152);
    }

    /**
     * @param mixed $value
     * @return array<string, mixed>
     */
    public function normalize($value): array
    {
        $this->nextId = 1;
        $this->nodes = 0;
        $this->bytes = 0;
        $this->seenObjects = [];
        $this->activeReferences = [];
        $this->budgetExceeded = false;

        $node = $this->node($value, 0);
        if ($this->budgetExceeded) {
            $node['budgetExceeded'] = true;
        }

        return $node;
    }

    /**
     * @param mixed $value
     * @return array<string, mixed>
     */
    private function node($value, int $depth): array
    {
        $this->nodes++;
        $id = $this->nextId++;

        if ($value === null) {
            return ['id' => $id, 'type' => 'null'];
        }
        if (is_bool($value)) {
            return ['id' => $id, 'type' => 'bool', 'scalar' => $value ? 'true' : 'false'];
        }
        if (is_int($value)) {
            return ['id' => $id, 'type' => 'int', 'scalar' => (string) $value];
        }
        if (is_float($value)) {
            return ['id' => $id, 'type' => 'float', 'scalar' => self::floatString($value)];
        }
        if (is_string($value)) {
            return $this->stringNode($id, $value);
        }
        if (is_array($value)) {
            return $this->arrayNode($id, $value, $depth);
        }
        if (is_object($value)) {
            return $this->objectNode($id, $value, $depth);
        }
        if (is_resource($value) || gettype($value) === 'resource (closed)') {
            return [
                'id' => $id,
                'type' => 'resource',
                'className' => is_resource($value) ? get_resource_type($value) : 'closed',
                'scalar' => (string) (int) $value,
            ];
        }

        return ['id' => $id, 'type' => 'unknown', 'scalar' => gettype($value)];
    }

    public static function floatString(float $value): string
    {
        if (is_nan($value)) {
            return 'NAN';
        }
        if (is_infinite($value)) {
            return $value > 0 ? 'INF' : '-INF';
        }
        $string = var_export($value, true);

        return $string;
    }

    /** @return array<string, mixed> */
    private function stringNode(int $id, string $value): array
    {
        $length = strlen($value);
        $truncatedBy = 0;
        $limit = min($this->maxStringBytes, max(0, $this->maxBytes - $this->bytes));
        if ($length > $limit) {
            $truncatedBy = $length - $limit;
            $value = substr($value, 0, $limit);
            if ($limit < $this->maxStringBytes) {
                $this->budgetExceeded = true;
            }
        }
        $this->bytes += strlen($value);

        $node = ['id' => $id, 'type' => 'string', 'length' => $length];
        if (self::isValidUtf8($value)) {
            $node['scalar'] = $value;
        } else {
            // Keep a valid UTF-8 prefix if the cut split a multibyte sequence.
            if ($truncatedBy > 0 && self::isValidUtf8(self::trimPartialUtf8($value))) {
                $node['scalar'] = self::trimPartialUtf8($value);
            } else {
                $node['scalar'] = base64_encode($value);
                $node['encoding'] = 'base64';
            }
        }
        if ($truncatedBy > 0) {
            $node['truncation'] = ['reason' => 'length', 'omitted' => $truncatedBy];
        }

        return $node;
    }

    private static function isValidUtf8(string $value): bool
    {
        return preg_match('//u', $value) === 1;
    }

    private static function trimPartialUtf8(string $value): string
    {
        for ($i = 0; $i < 4 && $value !== ''; $i++) {
            if (self::isValidUtf8($value)) {
                return $value;
            }
            $value = substr($value, 0, -1);
        }

        return $value;
    }

    /**
     * @param array<mixed> $value
     * @return array<string, mixed>
     */
    private function arrayNode(int $id, array $value, int $depth): array
    {
        $count = count($value);
        $node = ['id' => $id, 'type' => 'array', 'count' => $count];
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
        foreach ($value as $key => $_) {
            if ($shown >= $this->maxChildren || $this->overBudget()) {
                break;
            }
            $shown++;
            $entry = ['key' => is_int($key) ? (string) $key : $this->keyString((string) $key), 'keyType' => is_int($key) ? 'int' : 'string'];

            $refId = null;
            if (class_exists(\ReflectionReference::class)) {
                $reference = \ReflectionReference::fromArrayElement($value, $key);
                if ($reference !== null) {
                    $refId = $reference->getId();
                }
            }

            if ($refId !== null && isset($this->activeReferences[$refId])) {
                // A PHP reference that points back at an array already being walked.
                $this->nodes++;
                $entry['value'] = ['id' => $this->nextId++, 'type' => 'array', 'recursion' => true, 'referenceId' => substr(md5($refId), 0, 12)];
            } else {
                if ($refId !== null) {
                    $this->activeReferences[$refId] = true;
                }
                $entry['value'] = $this->node($value[$key], $depth + 1);
                if ($refId !== null) {
                    unset($this->activeReferences[$refId]);
                    $entry['isReference'] = true;
                }
            }
            $entries[] = $entry;
        }

        $node['entries'] = $entries;
        if ($shown < $count) {
            $node['truncation'] = ['reason' => $this->budgetExceeded ? 'budget' : 'children', 'omitted' => $count - $shown];
        }

        return $node;
    }

    private function keyString(string $key): string
    {
        $this->bytes += strlen($key);
        if (self::isValidUtf8($key)) {
            return $key;
        }

        return 'base64:' . base64_encode($key);
    }

    private function overBudget(): bool
    {
        if ($this->nodes >= $this->maxNodes || $this->bytes >= $this->maxBytes) {
            $this->budgetExceeded = true;

            return true;
        }

        return false;
    }

    /** @return array<string, mixed> */
    private function objectNode(int $id, object $value, int $depth): array
    {
        $class = get_class($value);
        $objectId = spl_object_id($value);
        // Anonymous classes are named "class@anonymous<NUL>/path:line$0": show the readable part.
        $node = ['id' => $id, 'type' => 'object', 'className' => \Runlet\Inspector::className($class), 'referenceId' => (string) $objectId];

        if (function_exists('enum_exists') && $value instanceof \UnitEnum) {
            $node['type'] = 'enum';
            $node['scalar'] = $value->name;
            if ($value instanceof \BackedEnum) {
                $backing = $value->value;
                $node['backingValue'] = is_int($backing) ? (string) $backing : $backing;
            }

            return $node;
        }

        if (isset($this->seenObjects[$objectId])) {
            $node['repeated'] = true;

            return $node;
        }
        $this->seenObjects[$objectId] = true;

        if ($value instanceof \Closure) {
            $node['type'] = 'closure';
            try {
                $reflection = new \ReflectionFunction($value);
                $file = $reflection->getFileName();
                $node['summary'] = ($file !== false ? $file : 'internal') . ':' . (int) $reflection->getStartLine();
            } catch (\Throwable $e) {
                // Leave the closure without a location.
            }

            return $node;
        }

        if ($value instanceof \DateTimeInterface) {
            $node['summary'] = $value->format('Y-m-d H:i:s.u P') . ' (' . $value->getTimezone()->getName() . ')';
        }

        if ($depth >= $this->maxDepth) {
            $node['truncation'] = ['reason' => 'depth', 'omitted' => -1];

            return $node;
        }

        $properties = function_exists('get_mangled_object_vars') ? get_mangled_object_vars($value) : (array) $value;
        if ($value instanceof \ArrayObject || $value instanceof \ArrayIterator) {
            $properties["\0" . get_class($value) . "\0storage"] = $value->getArrayCopy();
        }

        $count = count($properties);
        $node['count'] = $count;
        $entries = [];
        $shown = 0;
        foreach ($properties as $mangled => $propertyValue) {
            if ($shown >= $this->maxChildren || $this->overBudget()) {
                break;
            }
            $shown++;
            $mangled = (string) $mangled;
            $visibility = 'public';
            $declaringClass = null;
            $name = $mangled;
            if ($mangled !== '' && $mangled[0] === "\0") {
                $parts = explode("\0", $mangled, 3);
                $name = $parts[2] ?? $mangled;
                if (($parts[1] ?? '') === '*') {
                    $visibility = 'protected';
                } else {
                    $visibility = 'private';
                    $declaringClass = $parts[1] ?? null;
                }
            }
            $entry = ['key' => $this->keyString($name), 'keyType' => 'property', 'visibility' => $visibility];
            if ($declaringClass !== null && $declaringClass !== $class) {
                $entry['declaringClass'] = $declaringClass;
            }
            $entry['value'] = $this->node($propertyValue, $depth + 1);
            $entries[] = $entry;
        }
        $node['entries'] = $entries;
        if ($shown < $count) {
            $node['truncation'] = ['reason' => $this->budgetExceeded ? 'budget' : 'children', 'omitted' => $count - $shown];
        }

        return $node;
    }
}

final class SnippetCompiler
{
    /** Prefix added in front of tagless snippets. Same line, so line numbers stay intact. */
    public const TAG_PREFIX = '<?php ';

    /** Inserted on the opening tag's line when the run asks for strict types. */
    public const STRICT_TYPES = 'declare(strict_types=1);';

    /**
     * Returns [evalCode, prefixLength, hasImplicitResult, notice, magic].
     *
     * With $strictTypes, `declare(strict_types=1);` becomes the first statement unless the
     * snippet declares strict_types itself. Magic comments (`//?`, `/*?*\/`, …) become probe
     * calls inserted on their own lines; `magic` lists them (`probes`, `rejected`, and a
     * `notice` when they could not be added), or is null without magic comments. Line numbers
     * never change.
     *
     * @return array{0: string, 1: int, 2: bool, 3: string|null, 4: array{probes: array<int, array{line: int, kind: string, comment: string}>, rejected: array<int, array{line: int, comment: string, reason: string}>}|null}
     */
    public static function compile(string $code, bool $strictTypes = false, bool $magicComments = true): array
    {
        $prefix = '';
        if (!preg_match('/^\s*<\?php\b/', $code) && !preg_match('/^\s*<\?=/', $code)) {
            $prefix = self::TAG_PREFIX;
        }
        $source = $prefix . $code;
        $applyStrictTypes = $strictTypes && !self::declaresStrictTypes($source);

        if (!function_exists('token_get_all') || !class_exists(\RunletVendor\PhpParser\ParserFactory::class)) {
            $source .= "\n;return \\RunletRunner\\NoResult::instance();";

            return [self::evalReady($applyStrictTypes ? self::withStrictTypes($source) : $source), strlen($prefix), false, 'The tokenizer extension is unavailable, so the final expression value is not captured.'];
        }

        $parser = (new \RunletVendor\PhpParser\ParserFactory())->createForHostVersion();
        $statements = null;
        $firstError = null;
        try {
            $statements = $parser->parse($source);
        } catch (\RunletVendor\PhpParser\Error $error) {
            $firstError = $error;
            // An omitted final semicolon is accepted when the snippet is otherwise valid.
            try {
                $withSemicolon = $source . "\n;";
                $statements = $parser->parse($withSemicolon);
                $source = $withSemicolon;
            } catch (\RunletVendor\PhpParser\Error $ignored) {
                throw new SnippetParseError($firstError->getRawMessage(), $firstError->getStartLine(), self::column($source, $firstError), strlen($prefix));
            }
        }

        if ($statements === null) {
            $statements = [];
        }

        $list = $statements;
        $container = null;
        while (count($list) > 0) {
            $last = self::lastStatement($list);
            if ($last instanceof \RunletVendor\PhpParser\Node\Stmt\Namespace_) {
                $container = $last;
                $list = $last->stmts ?? [];
                continue;
            }
            break;
        }

        // Trailing comments (`1 + 1; // note`) become Nop statements: skip them.
        $last = self::lastStatement($list);
        $hasResult = false;
        $returned = null;
        /** @var array<int, array<int, mixed>> $edits [offset, deleteLength, text, group, key1, key2]; see applyEdits() */
        $edits = [];
        if ($last instanceof \RunletVendor\PhpParser\Node\Stmt\Expression && !($last->expr instanceof \RunletVendor\PhpParser\Node\Expr\Exit_)) {
            // `<expr> …;` becomes `return <expr>;`.
            $start = $last->getStartFilePos();
            $end = $last->getEndFilePos();
            $exprStart = $last->expr->getStartFilePos();
            $exprEnd = $last->expr->getEndFilePos();
            if ($start < $exprStart) {
                $edits[] = [$start, $exprStart - $start, '', 1, 0, 0];
            }
            $edits[] = [$exprStart, 0, 'return ', 3, 0, 0];
            $edits[] = [$exprEnd + 1, $end - $exprEnd, ';', 1, 0, 0];
            $hasResult = true;
            $returned = $last;
        } elseif ($last instanceof \RunletVendor\PhpParser\Node\Stmt\Return_) {
            $hasResult = true;
        }

        $sentinel = "\nreturn \\RunletRunner\\NoResult::instance();";
        if ($container !== null && self::isBracedNamespace($source, $container)) {
            $edits[] = [$container->getEndFilePos(), 0, $sentinel . "\n", 1, 0, 0];
        } else {
            $edits[] = [strlen($source), 0, (self::endsOutsidePhp($source) ? '<?php ' : '') . $sentinel, 1, 0, 0];
        }

        $plain = self::applyEdits($source, $edits);
        $magic = null;
        // Magic comments turned off (Settings): they stay ordinary comments, nothing is added.
        if ($magicComments && MagicComments::mentioned($source)) {
            [$plain, $magic] = self::instrument($source, $statements, $parser, $edits, $plain, $returned);
        }
        // Last: the edits above never touch the opening tag, so their offsets stay valid.
        if ($applyStrictTypes) {
            $plain = self::withStrictTypes($plain);
        }

        return [self::evalReady($plain), strlen($prefix), $hasResult, null, $magic];
    }

    /**
     * Adds the magic comments' probes to the compiled source. The instrumented source must
     * parse and keep every line where it was; otherwise the snippet runs without probes.
     *
     * @param \RunletVendor\PhpParser\Node\Stmt[] $statements
     * @param \RunletVendor\PhpParser\Parser $parser
     * @param array<int, array<int, mixed>> $edits
     * @return array{0: string, 1: array{probes: array<int, array{line: int, kind: string, comment: string}>, rejected: array<int, array{line: int, comment: string, reason: string}>, notice?: string}|null}
     */
    private static function instrument(string $source, array $statements, $parser, array $edits, string $plain, ?\RunletVendor\PhpParser\Node\Stmt\Expression $returned): array
    {
        try {
            $plan = MagicComments::plan($source, $statements, $parser, $returned);
        } catch (\Throwable $error) {
            return [$plain, ['probes' => [], 'rejected' => [], 'notice' => 'Runlet could not read the magic comments in this snippet (' . $error->getMessage() . '), so it runs without them.']];
        }
        if ($plan['probes'] === [] && $plan['rejected'] === []) {
            return [$plain, null];
        }
        $magic = ['probes' => $plan['probes'], 'rejected' => $plan['rejected']];
        if ($plan['probes'] === []) {
            return [$plain, $magic];
        }
        $problem = null;
        try {
            $instrumented = self::applyEdits($source, array_merge($edits, $plan['edits']));
            if (substr_count($instrumented, "\n") !== substr_count($plain, "\n")) {
                $problem = 'the lines moved';
            } else {
                $parser->parse($instrumented);
            }
        } catch (\Throwable $error) {
            $problem = $error->getMessage();
        }
        if ($problem !== null || !isset($instrumented)) {
            // Never run differently because of a probe: drop them all and say so.
            foreach ($plan['probes'] as $probe) {
                $magic['rejected'][] = ['line' => $probe['line'], 'comment' => $probe['comment'], 'reason' => 'Runlet could not add this probe to the snippet.', 'label' => 'not added'];
            }
            usort($magic['rejected'], static function (array $a, array $b): int {
                return $a['line'] <=> $b['line'];
            });
            $magic['probes'] = [];
            $magic['notice'] = 'Runlet could not add the magic comments\' probes to this snippet (' . $problem . '), so it runs without them.';

            return [$plain, $magic];
        }

        return [$instrumented, $magic];
    }

    /**
     * Applies insertions and replacements, back to front so earlier offsets stay valid.
     * Edits at one offset are joined in (group, key1, key2) order: closing parts first, then
     * replacements, inserted statements, `return `, and opening calls (outermost first).
     *
     * @param array<int, array<int, mixed>> $edits [offset, deleteLength, text, group, key1, key2]
     */
    private static function applyEdits(string $source, array $edits): string
    {
        $byOffset = [];
        $deletions = [];
        foreach ($edits as $edit) {
            $byOffset[(int) $edit[0]][] = $edit;
            if ($edit[1] > 0) {
                $deletions[] = [(int) $edit[0], (int) $edit[0] + (int) $edit[1]];
            }
        }
        foreach ($deletions as [$from, $to]) {
            foreach (array_keys($byOffset) as $offset) {
                if ($offset > $from && $offset < $to) {
                    throw new \RuntimeException('overlapping edits at offset ' . $offset);
                }
            }
        }
        krsort($byOffset);
        foreach ($byOffset as $offset => $group) {
            usort($group, static function (array $a, array $b): int {
                return [$a[3], $a[4], $a[5]] <=> [$b[3], $b[4], $b[5]];
            });
            $text = '';
            $delete = 0;
            foreach ($group as $edit) {
                $text .= $edit[2];
                $delete += (int) $edit[1];
            }
            $source = substr($source, 0, $offset) . $text . substr($source, $offset + $delete);
        }

        return $source;
    }

    /**
     * The last statement that is not a Nop (comments after the last statement).
     *
     * @param \RunletVendor\PhpParser\Node\Stmt[] $list
     */
    private static function lastStatement(array $list): ?\RunletVendor\PhpParser\Node\Stmt
    {
        for ($i = count($list) - 1; $i >= 0; $i--) {
            if (!$list[$i] instanceof \RunletVendor\PhpParser\Node\Stmt\Nop) {
                return $list[$i];
            }
        }

        return null;
    }

    /**
     * Whether the snippet has its own `declare(strict_types=…)` (either value), which
     * always wins over the setting.
     */
    public static function declaresStrictTypes(string $source): bool
    {
        if (!function_exists('token_get_all')) {
            return preg_match('/\bdeclare\s*\(\s*strict_types\s*=/i', $source) === 1;
        }
        $tokens = token_get_all($source);
        $count = count($tokens);
        for ($i = 0; $i < $count; $i++) {
            if (!is_array($tokens[$i]) || $tokens[$i][0] !== T_DECLARE) {
                continue;
            }
            $sawParenthesis = false;
            for ($j = $i + 1; $j < $count; $j++) {
                $token = $tokens[$j];
                if (is_array($token) && in_array($token[0], [T_WHITESPACE, T_COMMENT, T_DOC_COMMENT], true)) {
                    continue;
                }
                if (!$sawParenthesis) {
                    if ($token !== '(') {
                        break;
                    }
                    $sawParenthesis = true;
                    continue;
                }
                if (is_array($token) && $token[0] === T_STRING && strtolower($token[1]) === 'strict_types') {
                    return true;
                }
                break;
            }
        }

        return false;
    }

    /**
     * Makes `declare(strict_types=1);` the first statement on the opening tag's line, so
     * no line number changes. Whitespace before a snippet's own `<?php` (inline output,
     * which PHP does not allow before the declaration) moves after the declaration.
     */
    private static function withStrictTypes(string $source): string
    {
        if (preg_match('/^(\s*)<\?php(?=\s|$)/', $source, $match)) {
            return '<?php ' . self::STRICT_TYPES . $match[1] . substr($source, strlen($match[0]));
        }
        if (preg_match('/^\s*<\?=/', $source)) {
            return '<?php ' . self::STRICT_TYPES . ' ?>' . $source;
        }

        return $source;
    }

    /**
     * eval() starts in PHP mode. Strip a leading open tag (keeping its trailing
     * whitespace so line numbers are unchanged); otherwise switch to HTML mode first.
     */
    public static function evalReady(string $source): string
    {
        if (preg_match('/^<\?php(?=\s)/', $source)) {
            $rest = substr($source, 5);

            return $rest[0] === ' ' ? substr($rest, 1) : $rest;
        }

        return '?>' . $source;
    }

    private static function isBracedNamespace(string $source, \RunletVendor\PhpParser\Node\Stmt\Namespace_ $namespace): bool
    {
        $end = $namespace->getEndFilePos();

        return $end >= 0 && isset($source[$end]) && $source[$end] === '}';
    }

    private static function endsOutsidePhp(string $source): bool
    {
        $tokens = token_get_all($source);
        for ($i = count($tokens) - 1; $i >= 0; $i--) {
            $token = $tokens[$i];
            if (is_array($token)) {
                if ($token[0] === T_WHITESPACE || $token[0] === T_COMMENT || $token[0] === T_DOC_COMMENT) {
                    continue;
                }

                return $token[0] === T_INLINE_HTML || $token[0] === T_CLOSE_TAG;
            }

            return false;
        }

        return false;
    }

    private static function column(string $source, \RunletVendor\PhpParser\Error $error): int
    {
        if (!$error->hasColumnInfo()) {
            return 0;
        }

        return $error->getStartColumn($source);
    }
}

/** An error raised by a project driver (.runlet/*Driver.php), with the driver that raised it. */
final class DriverFailure extends \RuntimeException
{
    /** @var string */
    public $driverFile;
    /** @var string|null */
    public $driverClass;

    public function __construct(string $context, string $driverFile, ?string $driverClass, \Throwable $previous)
    {
        parent::__construct($context . ': ' . $previous->getMessage(), 0, $previous);
        $this->driverFile = $driverFile;
        $this->driverClass = $driverClass;
    }
}

final class SnippetParseError extends \Exception
{
    /** @var int */
    public $snippetLine;
    /** @var int */
    public $snippetColumn;

    public function __construct(string $message, int $line, int $column, int $prefixLength)
    {
        parent::__construct($message);
        $this->snippetLine = max(1, $line);
        $this->snippetColumn = ($line <= 1 && $column > 0) ? max(1, $column - $prefixLength) : $column;
    }
}

final class Runner
{
    /** @var \Runlet\Driver|null The driver being booted (exit diagnostics). */
    private static $bootingDriver;
    /** @var string The project path being booted (exit diagnostics). */
    private static $bootingPath = '';

    /** @var array<string, mixed> */
    private static $request = [];
    /** @var float */
    private static $startedAt = 0.0;
    /** @var string */
    private static $state = 'starting';
    /** @var bool */
    private static $ddCalled = false;
    /** @var bool */
    private static $finished = false;
    /** @var ValueNormalizer|null */
    private static $normalizer;
    /** @var int */
    private static $prefixLength = 0;
    /** @var int */
    private static $dumpCount = 0;
    /** @var array<string, mixed> Driver variables imported into the snippet scope. */
    private static $variables = [];
    /** @var array{context: string, file: string, class: string|null}|null The project driver code running now. */
    private static $driverContext;
    /** @var \Runlet\Inspector|null The run inspector (snippet runs only). */
    private static $inspector;
    /** @var \Runlet\Driver|null The driver that booted the project. */
    private static $driver;
    /** @var array{label: string|null, file: string|null, class: string|null} How errors from the booted driver are attributed. */
    private static $driverOrigin = ['label' => null, 'file' => null, 'class' => null];
    /** @var bool Whether returned and dumped objects get HTML previews. */
    private static $previews = false;
    /** @var bool Set while a preview renders, so dumps inside the view get none. */
    private static $previewing = false;
    /** @var int */
    private static $maxBodyBytes = 2097152;
    /** @var int The line of the snippet's eval() in this file: its code is "…(<line>) : eval()'d code". */
    private static $evalLine = 0;
    /** @var array<string, mixed>|null Profile Run options (`request.profile`), else null. */
    private static $profileOptions;
    /** @var Profiler|null The snippet's profiler during a Profile Run. */
    private static $profiler;

    /** Explicit `bootstrap` request values mapped to built-in drivers. */
    private const BUILTIN_DRIVERS = [
        'laravel' => \Runlet\Drivers\LaravelDriver::class,
        'lumen' => \Runlet\Drivers\LaravelDriver::class,
        'laravel-zero' => \Runlet\Drivers\LaravelDriver::class,
        'wordpress' => \Runlet\Drivers\WordPressDriver::class,
        'symfony' => \Runlet\Drivers\SymfonyDriver::class,
        'composer' => \Runlet\Drivers\ComposerDriver::class,
        'plain' => \Runlet\Drivers\PlainDriver::class,
    ];

    /** Built-in auto-detection order; the first whose canBootstrap() is true boots the project. */
    private const DETECTION_ORDER = [
        \Runlet\Drivers\LaravelDriver::class,
        \Runlet\Drivers\WordPressDriver::class,
        \Runlet\Drivers\SymfonyDriver::class,
        \Runlet\Drivers\ComposerDriver::class,
        \Runlet\Drivers\PlainDriver::class,
    ];

    public static function main(string $encodedRequest): void
    {
        self::$startedAt = microtime(true);
        $decoded = base64_decode($encodedRequest, true);
        $request = $decoded === false ? null : json_decode($decoded, true);
        // "run" (default) runs `code`; "commands" boots the project the same way and lists
        // its commands (driver commands() plus Composer scripts) instead; "panels" reports
        // its App Info sections (#19, Panels.php).
        $mode = is_array($request) && in_array($request['mode'] ?? 'run', ['commands', 'panels'], true) ? (string) $request['mode'] : 'run';
        if (!is_array($request) || !isset($request['nonce']) || ($mode === 'run' && !isset($request['code']))) {
            fwrite(fopen('php://stderr', 'wb'), "Runlet runner: invalid request\n");
            exit(70);
        }
        self::$request = $request;
        Channel::open((string) $request['nonce']);
        $limits = is_array($request['limits'] ?? null) ? $request['limits'] : [];
        self::$normalizer = new ValueNormalizer($limits);
        self::$maxBodyBytes = (int) ($limits['maxBodyBytes'] ?? self::$maxBodyBytes);
        if ($mode === 'run') {
            self::createInspector(is_array($request['inspector'] ?? null) ? $request['inspector'] : [], $limits);
            self::$profileOptions = is_array($request['profile'] ?? null) ? $request['profile'] : null;
        }

        register_shutdown_function([self::class, 'shutdown']);

        $cwd = getcwd();
        $projectPath = $cwd === false ? '.' : $cwd;
        $requested = strtolower((string) ($request['bootstrap'] ?? 'auto'));
        if ($requested !== 'custom' && !isset(self::BUILTIN_DRIVERS[$requested])) {
            $requested = 'auto';
        }

        // Emitted before any project code loads, so the app learns the PID (for Stop) even
        // if a driver hangs. The framework here is preliminary: "custom" while project
        // drivers are pending; `bootstrapped` reports the driver that actually booted.
        Channel::emit('started', [
            'pid' => getmypid(),
            'phpVersion' => PHP_VERSION,
            'phpBinary' => PHP_BINARY,
            'sapi' => PHP_SAPI,
            'workingDirectory' => $cwd,
            'framework' => self::preliminaryFramework($projectPath, $requested),
            'user' => function_exists('posix_geteuid') ? posix_geteuid() : null,
            'profilers' => (object) Profiler::loaded(),
        ]);

        if (self::$profileOptions !== null && ($reason = Profiler::unavailableReason()) !== null) {
            // Profile Run on a PHP without Excimer: nothing of the project or the snippet runs.
            Channel::emit('error', ['stage' => 'launch', 'className' => 'ProfilerUnavailable', 'message' => $reason]);
            self::finish('error');

            return;
        }

        if ($mode === 'commands') {
            // Read from composer.json before any project code runs, so the scripts are listed
            // even when the application cannot boot.
            Channel::emit('commands', ['origin' => 'composer', 'source' => 'Composer', 'commands' => self::composerScripts($projectPath)]);
        }

        self::$state = 'bootstrap';
        $bootstrapStarted = microtime(true);
        try {
            $booted = self::bootstrap($projectPath, $requested);
        } catch (DriverFailure $failure) {
            $previous = $failure->getPrevious() ?? $failure;
            self::emitThrowable('bootstrap', $previous, array_filter([
                'message' => self::cleanMessage($failure->getMessage()),
                'driverFile' => $failure->driverFile,
                'driverClass' => $failure->driverClass,
            ]));
            self::finish('error');

            return;
        } catch (\Throwable $error) {
            self::emitThrowable('bootstrap', $error);
            self::finish('error');

            return;
        }
        if ($mode === 'run') {
            self::installDumpHandler();
        }

        $types = [];
        foreach (self::$variables as $name => $value) {
            $types[$name] = self::typeName($value);
        }
        $bootstrapped = [
            'framework' => $booted['framework'],
            'frameworkVersion' => $booted['version'],
            'driverName' => $booted['name'],
            // Always a JSON object (never []), name => class or type, for completion.
            'variables' => (object) $types,
            'bootstrapMs' => (int) round((microtime(true) - $bootstrapStarted) * 1000),
        ];
        if ($booted['file'] !== null) {
            $bootstrapped['driverFile'] = $booted['file'];
        }
        if ($booted['environment'] !== null) {
            $bootstrapped['environment'] = $booted['environment'];
        }
        self::log('runner', 'Booted ' . $booted['name'] . ($booted['version'] !== null ? ' ' . $booted['version'] : '') . ($booted['environment'] !== null ? ' (environment: ' . $booted['environment'] . ')' : '') . ' in ' . $bootstrapped['bootstrapMs'] . ' ms', $types === [] ? null : 'variables: $' . implode(', $', array_keys($types)));
        Channel::emit('bootstrapped', $bootstrapped);
        self::$driver = $booted['driver'];
        self::$driverOrigin = ['label' => $booted['label'], 'file' => $booted['file'], 'class' => $booted['class']];
        if ($mode === 'run') {
            self::inspect($booted);
        }

        if ($mode === 'commands') {
            self::listDriverCommands($booted);

            return;
        }
        if ($mode === 'panels') {
            self::reportPanels($booted, $projectPath);

            return;
        }

        self::$state = 'parse';
        try {
            $compiled = SnippetCompiler::compile((string) $request['code'], ($request['strictTypes'] ?? false) === true, ($request['magicComments'] ?? true) !== false);
            [$evalCode, $prefixLength, $hasResult, $notice] = $compiled;
            $magic = $compiled[4] ?? null;
        } catch (SnippetParseError $error) {
            Channel::emit('error', [
                'stage' => 'parse',
                'className' => 'ParseError',
                'message' => $error->getMessage(),
                'snippetLine' => $error->snippetLine,
                'snippetColumn' => $error->snippetColumn,
                'inSnippet' => true,
            ]);
            self::finish('error');

            return;
        }
        self::$prefixLength = $prefixLength;
        if ($notice !== null) {
            Channel::emit('notice', ['message' => $notice]);
        }
        if ($magic !== null) {
            self::installProbes($magic, $limits);
        }

        self::$state = 'execute';
        $executeStarted = microtime(true);
        if (self::$profileOptions !== null) {
            self::$profiler = Profiler::start(self::$profileOptions, $projectPath);
        }
        Probe::begin();
        try {
            $value = self::evaluate($evalCode);
        } catch (\Throwable $error) {
            self::stopProfiler();
            self::emitThrowable($error instanceof \ParseError ? 'parse' : 'execute', $error);
            self::finish('error', $executeStarted);

            return;
        }
        self::stopProfiler();

        if ($value instanceof NoResult) {
            Channel::emit('result', ['hasValue' => false]);
        } else {
            $payload = ['hasValue' => true, 'value' => self::normalize($value)];
            $preview = self::preview($value);
            if ($preview !== null) {
                $payload['preview'] = $preview;
            }
            Channel::emit('result', $payload);
        }
        self::finish('completed', $executeStarted);
    }

    /**
     * Reports the snippet's magic comments (`probes`: what each shows, and why the others
     * show nothing) and arms the probes. Comments Runlet cannot show get one notice.
     *
     * @param array{probes: array<int, array{line: int, kind: string, comment: string}>, rejected: array<int, array{line: int, comment: string, reason: string, label: string}>, notice?: string} $magic
     * @param array<string, mixed> $limits
     */
    private static function installProbes(array $magic, array $limits): void
    {
        $probes = [];
        foreach ($magic['probes'] as $id => $probe) {
            $probes[] = ['id' => $id, 'line' => $probe['line'], 'kind' => $probe['kind'], 'comment' => $probe['comment']];
        }
        Channel::emit('probes', ['probes' => $probes, 'rejected' => $magic['rejected']]);
        if (isset($magic['notice'])) {
            Channel::emit('notice', ['message' => $magic['notice']]);
        } elseif ($magic['rejected'] !== []) {
            $parts = [];
            foreach (array_slice($magic['rejected'], 0, 5) as $rejected) {
                $parts[] = 'line ' . $rejected['line'] . ' (' . $rejected['comment'] . '): ' . $rejected['reason'];
            }
            $more = count($magic['rejected']) - count($parts);
            $count = count($magic['rejected']);
            Channel::emit('notice', ['message' => 'Runlet can\'t show ' . ($count === 1 ? 'a magic comment' : $count . ' magic comments') . ', and the code runs as written. '
                . implode(' ', $parts) . ($more > 0 ? ' (' . $more . ' more)' : '')]);
        }
        Probe::install($magic['probes'], $limits);
    }

    /**
     * The run inspector, created before bootstrap so drivers can prepare for it (WordPress
     * turns on SAVEQUERIES). Its values use tighter limits than results and dumps.
     *
     * @param array<string, mixed> $options
     * @param array<string, mixed> $limits
     */
    private static function createInspector(array $options, array $limits): void
    {
        self::$previews = ($options['previews'] ?? false) === true;
        $normalizer = new ValueNormalizer([
            'maxDepth' => min(6, (int) ($limits['maxDepth'] ?? 8)),
            'maxChildren' => 100,
            'maxStringBytes' => 16384,
            'maxNodes' => 5000,
            'maxValueBytes' => 524288,
        ]);
        self::$inspector = new \Runlet\Inspector(
            $options + array_intersect_key($limits, array_flip(['maxQueries', 'maxRecords', 'maxRecordBytes', 'maxBodyBytes'])),
            static function (string $type, array $payload): void {
                Channel::emit($type, $payload);
            },
            static function ($value) use ($normalizer): array {
                try {
                    return $normalizer->normalize($value);
                } catch (\Throwable $error) {
                    return ['id' => 0, 'type' => 'unknown', 'scalar' => 'Runlet could not inspect this value: ' . $error->getMessage()];
                }
            }
        );
        \Runlet\Inspector::setCurrent(self::$inspector);
    }

    /**
     * Calls the driver's inspect() hook (when the inspector is on), then reports the
     * inspector's sections. A failing hook is a notice; the run continues.
     *
     * @param array{framework: string, version: string|null, name: string, file: string|null, driver: \Runlet\Driver, label: string|null, class: string|null} $booted
     */
    private static function inspect(array $booted): void
    {
        $inspector = self::$inspector;
        if ($inspector === null || !$inspector->isEnabled()) {
            return;
        }
        $driver = $booted['driver'];
        try {
            self::callDriver($booted['label'], $booted['file'], $booted['class'], 'inspect()', static function () use ($driver, $inspector): void {
                $driver->inspect($inspector);
            });
        } catch (\Throwable $error) {
            $message = $error instanceof DriverFailure ? $error->getMessage() : $booted['name'] . ' failed in inspect(): ' . $error->getMessage();
            Channel::emit('notice', ['message' => self::cleanMessage($message) . ' The run continues, but the inspector may miss queries, mail, or logs.']);
        }
        $inspector->ready($booted['name']);
    }

    /**
     * The driver's HTML preview of a returned or dumped object, bounded, or null.
     *
     * @param mixed $value
     * @return array<string, mixed>|null
     */
    private static function preview($value): ?array
    {
        if (!self::$previews || self::$previewing || self::$driver === null || !is_object($value)) {
            return null;
        }
        $driver = self::$driver;
        self::$previewing = true;
        try {
            $preview = $driver->preview($value);
        } catch (\Throwable $error) {
            $preview = ['title' => get_class($value), 'error' => self::cleanMessage($error->getMessage())];
        } finally {
            self::$previewing = false;
        }
        if (!is_array($preview) || (!isset($preview['html']) && !isset($preview['error']))) {
            return null;
        }
        $result = [];
        $limits = ['kind' => 30, 'title' => 300, 'subject' => 1000, 'error' => 4000, 'html' => self::$maxBodyBytes, 'text' => self::$maxBodyBytes];
        foreach ($limits as $key => $limit) {
            if (!isset($preview[$key]) || !is_scalar($preview[$key])) {
                continue;
            }
            $text = (string) $preview[$key];
            [$text, $omitted] = \Runlet\Inspector::clip($key === 'title' ? \Runlet\Inspector::className($text) : $text, $limit);
            $result[$key] = $text;
            if ($omitted > 0 && ($key === 'html' || $key === 'text')) {
                $result[$key . 'OmittedBytes'] = $omitted;
            }
        }

        return $result;
    }

    /** @return mixed */
    private static function evaluate(string $__runletCode)
    {
        // Evaluated in its own function scope: snippet variables never leak into the runner.
        // Driver variables come first; EXTR_SKIP and the name checks in collectVariables()
        // keep them from replacing $__runletCode.
        extract(self::$variables, EXTR_SKIP);
        self::$evalLine = __LINE__ + 2;

        return eval($__runletCode);
    }

    /** @return array<string, mixed> */
    private static function normalize($value): array
    {
        if (self::$normalizer === null) {
            return ['id' => 0, 'type' => 'unknown'];
        }
        try {
            return self::$normalizer->normalize($value);
        } catch (\Throwable $error) {
            return ['id' => 0, 'type' => 'unknown', 'scalar' => 'Runlet could not inspect this value: ' . $error->getMessage()];
        }
    }

    /**
     * The framework reported in `started`, from file checks only (no project code runs).
     * `bootstrap` request values: auto (default), custom, or a built-in driver id.
     */
    private static function preliminaryFramework(string $projectPath, string $requested): string
    {
        if (isset(self::BUILTIN_DRIVERS[$requested])) {
            $class = self::BUILTIN_DRIVERS[$requested];

            return self::frameworkId(new $class(), $projectPath, false);
        }
        if ($requested === 'custom' || self::projectDriverFiles($projectPath) !== []) {
            return 'custom';
        }

        return self::frameworkId(self::detectBuiltinDriver($projectPath), $projectPath, false);
    }

    /**
     * Picks and runs a driver: project drivers in .runlet/ first (auto or custom), then the
     * built-in detection order. Also collects the driver's snippet variables.
     *
     * @return array{framework: string, version: string|null, name: string, environment: string|null, file: string|null, driver: \Runlet\Driver, label: string|null, class: string|null}
     */
    private static function bootstrap(string $projectPath, string $requested): array
    {
        $driver = null;
        $file = null;
        if (isset(self::BUILTIN_DRIVERS[$requested])) {
            $class = self::BUILTIN_DRIVERS[$requested];
            $driver = new $class();
        } else {
            $driver = $requested === 'auto' ? self::rememberedBuiltinDriver($projectPath) : null;
            if ($driver === null) {
                [$driver, $file] = self::discoverProjectDriver($projectPath);
            }
            if ($driver === null && $requested === 'custom') {
                throw new \RuntimeException('No Runlet project driver can bootstrap ' . $projectPath . '. Add a class extending Runlet\Driver in .runlet/<Name>Driver.php whose canBootstrap() returns true.');
            }
            if ($driver === null) {
                $driver = self::detectBuiltinDriver($projectPath);
            }
        }

        $class = $file === null ? null : get_class($driver);
        $file = $file === null ? null : self::relativeDriverPath($projectPath, $file);
        $label = $file === null ? null : $class . ' (' . $file . ')';
        $builtinKey = $file === null ? array_search(get_class($driver), self::BUILTIN_DRIVERS, true) : false;
        $stamp = self::runletDirectoryStamp($projectPath);
        $recalled = self::recalled('driver') === 'builtin:' . $builtinKey . '@' . $stamp;
        self::log('runner', 'Driver: ' . ($label ?? get_class($driver)), ($recalled ? 'remembered for this session (no .runlet folder changes)' : ($requested === 'auto' ? 'auto-detected' : 'requested: ' . $requested)) . ' in ' . $projectPath);
        if ($requested === 'auto' && is_string($builtinKey)) {
            self::remember('driver', 'builtin:' . $builtinKey . '@' . $stamp);
        }
        self::$bootingDriver = $driver;
        self::$bootingPath = $projectPath;
        if ((self::$request['mode'] ?? 'run') === 'commands') {
            // Before bootstrap(): host commands are declarations, listed even when boot fails.
            self::emitHostCommands($driver, $label, $file, $class);
        }
        self::callDriver($label, $file, $class, 'bootstrap()', static function () use ($driver, $projectPath): void {
            $driver->bootstrap($projectPath);
        });
        self::$variables = self::callDriver($label, $file, $class, 'variables()', static function () use ($driver): array {
            return self::collectVariables($driver->variables());
        });
        $version = self::callDriver($label, $file, $class, 'version()', static function () use ($driver): ?string {
            return $driver->version();
        });
        $name = self::callDriver($label, $file, $class, 'name()', static function () use ($driver): string {
            return $driver->name();
        });

        return [
            'framework' => self::frameworkId($driver, $projectPath, $file !== null),
            'version' => $version,
            'name' => $name,
            'environment' => self::driverEnvironment($driver, $label),
            'file' => $file,
            'driver' => $driver,
            'label' => $label,
            'class' => $class,
        ];
    }

    /**
     * The application's environment name from the driver's environment() (#12), for the
     * `bootstrapped` event: without control characters, trimmed, at most 64 characters; null
     * when there is none. It is informational, so a driver whose environment() throws only
     * gets a Run Log line and the run continues.
     */
    private static function driverEnvironment(\Runlet\Driver $driver, ?string $label): ?string
    {
        try {
            $environment = $driver->environment();
        } catch (\Throwable $error) {
            self::log('runner', ($label ?? get_class($driver)) . ': environment() failed; the environment is not reported', get_class($error) . ': ' . self::cleanMessage($error->getMessage()));

            return null;
        }
        // Invalid UTF-8 makes preg_replace() return null.
        $environment = is_string($environment) ? preg_replace('/\p{Cc}+/u', '', $environment) : null;
        if (!is_string($environment) || !preg_match('/^.{1,64}/us', trim($environment), $match)) {
            return null;
        }

        return rtrim($match[0]);
    }

    /**
     * A value the app remembered for this session (the request's `hints`, sent back from an
     * earlier run's `remember` events). Callers check it is still valid before using it.
     */
    public static function recalled(string $key): ?string
    {
        $hints = self::$request['hints'] ?? null;

        return is_array($hints) && isset($hints[$key]) && is_string($hints[$key]) ? $hints[$key] : null;
    }

    /** Asks the app to remember a value for this target until it quits (see recalled()). */
    public static function remember(string $key, string $value): void
    {
        if (self::recalled($key) !== $value) {
            Channel::emit('remember', ['key' => $key, 'value' => $value]);
        }
    }

    /** The remembered built-in driver, when no .runlet driver was added or changed since and it still accepts the project. */
    private static function rememberedBuiltinDriver(string $projectPath): ?\Runlet\Driver
    {
        $hint = self::recalled('driver');
        if ($hint === null || !preg_match('/^builtin:([a-z]+)@(.+)$/', $hint, $match) || $match[2] !== self::runletDirectoryStamp($projectPath)
            || !isset(self::BUILTIN_DRIVERS[$match[1]])) {
            return null;
        }
        $class = self::BUILTIN_DRIVERS[$match[1]];
        $driver = new $class();

        return $driver->canBootstrap($projectPath) ? $driver : null;
    }

    /** Changes when project drivers are added, removed, or edited in .runlet/. */
    private static function runletDirectoryStamp(string $projectPath): string
    {
        $directory = $projectPath . '/.runlet';
        if (!is_dir($directory)) {
            return 'none';
        }
        $stamp = (string) @filemtime($directory);
        foreach (glob($directory . '/*Driver.php') ?: [] as $file) {
            $stamp .= ':' . @filemtime($file);
        }

        return $stamp;
    }

    /** Emits one Run Log line (Run ▸ Show Run Log in the app). */
    public static function log(string $source, string $message, ?string $detail = null): void
    {
        Channel::emit('log', array_filter(['source' => $source, 'message' => $message, 'detail' => $detail], static function ($value): bool {
            return $value !== null;
        }));
    }

    /**
     * What explains an exit() during bootstrap: the driver's own hint (e.g. WordPress's
     * redirect) and the project file loaded last, which is usually where exit() was called
     * from (a plugin, a config file, a bootstrap script). Also logged.
     */
    private static function bootstrapExitHint(): string
    {
        $parts = [];
        $driver = self::$bootingDriver;
        if ($driver !== null && method_exists($driver, 'bootstrapExitHint')) {
            try {
                $hint = $driver->bootstrapExitHint();
                if (is_string($hint) && $hint !== '') {
                    $parts[] = $hint;
                }
            } catch (\Throwable $ignored) {
            }
        }
        $files = array_values(array_filter(get_included_files(), static function (string $file): bool {
            return $file !== '' && $file[0] === '/' && strpos($file, 'eval()') === false;
        }));
        $last = end($files);
        if (is_string($last) && $last !== '') {
            $root = rtrim(self::$bootingPath, '/') . '/';
            $shown = self::$bootingPath !== '' && strpos($last, $root) === 0 ? substr($last, strlen($root)) : $last;
            $parts[] = 'The last file loaded was ' . $shown . ' (' . count($files) . ' files in all).';
            self::log('bootstrap', 'exit() during bootstrap; last file loaded: ' . $shown, implode("\n", array_slice(array_map(static function (string $file) use ($root): string {
                return strpos($file, $root) === 0 ? substr($file, strlen($root)) : $file;
            }, $files), -8)));
        }

        return implode(' ', $parts);
    }

    /** Most commands one `commands` event lists, and the longest description kept. */
    private const MAX_COMMANDS = 5000;
    private const MAX_DESCRIPTION = 500;

    /**
     * Commands mode, after bootstrap: emits the driver's commands() and finishes.
     *
     * @param array{framework: string, version: string|null, name: string, file: string|null, driver: \Runlet\Driver, label: string|null, class: string|null} $booted
     */
    private static function listDriverCommands(array $booted): void
    {
        self::$state = 'commands';
        $driver = $booted['driver'];
        try {
            $commands = self::callDriver($booted['label'], $booted['file'], $booted['class'], 'commands()', static function () use ($driver): array {
                return $driver->commands();
            });
        } catch (DriverFailure $failure) {
            $previous = $failure->getPrevious() ?? $failure;
            self::emitThrowable('execute', $previous, array_filter([
                'message' => self::cleanMessage($failure->getMessage()),
                'driverFile' => $failure->driverFile,
                'driverClass' => $failure->driverClass,
            ]));
            self::finish('error');

            return;
        } catch (\Throwable $error) {
            self::emitThrowable('execute', $error, ['message' => $booted['name'] . ' could not list its commands: ' . self::cleanMessage($error->getMessage())]);
            self::finish('error');

            return;
        }

        $payload = [
            'origin' => 'driver',
            'source' => $booted['name'],
            'framework' => $booted['framework'],
            'commands' => self::normalizeCommands($commands, $booted['name']),
        ];
        if ($booted['file'] !== null) {
            $payload['driverFile'] = $booted['file'];
        }
        Channel::emit('commands', $payload);
        self::finish('completed');
    }

    /**
     * Panels mode (App Info, #19), after bootstrap: emits the built-in sections, then the
     * driver's panels(), and finishes. A failing panels() is the driver event's `error`; the
     * built-ins were sent already.
     *
     * @param array{framework: string, version: string|null, name: string, file: string|null, driver: \Runlet\Driver, label: string|null, class: string|null} $booted
     */
    private static function reportPanels(array $booted, string $projectPath): void
    {
        self::$state = 'panels';
        $driver = $booted['driver'];
        try {
            Channel::emit('panels', AppInfo::builtin($driver, $projectPath, $booted['name']));
        } catch (\Throwable $error) {
            Channel::emit('panels', ['origin' => 'builtin', 'source' => $booted['name'], 'sections' => [], 'error' => 'Runlet could not read the App Info: ' . self::cleanMessage($error->getMessage())]);
        }
        try {
            $payload = AppInfo::driver(self::callDriver($booted['label'], $booted['file'], $booted['class'], 'panels()', static function () use ($driver) {
                return $driver->panels();
            }), $booted['name']);
        } catch (\Throwable $error) {
            $payload = AppInfo::driver([], $booted['name']);
            $payload['error'] = self::cleanMessage($error instanceof DriverFailure ? $error->getMessage() : $booted['name'] . ' failed in panels(): ' . $error->getMessage());
        }
        if ($booted['file'] !== null) {
            $payload['driverFile'] = $booted['file'];
        }
        Channel::emit('panels', $payload);
        self::finish('completed');
    }

    /**
     * Commands mode, before bootstrap: emits the driver's hostCommands() as a `hostCommands`
     * event (static commands and command sources; empty lists when it declares none, so the
     * app knows the declaration is current). A failing hostCommands() is a notice, never a
     * reason to stop listing the driver's own commands.
     */
    private static function emitHostCommands(\Runlet\Driver $driver, ?string $label, ?string $file, ?string $class): void
    {
        $context = $label ?? get_class($driver);
        try {
            $entries = self::callDriver($label, $file, $class, 'hostCommands()', static function () use ($driver): array {
                return $driver->hostCommands();
            });
        } catch (\Throwable $error) {
            $previous = $error instanceof DriverFailure ? ($error->getPrevious() ?? $error) : $error;
            Channel::emit('notice', ['message' => $context . ': hostCommands() failed, so its host commands are not listed: ' . self::cleanMessage($previous->getMessage())]);

            return;
        }
        $commands = [];
        $sources = [];
        $skipped = [];
        foreach ($entries as $key => $entry) {
            $name = is_array($entry) && isset($entry['name']) && is_scalar($entry['name']) ? (string) $entry['name'] : (is_string($key) ? $key : '');
            $list = is_array($entry) && isset($entry['list']) && is_string($entry['list']) ? trim($entry['list']) : '';
            $console = is_array($entry) && isset($entry['console']) && is_string($entry['console']) ? trim($entry['console']) : '';
            if ($name !== '' && ($list !== '' || $console !== '')) {
                if (count($sources) < 20) {
                    $description = isset($entry['description']) && is_scalar($entry['description']) ? trim((string) $entry['description']) : '';
                    $sources[] = [
                        'name' => $name,
                        'format' => $list !== '' ? 'runlet' : 'symfony',
                        'list' => $list !== '' ? $list : $console . ' list --format=json',
                        'console' => $list !== '' ? null : $console,
                        'description' => $description === '' ? null : self::shorten($description, self::MAX_DESCRIPTION),
                    ];
                }
                continue;
            }
            if (is_string($entry) || (is_array($entry) && isset($entry['command']))) {
                $commands[$key] = $entry;
                continue;
            }
            $skipped[] = $name === '' ? '#' . $key : $name;
        }
        if ($skipped !== []) {
            Channel::emit('notice', ['message' => $context . ' returned host commands without a command, list, or console, which Runlet skipped: ' . implode(', ', array_slice($skipped, 0, 20)) . '.']);
        }
        Channel::emit('hostCommands', [
            'commands' => self::normalizeCommands($commands, $context),
            'sources' => $sources,
        ]);
    }

    /**
     * Validates commands() output: name-keyed entries or lists of entries with a `name`;
     * a string value is the command line. Invalid entries are skipped with a notice.
     *
     * @param array<mixed> $commands
     * @return array<int, array{name: string, command: string, description: string|null, group: string|null, needsInput?: bool}>
     */
    private static function normalizeCommands(array $commands, string $driverName): array
    {
        $result = [];
        $seen = [];
        $skipped = [];
        foreach ($commands as $key => $entry) {
            if (is_string($entry)) {
                $entry = ['command' => $entry];
            }
            $name = is_array($entry) && isset($entry['name']) && is_scalar($entry['name']) ? (string) $entry['name'] : (is_string($key) ? $key : '');
            $command = is_array($entry) && isset($entry['command']) && is_string($entry['command']) ? trim($entry['command']) : '';
            if ($name === '' || $command === '') {
                $skipped[] = $name === '' ? '#' . $key : $name;
                continue;
            }
            if (isset($seen[$name]) || count($result) >= self::MAX_COMMANDS) {
                continue;
            }
            $seen[$name] = true;
            $description = isset($entry['description']) && is_scalar($entry['description']) ? trim((string) $entry['description']) : '';
            $group = isset($entry['group']) && is_scalar($entry['group']) ? trim((string) $entry['group']) : '';
            $normalized = [
                'name' => $name,
                'command' => $command,
                'description' => $description === '' ? null : self::shorten($description, self::MAX_DESCRIPTION),
                'group' => $group === '' ? null : $group,
            ];
            if (is_array($entry) && ($entry['needsInput'] ?? false) === true) {
                $normalized['needsInput'] = true;
            }
            $result[] = $normalized;
        }
        if ($skipped !== []) {
            Channel::emit('notice', ['message' => $driverName . ' returned commands without a name or command line, which Runlet skipped: ' . implode(', ', array_slice($skipped, 0, 20)) . '.']);
        }

        return $result;
    }

    /** Composer's own event names: `scripts` entries Composer runs as hooks, not commands. */
    private const COMPOSER_EVENTS = [
        'pre-install-cmd', 'post-install-cmd', 'pre-update-cmd', 'post-update-cmd', 'pre-status-cmd', 'post-status-cmd',
        'pre-archive-cmd', 'post-archive-cmd', 'pre-autoload-dump', 'post-autoload-dump', 'post-root-package-install',
        'post-create-project-cmd', 'pre-operations-exec', 'pre-package-install', 'post-package-install',
        'pre-package-update', 'post-package-update', 'pre-package-uninstall', 'post-package-uninstall', 'init', 'command',
        'pre-file-download', 'post-file-download', 'pre-command-run', 'pre-pool-create',
    ];

    /**
     * Scripts from composer.json in the working directory, as `composer run-script <name>`.
     * Pure file read: no project code runs.
     *
     * @return array<int, array{name: string, command: string, description: string|null, group: string}>
     */
    private static function composerScripts(string $projectPath): array
    {
        $manifest = @file_get_contents($projectPath . '/composer.json');
        $composer = is_string($manifest) ? json_decode($manifest, true) : null;
        if (!is_array($composer) || !isset($composer['scripts']) || !is_array($composer['scripts'])) {
            return [];
        }
        $descriptions = isset($composer['scripts-descriptions']) && is_array($composer['scripts-descriptions']) ? $composer['scripts-descriptions'] : [];
        $result = [];
        foreach ($composer['scripts'] as $name => $script) {
            $name = (string) $name;
            if ($name === '' || in_array($name, self::COMPOSER_EVENTS, true)) {
                continue;
            }
            $description = isset($descriptions[$name]) && is_string($descriptions[$name]) ? trim($descriptions[$name]) : '';
            if ($description === '') {
                $steps = is_array($script) ? $script : [$script];
                $parts = [];
                foreach ($steps as $stepKey => $step) {
                    // Symfony Flex "auto-scripts" map commands to their runner: list the commands.
                    $parts[] = is_string($stepKey) ? $stepKey : (is_scalar($step) ? (string) $step : '');
                }
                $parts = array_values(array_filter($parts, 'strlen'));
                $description = count($parts) > 1 ? $parts[0] . ' (+' . (count($parts) - 1) . ' more)' : ($parts[0] ?? '');
            }
            $argument = preg_match('/^[A-Za-z0-9:._-]+$/', $name) ? $name : escapeshellarg($name);
            $result[] = [
                'name' => $name,
                'command' => 'composer run-script ' . $argument,
                'description' => $description === '' ? null : self::shorten($description, self::MAX_DESCRIPTION),
                'group' => 'composer',
            ];
        }

        return $result;
    }

    private static function shorten(string $text, int $limit): string
    {
        if (strlen($text) <= $limit) {
            return $text;
        }
        $cut = substr($text, 0, $limit);
        // Never end inside a multibyte UTF-8 sequence.
        while ($cut !== '' && preg_match('//u', $cut) !== 1) {
            $cut = substr($cut, 0, -1);
        }

        return $cut . '…';
    }

    private static function detectBuiltinDriver(string $projectPath): \Runlet\Driver
    {
        foreach (self::DETECTION_ORDER as $class) {
            $driver = new $class();
            if ($driver->canBootstrap($projectPath)) {
                return $driver;
            }
        }

        return new \Runlet\Drivers\PlainDriver();
    }

    private static function frameworkId(\Runlet\Driver $driver, string $projectPath, bool $isProjectDriver): string
    {
        if ($isProjectDriver) {
            return 'custom:' . get_class($driver);
        }
        if ($driver instanceof \Runlet\Drivers\LaravelDriver) {
            return $driver->flavor($projectPath);
        }
        if ($driver instanceof \Runlet\Drivers\WordPressDriver) {
            return 'wordpress';
        }
        if ($driver instanceof \Runlet\Drivers\SymfonyDriver) {
            return 'symfony';
        }
        if ($driver instanceof \Runlet\Drivers\ComposerDriver) {
            return 'composer';
        }

        return 'plain';
    }

    /**
     * Project driver files: <project>/.runlet/*Driver.php, sorted. Read straight from disk,
     * so a globally git-ignored .runlet/ folder works.
     *
     * @return string[]
     */
    private static function projectDriverFiles(string $projectPath): array
    {
        $directory = $projectPath . '/.runlet';
        $entries = is_dir($directory) ? @scandir($directory) : false;
        if (!is_array($entries)) {
            return [];
        }
        $files = [];
        foreach ($entries as $entry) {
            if (substr($entry, -10) === 'Driver.php' && is_file($directory . '/' . $entry)) {
                $files[] = $directory . '/' . $entry;
            }
        }
        sort($files, SORT_STRING);

        return $files;
    }

    /**
     * Loads every project driver file (after the project's Composer autoloader, when it
     * exists) and returns the first concrete Runlet\Driver declared in .runlet/ whose
     * canBootstrap() accepts the project.
     *
     * @return array{0: \Runlet\Driver|null, 1: string|null}
     */
    private static function discoverProjectDriver(string $projectPath): array
    {
        $files = self::projectDriverFiles($projectPath);
        if ($files === []) {
            return [null, null];
        }
        // Drivers may use project classes without loading Composer themselves. Loading it
        // again later (e.g. from the app's own bootstrap file) is harmless: Composer's
        // generated autoloader returns the already registered loader.
        $autoload = $projectPath . '/vendor/autoload.php';
        if (is_file($autoload)) {
            require_once $autoload;
        }

        $directory = $projectPath . '/.runlet';
        $realDirectory = realpath($directory);
        // A driver may extend another driver in .runlet/ regardless of file order.
        $siblingLoader = static function (string $class) use ($directory): void {
            $short = substr((string) strrchr('\\' . $class, '\\'), 1);
            if (substr($short, -6) === 'Driver' && is_file($directory . '/' . $short . '.php')) {
                self::requireFile($directory . '/' . $short . '.php');
            }
        };

        $candidates = [];
        spl_autoload_register($siblingLoader);
        try {
            foreach ($files as $file) {
                $before = get_declared_classes();
                $relative = self::relativeDriverPath($projectPath, $file);
                $context = 'Runlet driver ' . $relative . ' could not be loaded';
                self::$driverContext = ['context' => $context, 'file' => $relative, 'class' => null];
                try {
                    self::requireFile($file);
                } catch (\Throwable $error) {
                    throw new DriverFailure($context, $relative, null, $error);
                }
                foreach (array_diff(get_declared_classes(), $before) as $class) {
                    $reflection = new \ReflectionClass($class);
                    $declaredIn = $reflection->getFileName();
                    if ($reflection->isAbstract() || !$reflection->isSubclassOf(\Runlet\Driver::class)
                        || !is_string($declaredIn) || realpath(dirname($declaredIn)) !== $realDirectory) {
                        continue;
                    }
                    $candidates[$class] = $declaredIn;
                }
            }
        } finally {
            spl_autoload_unregister($siblingLoader);
            self::$driverContext = null;
        }

        foreach ($candidates as $class => $file) {
            $relative = self::relativeDriverPath($projectPath, $file);
            $driver = self::callDriver($class . ' (' . $relative . ')', $relative, $class, 'canBootstrap()', static function () use ($class, $projectPath): ?\Runlet\Driver {
                $driver = (new \ReflectionClass($class))->newInstance();

                return $driver->canBootstrap($projectPath) ? $driver : null;
            });
            if ($driver !== null) {
                return [$driver, $file];
            }
        }

        return [null, null];
    }

    /**
     * Runs one driver call. For project drivers ($label set), errors are wrapped so the
     * report names the driver, and fatal errors are attributed to it by shutdown().
     *
     * @return mixed
     */
    private static function callDriver(?string $label, ?string $file, ?string $class, string $method, \Closure $call)
    {
        if ($label === null || $file === null) {
            return $call();
        }
        $context = 'Runlet driver ' . $label . ' failed in ' . $method;
        self::$driverContext = ['context' => $context, 'file' => $file, 'class' => $class];
        try {
            return $call();
        } catch (\Throwable $error) {
            throw new DriverFailure($context, $file, $class, $error);
        } finally {
            self::$driverContext = null;
        }
    }

    /** The driver that booted the project (SQL tabs, #35); null before bootstrap. */
    public static function bootedDriver(): ?\Runlet\Driver
    {
        return self::$driver;
    }

    /**
     * Calls the booted driver: a project driver's errors (and fatal errors) name its file
     * and method, as during bootstrap.
     *
     * @return mixed
     */
    public static function callBootedDriver(string $method, \Closure $call)
    {
        $origin = self::$driverOrigin;

        return self::callDriver($origin['label'], $origin['file'], $origin['class'], $method, $call);
    }

    private static function requireFile(string $__runletFile): void
    {
        require_once $__runletFile;
    }

    private static function relativeDriverPath(string $projectPath, string $file): string
    {
        $prefix = rtrim($projectPath, '/') . '/';

        return strpos($file, $prefix) === 0 ? substr($file, strlen($prefix)) : $file;
    }

    /**
     * Keeps variables with valid, non-reserved names.
     *
     * @param array<mixed> $variables
     * @return array<string, mixed>
     */
    private static function collectVariables(array $variables): array
    {
        $accepted = [];
        $ignored = [];
        foreach ($variables as $name => $value) {
            $name = (string) $name;
            if (!preg_match('/^[A-Za-z_\x80-\xff][A-Za-z0-9_\x80-\xff]*$/', $name) || $name === 'this' || $name === 'GLOBALS' || strpos($name, '__runlet') === 0) {
                $ignored[] = $name;
                continue;
            }
            $accepted[$name] = $value;
        }
        if ($ignored !== []) {
            Channel::emit('notice', ['message' => 'Runlet ignored driver variables with names that cannot be snippet variables: ' . implode(', ', $ignored) . '.']);
        }

        return $accepted;
    }

    /** @param mixed $value */
    private static function typeName($value): string
    {
        if (is_object($value)) {
            $class = get_class($value);
            // Anonymous classes are named "class@anonymous<NUL>/path:line$0".
            $nul = strpos($class, "\0");

            return $nul === false ? $class : substr($class, 0, $nul);
        }
        $types = ['integer' => 'int', 'double' => 'float', 'boolean' => 'bool', 'NULL' => 'null', 'resource (closed)' => 'resource'];
        $type = gettype($value);

        return $types[$type] ?? $type;
    }

    private static function installDumpHandler(): void
    {
        $handler = static function ($value, $label = null): void {
            self::emitDump($value, $label);
        };

        // The active global dump() may come from the project, or from something loaded
        // earlier such as a php.ini auto_prepend_file with a namespace-scoped var-dumper.
        // Hook every VarDumper class that the active dump()/dd() actually call.
        $candidates = ['Symfony\Component\VarDumper\VarDumper'];
        foreach (['dump', 'dd'] as $function) {
            if (function_exists($function)) {
                $candidates = array_merge($candidates, self::varDumperClassesUsedBy($function, 0));
            }
        }
        $installed = false;
        foreach (array_unique($candidates) as $class) {
            if (class_exists($class) && method_exists($class, 'setHandler')) {
                $class::setHandler($handler);
                $installed = true;
            }
        }
        if ($installed) {
            return;
        }

        if (!function_exists('dump') && !function_exists('dd')) {
            eval('function dump(...$vars) { foreach ($vars as $v) { \RunletRunner\Runner::emitDump($v, null); } return $vars[0] ?? null; }'
                . 'function dd(...$vars) { foreach ($vars as $v) { \RunletRunner\Runner::emitDump($v, null); } exit(1); }');
        }
    }

    /**
     * Finds VarDumper classes referenced by the file defining $function, following
     * php-scoper style aliases (`function dump() { return \\Prefix\\dump(...); }`).
     *
     * @return string[]
     */
    private static function varDumperClassesUsedBy(string $function, int $depth): array
    {
        try {
            $reflection = new \ReflectionFunction($function);
        } catch (\Throwable $error) {
            return [];
        }
        $file = $reflection->getFileName();
        $lines = is_string($file) ? @file($file) : false;
        if (!is_array($lines)) {
            return [];
        }
        $classes = [];
        if (preg_match_all('/([A-Za-z0-9_\\\\]*Symfony\\\\Component\\\\VarDumper\\\\VarDumper)\b/', implode('', $lines), $matches)) {
            foreach ($matches[1] as $class) {
                $classes[] = ltrim($class, '\\');
            }
        }
        $start = max(0, (int) $reflection->getStartLine() - 1);
        $body = implode('', array_slice($lines, $start, max(1, (int) $reflection->getEndLine() - $start)));
        if ($depth < 3 && preg_match_all('/\\\\?([A-Za-z_][A-Za-z0-9_]*(?:\\\\[A-Za-z_][A-Za-z0-9_]*)+)\s*\(/', $body, $calls)) {
            foreach ($calls[1] as $target) {
                if (strcasecmp($target, $function) !== 0 && function_exists($target)) {
                    $classes = array_merge($classes, self::varDumperClassesUsedBy($target, $depth + 1));
                }
            }
        }

        return $classes;
    }

    /** @param mixed $value */
    public static function emitDump($value, $label = null): void
    {
        $origin = 'dump';
        $snippetFrame = null;
        $callerFrame = null;
        $laravelBenchmark = false;
        foreach (debug_backtrace(DEBUG_BACKTRACE_IGNORE_ARGS) as $frame) {
            $function = $frame['function'] ?? '';
            $class = $frame['class'] ?? '';
            $short = substr((string) strrchr('\\' . $function, '\\'), 1);
            if ($short === 'dd' && $class === '') {
                $origin = 'dd';
                self::$ddCalled = true;
            }
            if ($function === 'dd' && $class === 'Illuminate\\Support\\Benchmark') {
                $laravelBenchmark = true;
            }
            if ($callerFrame === null && ($short === 'dump' || $short === 'dd') && $class === '') {
                $callerFrame = $frame;
            }
            if ($snippetFrame === null && isset($frame['file']) && self::isSnippetFile($frame['file'])) {
                $snippetFrame = $frame;
            }
        }
        $frame = $snippetFrame ?? $callerFrame;
        if ($laravelBenchmark) {
            self::recordLaravelBenchmark($value);
        }

        self::$dumpCount++;
        $payload = ['index' => self::$dumpCount, 'origin' => $origin, 'value' => self::normalize($value)];
        if ($label !== null && $label !== '') {
            $payload['label'] = (string) $label;
        }
        $preview = self::preview($value);
        if ($preview !== null) {
            $payload['preview'] = $preview;
        }
        if ($frame !== null) {
            $payload += self::location($frame['file'] ?? null, $frame['line'] ?? null);
        }
        Channel::emit('dump', $payload);
    }

    /**
     * Laravel's Benchmark::dd() dumped its averages: also record them as a benchmark card,
     * with the iteration count from Benchmark::dd()'s arguments.
     *
     * @param mixed $value
     */
    private static function recordLaravelBenchmark($value): void
    {
        try {
            foreach (debug_backtrace(0) as $frame) {
                if (($frame['class'] ?? '') === 'Illuminate\\Support\\Benchmark' && ($frame['function'] ?? '') === 'dd') {
                    \Runlet\Benchmark::recordLaravelDump($value, is_array($frame['args'] ?? null) ? $frame['args'] : []);

                    return;
                }
            }
        } catch (\Throwable $error) {
            // The dump itself is still shown.
        }
    }

    /** Stops the Profile Run's sampling (the record is sent when the run finishes). */
    private static function stopProfiler(): void
    {
        if (self::$profiler !== null) {
            try {
                self::$profiler->stop();
            } catch (\Throwable $error) {
                Channel::emit('notice', ['message' => 'Runlet could not stop the profiler: ' . $error->getMessage()]);
                self::$profiler = null;
            }
        }
    }

    /** Sends the Profile Run's flame-graph data, before the inspector finishes. */
    private static function emitProfile(): void
    {
        $profiler = self::$profiler;
        self::$profiler = null;
        if ($profiler === null || self::$inspector === null) {
            return;
        }
        try {
            self::$inspector->measurement(Profiler::SECTION, 'profile', 'Profile', $profiler->record(), []);
        } catch (\Throwable $error) {
            Channel::emit('notice', ['message' => 'Runlet could not report the profile: ' . $error->getMessage()]);
        }
    }

    /** @return array<string, mixed> */
    private static function location(?string $file, ?int $line): array
    {
        if ($file === null) {
            return [];
        }
        if (self::isSnippetFile($file)) {
            return ['inSnippet' => true, 'snippetLine' => (int) $line];
        }

        return ['inSnippet' => false, 'file' => $file, 'line' => $line];
    }

    private static function cleanMessage(string $message): string
    {
        return (string) preg_replace("/(?:Standard input code|\\S+)\\(\\d+\\) : eval\\(\\)'d code/", 'snippet', $message);
    }

    /**
     * Whether a backtrace file is the snippet. Other code the runner evaluates (such as the
     * DBAL 4 inspector middleware) is "eval()'d code" too, but from another line.
     */
    public static function isSnippetFile(string $file): bool
    {
        $suffix = self::$evalLine > 0 ? '(' . self::$evalLine . ") : eval()'d code" : "eval()'d code";

        return substr($file, -strlen($suffix)) === $suffix;
    }

    /** @param array<string, mixed> $overrides */
    private static function emitThrowable(string $stage, \Throwable $error, array $overrides = []): void
    {
        $payload = $overrides + [
            'stage' => $stage,
            'className' => get_class($error),
            'message' => self::cleanMessage($error->getMessage()),
            'code' => is_int($error->getCode()) ? $error->getCode() : (string) $error->getCode(),
        ] + self::location($error->getFile(), $error->getLine());

        if (!($payload['inSnippet'] ?? false)) {
            foreach ($error->getTrace() as $frame) {
                if (isset($frame['file']) && self::isSnippetFile($frame['file'])) {
                    $payload['snippetLine'] = (int) ($frame['line'] ?? 0);
                    break;
                }
            }
        }

        $frames = [];
        foreach (array_slice(self::userTrace($error->getTrace()), 0, 40) as $frame) {
            $item = ['function' => ($frame['class'] ?? '') . ($frame['type'] ?? '') . ($frame['function'] ?? '')];
            $item += self::location($frame['file'] ?? null, $frame['line'] ?? null);
            $frames[] = $item;
        }
        $payload['trace'] = $frames;

        $previous = $error->getPrevious();
        if ($previous !== null) {
            $payload['previous'] = ['className' => get_class($previous), 'message' => $previous->getMessage()];
        }

        Channel::emit('error', $payload);
    }

    /**
     * Drops the runner's own frames (eval() and everything below it).
     *
     * @param array<int, array<string, mixed>> $trace
     * @return array<int, array<string, mixed>>
     */
    private static function userTrace(array $trace): array
    {
        $result = [];
        foreach ($trace as $frame) {
            if (($frame['function'] ?? '') === 'eval' || strpos((string) ($frame['class'] ?? ''), 'RunletRunner\\') === 0) {
                break;
            }
            $result[] = $frame;
        }

        return $result;
    }

    private static function finish(string $reason, ?float $executeStarted = null): void
    {
        if (self::$finished) {
            return;
        }
        self::$finished = true;
        self::$state = 'finished';
        Probe::finish();
        self::emitProfile();
        if (self::$inspector !== null) {
            self::$inspector->finish();
        }
        $payload = [
            'reason' => $reason,
            'elapsedMs' => (int) round((microtime(true) - self::$startedAt) * 1000),
            'peakMemory' => \Runlet\Benchmark::realPeakMemory(),
        ];
        if ($executeStarted !== null) {
            $payload['executeMs'] = (int) round((microtime(true) - $executeStarted) * 1000);
        }
        Channel::emit('runnerFinished', $payload);
    }

    public static function shutdown(): void
    {
        if (self::$finished) {
            return;
        }
        $error = error_get_last();
        $fatalTypes = E_ERROR | E_PARSE | E_CORE_ERROR | E_COMPILE_ERROR | E_USER_ERROR | E_RECOVERABLE_ERROR;
        $driver = self::$driverContext;
        $driverFields = $driver === null ? [] : array_filter(['driverFile' => $driver['file'], 'driverClass' => $driver['class']]);
        if ($error !== null && ($error['type'] & $fatalTypes) !== 0) {
            $stage = in_array(self::$state, ['execute', 'commands', 'panels'], true) ? 'execute' : (self::$state === 'parse' ? 'parse' : 'bootstrap');
            $message = self::cleanMessage($error['message']);
            Channel::emit('error', [
                'stage' => $stage,
                'className' => 'FatalError',
                'message' => $driver === null ? $message : $driver['context'] . ': ' . $message,
                'fatal' => true,
            ] + $driverFields + self::location($error['file'], $error['line']));
            self::finish('fatal');

            return;
        }

        if (self::$state === 'bootstrap') {
            // exit()/die() while booting the application: nothing would explain the empty run.
            $message = ($driver === null ? 'The application' : $driver['context'] . ': the driver') . ' called exit() while Runlet was bootstrapping it.';
            $hint = self::bootstrapExitHint();
            Channel::emit('error', [
                'stage' => 'bootstrap',
                'className' => 'Exit',
                'message' => $hint === '' ? $message : $message . ' ' . $hint,
            ] + $driverFields);
            self::finish('error');

            return;
        }

        if (self::$state === 'commands' || self::$state === 'panels') {
            Channel::emit('error', [
                'stage' => 'execute',
                'className' => 'Exit',
                'message' => ($driver === null ? 'The application' : $driver['context'] . ': the driver') . ' called exit() while Runlet was ' . (self::$state === 'panels' ? 'reading its App Info.' : 'listing its commands.'),
            ] + $driverFields);
            self::finish('error');

            return;
        }

        self::finish(self::$ddCalled ? 'dd' : 'exit');
    }
}
