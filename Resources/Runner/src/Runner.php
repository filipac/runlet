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
        $node = ['id' => $id, 'type' => 'object', 'className' => $class, 'referenceId' => (string) $objectId];

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
     * Returns [evalCode, prefixLength, hasImplicitResult, notice].
     *
     * With $strictTypes, `declare(strict_types=1);` becomes the first statement unless the
     * snippet declares strict_types itself. Line numbers never change.
     *
     * @return array{0: string, 1: int, 2: bool, 3: string|null}
     */
    public static function compile(string $code, bool $strictTypes = false): array
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
            $last = $list[count($list) - 1];
            if ($last instanceof \RunletVendor\PhpParser\Node\Stmt\Namespace_) {
                $container = $last;
                $list = $last->stmts ?? [];
                continue;
            }
            break;
        }

        $last = count($list) > 0 ? $list[count($list) - 1] : null;
        $hasResult = false;
        /** @var array<int, array{0: int, 1: int, 2: string}> $edits [start, length, replacement] */
        $edits = [];
        if ($last instanceof \RunletVendor\PhpParser\Node\Stmt\Expression && !($last->expr instanceof \RunletVendor\PhpParser\Node\Expr\Exit_)) {
            $start = $last->getStartFilePos();
            $end = $last->getEndFilePos();
            $exprStart = $last->expr->getStartFilePos();
            $exprEnd = $last->expr->getEndFilePos();
            $expression = substr($source, $exprStart, $exprEnd - $exprStart + 1);
            $edits[] = [$start, $end - $start + 1, 'return ' . $expression . ';'];
            $hasResult = true;
        } elseif ($last instanceof \RunletVendor\PhpParser\Node\Stmt\Return_) {
            $hasResult = true;
        }

        $sentinel = "\nreturn \\RunletRunner\\NoResult::instance();";
        if ($container !== null && self::isBracedNamespace($source, $container)) {
            $edits[] = [$container->getEndFilePos(), 0, $sentinel . "\n"];
        } else {
            $edits[] = [strlen($source), 0, (self::endsOutsidePhp($source) ? '<?php ' : '') . $sentinel];
        }

        // Apply back to front so earlier offsets stay valid.
        usort($edits, static function (array $a, array $b): int {
            return $b[0] <=> $a[0];
        });
        foreach ($edits as $edit) {
            $source = substr($source, 0, $edit[0]) . $edit[2] . substr($source, $edit[0] + $edit[1]);
        }
        // Last: the edits above never touch the opening tag, so their offsets stay valid.
        if ($applyStrictTypes) {
            $source = self::withStrictTypes($source);
        }

        return [self::evalReady($source), strlen($prefix), $hasResult, null];
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
        if (!is_array($request) || !isset($request['nonce'], $request['code'])) {
            fwrite(fopen('php://stderr', 'wb'), "Runlet runner: invalid request\n");
            exit(70);
        }
        self::$request = $request;
        Channel::open((string) $request['nonce']);
        self::$normalizer = new ValueNormalizer(is_array($request['limits'] ?? null) ? $request['limits'] : []);

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
        ]);

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
        self::installDumpHandler();

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
        Channel::emit('bootstrapped', $bootstrapped);

        self::$state = 'parse';
        try {
            [$evalCode, $prefixLength, $hasResult, $notice] = SnippetCompiler::compile((string) $request['code'], ($request['strictTypes'] ?? false) === true);
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

        self::$state = 'execute';
        $executeStarted = microtime(true);
        try {
            $value = self::evaluate($evalCode);
        } catch (\Throwable $error) {
            self::emitThrowable($error instanceof \ParseError ? 'parse' : 'execute', $error);
            self::finish('error', $executeStarted);

            return;
        }

        if ($value instanceof NoResult) {
            Channel::emit('result', ['hasValue' => false]);
        } else {
            Channel::emit('result', ['hasValue' => true, 'value' => self::normalize($value)]);
        }
        self::finish('completed', $executeStarted);
    }

    /** @return mixed */
    private static function evaluate(string $__runletCode)
    {
        // Evaluated in its own function scope: snippet variables never leak into the runner.
        // Driver variables come first; EXTR_SKIP and the name checks in collectVariables()
        // keep them from replacing $__runletCode.
        extract(self::$variables, EXTR_SKIP);

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
     * @return array{framework: string, version: string|null, name: string, file: string|null}
     */
    private static function bootstrap(string $projectPath, string $requested): array
    {
        $driver = null;
        $file = null;
        if (isset(self::BUILTIN_DRIVERS[$requested])) {
            $class = self::BUILTIN_DRIVERS[$requested];
            $driver = new $class();
        } else {
            [$driver, $file] = self::discoverProjectDriver($projectPath);
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
            'file' => $file,
        ];
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
        foreach (debug_backtrace(DEBUG_BACKTRACE_IGNORE_ARGS) as $frame) {
            $function = $frame['function'] ?? '';
            $class = $frame['class'] ?? '';
            $short = substr((string) strrchr('\\' . $function, '\\'), 1);
            if ($short === 'dd' && $class === '') {
                $origin = 'dd';
                self::$ddCalled = true;
            }
            if ($callerFrame === null && ($short === 'dump' || $short === 'dd') && $class === '') {
                $callerFrame = $frame;
            }
            if ($snippetFrame === null && isset($frame['file']) && self::isSnippetFile($frame['file'])) {
                $snippetFrame = $frame;
            }
        }
        $frame = $snippetFrame ?? $callerFrame;

        self::$dumpCount++;
        $payload = ['index' => self::$dumpCount, 'origin' => $origin, 'value' => self::normalize($value)];
        if ($label !== null && $label !== '') {
            $payload['label'] = (string) $label;
        }
        if ($frame !== null) {
            $payload += self::location($frame['file'] ?? null, $frame['line'] ?? null);
        }
        Channel::emit('dump', $payload);
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

    private static function isSnippetFile(string $file): bool
    {
        return substr($file, -strlen("eval()'d code")) === "eval()'d code";
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
        $payload = [
            'reason' => $reason,
            'elapsedMs' => (int) round((microtime(true) - self::$startedAt) * 1000),
            'peakMemory' => memory_get_peak_usage(true),
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
            $stage = self::$state === 'execute' ? 'execute' : (self::$state === 'parse' ? 'parse' : 'bootstrap');
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
            Channel::emit('error', [
                'stage' => 'bootstrap',
                'className' => 'Exit',
                'message' => ($driver === null ? 'The application' : $driver['context'] . ': the driver') . ' called exit() while Runlet was bootstrapping it.',
            ] + $driverFields);
            self::finish('error');

            return;
        }

        self::finish(self::$ddCalled ? 'dd' : 'exit');
    }
}
