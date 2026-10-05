<?php

declare(strict_types=1);

/*
 * Runlet run recorder (#5): the HTTP, Jobs, and Events sections of the run inspector. The
 * redaction every HTTP record goes through (HttpRecord), and the listeners the built-in
 * drivers attach: Laravel's HTTP client, queue, and event dispatcher, and WordPress's HTTP
 * API. Declared by the runner after the driver API (Drivers.php). Listeners only: they
 * never return a value an event dispatcher or a WordPress filter would act on, and nothing
 * they do throws into the application.
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace Runlet;

/**
 * @internal One HTTP request as the HTTP section shows it: redacted headers and URL, and
 * bodies (when the run keeps them) capped, with JSON pretty-printed and secret-named fields
 * redacted. Inspector::http() builds every record through it.
 */
final class HttpRecord
{
    public const REDACTED = '[redacted]';

    /** Headers whose values are always redacted, lowercased. */
    private const SECRET_HEADERS = [
        'authorization', 'proxy-authorization', 'cookie', 'set-cookie', 'set-cookie2',
        'x-api-key', 'api-key', 'apikey', 'x-apikey', 'x-auth-token', 'x-access-token',
        'x-refresh-token', 'x-csrf-token', 'x-xsrf-token', 'x-amz-security-token',
        'x-goog-api-key', 'x-functions-key', 'ocp-apim-subscription-key', 'private-token',
        'x-vault-token', 'x-shopify-access-token', 'x-hub-signature', 'x-hub-signature-256',
        'stripe-signature', 'x-signature', 'php-auth-pw', 'x-postmark-server-token',
    ];

    /**
     * @param array<string, mixed> $request see Inspector::http()
     * @param int|null $bodyLimit bytes kept of each body, or null to keep none
     * @return array<string, mixed>
     */
    public static function build(array $request, ?int $bodyLimit): array
    {
        $method = isset($request['method']) && is_scalar($request['method']) ? strtoupper(trim((string) $request['method'])) : '';
        $data = [
            'method' => Inspector::clip($method === '' ? 'GET' : $method, 20)[0],
            'url' => Inspector::clip(self::redactUrl(isset($request['url']) && is_scalar($request['url']) ? (string) $request['url'] : ''), 8192)[0],
        ];
        if (isset($request['status']) && is_int($request['status']) && $request['status'] > 0) {
            $data['status'] = $request['status'];
        }
        if (isset($request['reason']) && is_scalar($request['reason']) && (string) $request['reason'] !== '') {
            $data['reason'] = Inspector::clip((string) $request['reason'], 200)[0];
        }
        if (isset($request['durationMs']) && (is_int($request['durationMs']) || is_float($request['durationMs'])) && is_finite((float) $request['durationMs'])) {
            $data['durationMs'] = round(max(0.0, (float) $request['durationMs']), 3);
        }
        if (isset($request['client']) && is_scalar($request['client']) && (string) $request['client'] !== '') {
            $data['client'] = Inspector::clip((string) $request['client'], 50)[0];
        }
        if (($request['faked'] ?? false) === true) {
            $data['faked'] = true;
        }
        if (isset($request['error']) && is_scalar($request['error']) && (string) $request['error'] !== '') {
            $data['error'] = Inspector::clip(self::redactText((string) $request['error']), 4000)[0];
        }
        foreach (['request', 'response'] as $side) {
            $headers = self::headers($request[$side . 'Headers'] ?? []);
            $data[$side . 'Headers'] = $headers;
            $body = $request[$side . 'Body'] ?? null;
            $size = $request[$side . 'BodySize'] ?? null;
            if (is_string($body) && (!is_int($size) || $size < strlen($body))) {
                $size = strlen($body);
            }
            if (is_int($size) && $size >= 0) {
                $data[$side . 'BodySize'] = $size;
            }
            if ($bodyLimit === null || !is_string($body) || $body === '') {
                continue;
            }
            [$text, $omitted, $format] = self::body($body, self::headerValue($headers, 'content-type'), $bodyLimit);
            $data[$side . 'BodyFormat'] = $format;
            if ($text !== null) {
                $data[$side . 'Body'] = $text;
            }
            $omitted += is_int($size) ? max(0, $size - strlen($body)) : 0;
            if ($text !== null && $omitted > 0) {
                $data[$side . 'BodyOmittedBytes'] = $omitted;
            }
        }

        return $data;
    }

    /**
     * The URL with its credentials (the password of `user:password@`, or a lone `token@`) and
     * secret-named query parameters redacted.
     */
    public static function redactUrl(string $url): string
    {
        $url = (string) preg_replace('~^([a-z][a-z0-9+.-]*://[^/@:?#]*):[^/@?#]*@~i', '$1:' . self::REDACTED . '@', $url);
        $url = (string) preg_replace('~^([a-z][a-z0-9+.-]*://)[^/@:?#\[\]]+@~i', '$1' . self::REDACTED . '@', $url);
        $fragment = '';
        $hash = strpos($url, '#');
        if ($hash !== false) {
            $fragment = substr($url, $hash);
            $url = substr($url, 0, $hash);
        }
        $question = strpos($url, '?');
        if ($question === false) {
            return $url . $fragment;
        }

        return substr($url, 0, $question + 1) . self::redactQuery(substr($url, $question + 1)) . $fragment;
    }

