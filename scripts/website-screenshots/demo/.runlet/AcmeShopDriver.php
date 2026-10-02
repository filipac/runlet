<?php

use Illuminate\Cache\Events\CacheHit;
use Illuminate\Cache\Events\CacheMissed;
use Illuminate\Cache\Events\KeyWritten;
use Runlet\Drivers\LaravelDriver;
use Runlet\Inspector;

class AcmeShopDriver extends LaravelDriver
{
    public function name(): string
    {
        return 'Acme Shop';
    }

    public function commands(): array
    {
        return parent::commands() + [
            'smoke' => ['command' => 'php artisan test --filter=Checkout', 'description' => 'Run the checkout smoke tests', 'group' => 'acme'],
            'catalog:warm' => ['command' => 'php artisan cache:clear && php artisan shop:report', 'description' => 'Warm the catalog cache', 'group' => 'acme'],
        ];
    }

    public function hostCommands(): array
    {
        return [
            'tests' => ['command' => 'php artisan test', 'description' => 'Run the test suite with this Mac\'s PHP'],
            'up' => ['command' => 'docker compose up -d', 'description' => 'Start MySQL, Redis, and Mailpit'],
            'down' => ['command' => 'docker compose down', 'description' => 'Stop the local stack'],
            'deploy' => ['command' => './bin/deploy staging', 'description' => 'Deploy the current branch to staging'],
        ];
    }

    public function inspect(Inspector $inspector): void
    {
        parent::inspect($inspector);
        $events = $this->app['events'];
        $events->listen(CacheHit::class, fn (CacheHit $event) => $inspector->record('Cache', 'hit ' . $event->key, $event->value));
        $events->listen(CacheMissed::class, fn (CacheMissed $event) => $inspector->record('Cache', 'miss ' . $event->key, null));
        $events->listen(KeyWritten::class, fn (KeyWritten $event) => $inspector->record('Cache', 'write ' . $event->key, $event->value));
    }
}
