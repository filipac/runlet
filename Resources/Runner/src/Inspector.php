<?php

declare(strict_types=1);

/*
 * Runlet run inspector: the object drivers report queries, mail, log messages, HTML, and
 * their own sections to, plus the database hooks every driver inherits. Declared by the
 * runner before the driver API (Drivers.php). See docs/drivers.md, "Run inspector".
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace Runlet;

/**
 * The run inspector: what a run did besides its output. Runlet shows each section next to
 * the output: SQL queries, mail, log messages, HTML, and sections a driver defines itself
 * ("Cache", "HTTP calls", ...).
 *
 * Runlet creates one Inspector per snippet run and passes it to Driver::inspect() after
 * bootstrap() and before the snippet runs. Snippets reach it with Inspector::current().
 * No method throws, so all of them are safe inside event listeners. Recorded values are
 * bounded like other output, and recording stops at the run's limits (Runlet then reports
 * how many records it left out).
 */
final class Inspector
{
    public const QUERIES = 'Queries';
    public const MAIL = 'Mail';
    public const LOG = 'Log';
    public const HTML = 'HTML';

    /** @var Inspector|null */
    private static $current;

    /** @var \Closure(string, array<string, mixed>): void */
    private $emit;
    /** @var \Closure(mixed): array<string, mixed> */
    private $normalize;
    /** @var bool */
    private $enabled;
    /** @var bool */
    private $interceptMail;
    /** @var array<string, int> */
    private $limits;
    /** @var string[] */
    private $sections = [];
    /** @var int */
    private $index = 0;
    /** @var int */
    private $queries = 0;
    /** @var int */
    private $records = 0;
    /** @var int */
    private $bytes = 0;
    /** @var array<string, array{omitted: int, reason: string}> */
    private $omitted = [];
    /** @var array<string, true> */
    private $once = [];
    /** @var callable[] */
    private $finishers = [];
    /** @var bool */
    private $interceptingMail = false;
    /** @var string|null */
    private $interceptMailReason;
    /** @var bool */
    private $finished = false;

    /**
     * @internal Runlet creates the inspector for each run.
     * @param array<string, mixed> $options `enabled`, `interceptMail`, and the record limits
     */
    public function __construct(array $options, \Closure $emit, \Closure $normalize)
    {
        $this->enabled = ($options['enabled'] ?? false) === true;
        $this->interceptMail = ($options['interceptMail'] ?? false) === true;
        $this->emit = $emit;
        $this->normalize = $normalize;
        $this->limits = [
            'maxQueries' => max(0, (int) ($options['maxQueries'] ?? 2000)),
            'maxRecords' => max(0, (int) ($options['maxRecords'] ?? 2000)),
            'maxRecordBytes' => max(0, (int) ($options['maxRecordBytes'] ?? 8388608)),
            'maxBodyBytes' => max(0, (int) ($options['maxBodyBytes'] ?? 2097152)),
        ];
    }

    /** The current run's inspector, or null outside a snippet run (for example while Runlet lists commands). */
    public static function current(): ?self
    {
        return self::$current;
    }

    /** @internal */
    public static function setCurrent(?self $inspector): void
    {
        self::$current = $inspector;
    }

    /** Whether this run records anything; the inspector can be turned off in Runlet's settings. */
    public function isEnabled(): bool
    {
        return $this->enabled;
    }

    /** Shows $section in Runlet for this run even when nothing is recorded in it ("0 queries"). */
    public function section(string $section): void
    {
        $section = self::sectionName($section);
        if ($this->enabled && !in_array($section, $this->sections, true)) {
            $this->sections[] = $section;
        }
    }

    /**
     * Records one SQL statement in the Queries section.
     *
     * @param array<int|string, mixed> $bindings positional values (a list) or named ones (name => value)
     * @param float|null $ms how long the statement took, in milliseconds
     * @param string|null $connection the connection's name, shown next to the statement
     * @param array<string, mixed> $details optional `driver` (mysql, pgsql, sqlite, ...), `rawSql` (the
     *        statement with its bindings substituted by the database layer), and `location`
     *        (from location(), when the statement is reported after it ran), and `databaseAPI`
     *        (eloquent, doctrine, wordpress, pdo) for Explain's connection template (#4)
     */
    public function query(string $sql, array $bindings = [], ?float $ms = null, ?string $connection = null, array $details = []): void
    {
        if (!$this->enabled) {
            return;
        }
        try {
            [$text, $omittedBytes] = self::clip($sql, 65536);
            $data = ['sql' => $text];
            if ($omittedBytes > 0) {
                $data['omittedBytes'] = $omittedBytes;
            }
            $list = [];
            $shown = 0;
            foreach ($bindings as $name => $value) {
                if ($shown >= 100) {
                    break;
                }
                $shown++;
                $list[] = self::binding($value, is_string($name) ? ltrim($name, ':') : null);
            }
            $data['bindings'] = $list;
            if ($shown < count($bindings)) {
                $data['omittedBindings'] = count($bindings) - $shown;
            }
            if ($ms !== null && is_finite($ms)) {
                $data['timeMs'] = round($ms, 3);
            }
            if ($connection !== null && $connection !== '') {
                $data['connection'] = self::clip($connection, 200)[0];
            }
            if (isset($details['driver']) && is_string($details['driver']) && $details['driver'] !== '') {
                $data['driver'] = self::clip($details['driver'], 50)[0];
            }
            if (isset($details['databaseAPI']) && is_string($details['databaseAPI'])) {
                $data['databaseAPI'] = self::clip($details['databaseAPI'], 50)[0];
            }
            if (isset($details['rawSql']) && is_string($details['rawSql']) && $details['rawSql'] !== $sql) {
                $data['rawSql'] = self::clip($details['rawSql'], 65536)[0];
            }
            $location = isset($details['location']) && is_array($details['location']) ? $details['location'] : $this->location();
            $this->emitRecord(self::QUERIES, 'query', null, $data, $location);
        } catch (\Throwable $error) {
            // Recording must never break the code that ran the query.
        }
    }