    /** A query string (or a form body) with secret-named parameters' values redacted. */
    public static function redactQuery(string $query): string
    {
        $parts = explode('&', $query);
        foreach ($parts as $index => $part) {
            $equals = strpos($part, '=');
            if ($equals === false || $equals === strlen($part) - 1) {
                continue;
            }
            if (self::isSecretName(urldecode(substr($part, 0, $equals)))) {
                $parts[$index] = substr($part, 0, $equals + 1) . self::REDACTED;
            }
        }

        return implode('&', $parts);
    }

    /**
     * Whether a query parameter, form field, or JSON key is named like a secret: token,
     * key, secret, password, signature, api_key, auth, credential, session, code, …
     */
    public static function isSecretName(string $name): bool
    {
        $name = strtolower(trim($name));
        if ($name === '') {
            return false;
        }
        if (in_array($name, ['key', 'sig', 'code', 'pass', 'pwd', 'jwt', 'otp', 'sid', 'pin', 'cvv', 'cvc'], true)) {
            return true;
        }

        return preg_match('/token|secret|passw|pwd|passphrase|signature|api[-_ ]?key|auth(?!or)|credential|sess(ion|id)|cookie|(^|[-_.\[])key\]?$|(access|private|secret|signing|client|app|license|master|encryption)[-_]?key/', $name) === 1;
    }

    /** Text such as an error message, with the secrets of URLs in it redacted. */
    public static function redactText(string $text): string
    {
        return (string) preg_replace_callback('~[a-z][a-z0-9+.-]*://[^\s"\'<>]+~i', static function (array $match): string {
            return self::redactUrl($match[0]);
        }, $text);
    }

    /**
     * Headers as a list of {name, value, redacted?}, at most 100, values capped.
     *
     * @param mixed $headers name => string or list of strings, or a list of "Name: value" lines
     * @return array<int, array<string, mixed>>
     */
    public static function headers($headers): array
    {
        if (is_string($headers)) {
            $lines = preg_split('/\r?\n/', $headers) ?: [];
            $headers = [];
            foreach ($lines as $line) {
                $colon = strpos($line, ':');
                if ($colon !== false) {
                    $headers[] = [trim(substr($line, 0, $colon)), trim(substr($line, $colon + 1))];
                }
            }
        } elseif (is_object($headers) && method_exists($headers, 'getAll')) {
            $headers = $headers->getAll();
        }
        if (!is_iterable($headers)) {
            return [];
        }
        $result = [];
        foreach ($headers as $name => $values) {
            if (is_int($name) && is_array($values) && isset($values['name'], $values['value'])) {
                // Already a list of {name, value}.
                [$name, $values] = [$values['name'], $values['value']];
            } elseif (is_int($name) && is_array($values) && count($values) === 2 && isset($values[0], $values[1]) && is_string($values[0])) {
                [$name, $values] = $values;
            }
            if (!is_string($name) || trim($name) === '') {
                continue;
            }
            foreach (is_array($values) ? $values : [$values] as $value) {
                if (count($result) >= 100) {
                    break 2;
                }
                if (!is_scalar($value)) {
                    continue;
                }
                $entry = ['name' => Inspector::clip(trim($name), 200)[0]];
                [$redacted, $changed] = self::redactHeader(trim($name), (string) $value);
                $entry['value'] = Inspector::clip($redacted, 2048)[0];
                if ($changed) {
                    $entry['redacted'] = true;
                }
                $result[] = $entry;
            }
        }

        return $result;
    }

    /**
     * @return array{0: string, 1: bool} the value as shown, and whether anything was redacted
     */
    private static function redactHeader(string $name, string $value): array
    {
        $lower = strtolower($name);
        $secret = in_array($lower, self::SECRET_HEADERS, true)
            || (strpos($lower, 'access-control-') !== 0 && preg_match('/token|secret|passw|signature|api[-_]?key|auth|credential|session|cookie/', $lower) === 1);
        if (!$secret) {
            // A URL in a header (Location, Link, Refresh) gets the URL's redaction.
            $redacted = strpos($value, '://') === false ? $value : self::redactText($value);

            return [$redacted, $redacted !== $value];
        }
        if ($value === '') {
            return [$value, false];
        }
        switch ($lower) {
            case 'authorization':
            case 'proxy-authorization':
                // Keep the scheme: "Bearer [redacted]".
                return [preg_match('/^([A-Za-z][A-Za-z0-9_-]*)\s+\S/', $value, $match) ? $match[1] . ' ' . self::REDACTED : self::REDACTED, true];
            case 'cookie':
                // Keep the cookies' names: "session=[redacted]; theme=[redacted]".
                $pairs = [];
                foreach (explode(';', $value) as $pair) {
                    $pair = trim($pair);
                    if ($pair === '') {
                        continue;
                    }
                    $equals = strpos($pair, '=');
                    $pairs[] = ($equals === false ? $pair : substr($pair, 0, $equals)) . '=' . self::REDACTED;
                }

                return [implode('; ', $pairs), true];
            case 'set-cookie':
            case 'set-cookie2':
                // Keep the name and the attributes: "session=[redacted]; path=/; httponly".
                $parts = explode(';', $value);
                $equals = strpos($parts[0], '=');
                $parts[0] = ($equals === false ? trim($parts[0]) : trim(substr($parts[0], 0, $equals))) . '=' . self::REDACTED;

                return [implode(';', $parts), true];
            default:
                return [self::REDACTED, true];
        }
    }

