<?php

use Acme\App;
use Acme\DI;

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
}