    /**
     * Records one mail message in the Mail section: a Symfony Mime Email, a SwiftMailer
     * message, or an array with `subject`, `from`, `to`, `cc`, `bcc`, `replyTo` (addresses as
     * strings, `address => name` arrays, or Address objects), `html`, `text`, `attachments`
     * (each with `filename`, `contentType`, `size`), `mailer`, `mailable`, and `caller` (who
     * sent it, when that isn't the snippet: a plugin, a class).
     *
     * @param object|array<string, mixed> $message
     * @param array<string, mixed> $details merged over the message: `intercepted` (true when the
     *        mail was not sent), `error` (why sending failed), `queued`, `queueConnection`,
     *        `mailer`, `mailable`, `caller`, and `location` (from location(), for a message
     *        reported after it was sent)
     */
    public function mail($message, array $details = []): void
    {
        if (!$this->enabled) {
            return;
        }
        try {
            $fields = is_object($message) ? self::mimeMessage($message) : (is_array($message) ? $message : []);
            $fields = $details + $fields;
            $data = [];
            foreach (['subject', 'mailer', 'mailable', 'caller', 'queueConnection', 'queue'] as $key) {
                if (isset($fields[$key]) && is_scalar($fields[$key]) && (string) $fields[$key] !== '') {
                    $data[$key] = self::clip($key === 'mailable' ? self::className((string) $fields[$key]) : (string) $fields[$key], 1000)[0];
                }
            }
            foreach (['from', 'to', 'cc', 'bcc', 'replyTo'] as $key) {
                $data[$key] = self::addresses($fields[$key] ?? []);
            }
            $budget = $this->limits['maxBodyBytes'];
            foreach (['html', 'text'] as $key) {
                if (isset($fields[$key]) && is_string($fields[$key])) {
                    [$body, $omitted] = self::clip($fields[$key], $budget);
                    $data[$key] = $body;
                    if ($omitted > 0) {
                        $data[$key . 'OmittedBytes'] = $omitted;
                    }
                }
            }
            $attachments = [];
            foreach (is_array($fields['attachments'] ?? null) ? $fields['attachments'] : [] as $attachment) {
                if (count($attachments) >= 50 || !is_array($attachment)) {
                    continue;
                }
                $entry = [];
                foreach (['filename', 'contentType'] as $key) {
                    if (isset($attachment[$key]) && is_scalar($attachment[$key])) {
                        $entry[$key] = self::clip((string) $attachment[$key], 300)[0];
                    }
                }
                if (isset($attachment['size']) && is_int($attachment['size'])) {
                    $entry['size'] = $attachment['size'];
                }
                if (($attachment['inline'] ?? false) === true) {
                    $entry['inline'] = true;
                }
                $attachments[] = $entry;
            }
            $data['attachments'] = $attachments;
            $data['intercepted'] = ($fields['intercepted'] ?? false) === true;
            if (($fields['queued'] ?? false) === true) {
                $data['queued'] = true;
            }
            if (isset($fields['error']) && is_scalar($fields['error']) && (string) $fields['error'] !== '') {
                $data['error'] = self::clip((string) $fields['error'], 4000)[0];
            }
            $location = isset($details['location']) && is_array($details['location']) ? $details['location'] : $this->location();
            $this->emitRecord(self::MAIL, 'mail', null, $data, $location);
        } catch (\Throwable $error) {
            // Never break the mailer.
        }
    }

    /** Records rendered HTML (a page, an email, a fragment), previewed in a locked-down web view. */
    public function html(string $title, string $html, string $section = self::HTML): void
    {
        if (!$this->enabled) {
            return;
        }
        try {
            [$body, $omitted] = self::clip($html, $this->limits['maxBodyBytes']);
            $data = ['html' => $body];
            if ($omitted > 0) {
                $data['omittedBytes'] = $omitted;
            }
            $this->emitRecord(self::sectionName($section), 'html', $title, $data, $this->location());
        } catch (\Throwable $error) {
            // Never break the caller.
        }
    }

    /**
     * Records a log message in the Log section.
     *
     * @param array<mixed> $context shown as an expandable value
     */
    public function log(string $level, string $message, array $context = [], ?string $channel = null): void
    {
        if (!$this->enabled) {
            return;
        }
        try {
            $data = ['level' => strtolower(self::clip($level, 30)[0]), 'message' => self::clip($message, 16384)[0]];
            if ($channel !== null && $channel !== '') {
                $data['channel'] = self::clip($channel, 200)[0];
            }
            if ($context !== []) {
                $data['context'] = ($this->normalize)($context);
            }
            $this->emitRecord(self::LOG, 'log', null, $data, $this->location());
        } catch (\Throwable $error) {
            // Never break the logger.
        }
    }

    /**
     * Records any value under $title in a section of your own, such as "Cache" or
     * "HTTP calls". The value is shown like a dump (bounded, without calling its methods).
     *
     * @param mixed $value
     */
    public function record(string $section, string $title, $value): void
    {
        if (!$this->enabled) {
            return;
        }
        try {
            $this->emitRecord(self::sectionName($section), 'value', $title, ['value' => ($this->normalize)($value)], $this->location());
        } catch (\Throwable $error) {
            // Never break the caller.
        }
    }

    /**
     * @internal Records a benchmark (Runlet\bench(), Laravel's Benchmark::dd()) or a Profile
     * Run's profile. Recorded even with the inspector turned off: the run asked for them.
     *
     * @param array<string, mixed> $data
     * @param array<string, mixed>|null $location defaults to location()
     */
    public function measurement(string $section, string $kind, string $title, array $data, ?array $location = null): void
    {
        try {
            $this->emitRecord(self::sectionName($section), $kind, $title, $data, $location ?? $this->location());
        } catch (\Throwable $error) {
            // Never break the caller.
        }
    }