    /** @param array<int, array<string, mixed>> $headers */
    private static function headerValue(array $headers, string $name): ?string
    {
        foreach ($headers as $header) {
            if (strtolower((string) $header['name']) === $name) {
                return (string) $header['value'];
            }
        }

        return null;
    }

    /**
     * A body as the HTTP section shows it: JSON pretty-printed with secret-named fields
     * redacted, form fields redacted, other text as it is; binary and multipart bodies only
     * by size.
     *
     * @return array{0: string|null, 1: int, 2: string} the text, bytes left out, and its format
     */
    private static function body(string $body, ?string $contentType, int $limit): array
    {
        $type = strtolower((string) $contentType);
        if (strpos($type, 'multipart/') !== false) {
            return [null, 0, 'multipart'];
        }
        if (preg_match('//u', $body) !== 1) {
            return [null, 0, 'binary'];
        }
        $trimmed = ltrim($body);
        $first = $trimmed === '' ? '' : $trimmed[0];
        if ((strpos($type, 'json') !== false || $first === '{' || $first === '[') && strlen($body) <= 1048576) {
            $decoded = json_decode($body, false, 64);
            if (json_last_error() === JSON_ERROR_NONE && (is_array($decoded) || is_object($decoded))) {
                $pretty = json_encode(self::redactData($decoded), JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRESERVE_ZERO_FRACTION | JSON_PARTIAL_OUTPUT_ON_ERROR);
                if (is_string($pretty)) {
                    [$text, $omitted] = Inspector::clip($pretty, $limit);

                    return [$text, $omitted, 'json'];
                }
            }
        }
        if (strpos($type, 'x-www-form-urlencoded') !== false || ($type === '' && preg_match('/^[^\s=&]+=[^\s&]*(&[^\s=&]+=[^\s&]*)*$/', $body) === 1)) {
            [$text, $omitted] = Inspector::clip(self::redactQuery($body), $limit);

            return [$text, $omitted, 'form'];
        }
        // Plain text, or JSON cut short: redact "secret": "value" pairs where they show.
        $text = (string) preg_replace_callback('/("((?:[^"\\\\]|\\\\.){1,100})"\s*:\s*)("(?:[^"\\\\]|\\\\.)*"|[^,}\]\s]+)/', static function (array $match): string {
            return self::isSecretName($match[2]) ? $match[1] . '"' . self::REDACTED . '"' : $match[0];
        }, $body);
        [$text, $omitted] = Inspector::clip($text, $limit);

        return [$text, $omitted, 'text'];
    }

    /**
     * @param mixed $value decoded JSON (objects as stdClass)
     * @return mixed
     */
    private static function redactData($value, int $depth = 0)
    {
        if ($depth > 32) {
            return $value;
        }
        if (is_array($value)) {
            foreach ($value as $key => $item) {
                $value[$key] = self::redactData($item, $depth + 1);
            }
        } elseif (is_object($value)) {
            foreach (get_object_vars($value) as $key => $item) {
                $value->{$key} = $item !== null && $item !== '' && self::isSecretName((string) $key) ? self::REDACTED : self::redactData($item, $depth + 1);
            }
        }

        return $value;
    }

    /**
     * @internal The first bytes of a PSR-7 stream, without moving it: only a seekable stream
     * is read, and its position is put back. Null when it can't be read that way.
     *
     * @param mixed $stream
     */
    public static function peek($stream, int $max): ?string
    {
        if (!is_object($stream) || !method_exists($stream, 'isSeekable') || !$stream->isSeekable()) {
            return null;
        }
        try {
            $position = $stream->tell();
            $stream->rewind();
            $data = '';
            while (strlen($data) < $max && !$stream->eof()) {
                $chunk = $stream->read($max - strlen($data));
                if ($chunk === '') {
                    break;
                }
                $data .= $chunk;
            }
            $stream->seek($position);

            return $data;
        } catch (\Throwable $error) {
            return null;
        }
    }

