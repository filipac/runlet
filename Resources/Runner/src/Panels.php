<?php

declare(strict_types=1);

/*
 * App Info panels (#19).
 *
 * A request with `"mode": "panels"` boots the project exactly like a run, runs no snippet,
 * and reports key/value sections about the application instead: built-in ones for Laravel
 * (the data `artisan about` shows), Symfony, and WordPress, a PHP section for every target,
 * and then the driver's own `panels()`. Two `panels` events carry them (`origin` "builtin",
 * then "driver"), so a driver whose panels() fails or exits still leaves the built-ins.
 *
 * Everything is bounded (sections, rows, key and value lengths, total bytes) and passes
 * through the same redaction rule before it leaves the process: values whose key names a
 * secret (password, secret, token, key, salt, credential, …) are replaced, and so are
 * secret-looking values anywhere (credentials in URLs and DSNs, `password=` pairs, Laravel
 * `base64:` keys, JWTs, private key blocks, well-known API token prefixes). The app applies
 * the same rule again when it decodes the panels (`AppInfoRedaction` in RunletCore).
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace RunletRunner;

final class AppInfo
{
    /** Most sections in all, rows per section, items in a list value. */
    public const MAX_SECTIONS = 20;
    public const MAX_ROWS = 100;
    public const MAX_LIST = 50;
    /** Longest section title, row key, and value (bytes, cut on a UTF-8 boundary). */
    public const MAX_TITLE = 120;
    public const MAX_KEY = 200;
    public const MAX_VALUE = 2000;
    /** Bytes of keys and values in all; later rows are left out and counted. */
    public const MAX_BYTES = 262144;
    /** What a redacted value shows. */
    public const REDACTED = '••••••';

    /** Words that make a key a secret (after splitting on case changes and punctuation). */
    private const SECRET_WORDS = ['password', 'passwords', 'passwd', 'pwd', 'pass', 'passphrase', 'secret', 'secrets', 'token', 'tokens',
        'key', 'keys', 'apikey', 'salt', 'salts', 'credential', 'credentials', 'signature', 'cookie', 'cookies', 'dsn', 'nonce'];
    /** Substrings of a key with its punctuation removed ("APIKEY", "dbpassword"). */
    private const SECRET_PARTS = ['password', 'passwd', 'secret', 'token', 'apikey', 'privatekey', 'accesskey', 'credential'];

    /** @var int */
    private static $sections = 0;
    /** @var int */
    private static $bytes = 0;
    /** @var string */
    private static $root = '';
    /** @var string */
    private static $home = '';

    /**
     * The built-in sections: the framework's own (by the driver that booted the project), then
     * PHP. A built-in that fails becomes a note; the others are still reported.
     *
     * A driver that extends LaravelDriver or SymfonyDriver gets that framework's section from
     * the application it booted; any driver gets the Laravel sections when it bootstrapped
     * Laravel's global application, and the WordPress ones once WordPress is loaded.
     *
     * @return array<string, mixed> the `panels` event payload
     */
    public static function builtin(\Runlet\Driver $driver, string $projectPath, string $source): array
    {
        self::$root = rtrim($projectPath, '/');
        $home = getenv('HOME');
        self::$home = is_string($home) && strlen($home) > 1 ? rtrim($home, '/') : '';
        $notes = [];
        $sections = [];
        $collectors = [];
        $app = $driver instanceof \Runlet\Drivers\LaravelDriver ? self::protectedProperty($driver, \Runlet\Drivers\LaravelDriver::class, 'app') : self::bootedLaravel();
        if (is_object($app)) {
            $collectors['Laravel'] = static function () use ($app, &$notes): array {
                try {
                    return self::laravel($app);
                } catch (\Throwable $error) {
                    // `about`'s data could not be read (a package's section failed, say).
                    $notes[] = 'Runlet could not read the data of `artisan about` (' . $error->getMessage() . '), so it shows the configuration instead.';

                    return self::laravelConfig($app);
                }
            };
        } elseif ($driver instanceof \Runlet\Drivers\SymfonyDriver) {
            $kernel = self::protectedProperty($driver, \Runlet\Drivers\SymfonyDriver::class, 'kernel');
            if (is_object($kernel)) {
                $collectors['Symfony'] = static function () use ($kernel): array {
                    return self::symfony($kernel);
                };
            }
        } elseif ($driver instanceof \Runlet\Drivers\WordPressDriver || (defined('ABSPATH') && function_exists('get_bloginfo'))) {
            $collectors['WordPress'] = static function (): array {
                return self::wordpress();
            };
        }
        $collectors['PHP'] = static function (): array {
            return self::php();
        };
        foreach ($collectors as $name => $collect) {
            try {
                $sections = array_merge($sections, $collect());
            } catch (\Throwable $error) {
                $notes[] = 'Runlet could not read the ' . $name . ' details: ' . $error->getMessage();
            }
        }

        return self::payload('builtin', $source, $sections, $notes);
    }

    /**
     * The driver's panels() as a `panels` event payload: sections keyed by title
     * (`'Acme' => ['Tenant' => 'acme', …]`), or a list of `['title' => …, 'rows' => …]`.
     *
     * @param mixed $panels what panels() returned
     * @return array<string, mixed>
     */
    public static function driver($panels, string $source): array
    {
        $notes = [];
        $sections = [];
        if (!is_array($panels)) {
            $notes[] = $source . ' returned ' . gettype($panels) . ' from panels(), not an array of sections.';
            $panels = [];
        }
        $skipped = [];
        foreach ($panels as $key => $entry) {
            if (is_array($entry) && is_int($key) && isset($entry['title']) && is_scalar($entry['title']) && is_array($entry['rows'] ?? null)) {
                $sections[] = [(string) $entry['title'], $entry['rows']];
            } elseif (is_array($entry) && is_string($key)) {
                $sections[] = [$key, $entry];
            } else {
                $skipped[] = is_string($key) ? $key : '#' . $key;
            }
        }
        if ($skipped !== []) {
            $notes[] = $source . ' returned panels that are not sections of rows, which Runlet skipped: ' . implode(', ', array_slice($skipped, 0, 10)) . '.';
        }

        return self::payload('driver', $source, $sections, $notes);
    }

    /**
     * Bounds and redacts sections given as [title, rows] pairs.
     *
     * @param array<int, array{0: string, 1: array<mixed>}> $sections
     * @param string[] $notes
     * @return array<string, mixed>
     */
    private static function payload(string $origin, string $source, array $sections, array $notes): array
    {
        $result = [];
        $omittedSections = 0;
        $redacted = 0;
        $omittedBytes = 0;
        foreach ($sections as [$title, $rows]) {
            if (self::$sections >= self::MAX_SECTIONS) {
                $omittedSections++;
                continue;
            }
            self::$sections++;
            $title = trim(self::clip(self::plain($title), self::MAX_TITLE));
            $section = ['title' => $title === '' ? 'Untitled' : $title, 'rows' => []];
            $omittedRows = 0;
            $index = 0;
            foreach ($rows as $key => $value) {
                $index++;
                if (is_int($key) && is_array($value) && (isset($value['key']) || isset($value['label'])) && array_key_exists('value', $value)) {
                    $key = $value['key'] ?? $value['label'];
                    $value = $value['value'];
                }
                if (count($section['rows']) >= self::MAX_ROWS || self::$bytes >= self::MAX_BYTES) {
                    $omittedRows++;
                    continue;
                }
                $key = trim(self::clip(self::paths(self::plain(is_scalar($key) ? (string) $key : '#' . $index)), self::MAX_KEY));
                $row = ['key' => $key === '' ? '#' . $index : $key];
                if (self::isSecretKey($row['key'])) {
                    $row['value'] = self::REDACTED;
                    $row['redacted'] = true;
                } else {
                    $value = self::value($value);
                    $masked = self::redactValue($value);
                    if ($masked !== $value) {
                        $row['redacted'] = true;
                    }
                    $row['value'] = $masked;
                }
                if (isset($row['redacted'])) {
                    $redacted++;
                }
                $size = strlen($row['key']) + strlen((string) json_encode($row['value'], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PARTIAL_OUTPUT_ON_ERROR));
                if (self::$bytes + $size > self::MAX_BYTES) {
                    self::$bytes = self::MAX_BYTES;
                    $omittedBytes++;
                    $omittedRows++;
                    continue;
                }
                self::$bytes += $size;
                $section['rows'][] = $row;
            }
            if ($omittedRows > 0) {
                $section['omittedRows'] = $omittedRows;
            }
            $result[] = $section;
        }
        if ($omittedSections > 0) {
            $notes[] = 'Runlet shows at most ' . self::MAX_SECTIONS . ' sections and left out ' . $omittedSections . ($omittedSections === 1 ? ' section' : ' sections') . ' from ' . $source . '.';
        }
        if ($omittedBytes > 0) {
            $notes[] = 'App Info is limited to ' . (self::MAX_BYTES / 1024) . ' KB, so ' . $omittedBytes . ($omittedBytes === 1 ? ' row' : ' rows') . ' from ' . $source . ' were left out.';
        }
        $payload = ['origin' => $origin, 'source' => $source, 'sections' => $result, 'redacted' => $redacted];
        if ($omittedSections > 0) {
            $payload['omittedSections'] = $omittedSections;
        }
        if ($notes !== []) {
            $payload['notes'] = array_map(static function (string $note): string {
                return self::clip($note, 1000);
            }, $notes);
        }

        return $payload;
    }

    // MARK: Redaction

    /** Whether a key names a secret: "APP_KEY", "DB_PASSWORD", "stripeSecret", "API token". */
    public static function isSecretKey(string $key): bool
    {
        $spaced = (string) preg_replace('/([a-z0-9])([A-Z])/', '$1 $2', $key);
        $words = preg_split('/[^a-z0-9]+/', strtolower($spaced), -1, PREG_SPLIT_NO_EMPTY) ?: [];
        foreach ($words as $word) {
            if (in_array($word, self::SECRET_WORDS, true)) {
                return true;
            }
        }
        $joined = implode('', $words);
        foreach (self::SECRET_PARTS as $part) {
            if (strpos($joined, $part) !== false) {
                return true;
            }
        }

        return false;
    }

    /**
     * Masks secret-looking parts of a value: the password in `scheme://user:password@host`,
     * `password=…` style pairs, and whole tokens (Laravel `base64:` keys, JWTs, private key
     * blocks, Stripe/GitHub/GitLab/Slack/AWS/Google keys, `Bearer …`). Lists are masked item
     * by item. Other values are returned unchanged.
     *
     * @param mixed $value
     * @return mixed
     */
    public static function redactValue($value)
    {
        if (is_array($value)) {
            return array_map([self::class, 'redactValue'], $value);
        }
        if (!is_string($value) || $value === '') {
            return $value;
        }
        $masked = (string) preg_replace('~-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(-----END [A-Z0-9 ]*PRIVATE KEY-----|$)~s', self::REDACTED, $value);
        $masked = (string) preg_replace('~^base64:[A-Za-z0-9+/]{16,}={0,2}$~', self::REDACTED, $masked);
        // user:password@ in URLs and DSNs (the user stays).
        $masked = (string) preg_replace('~([a-z][a-z0-9+.\-]*://[^:/?#@\s]*):[^@/?#\s]+@~i', '$1:' . self::REDACTED . '@', $masked);
        // password=…, token: …, api_key=… inside connection strings and query strings.
        $masked = (string) preg_replace('~\b((?:[a-z0-9]+[_\-.])*(?:password|passwd|pwd|pass|secret|token|api[_\-]?key|access[_\-]?key|private[_\-]?key|auth[_\-]?key|signature|sig))(\s*[=:]\s*)("[^"]*"|\'[^\']*\'|[^;&,\s]+)~i', '$1$2' . self::REDACTED, $masked);
        $masked = (string) preg_replace([
            '~\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}~',
            '~\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{10,}~',
            '~\bgh[pousr]_[A-Za-z0-9]{20,}~',
            '~\bgithub_pat_[A-Za-z0-9_]{20,}~',
            '~\bglpat-[A-Za-z0-9_\-]{16,}~',
            '~\bxox[abprs]-[A-Za-z0-9\-]{10,}~',
            '~\bAKIA[0-9A-Z]{16}\b~',
            '~\bAIza[0-9A-Za-z_\-]{35}\b~',
            '#\b(Bearer|Basic)\s+[A-Za-z0-9._~+/\-]{16,}=*#',
        ], [self::REDACTED, self::REDACTED, self::REDACTED, self::REDACTED, self::REDACTED, self::REDACTED, self::REDACTED, self::REDACTED, '$1 ' . self::REDACTED], $masked);

        return $masked;
    }

    // MARK: Values

    /**
     * A row value: null, bool, int, a finite float, a string, or a list of strings; anything
     * else becomes a short string. Strings are bounded and paths are shortened.
     *
     * @param mixed $value
     * @return mixed
     */
    private static function value($value, int $depth = 0)
    {
        if ($value === null || is_bool($value) || is_int($value)) {
            return $value;
        }
        if (is_float($value)) {
            return is_finite($value) ? $value : (string) $value;
        }
        if (is_string($value)) {
            return self::clip(self::paths(self::plain($value)), self::MAX_VALUE);
        }
        if (is_array($value)) {
            $isList = $value === [] || array_keys($value) === range(0, count($value) - 1);
            if ($isList && $depth === 0) {
                $items = [];
                foreach (array_slice($value, 0, self::MAX_LIST) as $item) {
                    $item = self::value($item, 1);
                    $items[] = is_string($item) ? $item : self::scalarText($item);
                }
                if (count($value) > self::MAX_LIST) {
                    $items[] = '… ' . (count($value) - self::MAX_LIST) . ' more';
                }

                return $items;
            }
            $json = json_encode(self::jsonable($value, 0), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PARTIAL_OUTPUT_ON_ERROR);

            return self::clip(self::paths(is_string($json) ? $json : 'array(' . count($value) . ')'), self::MAX_VALUE);
        }
        if (is_object($value)) {
            return self::clip(self::paths(self::objectText($value)), self::MAX_VALUE);
        }

        return gettype($value);
    }

    /** @param mixed $value */
    private static function scalarText($value): string
    {
        if ($value === null) {
            return 'null';
        }
        if (is_bool($value)) {
            return $value ? 'true' : 'false';
        }

        return is_scalar($value) ? (string) $value : (string) json_encode($value);
    }

    private static function objectText(object $value): string
    {
        try {
            if ($value instanceof \DateTimeInterface) {
                return $value->format(DATE_ATOM);
            }
            if (function_exists('enum_exists') && $value instanceof \UnitEnum) {
                return $value instanceof \BackedEnum ? (string) $value->value : $value->name;
            }
            if (method_exists($value, '__toString')) {
                return (string) $value;
            }
            if ($value instanceof \JsonSerializable) {
                $json = json_encode($value, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PARTIAL_OUTPUT_ON_ERROR);

                return is_string($json) ? $json : get_class($value);
            }
        } catch (\Throwable $error) {
            // Fall back to the class name.
        }

        return \Runlet\Inspector::className(get_class($value)) . ' object';
    }

    /**
     * Nested arrays for JSON text: scalars as they are, objects as text, depth 3.
     *
     * @param mixed $value
     * @return mixed
     */
    private static function jsonable($value, int $depth)
    {
        if (is_array($value)) {
            if ($depth >= 3) {
                return 'array(' . count($value) . ')';
            }
            $result = [];
            foreach (array_slice($value, 0, self::MAX_LIST, true) as $key => $item) {
                $result[$key] = self::isSecretKey((string) $key) ? self::REDACTED : self::jsonable($item, $depth + 1);
            }

            return $result;
        }
        if (is_object($value)) {
            return self::objectText($value);
        }

        return is_float($value) && !is_finite($value) ? (string) $value : $value;
    }

    /** Removes console style tags (`<fg=yellow;options=bold>`, `</>`, `<info>`) and trims. */
    private static function plain(string $text): string
    {
        return trim((string) preg_replace('~</?(?:fg|bg|options|href)=[^>]*>|</>|</?(?:info|comment|question|error|warning)>~', '', $text));
    }

    /** Paths inside the project become relative to it; paths in the home folder start with ~. */
    private static function paths(string $text): string
    {
        if (self::$root !== '' && self::$root !== '/' && strpos($text, self::$root) !== false) {
            $root = preg_quote(self::$root, '~');
            $text = (string) preg_replace(['~' . $root . '/~', '~' . $root . '(?![\w.\-])~'], ['', '.'], $text);
        }
        if (self::$home !== '' && strpos($text, self::$home . '/') !== false) {
            $text = str_replace(self::$home . '/', '~/', $text);
        }

        return $text;
    }

    private static function clip(string $text, int $limit): string
    {
        [$clipped, $omitted] = \Runlet\Inspector::clip($text, $limit);

        return $omitted > 0 ? $clipped . '…' : $clipped;
    }

    /** Laravel's global application, when a project driver bootstrapped it. */
    private static function bootedLaravel(): ?object
    {
        $application = 'Illuminate\Foundation\Application';
        if (!class_exists($application, false) || !class_exists('Illuminate\Container\Container', false)) {
            return null;
        }
        $app = \Illuminate\Container\Container::getInstance();

        return $app instanceof $application && method_exists($app, 'hasBeenBootstrapped') && $app->hasBeenBootstrapped() ? $app : null;
    }

    /** @return mixed */
    private static function protectedProperty(object $object, string $class, string $name)
    {
        try {
            $property = new \ReflectionProperty($class, $name);
            $property->setAccessible(true);

            return $property->getValue($object);
        } catch (\Throwable $error) {
            return null;
        }
    }

    // MARK: Laravel

    /**
     * What `artisan about` shows (Environment, Cache, Drivers, Storage, and sections packages
     * add with AboutCommand::add()), read in-process from the command's data provider with
     * the console wording ("Enabled", "Not cached", "stack / single"). Runlet doesn't run
     * `composer --version` for it, so Composer's version is left out. Lumen and Laravel before
     * 9.21 have no `about`; they get the same rows from the configuration.
     *
     * @return array<int, array{0: string, 1: array<string, mixed>}>
     */
    private static function laravel(object $app): array
    {
        $about = 'Illuminate\Foundation\Console\AboutCommand';
        if (!class_exists($about) || !method_exists($about, 'format') || !method_exists($about, 'gatherApplicationInformation') || !method_exists($app, 'call')) {
            return self::laravelConfig($app);
        }
        $composer = self::quietComposer($app);
        $command = $composer !== null ? new $about($composer) : $app->make($about);
        if (method_exists($command, 'setLaravel')) {
            $command->setLaravel($app);
        }
        $gather = new \ReflectionMethod($about, 'gatherApplicationInformation');
        $gather->setAccessible(true);
        $gather->invoke($command);
        $property = new \ReflectionProperty($about, 'data');
        $property->setAccessible(true);
        $data = $property->getValue();
        if (!is_array($data)) {
            return self::laravelConfig($app);
        }

        $sections = [];
        foreach ($data as $title => $items) {
            $rows = [];
            foreach ((array) $items as $item) {
                if (is_array($item)) {
                    $pairs = [$item];
                } else {
                    $resolver = is_string($item) ? $app->make($item) : $item;
                    $pairs = [];
                    foreach ((array) $app->call($resolver) as $key => $value) {
                        $pairs[] = [$key, $value];
                    }
                }
                foreach ($pairs as $pair) {
                    if (!is_array($pair) || !array_key_exists(0, $pair)) {
                        continue;
                    }
                    $value = $pair[1] ?? null;
                    if ($value instanceof \Closure) {
                        $value = $value(false);
                    }
                    if ($composer !== null && (string) $pair[0] === 'Composer Version') {
                        continue;
                    }
                    $rows[(string) $pair[0]] = is_string($value) ? self::consoleWords($value) : $value;
                }
            }
            $sections[(string) $title] = $rows;
        }
        // `about` lists Environment, Cache, and Drivers first, in that order.
        $order = ['Environment', 'Cache', 'Drivers'];
        uksort($sections, static function ($left, $right) use ($order): int {
            $a = array_search($left, $order, true);
            $b = array_search($right, $order, true);

            return ($a === false ? 99 : $a) <=> ($b === false ? 99 : $b);
        });
        $result = [];
        foreach ($sections as $title => $rows) {
            $result[] = [(string) $title, $rows];
        }

        return $result;
    }

    /**
     * Illuminate\Support\Composer without `composer --version` (a process Runlet doesn't
     * start), when getVersion() can be overridden safely; else null (the container's).
     */
    private static function quietComposer(object $app): ?object
    {
        $class = 'Illuminate\Support\Composer';
        try {
            if (!class_exists($class) || !method_exists($app, 'make') || !method_exists($app, 'basePath')) {
                return null;
            }
            $method = new \ReflectionMethod($class, 'getVersion');
            $constructor = new \ReflectionMethod($class, '__construct');
            if ($method->hasReturnType() || $method->getNumberOfParameters() > 0 || $constructor->getNumberOfRequiredParameters() > 2) {
                return null;
            }

            return new class($app->make('files'), $app->basePath()) extends \Illuminate\Support\Composer {
                public function getVersion()
                {
                    return null;
                }
            };
        } catch (\Throwable $error) {
            return null;
        }
    }

    /** "ENABLED" → "Enabled", "NOT CACHED" → "Not cached"; other text unchanged. */
    private static function consoleWords(string $value): string
    {
        $value = trim(strip_tags($value));
        if (preg_match('/^[A-Z][A-Z ]+$/', $value) && in_array($value, ['ENABLED', 'OFF', 'CACHED', 'NOT CACHED', 'LINKED', 'NOT LINKED'], true)) {
            return ucfirst(strtolower($value));
        }

        return $value;
    }

    /**
     * The configuration rows of `about`, for Lumen and Laravel without the command.
     *
     * @return array<int, array{0: string, 1: array<string, mixed>}>
     */
    private static function laravelConfig(object $app): array
    {
        $config = null;
        if (method_exists($app, 'bound') && $app->bound('config')) {
            $config = $app->make('config');
        }
        $get = static function (string $key) use ($config) {
            return is_object($config) && method_exists($config, 'get') ? $config->get($key) : null;
        };
        $version = method_exists($app, 'version') ? (string) $app->version() : null;
        $environment = method_exists($app, 'environment') ? $app->environment() : $get('app.env');
        $maintenance = method_exists($app, 'isDownForMaintenance') ? $app->isDownForMaintenance() : null;

        return array_values(array_filter([
            ['Environment', array_filter([
                'Application Name' => $get('app.name'),
                'Laravel Version' => $version,
                'PHP Version' => PHP_VERSION,
                'Environment' => is_string($environment) ? $environment : null,
                'Debug Mode' => $get('app.debug') ? 'Enabled' : 'Off',
                'URL' => is_string($get('app.url')) ? preg_replace('~^https?://~', '', (string) $get('app.url')) : null,
                'Maintenance Mode' => $maintenance === null ? null : ($maintenance ? 'Enabled' : 'Off'),
                'Timezone' => $get('app.timezone'),
                'Locale' => $get('app.locale'),
            ], static function ($value): bool {
                return $value !== null;
            })],
            ['Drivers', array_filter([
                'Broadcasting' => $get('broadcasting.default'),
                'Cache' => $get('cache.default'),
                'Database' => $get('database.default'),
                'Logs' => $get('logging.default'),
                'Mail' => $get('mail.default') ?? $get('mail.driver'),
                'Queue' => $get('queue.default'),
                'Session' => $get('session.driver'),
            ], static function ($value): bool {
                return $value !== null;
            })],
        ], static function (array $section): bool {
            return $section[1] !== [];
        }));
    }

    // MARK: Symfony

    /**
     * The kernel part of `bin/console about`: version and support dates, environment, debug,
     * charset, kernel class, cache and log folders, and the number of bundles.
     *
     * @return array<int, array{0: string, 1: array<string, mixed>}>
     */
    private static function symfony(object $kernel): array
    {
        $kernelClass = 'Symfony\Component\HttpKernel\Kernel';
        $constant = static function (string $name) use ($kernelClass): ?string {
            return defined($kernelClass . '::' . $name) ? (string) constant($kernelClass . '::' . $name) : null;
        };
        $call = static function (string $method) use ($kernel) {
            return method_exists($kernel, $method) ? $kernel->{$method}() : null;
        };
        $debug = $call('isDebug');
        $bundles = $call('getBundles');

        return [['Symfony', array_filter([
            'Version' => $constant('VERSION'),
            'End of maintenance' => $constant('END_OF_MAINTENANCE'),
            'End of life' => $constant('END_OF_LIFE'),
            'Environment' => $call('getEnvironment'),
            'Debug' => $debug === null ? null : ($debug ? 'Enabled' : 'Off'),
            'Charset' => $call('getCharset'),
            'Kernel' => get_class($kernel),
            'Cache directory' => $call('getCacheDir'),
            'Build directory' => $call('getBuildDir'),
            'Log directory' => $call('getLogDir'),
            'Bundles' => is_array($bundles) ? count($bundles) : null,
        ], static function ($value): bool {
            return $value !== null;
        })]];
    }

    // MARK: WordPress

    /**
     * WordPress version, environment type, URLs, theme, multisite, plugins, and the debug
     * constants from wp-config.php.
     *
     * @return array<int, array{0: string, 1: array<string, mixed>}>
     */
    private static function wordpress(): array
    {
        $call = static function (string $function, ...$arguments) {
            return function_exists($function) ? $function(...$arguments) : null;
        };
        $theme = $call('wp_get_theme');
        $themeName = null;
        if (is_object($theme) && method_exists($theme, 'get')) {
            $themeName = trim($theme->get('Name') . ' ' . $theme->get('Version'));
            if ($call('is_child_theme') === true && method_exists($theme, 'parent') && is_object($theme->parent())) {
                $themeName .= ' (child of ' . $theme->parent()->get('Name') . ')';
            }
        }
        $plugins = $call('get_option', 'active_plugins', []);
        $multisite = $call('is_multisite') === true;
        $network = $multisite ? $call('get_site_option', 'active_sitewide_plugins', []) : [];
        $permalinks = $call('get_option', 'permalink_structure');
        $site = array_filter([
            'Version' => $call('get_bloginfo', 'version'),
            'Environment type' => $call('wp_get_environment_type'),
            'Site URL' => $call('site_url'),
            'Home URL' => $call('home_url'),
            'Active theme' => $themeName,
            'Multisite' => $multisite ? 'Yes' : 'No',
            'Active plugins' => is_array($plugins) ? count($plugins) + (is_array($network) ? count($network) : 0) : null,
            'Permalinks' => is_string($permalinks) ? ($permalinks === '' ? 'Plain' : $permalinks) : null,
            'Locale' => $call('get_locale'),
            'Timezone' => $call('wp_timezone_string'),
        ], static function ($value): bool {
            return $value !== null && $value !== '';
        });

        $flag = static function (string $name) {
            if (!defined($name)) {
                return null;
            }
            $value = constant($name);

            return is_bool($value) ? ($value ? 'On' : 'Off') : $value;
        };
        $debug = array_filter([
            'WP_DEBUG' => $flag('WP_DEBUG'),
            'WP_DEBUG_LOG' => $flag('WP_DEBUG_LOG'),
            'WP_DEBUG_DISPLAY' => $flag('WP_DEBUG_DISPLAY'),
            'SCRIPT_DEBUG' => $flag('SCRIPT_DEBUG'),
            'SAVEQUERIES' => $flag('SAVEQUERIES'),
            'WP_CACHE' => $flag('WP_CACHE'),
            'DISABLE_WP_CRON' => $flag('DISABLE_WP_CRON'),
            'WP_MEMORY_LIMIT' => $flag('WP_MEMORY_LIMIT'),
        ], static function ($value): bool {
            return $value !== null;
        });

        global $wpdb;
        $database = [];
        if (is_object($wpdb)) {
            $server = method_exists($wpdb, 'db_server_info') ? $wpdb->db_server_info() : (method_exists($wpdb, 'db_version') ? $wpdb->db_version() : null);
            $database = array_filter([
                'Server' => is_string($server) ? $server : null,
                'Name' => defined('DB_NAME') ? (string) DB_NAME : null,
                'Host' => defined('DB_HOST') ? (string) DB_HOST : null,
                'Charset' => defined('DB_CHARSET') ? (string) DB_CHARSET : null,
                'Table prefix' => isset($wpdb->prefix) && is_string($wpdb->prefix) ? $wpdb->prefix : null,
            ], static function ($value): bool {
                return $value !== null && $value !== '';
            });
        }

        return array_values(array_filter([['WordPress', $site], ['Debug', $debug], ['Database', $database]], static function (array $section): bool {
            return $section[1] !== [];
        }));
    }

    // MARK: PHP

    /**
     * The PHP that boots the project: version, memory limit, OPcache and Xdebug for the CLI,
     * time zone, php.ini, PDO drivers, and how many extensions are loaded.
     *
     * @return array<int, array{0: string, 1: array<string, mixed>}>
     */
    private static function php(): array
    {
        $opcache = 'Not loaded';
        if (extension_loaded('Zend OPcache')) {
            $opcache = filter_var(ini_get('opcache.enable_cli'), FILTER_VALIDATE_BOOLEAN) ? 'Enabled' : 'Off for the CLI';
        }
        $xdebug = phpversion('xdebug');
        $mode = ini_get('xdebug.mode');
        $ini = php_ini_loaded_file();

        return [['PHP', array_filter([
            'Version' => PHP_VERSION,
            'Memory limit' => (string) ini_get('memory_limit'),
            'OPcache' => $opcache,
            'Xdebug' => is_string($xdebug) ? $xdebug . (is_string($mode) && $mode !== '' ? ' (mode: ' . $mode . ')' : '') : 'Not loaded',
            'Time zone' => date_default_timezone_get(),
            'php.ini' => is_string($ini) ? $ini : 'None',
            'PDO drivers' => class_exists('PDO') ? \PDO::getAvailableDrivers() : null,
            'Extensions' => count(get_loaded_extensions()),
        ], static function ($value): bool {
            return $value !== null;
        })]];
    }
}