    /**
     * Records the queries a PDO connection runs through prepare() and execute(), for code
     * that uses PDO directly (PDO cannot be hooked globally). It installs a statement class
     * on $pdo, so it is skipped for connections that already use their own (as database
     * layers often do) and for persistent connections. PDO::query() and PDO::exec() are not
     * seen. Returns whether the connection is watched.
     */
    public function watchPdo(\PDO $pdo, string $connection = 'pdo'): bool
    {
        if (!$this->enabled || !class_exists(InspectedPdoStatement::class, false)) {
            return false;
        }
        if (!$this->once('pdo:' . spl_object_id($pdo))) {
            return true;
        }
        try {
            $current = $pdo->getAttribute(\PDO::ATTR_STATEMENT_CLASS);
            if (is_array($current) && isset($current[0]) && is_string($current[0]) && strcasecmp($current[0], 'PDOStatement') !== 0) {
                $this->notice('Runlet does not record queries on the "' . $connection . '" PDO connection: it already uses its own statement class (' . $current[0] . ').');

                return false;
            }
            $driver = (string) $pdo->getAttribute(\PDO::ATTR_DRIVER_NAME);
            $pdo->setAttribute(\PDO::ATTR_STATEMENT_CLASS, [InspectedPdoStatement::class, [$this, $connection, $driver]]);
            $this->section(self::QUERIES);

            return true;
        } catch (\Throwable $error) {
            $this->notice('Runlet does not record queries on the "' . $connection . '" PDO connection: ' . $error->getMessage());

            return false;
        }
    }

    /** Whether this run asks drivers to intercept mail instead of sending it (Runlet's Intercept Mail setting). */
    public function shouldInterceptMail(): bool
    {
        return $this->enabled && $this->interceptMail;
    }

    /**
     * Tells Runlet that this run intercepts mail: messages are recorded but not sent. Call it
     * from inspect() when your driver honours shouldInterceptMail(); Runlet warns when
     * interception was asked for and no driver confirmed it.
     */
    public function interceptingMail(): void
    {
        $this->interceptingMail = true;
    }

    /**
     * Tells Runlet why this run can't intercept mail although it was asked to ("A plugin
     * (acme-smtp) replaces wp_mail(); Runlet can't stop its mail."). Runlet adds it to its
     * warning. A driver that also calls interceptingMail() makes this moot.
     */
    public function cannotInterceptMail(string $reason): void
    {
        $this->interceptMailReason = self::clip(trim($reason), 1000)[0];
    }

    /** True the first time $key is passed during this run; hooks use it to attach only once. */
    public function once(string $key): bool
    {
        if (isset($this->once[$key])) {
            return false;
        }
        $this->once[$key] = true;

        return true;
    }

    /** Calls $callback when the run finishes, before Runlet reports it (to flush a query log, for example). */
    public function atFinish(callable $callback): void
    {
        $this->finishers[] = $callback;
    }

    /**
     * Where the code running now comes from: the snippet line, else the first project file
     * outside vendor/. Pass it as `location` to query() when you report a query later.
     *
     * @return array{inSnippet?: bool, snippetLine?: int, file?: string, line?: int}
     */
    public function location(): array
    {
        $candidate = [];
        foreach (debug_backtrace(DEBUG_BACKTRACE_IGNORE_ARGS) as $frame) {
            $file = $frame['file'] ?? null;
            if (!is_string($file)) {
                continue;
            }
            if (substr($file, -13) === "eval()'d code") {
                if (\RunletRunner\Runner::isSnippetFile($file)) {
                    return ['inSnippet' => true, 'snippetLine' => (int) ($frame['line'] ?? 0)];
                }
                continue;
            }
            if ($candidate === [] && strpos($file, 'Standard input code') !== 0 && $file !== '-' && strpos($file, '/vendor/') === false) {
                $candidate = ['inSnippet' => false, 'file' => $file, 'line' => (int) ($frame['line'] ?? 0)];
            }
        }

        return $candidate;
    }

    /** @internal Reports which sections this run shows and whether mail is intercepted. */
    public function ready(string $driverName): void
    {
        if (!$this->enabled) {
            return;
        }
        $payload = [
            'sections' => $this->sections,
            'interceptMail' => $this->interceptMail,
            'interceptingMail' => $this->interceptMail && $this->interceptingMail,
            'driverName' => $driverName,
        ];
        if ($this->interceptMail && !$this->interceptingMail && $this->interceptMailReason !== null && $this->interceptMailReason !== '') {
            $payload['interceptMailReason'] = $this->interceptMailReason;
        }
        ($this->emit)('inspector', $payload);
    }

    /** @internal Runs the finish callbacks and reports records left out by the limits. */
    public function finish(): void
    {
        if ($this->finished) {
            return;
        }
        foreach ($this->finishers as $callback) {
            try {
                $callback();
            } catch (\Throwable $error) {
                // A failing flush loses only its own records.
            }
        }
        $this->finished = true;
        foreach ($this->omitted as $section => $omitted) {
            ($this->emit)('recordLimit', ['section' => $section, 'omitted' => $omitted['omitted'], 'reason' => $omitted['reason']]);
        }
    }

