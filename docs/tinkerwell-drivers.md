# Porting from Tinkerwell

Runlet doesn't load Tinkerwell drivers, but porting one is mostly a rename. Move the file from `.tinkerwell/` to `.runlet/`, rename the class and its methods, and add the return types.

## Method by Method

| Tinkerwell (`.tinkerwell/*TinkerwellDriver.php`) | Runlet (`.runlet/*Driver.php`) |
| --- | --- |
| `class X extends TinkerwellDriver` | `class X extends \Runlet\Driver` |
| `extends LaravelTinkerwellDriver`, and the like | `extends \Runlet\Drivers\LaravelDriver`, and the like |
| `canBootstrap($projectPath)` | `canBootstrap(string $projectPath): bool`. The default is `true`, so you can often leave it out. |
| `bootstrap($projectPath)` | `bootstrap(string $projectPath): void` |
| `getAvailableVariables()` | `variables(): array` |
| `appVersion()` | `version(): ?string` |
| `contextMenu()` | No equivalent. For commands, see [Project Commands](project-commands.md#adding-commands). |
| `appPanels()`, `.tinkerwell/panels/*Panel.php` | `panels(): array` ([App Info](app-info.md#adding-sections)) |

Runlet's methods must keep these signatures, including the return types: PHP rejects an incompatible declaration, and Runlet reports it as a boot error that names the driver file.

## An Example

Before, in `.tinkerwell/MyCustomTinkerwellDriver.php`:

```php
class MyCustomTinkerwellDriver extends TinkerwellDriver
{
    public function canBootstrap($projectPath) { return true; }
    public function bootstrap($projectPath) { require '/var/www/.tinkerwell/boot.php'; }
    public function getAvailableVariables() { return ['_app' => DI::get(App::class)]; }
    public function appVersion() { return 'My API'; }
}
```

After, in `.runlet/MyApiDriver.php`, with `boot.php` moved next to it:

```php
<?php
// .runlet/MyApiDriver.php
class MyApiDriver extends \Runlet\Driver
{
    public function bootstrap(string $projectPath): void { require __DIR__ . '/boot.php'; }
    public function variables(): array { return ['_app' => DI::get(App::class)]; }
    public function version(): ?string { return 'My API'; }
}
```

> [!TIP]
> Use `__DIR__` instead of an absolute container path such as `/var/www`, so the same driver runs on your Mac and inside the container.

The file name must end in `Driver.php`. [Project Drivers](drivers.md) has the rest of the API: commands, the run inspector, SQL connections, App Info, and more.

## For developers

Split out of `drivers.md` ("Migrating a Tinkerwell driver") under [#289](https://github.com/filipac/runlet/issues/289). The comparison with Tinkerwell's features is in [tinkerwell-feature-review.md](tinkerwell-feature-review.md).
