# Frameworks

Runlet detects your project's framework and boots it before every run, so a snippet starts with the application ready: its models, services, configuration, and database connection. Laravel boots the way an Artisan command does, and WordPress the way WP-CLI does.

```php
use App\Models\User;

$user = User::find(1);
$user->subscriptions;
```

No route, controller, or temporary command. As in Tinker, the last expression is the result.

## Supported Frameworks

| Project | Detected by | Snippets start with |
| --- | --- | --- |
| Laravel, Lumen, Laravel Zero | `bootstrap/app.php`, plus `artisan` or the `laravel-zero/framework` package | `$app` |
| WordPress (classic, Bedrock, `public/wp`) | `wp-load.php` in the project, or in `web/wp/`, `public/wp/`, `wordpress/`, or `wp/` | `$wpdb` |
| Symfony | `bin/console`, plus `src/Kernel.php` or `config/bundles.php` | `$kernel`, `$container` |
| Composer projects | `composer.json` or `vendor/autoload.php` | The Composer autoloader, loaded |
| Anything else | | Plain PHP |

Runlet checks them in this order, and the first that recognises the project boots it. A [project driver](drivers.md) in your project's `.runlet/` folder comes before all of them, so you can boot anything else, or boot one of these differently.

The tab card and the status bar show what the last run booted, such as "Laravel 13.34.0". Before the first run, Runlet reads the project's files to guess, without running anything.

> [!NOTE]
> Laravel, Symfony, and Composer projects need their dependencies installed. Runlet never runs Composer: when `vendor/autoload.php` is missing, the run says so, and asks you to run `composer install` in the project.

## Laravel

Laravel and Laravel Zero boot through the console kernel, exactly as an Artisan command boots: service providers, configuration, facades, and helpers are ready. Lumen builds its console kernel (for facades and the console setup) and boots the application.