    /** @param mixed $stream */
    public static function size($stream): ?int
    {
        try {
            $size = is_object($stream) && method_exists($stream, 'getSize') ? $stream->getSize() : null;

            return is_int($size) ? $size : null;
        } catch (\Throwable $error) {
            return null;
        }
    }
}

/**
 * @internal Laravel's HTTP client (#5, Laravel 8.45+; ConnectionFailed 8.48+): each
 * RequestSending paired with its ResponseReceived or ConnectionFailed, timed, and recorded in
 * the HTTP section. A response from Http::fake() is marked faked.
 */
final class LaravelHttpRecorder
{
    /** Bytes of a body read to show its first maxHttpBodyBytes (more, so JSON can be pretty-printed). */
    private const READ_BYTES = 65536;

    /** @var Inspector */
    private $inspector;
    /** @var \Closure(): bool whether Http::fake() is on */
    private $faking;
    /** @var array<int, array{request: object, started: int, location: array<string, mixed>, method: string, url: string}> */
    private $pending = [];

    public function __construct(Inspector $inspector, \Closure $faking)
    {
        $this->inspector = $inspector;
        $this->faking = $faking;
    }

    /** @param object $events the application's event dispatcher */
    public function install($events): void
    {
        $events->listen('Illuminate\Http\Client\Events\RequestSending', function ($event): void {
            $this->sending($event);
        });
        $events->listen('Illuminate\Http\Client\Events\ResponseReceived', function ($event): void {
            $this->received($event, true);
        });
        $events->listen('Illuminate\Http\Client\Events\ConnectionFailed', function ($event): void {
            $this->received($event, false);
        });
        $this->inspector->atFinish(function (): void {
            foreach ($this->pending as $entry) {
                $this->inspector->http($this->describe($entry['request'], null) + [
                    'client' => 'Laravel',
                    'error' => 'No response was recorded: the request stopped before one arrived, or the run ended first.',
                    'location' => $entry['location'],
                ]);
            }
            $this->pending = [];
        });
    }

    /** @param object $event */
    private function sending($event): void
    {
        try {
            $request = $event->request ?? null;
            if (!is_object($request) || count($this->pending) >= 1000) {
                return;
            }
            $this->pending[spl_object_id($request)] = [
                'request' => $request,
                'started' => hrtime(true),
                'location' => $this->inspector->location(),
                'method' => self::call($request, 'method'),
                'url' => self::call($request, 'url'),
            ];
        } catch (\Throwable $error) {
            // Never break the HTTP client.
        }
    }

    /** @param object $event */
    private function received($event, bool $answered): void
    {
        try {
            $request = $event->request ?? null;
            if (!is_object($request)) {
                return;
            }
            $entry = $this->take($request);
            $response = $answered && isset($event->response) && is_object($event->response) ? $event->response : null;
            $record = $this->describe($request, $response) + ['client' => 'Laravel'];
            if ($entry !== null) {
                $record['durationMs'] = (hrtime(true) - $entry['started']) / 1e6;
                $record['location'] = $entry['location'];
            }
            if (!$answered) {
                $exception = $event->exception ?? null;
                $record['error'] = $exception instanceof \Throwable ? $exception->getMessage() : 'The connection failed: no response.';
            } elseif ($response !== null) {
                $record['faked'] = $this->isFaked($response);
            }
            $this->inspector->http($record);
        } catch (\Throwable $error) {
            // Never break the HTTP client.
        }
    }

    /**
     * The pending request $request belongs to: the same object, else (ConnectionFailed
     * wraps the failed request anew) the latest one with the same method and URL.
     *
     * @return array{request: object, started: int, location: array<string, mixed>, method: string, url: string}|null
     */
    private function take(object $request): ?array
    {
        $key = spl_object_id($request);
        if (!isset($this->pending[$key])) {
            $method = self::call($request, 'method');
            $url = self::call($request, 'url');
            $key = null;
            foreach ($this->pending as $id => $entry) {
                if ($entry['method'] === $method && $entry['url'] === $url) {
                    $key = $id;
                }
            }
            if ($key === null) {
                return null;
            }
        }
        $entry = $this->pending[$key];
        unset($this->pending[$key]);

        return $entry;
    }

    /**
     * @param object $request Illuminate\Http\Client\Request
     * @param object|null $response Illuminate\Http\Client\Response
     * @return array<string, mixed>
     */
    private function describe($request, $response): array
    {
        $bodies = $this->inspector->shouldRecordHttpBodies();
        $record = [
            'method' => self::call($request, 'method'),
            'url' => self::call($request, 'url'),
            'requestHeaders' => self::headers($request),
        ];
        $psrRequest = method_exists($request, 'toPsrRequest') ? $request->toPsrRequest() : null;
        $stream = is_object($psrRequest) && method_exists($psrRequest, 'getBody') ? $psrRequest->getBody() : null;
        $record['requestBodySize'] = HttpRecord::size($stream);
        if ($bodies) {
            $record['requestBody'] = HttpRecord::peek($stream, self::READ_BYTES);
        }
        if ($response === null) {
            return $record;
        }
        $status = method_exists($response, 'status') ? $response->status() : null;
        $record['status'] = is_numeric($status) ? (int) $status : null;
        $record['reason'] = self::call($response, 'reason');
        $record['responseHeaders'] = self::headers($response);
        $psrResponse = method_exists($response, 'toPsrResponse') ? $response->toPsrResponse() : null;
        $stream = is_object($psrResponse) && method_exists($psrResponse, 'getBody') ? $psrResponse->getBody() : null;
        $record['responseBodySize'] = HttpRecord::size($stream);
        if ($bodies) {
            $record['responseBody'] = HttpRecord::peek($stream, self::READ_BYTES);
        }

        return $record;
    }

