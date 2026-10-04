import Foundation

/// Declarations of the runner's public snippet API (#196), opened in every PHPantom session as
/// an in-memory document, so `\Runlet\` completes, hovers, and shows signatures in snippets: the
/// `Runlet\` functions and `\Runlet\Inspector`'s public methods. Never written to disk, never run.
///
/// Keep it in step with `Resources/Runner/src`: `RunletAPIStubTests` compares every signature here
/// (names, parameters, types, defaults, return types) with the built runner's, by reflection.
public enum RunletAPIStub {
    /// A stable, never-written URI under the workspace root, next to the tabs' scratch documents.
    public static func uri(root: URL) -> String {
        root.appendingPathComponent(".runlet-scratch", isDirectory: true)
            .appendingPathComponent("runlet-api.php").absoluteString
    }

    public static let source = #"""
    <?php

    // Runlet's snippet API, for completion only (#196). The runner defines the real functions and
    // class on every target; see docs/snippet-api.md.

    namespace Runlet;

    /**
     * Shows a notice card in Runlet's output, with the line that called it. The run goes on.
     * Works whether or not the run inspector is on.
     *
     * @param string $message the card's text (at most 16 KB is shown)
     * @param array<mixed> $context shown under the message as an expandable value, bounded like dumps
     */
    function notice(string $message, array $context = []): void
    {
    }

    /**
     * Shows a warning card in Runlet's output, with the line that called it. The run goes on.
     * Works whether or not the run inspector is on.
     *
     * @param string $message the card's text (at most 16 KB is shown)
     * @param array<mixed> $context shown under the message as an expandable value, bounded like dumps
     */
    function warning(string $message, array $context = []): void
    {
    }

    /**
     * Shows an error card in Runlet's output, with the line that called it, without ending the
     * run: it goes on and isn't marked failed. A caught Throwable shows its class, message, where
     * it was thrown, its cause, and its stack trace. Works whether or not the run inspector is on.
     *
     * @param string|\Throwable $message the card's text (at most 16 KB is shown), or a Throwable
     * @param array<mixed> $context shown under the message as an expandable value, bounded like dumps
     */
    function error($message, array $context = []): void
    {
    }

    /**
     * Measures $callables and shows a benchmark card in Runlet's output (and the Benchmarks
     * section): min, mean, median, p95, max, operations per second, memory, and the distribution
     * of call times. Pass an array of callables, keyed by label, to compare them side by side.
     *
     * @param callable|array<int|string, callable> $callables
     * @param int $iterations timed calls per callable (1–100,000)
     * @param string|null $label the card's title
     * @param float|null $seconds time budget per callable, in seconds (1 s by default, at most 60 s)
     * @return array<int|string, mixed> times in milliseconds (`mean_ms`, `median_ms`, `min_ms`,
     *         `max_ms`, `p95_ms`), `ops_per_sec`, `iterations`, and memory
     */
    function bench($callables, int $iterations = 1000, ?string $label = null, ?float $seconds = null): array
    {
    }

    /**
     * Shows EXPLAIN rows as Runlet's plan card: the plan as a tree with full scans highlighted,
     * and the database's own output under Raw. Pass the rows of `EXPLAIN FORMAT=JSON` (MySQL,
     * MariaDB), `EXPLAIN (FORMAT JSON)` (PostgreSQL), or `EXPLAIN QUERY PLAN` (SQLite), and the
     * connection they came from (a PDO, an Illuminate or Doctrine DBAL connection, $wpdb, or the
     * database's name). Nothing is sent to the database.
     *
     * @param mixed $rows the EXPLAIN's rows, as objects or arrays
     * @param mixed $connection the connection, or the database's name; null tells by the rows
     * @param string|null $connectionName the name the card shows for the connection
     * @return mixed nothing to show when Runlet shows the plan; otherwise the rows as they are
     */
    function explainPlan($rows, $connection = null, ?string $connectionName = null)
    {
    }

