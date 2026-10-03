<?php

use App\Services\PriceFormatter;
use Runlet\Drivers\LaravelDriver;

/** Boots Laravel with the built-in driver, then adds tenant context and extra variables. */
class TenantDriver extends LaravelDriver
{
    public function name(): string
    {
        return 'Tenant Laravel';
    }

    public function bootstrap(string $projectPath): void
    {
        parent::bootstrap($projectPath);
        config(['app.tenant' => 'acme']);
    }

    public function variables(): array
    {
        return parent::variables() + [
            'tenant' => config('app.tenant'),
            'formatter' => $this->app->make(PriceFormatter::class),
        ];
    }

    /**
     * SQL tabs: the tenant's own database is the default; named Laravel connections still
     * come from the built-in driver (parent::sqlConnection()).
     */
    public function sqlConnection(?string $connection)
    {
        if ($connection !== null) {
            return parent::sqlConnection($connection);
        }
        $tenant = new \PDO('sqlite::memory:');
        $tenant->exec("CREATE TABLE tenant_settings (tenant TEXT, plan TEXT)");
        $tenant->exec("INSERT INTO tenant_settings VALUES ('" . config('app.tenant') . "', 'gold')");

        return $tenant;
    }
}