    /**
     * @param array<string, mixed> $data
     * @param array<string, mixed> $location
     */
    private function emitRecord(string $section, string $kind, ?string $title, array $data, array $location): void
    {
        if ($this->finished) {
            return;
        }
        $this->section($section);
        $isQuery = $kind === 'query';
        if ($isQuery ? $this->queries >= $this->limits['maxQueries'] : $this->records >= $this->limits['maxRecords']) {
            $this->omit($section, 'count');

            return;
        }
        $size = strlen((string) json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PARTIAL_OUTPUT_ON_ERROR));
        if ($this->bytes + $size > $this->limits['maxRecordBytes']) {
            $this->omit($section, 'bytes');

            return;
        }
        $this->bytes += $size;
        if ($isQuery) {
            $this->queries++;
        } else {
            $this->records++;
        }
        $payload = ['index' => ++$this->index, 'section' => $section, 'kind' => $kind];
        if ($title !== null) {
            $payload['title'] = self::clip($title, 300)[0];
        }
        foreach (['inSnippet', 'snippetLine', 'file', 'line'] as $key) {
            if (isset($location[$key])) {
                $payload[$key] = $location[$key];
            }
        }
        $payload['data'] = $data;
        ($this->emit)('record', $payload);
    }

    private function omit(string $section, string $reason): void
    {
        if (!isset($this->omitted[$section])) {
            $this->omitted[$section] = ['omitted' => 0, 'reason' => $reason];
        }
        $this->omitted[$section]['omitted']++;
    }

    private function notice(string $message): void
    {
        ($this->emit)('notice', ['message' => $message]);
    }

    /**
     * A class name without the file and line PHP appends to anonymous classes
     * ("class@anonymous<NUL>/path:3$0").
     *
     * @internal
     */
    public static function className(string $class): string
    {
        $nul = strpos($class, "\0");

        return $nul === false ? $class : substr($class, 0, $nul);
    }

    private static function sectionName(string $section): string
    {
        $section = trim(self::clip(trim($section), 60)[0]);

        return $section === '' ? 'Custom' : $section;
    }

    /**
     * Valid UTF-8 cut to at most $limit bytes, and the number of bytes left out. Invalid
     * bytes become U+FFFD.
     *
     * @internal
     * @return array{0: string, 1: int}
     */
    public static function clip(string $text, int $limit): array
    {
        $omitted = 0;
        if (strlen($text) > $limit) {
            $omitted = strlen($text) - $limit;
            $text = substr($text, 0, $limit);
            for ($i = 0; $i < 4 && $text !== '' && preg_match('//u', $text) !== 1; $i++) {
                $text = substr($text, 0, -1);
                $omitted++;
            }
        }
        if (preg_match('//u', $text) !== 1) {
            $text = function_exists('mb_convert_encoding')
                ? (string) mb_convert_encoding($text, 'UTF-8', 'UTF-8')
                : (string) preg_replace('/[\x80-\xFF]/', "\u{FFFD}", $text);
        }

        return [$text, $omitted];
    }

    /**
     * @param mixed $value
     * @return array<string, mixed>
     */
    private static function binding($value, ?string $name): array
    {
        $entry = $name === null ? [] : ['name' => $name];
        if ($value === null) {
            return $entry + ['type' => 'null'];
        }
        if (is_bool($value)) {
            return $entry + ['type' => 'bool', 'value' => $value ? 'true' : 'false'];
        }
        if (is_int($value)) {
            return $entry + ['type' => 'int', 'value' => (string) $value];
        }
        if (is_float($value)) {
            return $entry + ['type' => 'float', 'value' => is_finite($value) ? var_export($value, true) : (string) $value];
        }
        if (is_string($value)) {
            if (preg_match('//u', $value) !== 1) {
                return $entry + ['type' => 'binary', 'size' => strlen($value)];
            }
            [$text, $omitted] = self::clip($value, 1024);
            $entry += ['type' => 'string', 'value' => $text];

            return $omitted > 0 ? $entry + ['omittedBytes' => $omitted] : $entry;
        }
        if ($value instanceof \DateTimeInterface) {
            return $entry + ['type' => 'datetime', 'value' => $value->format('Y-m-d H:i:s')];
        }
        if (function_exists('enum_exists') && $value instanceof \BackedEnum) {
            return self::binding($value->value, $name);
        }
        if (is_resource($value)) {
            return $entry + ['type' => 'resource', 'value' => get_resource_type($value)];
        }
        if (is_array($value)) {
            return $entry + ['type' => 'array', 'value' => 'array(' . count($value) . ')'];
        }

        return $entry + ['type' => 'object', 'value' => is_object($value) ? get_class($value) : gettype($value)];
    }

    /**
     * Addresses as [{address, name?}], from strings ("Ada <ada@example.com>"),
     * `address => name` arrays, `['address' => …, 'name' => …]` entries, or Address objects.
     *
     * @param mixed $value
     * @return array<int, array{address: string, name?: string}>
     */
    private static function addresses($value): array
    {
        if ($value === null || $value === '' || $value === []) {
            return [];
        }
        $result = [];
        foreach (is_array($value) ? $value : [$value] as $key => $item) {
            if (count($result) >= 50) {
                break;
            }
            $address = '';
            $name = '';
            if (is_object($item) && method_exists($item, 'getAddress')) {
                $address = (string) $item->getAddress();
                $name = method_exists($item, 'getName') ? (string) $item->getName() : '';
            } elseif (is_array($item)) {
                $address = (string) ($item['address'] ?? $item['email'] ?? '');
                $name = (string) ($item['name'] ?? '');
            } elseif (is_string($key) && strpos($key, '@') !== false) {
                $address = $key;
                $name = is_string($item) ? $item : '';
            } elseif (is_string($item)) {
                if (preg_match('/^\s*"?([^"<]*)"?\s*<([^>]+)>\s*$/', $item, $match)) {
                    $name = trim($match[1]);
                    $address = trim($match[2]);
                } else {
                    $address = trim($item);
                }
            }
            if ($address === '') {
                continue;
            }
            $entry = ['address' => self::clip($address, 320)[0]];
            if ($name !== '') {
                $entry['name'] = self::clip($name, 320)[0];
            }
            $result[] = $entry;
        }

        return $result;
    }

    /**
     * The fields of a Symfony Mime Email or SwiftMailer message. Inline images (`cid:`
     * references) become data: URLs, so previews show them without loading anything.
     *
     * @return array<string, mixed>
     */
    private static function mimeMessage(object $message): array
    {
        $fields = [];
        $inline = [];
        if (is_a($message, 'Symfony\Component\Mime\Email')) {
            $fields['subject'] = $message->getSubject();
            foreach (['from' => 'getFrom', 'to' => 'getTo', 'cc' => 'getCc', 'bcc' => 'getBcc', 'replyTo' => 'getReplyTo'] as $key => $method) {
                $fields[$key] = $message->$method();
            }
            $fields['html'] = self::bodyString($message->getHtmlBody());
            $fields['text'] = self::bodyString($message->getTextBody());
            $attachments = [];
            foreach ($message->getAttachments() as $part) {
                $body = method_exists($part, 'getBody') ? (string) $part->getBody() : '';
                $type = method_exists($part, 'getMediaType') ? $part->getMediaType() . '/' . $part->getMediaSubtype() : null;
                $isInline = method_exists($part, 'getDisposition') && $part->getDisposition() === 'inline';
                if (method_exists($part, 'getContentId')) {
                    $inline[(string) $part->getContentId()] = [$type ?? 'application/octet-stream', $body];
                }
                $attachments[] = array_filter([
                    'filename' => method_exists($part, 'getFilename') ? $part->getFilename() : null,
                    'contentType' => $type,
                    'size' => strlen($body),
                    'inline' => $isInline ? true : null,
                ], static function ($value): bool {
                    return $value !== null;
                });
            }
            $fields['attachments'] = $attachments;
        } elseif (is_a($message, 'Swift_Mime_SimpleMessage')) {
            $fields['subject'] = $message->getSubject();
            foreach (['from' => 'getFrom', 'to' => 'getTo', 'cc' => 'getCc', 'bcc' => 'getBcc', 'replyTo' => 'getReplyTo'] as $key => $method) {
                $fields[$key] = $message->$method();
            }
            $bodies = [[(string) $message->getContentType(), (string) $message->getBody()]];
            $attachments = [];
            foreach ($message->getChildren() as $child) {
                $type = (string) $child->getContentType();
                if (is_a($child, 'Swift_Mime_Attachment')) {
                    $body = (string) $child->getBody();
                    if (is_a($child, 'Swift_Mime_EmbeddedFile')) {
                        $inline[(string) $child->getId()] = [$type, $body];
                    }
                    $attachments[] = ['filename' => $child->getFilename(), 'contentType' => $type, 'size' => strlen($body), 'inline' => is_a($child, 'Swift_Mime_EmbeddedFile')];
                } else {
                    $bodies[] = [$type, (string) $child->getBody()];
                }
            }
            foreach ($bodies as [$type, $body]) {
                if (stripos($type, 'html') !== false && !isset($fields['html'])) {
                    $fields['html'] = $body;
                } elseif (stripos($type, 'text/plain') !== false && !isset($fields['text'])) {
                    $fields['text'] = $body;
                }
            }
            $fields['attachments'] = $attachments;
        }
        if (isset($fields['html']) && is_string($fields['html']) && $inline !== [] && strpos($fields['html'], 'cid:') !== false) {
            $budget = 4 * 1048576;
            foreach ($inline as $id => [$type, $body]) {
                if ($id === '' || strlen($body) > $budget || strpos($fields['html'], 'cid:' . $id) === false) {
                    continue;
                }
                $budget -= strlen($body);
                $fields['html'] = str_replace('cid:' . $id, 'data:' . $type . ';base64,' . base64_encode($body), $fields['html']);
            }
        }

        return $fields;
    }

    /** @param mixed $body */
    private static function bodyString($body): ?string
    {
        if (is_resource($body)) {
            @rewind($body);
            $contents = stream_get_contents($body);
            @rewind($body);

            return $contents === false ? null : $contents;
        }

        return is_string($body) ? $body : null;
    }
}

