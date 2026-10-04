<?php

declare(strict_types=1);

/*
 * Snippet messages (#196): \Runlet\notice(), \Runlet\warning(), and \Runlet\error() (and the
 * same methods on \Runlet\Inspector) put notice, warning, and non-fatal error cards in Runlet's
 * output, with the line that called them. They are output, not inspector records: they show
 * whether the run inspector is on or off, and none of them ends the run or marks it failed.
 * Declared by the runner after Runner.php. See docs/snippet-api.md.
 *
 * Each card is a `notice` event with `level`, `user: true`, the caller's location, and an
 * optional `context` value and `exception`. Older app builds read only `message`.
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace RunletRunner;

final class SnippetMessages
{
    /** Cards per run; the rest are counted in one notice when the run finishes. */
    public const MAX_MESSAGES = 200;
    /** Bytes of one card's message. */
    public const MAX_MESSAGE_BYTES = 16384;
    /** Bytes of all cards together (messages, contexts, traces); later cards are left out. */
    public const MAX_TOTAL_BYTES = 8388608;

    /** @var int */
    private static $shown = 0;
    /** @var int */
    private static $omitted = 0;
    /** @var int */
    private static $bytes = 0;
    /** @var array<string, int> */
    private static $limits = [];
    /** @var ValueNormalizer|null */
    private static $normalizer;
    /** @var bool */
    private static $finished = false;

    /**
     * The run's value limits (`request.limits`). Contexts use tighter ones, like the run
     * inspector's values.
     *
     * @param array<string, mixed> $limits
     */
    public static function configure(array $limits): void
    {
        self::$limits = ['maxDepth' => min(6, (int) ($limits['maxDepth'] ?? 8))];
        self::$normalizer = null;
    }

    /**
     * Shows one card. Never throws: a message Runlet cannot show is dropped.
     *
     * @param string $level notice, warning, or error
     * @param mixed $message a string, or (for errors) a Throwable
     * @param mixed $context
     */
    public static function emit(string $level, $message, $context = []): void
    {
        try {
            if (self::$finished) {
                return;
            }
            if (self::$shown >= self::MAX_MESSAGES) {
                self::$omitted++;

                return;
            }
            $payload = ['level' => in_array($level, ['notice', 'warning', 'error'], true) ? $level : 'notice', 'user' => true];
            if ($message instanceof \Throwable) {
                $details = Runner::describeThrowable($message);
                $text = (string) $details['message'];
                unset($details['message']);
                $payload['exception'] = $details;
            } else {
                $text = self::text($message);
            }
            [$text, $omittedBytes] = \Runlet\Inspector::clip($text, self::MAX_MESSAGE_BYTES);
            $payload = ['message' => $text] + $payload;
            if ($omittedBytes > 0) {
                $payload['omittedBytes'] = $omittedBytes;
            }
            $payload += \Runlet\Inspector::callerLocation();
            if ($context !== [] && $context !== null) {
                $payload['context'] = self::normalize($context);
            }
            $size = strlen((string) json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PARTIAL_OUTPUT_ON_ERROR));
            if (self::$bytes + $size > self::MAX_TOTAL_BYTES) {
                self::$omitted++;

                return;
            }
            self::$bytes += $size;
            self::$shown++;
            Channel::emit('notice', $payload);
        } catch (\Throwable $error) {
            // Showing a message must never break the snippet.
        }
    }

    /** Reports the cards the limits left out, once, when the run finishes. */
    public static function finish(): void
    {
        if (self::$finished) {
            return;
        }
        self::$finished = true;
        if (self::$omitted > 0) {
            Channel::emit('notice', ['message' => 'Runlet left out ' . self::$omitted . ' more ' . (self::$omitted === 1 ? 'card' : 'cards')
                . ' from \\Runlet\\notice(), warning(), and error(): a run shows at most ' . self::MAX_MESSAGES . ' of them (' . (int) (self::MAX_TOTAL_BYTES / 1048576) . ' MB in all).']);
        }
    }

    /**
     * A message that is not a string, as text: without calling the snippet's code, except
     * __toString() on a Stringable object.
     *
     * @param mixed $message
     */
    private static function text($message): string
    {
        if (is_string($message)) {
            return $message;
        }
        if ($message === null) {
            return '';
        }
        if (is_bool($message)) {
            return $message ? 'true' : 'false';
        }
        if (is_int($message)) {
            return (string) $message;
        }
        if (is_float($message)) {
            return ValueNormalizer::floatString($message);
        }
        if (is_object($message) && method_exists($message, '__toString')) {
            try {
                return (string) $message;
            } catch (\Throwable $error) {
                return \Runlet\Inspector::className(get_class($message));
            }
        }
        if (is_object($message)) {
            return \Runlet\Inspector::className(get_class($message));
        }
        if (is_array($message)) {
            return 'array(' . count($message) . ')';
        }

        return gettype($message);
    }

    /**
     * @param mixed $value
     * @return array<string, mixed>
     */
    private static function normalize($value): array
    {
        if (self::$normalizer === null) {
            self::$normalizer = new ValueNormalizer([
                'maxDepth' => self::$limits['maxDepth'] ?? 6,
                'maxChildren' => 100,
                'maxStringBytes' => 16384,
                'maxNodes' => 5000,
                'maxValueBytes' => 524288,
            ]);
        }
        try {
            return self::$normalizer->normalize($value);
        } catch (\Throwable $error) {
            return ['id' => 0, 'type' => 'unknown', 'scalar' => 'Runlet could not inspect this value: ' . $error->getMessage()];
        }
    }
}

namespace Runlet;

/**
 * Shows a notice card in Runlet's output, with the line that called it, like Runlet's own
 * notices. The run goes on. Works whether or not the run inspector is on.
 *
 *     \Runlet\notice('Imported 120 rows', ['skipped' => 3]);
 *
 * @param string $message the card's text (at most 16 KB is shown)
 * @param array<mixed> $context shown under the message as an expandable value, bounded like dumps
 */
function notice(string $message, array $context = []): void
{
    \RunletRunner\SnippetMessages::emit('notice', $message, $context);
}

/**
 * Shows a warning card in Runlet's output, with the line that called it. The run goes on.
 * Works whether or not the run inspector is on.
 *
 *     \Runlet\warning('Cache is cold', ['store' => 'redis']);
 *
 * @param string $message the card's text (at most 16 KB is shown)
 * @param array<mixed> $context shown under the message as an expandable value, bounded like dumps
 */
function warning(string $message, array $context = []): void
{
    \RunletRunner\SnippetMessages::emit('warning', $message, $context);
}

/**
 * Shows an error card in Runlet's output, with the line that called it, without ending the
 * run: the run goes on, and it isn't marked failed. Pass a caught Throwable to show its class,
 * message, where it was thrown, and its stack trace, like an uncaught error's card. Works
 * whether or not the run inspector is on.
 *
 *     try {
 *         $client->sync();
 *     } catch (\Throwable $e) {
 *         \Runlet\error($e, ['client' => $client->id]);
 *     }
 *
 * @param string|\Throwable $message the card's text (at most 16 KB is shown), or a Throwable
 * @param array<mixed> $context shown under the message as an expandable value, bounded like dumps
 */
function error($message, array $context = []): void
{
    \RunletRunner\SnippetMessages::emit('error', $message, $context);
}
