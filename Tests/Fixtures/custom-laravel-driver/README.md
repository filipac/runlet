# custom-laravel-driver

Only a `.runlet/` folder. `DriverTests` copies it into a temporary directory whose other
entries are symlinks to `Tests/Fixtures/laravel-app` (created by `scripts/setup-fixtures.sh`),
so the Laravel fixture runs with a project driver that extends `Runlet\Drivers\LaravelDriver`.