if (class_exists('PDOStatement', false)) {
    /**
     * @internal The statement class Inspector::watchPdo() installs: reports every execute()
     * with its bound values and timing.
     */
    class InspectedPdoStatement extends \PDOStatement
    {
        /** @var Inspector */
        private $inspector;
        /** @var string */
        private $connection;
        /** @var string */
        private $driver;
        /** @var array<int|string, mixed> */
        private $bound = [];

        protected function __construct(Inspector $inspector, string $connection, string $driver)
        {
            $this->inspector = $inspector;
            $this->connection = $connection;
            $this->driver = $driver;
        }

        #[\ReturnTypeWillChange]
        public function bindValue($param, $value, $type = \PDO::PARAM_STR)
        {
            $this->bound[$param] = $value;

            return parent::bindValue($param, $value, $type);
        }

        #[\ReturnTypeWillChange]
        public function bindParam($param, &$var, $type = \PDO::PARAM_STR, $maxLength = 0, $driverOptions = null)
        {
            $this->bound[$param] = &$var;
            if (func_num_args() >= 5) {
                return parent::bindParam($param, $var, $type, $maxLength, $driverOptions);
            }
            if (func_num_args() === 4) {
                return parent::bindParam($param, $var, $type, $maxLength);
            }

            return parent::bindParam($param, $var, $type);
        }

        #[\ReturnTypeWillChange]
        public function execute($params = null)
        {
            $started = microtime(true);
            try {
                return $params === null ? parent::execute() : parent::execute($params);
            } finally {
                $values = is_array($params) ? $params : $this->bound;
                if (!is_array($params)) {
                    ksort($values);
                }
                $this->inspector->query((string) $this->queryString, $values, (microtime(true) - $started) * 1000, $this->connection, ['driver' => $this->driver, 'databaseAPI' => 'pdo']);
            }
        }
    }
}