    /**
     * Http::fake() answered, not the server: the factory has fakes, and the response has
     * no transfer (no TransferStats, or the empty ones Laravel's fakes report).
     *
     * @param object $response
     */
    private function isFaked($response): bool
    {
        if (!($this->faking)()) {
            return false;
        }
        $stats = $response->transferStats ?? null;
        if (!is_object($stats)) {
            return true;
        }
        $time = method_exists($stats, 'getTransferTime') ? $stats->getTransferTime() : null;
        $handler = method_exists($stats, 'getHandlerStats') ? $stats->getHandlerStats() : [];

        return $time === null && ($handler === [] || $handler === null);
    }

    /**
     * @param object $message a client Request or Response
     * @return array<string, mixed>
     */
    private static function headers($message): array
    {
        try {
            $headers = method_exists($message, 'headers') ? $message->headers() : [];

            return is_array($headers) ? $headers : [];
        } catch (\Throwable $error) {
            return [];
        }
    }

    /** @param object $object */
    private static function call($object, string $method): string
    {
        try {
            $value = method_exists($object, $method) ? $object->{$method}() : null;

            return is_scalar($value) ? (string) $value : '';
        } catch (\Throwable $error) {
            return '';
        }
    }
}

/**
 * @internal Laravel's queue (#5): jobs pushed to a queue (JobQueueing, Laravel 10.42+, and
 * JobQueued, 8.24+; queue and delay on the event from 11.0), and jobs run during the run,
 * as the sync queue does (JobProcessing, JobProcessed, JobExceptionOccurred, JobFailed,
 * JobReleasedAfterException), timed.
 */
final class LaravelJobRecorder
{
    /** @var Inspector */
    private $inspector;
    /** @var \Closure(?string): bool whether a connection runs jobs right away (the sync driver) */
    private $isSync;
    /** @var array<int, array{started: int, location: array<string, mixed>, event: object}> JobQueueing without JobQueued yet */
    private $queueing = [];
    /** @var array<int, array{started: int, location: array<string, mixed>, job: object, connection: ?string, exception: ?\Throwable}> */
    private $running = [];

    public function __construct(Inspector $inspector, \Closure $isSync)
    {
        $this->inspector = $inspector;
        $this->isSync = $isSync;
    }

    /** @param object $events the application's event dispatcher */
    public function install($events): void
    {
        $listen = function (string $event, string $method) use ($events): void {
            $events->listen('Illuminate\Queue\Events\\' . $event, function ($event) use ($method): void {
                try {
                    $this->{$method}($event);
                } catch (\Throwable $error) {
                    // Never break the queue.
                }
            });
        };
        $listen('JobQueueing', 'queueing');
        $listen('JobQueued', 'queued');
        $listen('JobProcessing', 'processing');
        $listen('JobProcessed', 'processed');
        $listen('JobExceptionOccurred', 'exceptionOccurred');
        $listen('JobFailed', 'failed');
        $listen('JobReleasedAfterException', 'released');
        $this->inspector->atFinish(function (): void {
            foreach ($this->running as $entry) {
                $this->record('unfinished', $entry['job'], $entry['connection'], $entry);
            }
            foreach ($this->queueing as $entry) {
                $this->inspector->job($this->queuedJob($entry['event'], 'notQueued') + ['location' => $entry['location']]);
            }
            $this->running = [];
            $this->queueing = [];
        });
    }

    /** @param object $event */
    private function queueing($event): void
    {
        $job = $event->job ?? null;
        if (!is_object($job) || ($this->isSync)(self::string($event, 'connectionName')) || count($this->queueing) >= 1000) {
            return;
        }
        $this->queueing[spl_object_id($job)] = ['started' => hrtime(true), 'location' => $this->inspector->location(), 'event' => $event];
    }

    /** @param object $event */
    private function queued($event): void
    {
        if (($this->isSync)(self::string($event, 'connectionName'))) {
            return;
        }
        $job = $event->job ?? null;
        $record = $this->queuedJob($event, 'queued');
        if (is_object($job) && isset($this->queueing[spl_object_id($job)])) {
            $record['location'] = $this->queueing[spl_object_id($job)]['location'];
            unset($this->queueing[spl_object_id($job)]);
        }
        $this->inspector->job($record);
    }