- **Variables:** `$app`, the application.
- **Version:** Laravel's version (Lumen's number only), or a Laravel Zero application's own version.
- **Environment:** `app()->environment()`, from `APP_ENV` (an environment variable wins over `.env`) or `app.env`.
- **Commands:** every visible Artisan command, or a Laravel Zero application's commands through its own binary. See [Project Commands](project-commands.md).
- **The run inspector** records queries, mail (and can [intercept it](driver-inspector.md#mail-interception)), and log messages.

## Symfony

Runlet loads your `.env` files as the Runtime component does (`Dotenv::bootEnv()`, or `loadEnv()` on older versions, or `config/bootstrap.php` for Symfony 4 recipes). It then boots your kernel, `App\Kernel` or the one declared in `src/Kernel.php`, with `APP_ENV` (`dev` by default) and `APP_DEBUG`.

- **Variables:** `$kernel`, and `$container`, the kernel's container.
- **Version:** Symfony's version. **Environment:** the kernel's (`dev`, `test`, `prod`, …).
- **Commands:** every visible `bin/console` command.
- **The run inspector** records the queries of every Doctrine connection, and mail sent through Symfony Mailer (intercepted on Symfony 6.3 and later).

The first run warms `var/cache/<env>`, just as `bin/console` would.

## WordPress

WordPress expects to load in the global scope. Like WP-CLI, Runlet loads `wp-load.php` from a function in which WordPress's globals are declared `global`, and promotes any other variable the load defines to a global afterwards. It also:

- needs a `wp-config.php` next to `wp-load.php`, or one folder above it;
- loads `vendor/autoload.php` first when the project has one, as Bedrock needs;
- sets `WP_USE_THEMES` to `false`, and loads the admin APIs (`wp-admin/includes/admin.php`), as WP-CLI does.

**The request.** WordPress runs see your site's real host and scheme, not `http://localhost`, so canonical-host and force-HTTPS code (page caches such as W3 Total Cache, SSL plugins) doesn't redirect and exit. The URL comes from `WP_HOME`, `WP_SITEURL`, or `DOMAIN_CURRENT_SITE`, as `wp-config.php` really defines them (Runlet evaluates it in a separate PHP process, as WP-CLI does), else from the `home` option in the database. The Run Log shows which request a run used, and where its URL came from.

**Protections.** Before WordPress loads, Runlet:

- turns `wp_die()` into an exception (`RuntimeException("wp_die(): …")`) instead of an HTML page;
- turns off WordPress's fatal-error handler, so a snippet's fatal error never prints an error page, pauses a plugin, or emails a recovery link;
- bypasses maintenance mode, the `advanced-cache.php` drop-in, and multisite site-status checks;
- doesn't spawn WP-Cron. A snippet can still call `wp_cron()` or `spawn_cron()`.

If the database is unreachable or WordPress isn't installed, the run reports a boot error. When a plugin redirects and exits while WordPress boots, the error says which redirect WordPress tried, and which file sent it.

- **Variables:** `$wpdb`. For other globals, write `global $post;` or use `$GLOBALS`.
- **Environment:** `wp_get_environment_type()`, from `WP_ENVIRONMENT_TYPE`. WordPress says `production` when it isn't set, so define it as `local` on your Mac.
- **The run inspector** records queries (with their times, through `SAVEQUERIES`, unless `wp-config.php` sets it itself) and every `wp_mail()` message, which it can [intercept](driver-inspector.md#wordpress-mail). It never adds a file to your site.
- **SQL tabs** open their own connection from `wp-config.php`'s settings. See [WordPress Connection](driver-databases.md#wordpress-connection).
- **The Run Log** has a "WordPress boot" line: where the boot time went, the slowest plugins, and whether PHP's opcode cache is on.

### WordPress Limitations

- **Global scope.** Code that runs while WordPress loads, such as plugin files and early hooks, sees only the globals Runlet declares as global. A plugin that defines a new top-level variable during load, and reads it through `global` during that same load, can behave differently, exactly as under WP-CLI.
- **Multisite.** Runs boot the network's main site. For another site, set `$_SERVER['HTTP_HOST']` (and `REQUEST_URI` for a subdirectory site) in a project driver that extends the WordPress driver, before it calls `parent::bootstrap()`. See [Extending a Built-in Driver](drivers.md#extending-a-built-in-driver).

## Composer and Plain PHP

A **Composer project** gets its autoloader loaded, so your classes and packages are ready, and nothing else. Runlet lists its Composer scripts in the Commands panel.

Anything else runs as **plain PHP**, in the project's folder.

Neither reports a version or an environment. If your application has a bootstrap file of its own, a short [project driver](drivers.md#writing-a-project-driver) boots it and hands snippets your container or app object.

## What the Run Inspector Records

Next to the output, the [run inspector](driver-inspector.md) shows what a run did. Without any setup, it records:

| Project | Queries | Mail | Logs |
| --- | --- | --- | --- |
| Laravel, Lumen, Laravel Zero | Yes | Yes, with interception | Yes |
| Eloquent without Laravel | Yes | – | – |
| Symfony | Doctrine connections | Symfony Mailer (interception on 6.3+) | – |
| WordPress | Yes (`$wpdb`) | `wp_mail()` (interception on 5.7+) | – |
| Standalone Doctrine DBAL, plain PDO | One line in a project driver | – | – |

## Completion

Completion comes from PHPantom, bundled with Runlet, which indexes your project without running its code: models, relations, and columns complete as you type. For Docker and SSH targets, it indexes the checkout on your Mac that you set as the profile's local source or local folder. Variables a driver hands to snippets (`$app`, `$wpdb`, `$container`) complete with their classes.

## Other Frameworks

Testbench, Craft, Drupal, Magento, and other frameworks have no built-in driver yet. A [project driver](drivers.md) can boot them: one PHP class in the project's `.runlet/` folder. If you're coming from Tinkerwell, [porting a Tinkerwell driver](tinkerwell-drivers.md) is mostly a rename.

## For developers

- The built-in drivers are `Runlet\Drivers\LaravelDriver`, `WordPressDriver`, `SymfonyDriver`, `ComposerDriver`, and `PlainDriver` in `Resources/Runner/src/Drivers.php`, tried in that order after project drivers; the reported `framework` is `laravel`, `lumen`, `laravel-zero`, `wordpress`, `symfony`, `composer`, or `plain`. Every driver works on PHP 7.4 and later. `LaravelDriver` and `SymfonyDriver` extend `ComposerDriver`, whose `requireAutoloader()` throws the `composer install` message.
- **Choosing a driver explicitly.** The run request's `bootstrap` field defaults to `auto`. It also accepts `custom` (project drivers only; an error if none can boot the project); `laravel`, `lumen`, or `laravel-zero` (all use `LaravelDriver`, which detects the flavour itself); and `wordpress`, `symfony`, `composer`, or `plain`. An explicit built-in value skips both project drivers and detection. The app always sends `auto`.
- **Remembered for the session.** Runs remember per target, until Runlet quits, the built-in driver they chose (while no `.runlet` driver is added or edited) and a WordPress site URL (while `wp-config.php` has the same modification time and size, which skips the evaluation and database lookup, about 50 ms per run). The Run Log says "remembered for this session"; a run that fails while booting forgets that target's values.
- **Laravel.** The flavour comes from the installed packages before boot (`laravel/lumen-framework`, `laravel-zero/framework`) and from the application class after it. Lumen's console kernel has an empty `bootstrap()`, which Runlet doesn't call; it constructs the kernel and calls `$app->boot()`. Lumen's version string ("Lumen (10.0.4) (Laravel Components ^10.0)") is reduced to its number.
- **WordPress.** The request is prepared in `WordPressDriver::prepareRequest()`: `HTTP_HOST`, `SERVER_NAME`, `REQUEST_URI`, `REQUEST_METHOD=GET`, `SERVER_PROTOCOL`, `SERVER_PORT`, `REMOTE_ADDR=127.0.0.1`, `HTTP_USER_AGENT=Runlet`, and `HTTPS=on` for an `https` site, each only when not already set. The site URL comes from an evaluation of `wp-config.php` in a separate PHP process (the line that loads `wp-settings.php` removed, `__DIR__` and `__FILE__` pointing at the real file, output discarded), else from `home` read with the real database settings (one read-only query), else from `wp-config.php` read as text ignoring comments, else `localhost` (`REQUEST_URI` `/`); as a last resort, `home` is applied once WordPress connects (on `muplugins_loaded`). Boot timings come from the earliest callback on `muplugins_loaded`, `plugins_loaded`, `setup_theme`, `after_setup_theme`, `init`, and `wp_loaded`, and from `plugin_loaded`. `bootstrapExitHint()` reports the redirect WordPress tried; the multisite limitation used to say `DOMAIN_CURRENT_SITE` had to be a literal, which the `wp-config.php` evaluation replaced.
- **Symfony.** `loadEnvironment()` and `kernelClass()` are overridable; a missing kernel throws "Runlet could not find the Symfony kernel (expected App\Kernel in src/Kernel.php)".
- The detection table, the WordPress details, and the limitations moved here from `drivers.md`, and "Run inside your real application" from the old readme ([#289](https://github.com/filipac/runlet/issues/289)).