/**
 * Query recording for the database layers Runlet knows: illuminate/database (Eloquent, with
 * or without Laravel), Doctrine DBAL 2 to 4, and WordPress's $wpdb. Every driver has these
 * as protected methods; call them from inspect().
 */
trait InspectsDatabases
{
    /**
     * Records queries from illuminate/database (Eloquent and the query builder), with or
     * without Laravel. $database is a Capsule manager, a DatabaseManager, or a single
     * Connection; by default it is whatever Eloquent models use (or Capsule's global
     * instance). Returns whether any connection was found.
     *
     * Queries stream live, with the snippet line, through the connections' event
     * dispatcher. When they have none and illuminate/events is installed, Runlet gives them
     * one for this run. Without illuminate/events it falls back to each connection's query
     * log: queries then arrive as the next one starts and when the run finishes, and on
     * Laravel 7 and older without a snippet line.
     *
     * @param object|null $database
     */
    protected function inspectEloquent(Inspector $inspector, $database = null): bool
    {
        [$connections, $container, $manager] = self::eloquentConnections($database);
        if ($connections === [] && $manager === null) {
            return false;
        }
        $inspector->section(Inspector::QUERIES);
        $dispatcher = self::eloquentDispatcher($connections, $container);
        if ($dispatcher !== null) {
            foreach ($connections as $connection) {
                if (method_exists($connection, 'getEventDispatcher') && $connection->getEventDispatcher() === null) {
                    $connection->setEventDispatcher($dispatcher);
                }
            }
            if ($inspector->once('eloquent:' . spl_object_id($dispatcher))) {
                $dispatcher->listen('Illuminate\Database\Events\QueryExecuted', static function ($event) use ($inspector): void {
                    self::recordEloquentQuery($inspector, $event->sql ?? '', $event->bindings ?? [], $event->time ?? null, $event->connection ?? null, $event->connectionName ?? null, null);
                });
            }

            return true;
        }
        if ($manager !== null) {
            // Without events, only connections that exist now can keep a query log. Creating a
            // Connection object opens nothing (PDO connects on first use).
            foreach (self::configuredConnectionNames($container) as $name) {
                try {
                    $manager->connection($name);
                } catch (\Throwable $error) {
                    // A connection Runlet cannot create (unknown driver) is not used by the app either.
                }
            }
            $connections = array_values($manager->getConnections());
        }
        foreach ($connections as $connection) {
            self::eloquentQueryLog($inspector, $connection);
        }

        return $connections !== [];
    }

    /**
     * Records queries on a Doctrine DBAL connection (DBAL 2, 3, or 4), for Symfony or
     * standalone DBAL. $name labels the connection in Runlet. Returns whether it is hooked.
     *
     * @param object $connection a Doctrine\DBAL\Connection
     */
    protected function inspectDoctrine(Inspector $inspector, $connection, string $name = 'doctrine'): bool
    {
        if (!is_object($connection) || !is_a($connection, 'Doctrine\DBAL\Connection')) {
            return false;
        }
        $inspector->section(Inspector::QUERIES);
        if (!$inspector->once('doctrine:' . spl_object_id($connection))) {
            return true;
        }
        $params = method_exists($connection, 'getParams') ? $connection->getParams() : [];
        $driver = isset($params['driver']) && is_string($params['driver']) ? (string) preg_replace('/^pdo_/', '', $params['driver']) : null;
        if (interface_exists('Doctrine\DBAL\Logging\SQLLogger')) {
            // DBAL 2 and 3: an SQL logger, chained to the one the application set.
            $configuration = $connection->getConfiguration();
            $configuration->setSQLLogger(new class ($inspector, $name, $driver, $configuration->getSQLLogger()) implements \Doctrine\DBAL\Logging\SQLLogger {
                /** @var Inspector */
                private $inspector;
                /** @var string */
                private $name;
                /** @var string|null */
                private $driver;
                /** @var \Doctrine\DBAL\Logging\SQLLogger|null */
                private $previous;
                /** @var array{0: string, 1: array<int|string, mixed>, 2: float}|null */
                private $current;

                public function __construct(Inspector $inspector, string $name, ?string $driver, $previous)
                {
                    $this->inspector = $inspector;
                    $this->name = $name;
                    $this->driver = $driver;
                    $this->previous = $previous;
                }

                public function startQuery($sql, ?array $params = null, ?array $types = null)
                {
                    $this->current = [(string) $sql, $params ?? [], microtime(true)];
                    if ($this->previous !== null) {
                        $this->previous->startQuery($sql, $params, $types);
                    }
                }

                public function stopQuery()
                {
                    if ($this->previous !== null) {
                        $this->previous->stopQuery();
                    }
                    if ($this->current === null) {
                        return;
                    }
                    [$sql, $params, $started] = $this->current;
                    $this->current = null;
                    // DBAL logs transaction control as quoted pseudo statements ("COMMIT").
                    $sql = (string) preg_replace('/^"([A-Z ]+)"$/', '$1', $sql);
                    $this->inspector->query($sql, $params, (microtime(true) - $started) * 1000, $this->name, ['driver' => $this->driver, 'databaseAPI' => 'doctrine']);
                }
            });

            return true;
        }
        if (PHP_VERSION_ID >= 80100 && class_exists('Doctrine\DBAL\Driver\Middleware\AbstractConnectionMiddleware')) {
            // DBAL 4: wrap the driver (or the open driver connection) in a timing middleware.
            if (!class_exists('Runlet\Doctrine\InspectedConnection', false)) {
                eval(self::doctrineMiddleware());
            }
            $record = static function (string $sql, array $params, int $started) use ($inspector, $name, $driver): void {
                $inspector->query($sql, $params, (hrtime(true) - $started) / 1e6, $name, ['driver' => $driver, 'databaseAPI' => 'doctrine']);
            };
            if ($connection->isConnected()) {
                $inner = self::readProperty($connection, '_conn', 'Doctrine\DBAL\Connection');
                if (is_object($inner)) {
                    self::writeProperty($connection, '_conn', new \Runlet\Doctrine\InspectedConnection($inner, $record), 'Doctrine\DBAL\Connection');
                }
            } else {
                $inner = self::readProperty($connection, 'driver', 'Doctrine\DBAL\Connection');
                if (is_object($inner)) {
                    self::writeProperty($connection, 'driver', new \Runlet\Doctrine\InspectedDriver($inner, $record), 'Doctrine\DBAL\Connection');
                }
            }

            return true;
        }

        return false;
    }