    /**
     * @param object $event JobQueueing or JobQueued
     * @return array<string, mixed>
     */
    private function queuedJob($event, string $status): array
    {
        $job = $event->job ?? null;
        $payload = isset($event->payload) && is_string($event->payload) ? json_decode($event->payload, true) : null;
        $payload = is_array($payload) ? $payload : [];
        [$class, $name] = self::names($job, $payload);
        $record = ['status' => $status, 'class' => $class, 'name' => $name, 'connection' => self::string($event, 'connectionName')];
        $record['queue'] = self::string($event, 'queue') ?? (is_object($job) ? self::string($job, 'queue') : null);
        $delay = property_exists($event, 'delay') ? $event->delay : (is_object($job) ? ($job->delay ?? null) : null);
        $record['delay'] = self::seconds($delay);
        $id = $event->id ?? null;
        if (is_scalar($id) && (string) $id !== '') {
            $record['id'] = (string) $id;
        }
        if (isset($payload['uuid']) && is_string($payload['uuid'])) {
            $record['uuid'] = $payload['uuid'];
        }

        return $record;
    }

    /** @param object $event */
    private function processing($event): void
    {
        $job = $event->job ?? null;
        if (!is_object($job) || count($this->running) >= 1000) {
            return;
        }
        $this->running[spl_object_id($job)] = [
            'started' => hrtime(true),
            'location' => $this->inspector->location(),
            'job' => $job,
            'connection' => self::string($event, 'connectionName'),
            'exception' => null,
        ];
    }

    /** @param object $event */
    private function processed($event): void
    {
        $this->finish($event, 'processed');
    }

    /** @param object $event */
    private function exceptionOccurred($event): void
    {
        $job = $event->job ?? null;
        if (is_object($job) && isset($this->running[spl_object_id($job)]) && ($event->exception ?? null) instanceof \Throwable) {
            $this->running[spl_object_id($job)]['exception'] = $event->exception;
        }
    }

    /** @param object $event */
    private function failed($event): void
    {
        $this->finish($event, 'failed');
    }

    /** @param object $event */
    private function released($event): void
    {
        $this->finish($event, 'released');
    }

    /** @param object $event */
    private function finish($event, string $status): void
    {
        $job = $event->job ?? null;
        if (!is_object($job)) {
            return;
        }
        $entry = $this->running[spl_object_id($job)] ?? null;
        unset($this->running[spl_object_id($job)]);
        if ($status === 'failed' && ($event->exception ?? null) instanceof \Throwable) {
            $entry = ($entry ?? []) + ['exception' => null];
            $entry['exception'] = $event->exception;
        }
        $this->record($status, $job, self::string($event, 'connectionName') ?? ($entry['connection'] ?? null), $entry);
    }

    /**
     * @param object $job an Illuminate\Contracts\Queue\Job
     * @param array<string, mixed>|null $entry the job's JobProcessing entry
     */
    private function record(string $status, $job, ?string $connection, ?array $entry): void
    {
        $payload = [];
        try {
            $payload = method_exists($job, 'payload') ? $job->payload() : [];
        } catch (\Throwable $error) {
            // A queue driver with a payload Laravel can't decode.
        }
        $payload = is_array($payload) ? $payload : [];
        $class = isset($payload['data']['commandName']) && is_string($payload['data']['commandName']) ? $payload['data']['commandName'] : (isset($payload['job']) && is_string($payload['job']) ? $payload['job'] : get_class($job));
        $name = isset($payload['displayName']) && is_string($payload['displayName']) ? self::cleanName($payload['displayName']) : null;
        $record = [
            'status' => $status,
            'class' => $class,
            'name' => $name === $class ? null : $name,
            'connection' => $connection,
            'queue' => self::call($job, 'getQueue'),
            'id' => self::call($job, 'getJobId'),
            'uuid' => isset($payload['uuid']) && is_string($payload['uuid']) ? $payload['uuid'] : null,
        ];
        $attempts = self::call($job, 'attempts');
        if ($attempts !== null && is_numeric($attempts)) {
            $record['attempts'] = (int) $attempts;
        }
        if ($entry !== null && isset($entry['started'])) {
            $record['durationMs'] = (hrtime(true) - $entry['started']) / 1e6;
        }
        if (isset($entry['location'])) {
            $record['location'] = $entry['location'];
        }
        if (isset($entry['exception']) && $entry['exception'] instanceof \Throwable) {
            $record['exception'] = $entry['exception'];
        }
        $this->inspector->job($record);
    }