    /**
     * The run inspector: what a run did besides its output (queries, mail, log messages, HTML,
     * and sections of your own). Snippets reach it with Inspector::current(). No method throws.
     * notice(), warning(), and error() are output, not records: they show even when the
     * inspector is off.
     */
    final class Inspector
    {
        public const QUERIES = 'Queries';
        public const MAIL = 'Mail';
        public const LOG = 'Log';
        public const HTML = 'HTML';

        /** The current run's inspector, or null outside a snippet run. */
        public static function current(): ?self
        {
        }

        /** Whether this run records anything; the inspector can be turned off in Runlet's settings. */
        public function isEnabled(): bool
        {
        }

        /** Shows $section in Runlet for this run even when nothing is recorded in it ("0 queries"). */
        public function section(string $section): void
        {
        }

        /**
         * Records one SQL statement in the Queries section.
         *
         * @param array<int|string, mixed> $bindings positional values (a list) or named ones (name => value)
         * @param float|null $ms how long the statement took, in milliseconds
         * @param string|null $connection the connection's name, shown next to the statement
         * @param array<string, mixed> $details optional `driver`, `rawSql`, `location`, and `databaseAPI`
         */
        public function query(string $sql, array $bindings = [], ?float $ms = null, ?string $connection = null, array $details = []): void
        {
        }

        /**
         * Records one mail message in the Mail section: a Symfony Mime Email, a SwiftMailer
         * message, or an array with `subject`, `from`, `to`, `cc`, `bcc`, `replyTo`, `html`,
         * `text`, `attachments`, `mailer`, and `mailable`.
         *
         * @param object|array<string, mixed> $message
         * @param array<string, mixed> $details `intercepted`, `queued`, `queueConnection`, `mailer`, `mailable`
         */
        public function mail($message, array $details = []): void
        {
        }

        /** Records rendered HTML (a page, an email, a fragment), previewed in a locked-down web view. */
        public function html(string $title, string $html, string $section = self::HTML): void
        {
        }

        /**
         * Records a log message in the Log section.
         *
         * @param array<mixed> $context shown as an expandable value
         */
        public function log(string $level, string $message, array $context = [], ?string $channel = null): void
        {
        }

        /**
         * Records any value under $title in a section of your own, such as "Cache" or "HTTP
         * calls". The value is shown like a dump (bounded, without calling its methods).
         *
         * @param mixed $value
         */
        public function record(string $section, string $title, $value): void
        {
        }

        /**
         * Records the queries a PDO connection runs through prepare() and execute(). Returns
         * whether the connection is watched.
         */
        public function watchPdo(\PDO $pdo, string $connection = 'pdo'): bool
        {
        }

        /** Whether this run asks drivers to intercept mail instead of sending it. */
        public function shouldInterceptMail(): bool
        {
        }

        /** Tells Runlet that this run intercepts mail: messages are recorded but not sent. */
        public function interceptingMail(): void
        {
        }

        /** True the first time $key is passed during this run; hooks use it to attach only once. */
        public function once(string $key): bool
        {
        }

        /** Calls $callback when the run finishes, before Runlet reports it. */
        public function atFinish(callable $callback): void
        {
        }

        /**
         * Where the code running now comes from: the snippet line, else the first project file
         * outside vendor/.
         *
         * @return array{inSnippet?: bool, snippetLine?: int, file?: string, line?: int}
         */
        public function location(): array
        {
        }

        /**
         * Shows a notice card in Runlet's output, with the line that called it: the same as
         * \Runlet\notice().
         *
         * @param array<mixed> $context shown under the message as an expandable value
         */
        public function notice(string $message, array $context = []): void
        {
        }

        /**
         * Shows a warning card in Runlet's output, with the line that called it: the same as
         * \Runlet\warning().
         *
         * @param array<mixed> $context shown under the message as an expandable value
         */
        public function warning(string $message, array $context = []): void
        {
        }

        /**
         * Shows an error card in Runlet's output without ending the run or marking it failed:
         * the same as \Runlet\error().
         *
         * @param string|\Throwable $message
         * @param array<mixed> $context shown under the message as an expandable value
         */
        public function error($message, array $context = []): void
        {
        }
    }

    """#
}