    /**
     * Records WordPress's queries through $wpdb: live with timings when SAVEQUERIES is on
     * (Runlet's WordPress driver turns it on unless wp-config.php sets it), otherwise
     * through the `query` filter, without timings.
     */
    protected function inspectWordPress(Inspector $inspector): bool
    {
        $wpdb = $GLOBALS['wpdb'] ?? null;
        if (!is_object($wpdb) || !is_a($wpdb, 'wpdb') || !function_exists('add_filter')) {
            return false;
        }
        $inspector->section(Inspector::QUERIES);
        if (!$inspector->once('wordpress')) {
            return true;
        }
        $driver = is_a($wpdb, 'WP_SQLite_DB') ? 'sqlite' : 'mysql';
        if (defined('SAVEQUERIES') && SAVEQUERIES && isset($GLOBALS['wp_version']) && version_compare((string) $GLOBALS['wp_version'], '5.3', '>=')) {
            add_filter('log_query_custom_data', static function ($data, $query, $time) use ($inspector, $driver) {
                $inspector->query((string) $query, [], is_numeric($time) ? (float) $time * 1000 : null, 'wpdb', ['driver' => $driver, 'databaseAPI' => 'wordpress']);

                return $data;
            }, 10, 3);
        } else {
            add_filter('query', static function ($query) use ($inspector, $driver) {
                $inspector->query((string) $query, [], null, 'wpdb', ['driver' => $driver, 'databaseAPI' => 'wordpress']);

                return $query;
            }, PHP_INT_MAX, 1);
        }

        return true;
    }