    /**
     * The job's class and, for Laravel's wrappers, what it runs: the mailable, notification,
     * listener, broadcast event, or closure. Read from properties and the queue payload only:
     * no method of the application runs.
     *
     * @param mixed $job the command object (or a class name pushed as a string)
     * @param array<string, mixed> $payload
     * @return array{0: string, 1: string|null}
     */
    public static function names($job, array $payload = []): array
    {
        if (is_string($job)) {
            return [$job, null];
        }
        if (!is_object($job)) {
            return ['', null];
        }
        $class = get_class($job);
        $name = null;
        if (isset($payload['displayName']) && is_string($payload['displayName'])) {
            $name = self::cleanName($payload['displayName']);
        } elseif (is_a($job, 'Illuminate\Mail\SendQueuedMailable') && isset($job->mailable) && is_object($job->mailable)) {
            $name = get_class($job->mailable);
        } elseif (is_a($job, 'Illuminate\Notifications\SendQueuedNotifications') && isset($job->notification) && is_object($job->notification)) {
            $name = get_class($job->notification);
        } elseif (is_a($job, 'Illuminate\Events\CallQueuedListener') && isset($job->class) && is_string($job->class)) {
            $name = $job->class;
        } elseif (is_a($job, 'Illuminate\Broadcasting\BroadcastEvent') && isset($job->event) && is_object($job->event)) {
            $name = get_class($job->event);
        } elseif (is_a($job, 'Illuminate\Queue\CallQueuedClosure')) {
            $name = 'Closure';
        }

        return [$class, $name === $class ? null : $name];
    }

    /** "Closure (Standard input code(3) : eval()'d code:5)" from a snippet's closure reads "Closure". */
    private static function cleanName(string $name): string
    {
        return strpos($name, "eval()'d code") !== false && strpos($name, 'Closure') === 0 ? 'Closure' : $name;
    }

    /**
     * A delay in seconds: an int, a DateTimeInterface, or a DateInterval.
     *
     * @param mixed $delay
     */
    private static function seconds($delay): ?int
    {
        if (is_int($delay)) {
            return max(0, $delay);
        }
        if ($delay instanceof \DateTimeInterface) {
            return max(0, $delay->getTimestamp() - time());
        }
        if ($delay instanceof \DateInterval) {
            return max(0, (new \DateTimeImmutable('@0'))->add($delay)->getTimestamp());
        }

        return null;
    }

    /** @param object $object */
    private static function string($object, string $property): ?string
    {
        $value = $object->{$property} ?? null;

        return is_scalar($value) && (string) $value !== '' ? (string) $value : null;
    }

    /** @param object $object */
    private static function call($object, string $method): ?string
    {
        try {
            $value = method_exists($object, $method) ? $object->{$method}() : null;

            return is_scalar($value) && (string) $value !== '' ? (string) $value : null;
        } catch (\Throwable $error) {
            return null;
        }
    }
}

/**
 * @internal Laravel's events (#5), when the run records them: a wildcard listener, last in
 * line, that never returns a value, so it can't stop an event. Leaves out what other sections
 * show (queries, mail, logs, HTTP, jobs) and the framework's own bookkeeping.
 */
final class LaravelEventRecorder
{
    /** Events with these prefixes are left out. */
    private const EXCLUDED = [
        // Shown in other sections.
        'Illuminate\Database\Events\\', 'Illuminate\Log\\', 'Illuminate\Mail\Events\\',
        'Illuminate\Http\Client\Events\\', 'Illuminate\Queue\Events\\',
        // The framework's own bookkeeping.
        'Illuminate\Foundation\Events\\', 'Illuminate\Routing\Events\\', 'Illuminate\Console\Events\\',
        'Illuminate\Redis\Events\\', 'Illuminate\Cache\Events\Retrieving', 'Illuminate\Cache\Events\Writing',
        'Illuminate\Cache\Events\Forgetting', 'Illuminate\Auth\Events\Attempting', 'Illuminate\Contracts\\',
        'bootstrapping: ', 'bootstrapped: ', 'eloquent.booting: ', 'eloquent.booted: ', 'eloquent.retrieved: ',
        'creating: ', 'composing: ', 'illuminate.', 'kernel.handled', 'router.', 'connection.', 'locale.changed',
    ];

    /** @var Inspector */
    private $inspector;
    /** @var bool */
    private $busy = false;

    public function __construct(Inspector $inspector)
    {
        $this->inspector = $inspector;
    }

    /** @param object $events the application's event dispatcher */
    public function install($events): void
    {
        $this->inspector->section(Inspector::EVENTS);
        $events->listen('*', function ($name, $payload = []): void {
            $this->dispatched($name, $payload);
        });
    }

    public static function excluded(string $name): bool
    {
        foreach (self::EXCLUDED as $prefix) {
            if (strncmp($name, $prefix, strlen($prefix)) === 0) {
                return true;
            }
        }

        return false;
    }

    /**
     * @param mixed $name
     * @param mixed $payload
     */
    private function dispatched($name, $payload): void
    {
        // A payload's summary must not record the events reading it causes.
        if ($this->busy || !is_string($name) || self::excluded($name)) {
            return;
        }
        $this->busy = true;
        try {
            $value = is_array($payload) && count($payload) === 1 && array_key_exists(0, $payload) ? $payload[0] : $payload;
            $this->inspector->event($name, $value);
        } catch (\Throwable $error) {
            // Never break the dispatcher.
        } finally {
            $this->busy = false;
        }
    }
}

