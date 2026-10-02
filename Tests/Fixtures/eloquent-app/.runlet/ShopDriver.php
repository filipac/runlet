<?php

use Runlet\Inspector;
use Shop\Cache;
use Shop\Container;

/**
 * Runlet project driver for a Slim-style app that sets up Eloquent through Capsule, without
 * Laravel. Runlet loads vendor/autoload.php before this file.
 *
 * Queries from Eloquent are recorded without any code here: the base Driver::inspect()
 * finds the Capsule connections. The Doctrine DBAL connection and the app's own cache are
 * reported explicitly.
 */
class ShopDriver extends \Runlet\Driver
{
    /** @var Container|null */
    private $container;

    public function canBootstrap(string $projectPath): bool
    {
        return is_file($projectPath . '/config/bootstrap.php');
    }

    public function bootstrap(string $projectPath): void
    {
        $this->container = require $projectPath . '/config/bootstrap.php';
    }

    public function variables(): array
    {
        return ['container' => $this->container];
    }

    public function version(): ?string
    {
        return 'Shop';
    }

    public function inspect(Inspector $inspector): void
    {
        // Eloquent through Capsule, detected automatically.
        parent::inspect($inspector);

        // A Doctrine DBAL connection Runlet cannot find on its own.
        $this->inspectDoctrine($inspector, $this->container->get('reports'), 'reports');

        // A custom "Cache" section in Runlet's inspector.
        Cache::listen(static function (string $operation, string $key, $value) use ($inspector): void {
            $inspector->record('Cache', $operation . ' ' . $key, $value);
        });
    }
}