    /** DBAL 4 middleware classes, evaluated only when DBAL 4 (PHP 8.1+) is in use. */
    private static function doctrineMiddleware(): string
    {
        return <<<'PHP'
namespace Runlet\Doctrine;

final class InspectedDriver extends \Doctrine\DBAL\Driver\Middleware\AbstractDriverMiddleware
{
    private \Closure $record;

    public function __construct(\Doctrine\DBAL\Driver $driver, \Closure $record)
    {
        parent::__construct($driver);
        $this->record = $record;
    }

    public function connect(#[\SensitiveParameter] array $params): \Doctrine\DBAL\Driver\Connection
    {
        return new InspectedConnection(parent::connect($params), $this->record);
    }
}

final class InspectedConnection extends \Doctrine\DBAL\Driver\Middleware\AbstractConnectionMiddleware
{
    private \Closure $record;

    public function __construct(\Doctrine\DBAL\Driver\Connection $connection, \Closure $record)
    {
        parent::__construct($connection);
        $this->record = $record;
    }

    public function prepare(string $sql): \Doctrine\DBAL\Driver\Statement
    {
        return new InspectedStatement(parent::prepare($sql), $sql, $this->record);
    }

    public function query(string $sql): \Doctrine\DBAL\Driver\Result
    {
        $started = hrtime(true);
        try {
            return parent::query($sql);
        } finally {
            ($this->record)($sql, [], $started);
        }
    }

    public function exec(string $sql): int|string
    {
        $started = hrtime(true);
        try {
            return parent::exec($sql);
        } finally {
            ($this->record)($sql, [], $started);
        }
    }
}

final class InspectedStatement extends \Doctrine\DBAL\Driver\Middleware\AbstractStatementMiddleware
{
    private array $params = [];
    private string $sql;
    private \Closure $record;

    public function __construct(\Doctrine\DBAL\Driver\Statement $statement, string $sql, \Closure $record)
    {
        parent::__construct($statement);
        $this->sql = $sql;
        $this->record = $record;
    }

    public function bindValue(int|string $param, mixed $value, \Doctrine\DBAL\ParameterType $type = \Doctrine\DBAL\ParameterType::STRING): void
    {
        $this->params[$param] = $value;
        parent::bindValue($param, $value, $type);
    }

    public function execute(): \Doctrine\DBAL\Driver\Result
    {
        $started = hrtime(true);
        try {
            return parent::execute();
        } finally {
            ($this->record)($this->sql, $this->params, $started);
        }
    }
}
PHP;
    }

    /**
     * The illuminate/database connections to watch, the container they were configured in,
     * and their DatabaseManager.
     *
     * @param object|null $database
     * @return array{0: array<int, object>, 1: object|null, 2: object|null}
     */
    private static function eloquentConnections($database): array
    {
        if ($database === null) {
            // Only classes the application already loaded: detection never autoloads.
            if (class_exists('Illuminate\Database\Eloquent\Model', false)) {
                $database = \Illuminate\Database\Eloquent\Model::getConnectionResolver();
            }
            if ($database === null && class_exists('Illuminate\Database\Capsule\Manager', false)) {
                $database = self::readStaticProperty('Illuminate\Database\Capsule\Manager', 'instance');
            }
        }
        if (!is_object($database)) {
            return [[], null, null];
        }
        $container = null;
        if (is_a($database, 'Illuminate\Database\Capsule\Manager')) {
            $container = $database->getContainer();
            $database = $database->getDatabaseManager();
        }
        if (is_a($database, 'Illuminate\Database\DatabaseManager')) {
            $container = $container ?? self::readProperty($database, 'app');

            return [array_values($database->getConnections()), is_object($container) ? $container : null, $database];
        }
        if (is_a($database, 'Illuminate\Database\Connection')) {
            return [[$database], null, null];
        }
        if (is_a($database, 'Illuminate\Database\ConnectionResolver')) {
            $connections = self::readProperty($database, 'connections');

            return [is_array($connections) ? array_values(array_filter($connections, 'is_object')) : [], null, null];
        }

        return [[], null, null];
    }

    /**
     * The dispatcher that QueryExecuted events go to: the connections' own, the container's
     * `events`, or (when illuminate/events is installed) a new one bound into the container,
     * so connections created later during the run get it too.
     *
     * @param array<int, object> $connections
     * @param object|null $container
     * @return object|null
     */
    private static function eloquentDispatcher(array $connections, $container)
    {
        foreach ($connections as $connection) {
            if (method_exists($connection, 'getEventDispatcher') && is_object($connection->getEventDispatcher())) {
                return $connection->getEventDispatcher();
            }
        }
        $isContainer = is_object($container) && is_a($container, 'Illuminate\Contracts\Container\Container');
        if ($isContainer && $container->bound('events')) {
            $events = $container->make('events');
            if (is_object($events) && method_exists($events, 'listen')) {
                return $events;
            }
        }
        if (!class_exists('Illuminate\Events\Dispatcher')) {
            return null;
        }
        $dispatcher = new \Illuminate\Events\Dispatcher($isContainer ? $container : null);
        if ($isContainer) {
            $container->instance('events', $dispatcher);
        }

        return $dispatcher;
    }

    /**
     * Names in the container's `database.connections` configuration.
     *
     * @param object|null $container
     * @return string[]
     */
    private static function configuredConnectionNames($container): array
    {
        try {
            $connections = is_object($container) && $container instanceof \ArrayAccess ? $container['config']['database.connections'] : null;
        } catch (\Throwable $error) {
            return [];
        }

        return is_array($connections) ? array_map('strval', array_keys($connections)) : [];
    }

    /**
     * Fallback without an event dispatcher: turns on the connection's query log and reports
     * each logged query when the next one starts (beforeExecuting(), Laravel 8+) and at the
     * end of the run.
     *
     * @param object $connection
     */
    private static function eloquentQueryLog(Inspector $inspector, $connection): void
    {
        if (!is_a($connection, 'Illuminate\Database\Connection') || !$inspector->once('eloquent-log:' . spl_object_id($connection))) {
            return;
        }
        $connection->enableQueryLog();
        $reported = count($connection->getQueryLog());
        $pending = null;
        $flush = static function () use ($inspector, $connection, &$reported, &$pending): void {
            $log = $connection->getQueryLog();
            $count = count($log);
            for ($index = $reported; $index < $count; $index++) {
                $entry = is_array($log[$index]) ? $log[$index] : [];
                self::recordEloquentQuery($inspector, $entry['query'] ?? '', $entry['bindings'] ?? [], $entry['time'] ?? null, $connection, null, $pending ?? []);
                $pending = null;
            }
            $reported = $count;
        };
        if (method_exists($connection, 'beforeExecuting')) {
            $connection->beforeExecuting(static function () use ($inspector, $flush, &$pending): void {
                $flush();
                // A query that failed was never logged; its location is dropped here.
                $pending = $inspector->location();
            });
        }
        $inspector->atFinish($flush);
    }

    /**
     * @param mixed $sql
     * @param mixed $bindings
     * @param mixed $time
     * @param object|null $connection
     * @param array<string, mixed>|null $location
     */
    private static function recordEloquentQuery(Inspector $inspector, $sql, $bindings, $time, $connection, $name, ?array $location): void
    {
        $sql = is_string($sql) ? $sql : '';
        $bindings = is_array($bindings) ? $bindings : [];
        $details = $location === null ? [] : ['location' => $location];
        $details['databaseAPI'] = 'eloquent';
        if (is_object($connection)) {
            try {
                $name = $name ?? $connection->getName();
                $details['driver'] = $connection->getDriverName();
                $bindings = $connection->prepareBindings($bindings);
                $grammar = $connection->getQueryGrammar();
                if (is_object($grammar) && method_exists($grammar, 'substituteBindingsIntoRawSql')) {
                    $details['rawSql'] = $grammar->substituteBindingsIntoRawSql($sql, $bindings);
                }
            } catch (\Throwable $error) {
                // Keep what is known; the query itself is still recorded.
            }
        }
        $inspector->query($sql, $bindings, is_numeric($time) ? (float) $time : null, is_scalar($name) ? (string) $name : null, $details);
    }

    /**
     * @param object $object
     * @return mixed
     */
    protected static function readProperty($object, string $property, ?string $class = null)
    {
        try {
            $reflection = new \ReflectionProperty($class ?? get_class($object), $property);
            if (PHP_VERSION_ID < 80100) {
                $reflection->setAccessible(true);
            }

            return $reflection->getValue($object);
        } catch (\Throwable $error) {
            return null;
        }
    }

    /**
     * @param object $object
     * @param mixed $value
     */
    protected static function writeProperty($object, string $property, $value, ?string $class = null): void
    {
        $reflection = new \ReflectionProperty($class ?? get_class($object), $property);
        if (PHP_VERSION_ID < 80100) {
            $reflection->setAccessible(true);
        }
        $reflection->setValue($object, $value);
    }

    /** @return mixed */
    private static function readStaticProperty(string $class, string $property)
    {
        try {
            $reflection = new \ReflectionProperty($class, $property);
            if (PHP_VERSION_ID < 80100) {
                $reflection->setAccessible(true);
            }

            return $reflection->getValue();
        } catch (\Throwable $error) {
            return null;
        }
    }
}