/**
 * @internal WordPress's HTTP API (#5): requests through WP_Http (wp_remote_get() and
 * friends), timed from `pre_http_request` (last in line) to `http_api_debug`. A request a
 * `pre_http_request` callback answered never reached the network: it's marked faked.
 */
final class WordPressHttpRecorder
{
    /** @var Inspector */
    private $inspector;
    /** @var array<int, array{started: int, location: array<string, mixed>, url: string}> */
    private $pending = [];

    public function __construct(Inspector $inspector)
    {
        $this->inspector = $inspector;
    }

    public function install(): void
    {
        add_filter('pre_http_request', [$this, 'before'], PHP_INT_MAX, 3);
        add_action('http_api_debug', [$this, 'after'], PHP_INT_MAX, 5);
        $this->inspector->atFinish(function (): void {
            $this->pending = [];
        });
    }

    /**
     * @internal `pre_http_request`: returns $preempt unchanged.
     *
     * @param mixed $preempt false, or another callback's answer
     * @param mixed $args
     * @param mixed $url
     * @return mixed
     */
    public function before($preempt, $args = [], $url = '')
    {
        try {
            $args = is_array($args) ? $args : [];
            if ($preempt !== false) {
                $this->inspector->http($this->describe((string) $url, $args, $preempt) + ['faked' => true, 'durationMs' => 0.0]);
            } elseif (count($this->pending) < 1000) {
                $this->pending[] = ['started' => hrtime(true), 'location' => $this->inspector->location(), 'url' => (string) $url];
            }
        } catch (\Throwable $error) {
            // Never break WordPress.
        }

        return $preempt;
    }

    /**
     * @internal `http_api_debug`.
     *
     * @param mixed $response
     * @param mixed $context
     * @param mixed $class
     * @param mixed $args
     * @param mixed $url
     */
    public function after($response, $context = '', $class = '', $args = [], $url = ''): void
    {
        if ($context !== 'response') {
            return;
        }
        try {
            $url = (string) $url;
            $entry = null;
            for ($i = count($this->pending) - 1; $i >= 0; $i--) {
                if ($this->pending[$i]['url'] === $url) {
                    $entry = $this->pending[$i];
                    array_splice($this->pending, $i, 1);
                    break;
                }
            }
            $record = $this->describe($url, is_array($args) ? $args : [], $response);
            if ($entry !== null) {
                $record['durationMs'] = (hrtime(true) - $entry['started']) / 1e6;
                $record['location'] = $entry['location'];
            }
            $this->inspector->http($record);
        } catch (\Throwable $error) {
            // Never break WordPress.
        }
    }

    /**
     * @param array<string, mixed> $args WP_Http's parsed arguments
     * @param mixed $response an array, a WP_Error, or another callback's answer
     * @return array<string, mixed>
     */
    private function describe(string $url, array $args, $response): array
    {
        $bodies = $this->inspector->shouldRecordHttpBodies();
        $headers = $args['headers'] ?? [];
        $headers = is_array($headers) || is_string($headers) ? HttpRecord::headers($headers) : [];
        $named = array_map(static function (array $header): string {
            return strtolower((string) $header['name']);
        }, $headers);
        if (isset($args['user-agent']) && is_string($args['user-agent']) && !in_array('user-agent', $named, true)) {
            // WordPress sends its user-agent argument as the header.
            $headers[] = ['name' => 'User-Agent', 'value' => $args['user-agent']];
        }
        $body = $args['body'] ?? null;
        if (is_array($body)) {
            $body = http_build_query($body, '', '&');
        }
        $record = [
            'client' => 'WordPress',
            'method' => isset($args['method']) && is_string($args['method']) ? $args['method'] : 'GET',
            'url' => $url,
            'requestHeaders' => $headers,
            'requestBodySize' => is_string($body) ? strlen($body) : null,
        ];
        if ($bodies && is_string($body)) {
            $record['requestBody'] = $body;
        }
        if (is_object($response) && is_a($response, 'WP_Error')) {
            $record['error'] = method_exists($response, 'get_error_message') ? (string) $response->get_error_message() : 'WP_Error';

            return $record;
        }
        if (!is_array($response)) {
            return $record;
        }
        $code = $response['response']['code'] ?? null;
        if (is_numeric($code) && (int) $code > 0) {
            $record['status'] = (int) $code;
        } elseif (($args['blocking'] ?? true) === false) {
            $record['error'] = 'Not blocking: WordPress didn\'t wait for the response.';
        }
        $message = $response['response']['message'] ?? null;
        if (is_string($message)) {
            $record['reason'] = $message;
        }
        $record['responseHeaders'] = $response['headers'] ?? [];
        $responseBody = $response['body'] ?? null;
        if (is_string($responseBody)) {
            $record['responseBodySize'] = strlen($responseBody);
            if ($bodies) {
                $record['responseBody'] = $responseBody;
            }
        }

        return $record;
    }
}
