<?php

use Acme\App;
use Acme\DI;
use Acme\EmailAddress;
use Acme\Money;

/**
 * Runlet project driver for a non-framework app. Runlet loads vendor/autoload.php (when
 * present) before this file, so Acme\ classes resolve without requiring Composer here.
 */
class AcmeApiDriver extends \Runlet\Driver
{
    public function canBootstrap(string $projectPath): bool
    {
        return is_file($projectPath . '/config/bootstrap.php');
    }

    public function bootstrap(string $projectPath): void
    {
        require __DIR__ . '/boot.php';
    }

    public function variables(): array
    {
        return ['_app' => DI::get(App::class)];
    }

    public function version(): ?string
    {
        return 'Acme Lease API';
    }

    /**
     * SQL tabs: the app's own database. "main" (the default) is a PDO; "archive" shows the
     * callable form, for a client without PDO: it runs the statement and returns the rows,
     * or the number of affected rows.
     */
    public function sqlConnection(?string $connection)
    {
        $database = DI::get(App::class)->database();
        switch ($connection ?? 'main') {
            case 'main':
                return $database;
            case 'archive':
                return static function (string $sql) use ($database) {
                    $statement = $database->query($sql);

                    return $statement->columnCount() > 0 ? $statement->fetchAll(\PDO::FETCH_ASSOC) : $statement->rowCount();
                };
            default:
                throw new \InvalidArgumentException('Acme has no "' . $connection . '" database.');
        }
    }

    /** SQL tabs: the connection picker's names, the default first. */
    public function sqlConnections(): array
    {
        return ['main', 'archive'];
    }

    /** Commands for Runlet's Commands panel. Composer scripts are listed automatically. */
    public function commands(): array
    {
        return [
            'acme:routes' => [
                'command' => 'php bin/acme routes',
                'description' => 'List the routes of ' . DI::get(App::class)->name(),
                'group' => 'acme',
            ],
            // A string is shorthand for ['command' => ...].
            'health' => 'php bin/acme health',
        ];
    }

    /**
     * How Acme's value objects show in Runlet's output: Money as "1,250.00 EUR" with its
     * fields, an email address as its address. A subclass of Money gets Money's caster.
     */
    public function casters(): array
    {
        return [
            Money::class => fn (Money $money) => new \Runlet\Cast($money->format(), [
                'cents' => $money->cents(),
                'currency' => $money->currency(),
            ]),
            EmailAddress::class => fn (EmailAddress $email) => $email->value(),
        ];
    }

    /** Extra App Info sections, shown after Runlet's own (PHP) when App Info opens. */
    public function panels(): array
    {
        $app = DI::get(App::class);

        return [
            'Acme API' => [
                'Application' => $app->name(),
                'Routes' => count($app->routes()),
                'Route list' => $app->routes(),
                'Read-only' => false,
                // Fixture values: Runlet hides the token (by its name) and the URL's password.
                'API token' => 'acme-fixture-token-1234',
                'Upstream' => 'https://acme:fixture-password@api.acme.test/v1',
            ],
        ];
    }
}
