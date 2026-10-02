<?php

declare(strict_types=1);

/*
 * Runlet driver API, declared by the runner before anything from the project loads.
 *
 * A driver boots one kind of application for a run and hands variables to the snippet.
 * Runlet ships the built-in drivers below; a project adds its own in
 * `<project>/.runlet/*Driver.php` by extending Runlet\Driver or a built-in driver.
 * See docs/drivers.md.
 *
 * This file must stay compatible with PHP 7.4 syntax and runtime.
 */

namespace Runlet;

/**
 * Base class for every Runlet driver.
 *
 * Runlet calls, in order: canBootstrap(), bootstrap(), variables(), version(), name(), and
 * then commands() when it lists the project's commands instead of running a snippet.
 * Each run is a fresh PHP process, so a driver boots exactly once per run.
 */
abstract class Driver
{
    /** Name shown in Runlet's status bar. Defaults to the short class name. */
    public function name(): string
    {
        $class = get_class($this);
        $separator = strrpos($class, '\\');

        return $separator === false ? $class : substr($class, $separator + 1);
    }

    /**
     * Whether this driver can boot the project at $projectPath (the run's working
     * directory). Project drivers default to true.
     */
    public function canBootstrap(string $projectPath): bool
    {
        return true;
    }

    /** Boots the application. Throw to report a bootstrap error. */
    abstract public function bootstrap(string $projectPath): void;

    /**
     * Variables available in every snippet, as name => value. Called after bootstrap().
     *
     * @return array<string, mixed>
     */
    public function variables(): array
    {
        return [];
    }

    /** Application or framework version shown next to the driver name, if any. */
    public function version(): ?string
    {
        return null;
    }

    /**
     * Commands listed in Runlet's Commands panel, keyed by name. Called after bootstrap(),
     * only when the panel loads commands, never during a snippet run. Each entry is
     *
     *     'name' => ['command' => 'php artisan name', 'description' => '…', 'group' => 'ns']
     *
     * where `command` is a shell command line run in the project directory (inside the
     * container for Docker targets), and `description` and `group` are optional. A string
     * value is shorthand for `['command' => …]`. Extend a built-in driver's list with
     * `parent::commands() + [...]` or array_merge(). Composer scripts are added by Runlet.
     *
     * @return array<string, array{command: string, description?: string|null, group?: string|null}|string>
     */
    public function commands(): array
    {
        return [];
    }

    /**
     * Describes Symfony Console commands (Artisan, bin/console, ...) for commands():
     * aliases and hidden commands are skipped, and each command is grouped by its
     * namespace (`make:model` in "make"; `migrate` joins "migrate" when `migrate:*` exists).
     *
     * @param iterable<mixed> $commands name => Symfony\Component\Console\Command\Command, as from Application::all()
     * @param string $commandPrefix the console invocation, e.g. "php artisan"
     * @return array<string, array{command: string, description: string|null, group: string|null}>
     */
    protected function consoleCommands(iterable $commands, string $commandPrefix): array
    {
        $descriptions = [];
        foreach ($commands as $key => $command) {
            if (!is_object($command) || !method_exists($command, 'getName')) {
                continue;
            }
            $name = (string) $command->getName();
            // Application::all() lists every alias as its own key.
            if ($name === '' || (is_string($key) && $key !== $name) || isset($descriptions[$name])) {
                continue;
            }
            if (method_exists($command, 'isHidden') && $command->isHidden()) {
                continue;
            }
            $description = method_exists($command, 'getDescription') ? trim((string) $command->getDescription()) : '';
            $descriptions[$name] = $description === '' ? null : $description;
        }
        ksort($descriptions, SORT_STRING);

        $namespaces = [];
        foreach (array_keys($descriptions) as $name) {
            $colon = strpos((string) $name, ':');
            if ($colon !== false && $colon > 0) {
                $namespaces[substr((string) $name, 0, $colon)] = true;
            }
        }

        $result = [];
        foreach ($descriptions as $name => $description) {
            $name = (string) $name;
            $colon = strpos($name, ':');
            if ($colon !== false && $colon > 0) {
                $group = substr($name, 0, $colon);
            } else {
                $group = isset($namespaces[$name]) ? $name : null;
            }
            $argument = preg_match('/^[A-Za-z0-9:._-]+$/', $name) ? $name : escapeshellarg($name);
            $result[$name] = ['command' => $commandPrefix . ' ' . $argument, 'description' => $description, 'group' => $group];
        }

        return $result;
    }
}

namespace Runlet\Drivers;

use Runlet\Driver;

/** A directory without Composer or framework markers: nothing is loaded. */
class PlainDriver extends Driver
{
    public function name(): string
    {
        return 'PHP';
    }

    public function bootstrap(string $projectPath): void
    {
    }
}

/** Any Composer project: loads vendor/autoload.php. */
class ComposerDriver extends Driver
{
    public function name(): string
    {
        return 'Composer';
    }

    public function canBootstrap(string $projectPath): bool
    {
        return is_file($projectPath . '/composer.json') || is_file($projectPath . '/vendor/autoload.php');
    }

    public function bootstrap(string $projectPath): void
    {
        $this->requireAutoloader($projectPath);
    }

    /** Loads the project's Composer autoloader, or explains how to install it. */
    protected function requireAutoloader(string $projectPath): void
    {
        $autoload = $projectPath . '/vendor/autoload.php';
        if (!is_file($autoload)) {
            throw new \RuntimeException('Composer dependencies are not installed: ' . $autoload . ' is missing. Run `composer install` in the project.');
        }
        require_once $autoload;
    }
}

/**
 * Laravel, Lumen, and Laravel Zero: loads bootstrap/app.php and bootstraps it like an
 * Artisan command does, so providers, config, facades, and helpers are ready.
 */
class LaravelDriver extends ComposerDriver
{
    /** @var object|null The application returned by bootstrap/app.php. */
    protected $app;
    /** @var string|null */
    private $projectPath;

    public function name(): string
    {
        switch ($this->flavor($this->projectPath ?? '.')) {
            case 'lumen':
                return 'Lumen';
            case 'laravel-zero':
                return 'Laravel Zero';
            default:
                return 'Laravel';
        }
    }

    public function canBootstrap(string $projectPath): bool
    {
        if (!is_file($projectPath . '/bootstrap/app.php')) {
            return false;
        }

        // Laravel and Lumen ship `artisan`; Laravel Zero apps name their entry script themselves.
        return is_file($projectPath . '/artisan') || self::hasPackage($projectPath, 'laravel-zero/framework');
    }

    /**
     * Which Laravel-family framework the project uses: "laravel", "lumen", or "laravel-zero".
     * After bootstrap() this comes from the application class, before it from installed packages.
     */
    public function flavor(string $projectPath): string
    {
        if (is_object($this->app)) {
            if (is_a($this->app, 'Laravel\Lumen\Application')) {
                return 'lumen';
            }
            if (is_a($this->app, 'LaravelZero\Framework\Application')) {
                return 'laravel-zero';
            }

            return 'laravel';
        }
        if (self::hasPackage($projectPath, 'laravel/lumen-framework')) {
            return 'lumen';
        }
        if (self::hasPackage($projectPath, 'laravel-zero/framework')) {
            return 'laravel-zero';
        }

        return 'laravel';
    }

    public function bootstrap(string $projectPath): void
    {
        $this->projectPath = $projectPath;
        $this->requireAutoloader($projectPath);

        $app = require $projectPath . '/bootstrap/app.php';
        if (!is_object($app) || !method_exists($app, 'make')) {
            throw new \RuntimeException('bootstrap/app.php did not return a Laravel application.');
        }
        $this->app = $app;

        if ($this->flavor($projectPath) === 'lumen') {
            // Lumen's console kernel has an empty bootstrap(): constructing it prepares the
            // console environment (facades, URL generation), and boot() boots the providers.
            if (method_exists($app, 'bound') && $app->bound('Illuminate\Contracts\Console\Kernel')) {
                $app->make('Illuminate\Contracts\Console\Kernel');
            }
            if (method_exists($app, 'boot')) {
                $app->boot();
            }

            return;
        }

        // Laravel and Laravel Zero; the kernel skips bootstrappers that already ran.
        $app->make('Illuminate\Contracts\Console\Kernel')->bootstrap();
    }

    /** @return array<string, mixed> */
    public function variables(): array
    {
        return $this->app === null ? [] : ['app' => $this->app];
    }

    public function version(): ?string
    {
        if (!is_object($this->app) || !method_exists($this->app, 'version')) {
            return null;
        }
        $version = (string) $this->app->version();
        // Lumen reports "Lumen (10.0.4) (Laravel Components ^10.0)".
        if (preg_match('/^Lumen \(([^)]+)\)/', $version, $match)) {
            return $match[1];
        }

        return $version;
    }

    /** Every visible Artisan command (or the Laravel Zero app's commands), as `php <script> <name>`. */
    public function commands(): array
    {
        if (!is_object($this->app) || !method_exists($this->app, 'make')) {
            return [];
        }
        $kernel = $this->app->make('Illuminate\Contracts\Console\Kernel');
        if (!is_object($kernel) || !method_exists($kernel, 'all')) {
            return [];
        }

        return $this->consoleCommands($kernel->all(), 'php ' . $this->consoleScript($this->projectPath ?? '.'));
    }

    /**
     * The console entry script, relative to the project: `artisan` for Laravel and Lumen; for
     * Laravel Zero, the binary named in composer.json "bin", or the PHP script in the project
     * root that loads bootstrap/app.php.
     */
    protected function consoleScript(string $projectPath): string
    {
        if ($this->flavor($projectPath) !== 'laravel-zero') {
            return 'artisan';
        }
        $manifest = @file_get_contents($projectPath . '/composer.json');
        $composer = is_string($manifest) ? json_decode($manifest, true) : null;
        foreach ((array) ($composer['bin'] ?? []) as $binary) {
            if (is_string($binary) && $binary !== '' && is_file($projectPath . '/' . $binary)) {
                return preg_match('/^[A-Za-z0-9\/._-]+$/', $binary) ? $binary : escapeshellarg($binary);
            }
        }
        foreach ((array) @scandir($projectPath) as $entry) {
            $path = $projectPath . '/' . $entry;
            if (!is_string($entry) || $entry === '' || $entry[0] === '.' || strpos($entry, '.') !== false || !is_file($path)) {
                continue;
            }
            $head = (string) @file_get_contents($path, false, null, 0, 2048);
            if (strpos($head, '#!') === 0 && strpos($head, 'php') !== false && strpos($head, 'bootstrap/app.php') !== false) {
                return preg_match('/^[A-Za-z0-9._-]+$/', $entry) ? $entry : escapeshellarg($entry);
            }
        }

        return is_file($projectPath . '/artisan') ? 'artisan' : 'application';
    }

    private static function hasPackage(string $projectPath, string $package): bool
    {
        if (is_dir($projectPath . '/vendor/' . $package)) {
            return true;
        }
        $manifest = @file_get_contents($projectPath . '/composer.json');
        $composer = is_string($manifest) ? json_decode($manifest, true) : null;
        if (!is_array($composer)) {
            return false;
        }
        foreach (['require', 'require-dev'] as $section) {
            if (isset($composer[$section][$package])) {
                return true;
            }
        }

        return false;
    }
}

/**
 * WordPress: a standard install, Bedrock (web/wp), public/wp, wordpress/, or wp/.
 *
 * WordPress is written for the global scope. Like WP-CLI, Runlet loads it from a function
 * whose WordPress globals are declared `global`, then promotes any other variable the
 * load defined. Snippets run in their own scope: use `global $post;` (or $GLOBALS) for
 * globals other than the injected $wpdb.
 */
class WordPressDriver extends Driver
{
    /** Globals WordPress core and common setups assign at file scope while loading. */
    private const WORDPRESS_GLOBALS = [
        'wpdb', 'table_prefix', 'wp_version', 'wp_db_version', 'tinymce_version', 'required_php_version',
        'required_php_extensions', 'required_mysql_version', 'wp_local_package', 'blog_id', 'site_id', 'public',
        'current_site', 'current_blog', 'path', 'domain', 'shortcode_tags', 'wp_filter', 'wp_actions', 'wp_filters',
        'wp_current_filter', 'wp_object_cache', 'wp_embed', 'wp_textdomain_registry', 'wp_plugin_paths',
        'wp_the_query', 'wp_query', 'wp_rewrite', 'wp', 'wp_widget_factory', 'wp_roles', 'locale', 'locale_file',
        'wp_locale', 'wp_locale_switcher', 'wp_theme', 'wp_theme_directories', 'pagenow', 'is_lynx', 'is_gecko',
        'is_winIE', 'is_macIE', 'is_opera', 'is_NS4', 'is_safari', 'is_chrome', 'is_iphone', 'is_IE', 'is_edge',
        'is_apache', 'is_nginx', 'is_caddy', 'is_IIS', 'is_iis7', '_wp_switched_stack', 'switched', 'current_user',
        'post', 'posts', 'wp_post_types', 'wp_taxonomies', 'wp_post_statuses', 'wp_scripts', 'wp_styles', 'l10n',
        'allowedposttags', 'allowedtags', 'allowedentitynames', 'allowedxmlentitynames', 'wp_registered_sidebars',
        'wp_registered_widgets', 'wp_meta_boxes', 'wp_settings_errors', 'wp_rest_server', 'wp_sitemaps',
        'mu_plugin', 'network_plugin', 'plugin', '_wp_plugin_file',
    ];

    /** @var array<int, string> */
    private const LOADERS = ['wp-load.php', 'web/wp/wp-load.php', 'public/wp/wp-load.php', 'wordpress/wp-load.php', 'wp/wp-load.php'];

    public function name(): string
    {
        return 'WordPress';
    }

    public function canBootstrap(string $projectPath): bool
    {
        return $this->locateLoader($projectPath) !== null;
    }

    public function bootstrap(string $projectPath): void
    {
        $loader = $this->locateLoader($projectPath);
        if ($loader === null) {
            throw new \RuntimeException('WordPress was not found: there is no wp-load.php in ' . $projectPath . ' (also looked in ' . implode(', ', array_map('dirname', array_slice(self::LOADERS, 1))) . ').');
        }
        $config = self::configFile(dirname($loader));
        if ($config === null) {
            throw new \RuntimeException('WordPress is not configured: wp-config.php was not found next to ' . $loader . ' or one directory above it.');
        }
        if (is_file($projectPath . '/vendor/autoload.php')) {
            require_once $projectPath . '/vendor/autoload.php';
        }

        $this->prepareRequest($config);
        if (!defined('WP_USE_THEMES')) {
            define('WP_USE_THEMES', false);
        }
        $guard = $this->installBootstrapHooks();

        self::load($loader);

        if (function_exists('remove_filter')) {
            remove_filter('nocache_headers', $guard, 10);
        }
        // The admin APIs (get_plugins(), wp_delete_post() helpers, ...), as WP-CLI loads them.
        if (defined('ABSPATH') && is_file(ABSPATH . 'wp-admin/includes/admin.php')) {
            require_once ABSPATH . 'wp-admin/includes/admin.php';
        }
    }

    /** @return array<string, mixed> */
    public function variables(): array
    {
        return isset($GLOBALS['wpdb']) ? ['wpdb' => $GLOBALS['wpdb']] : [];
    }

    public function version(): ?string
    {
        return isset($GLOBALS['wp_version']) ? (string) $GLOBALS['wp_version'] : null;
    }

    /** The wp-load.php to use, or null when the project is not WordPress. */
    protected function locateLoader(string $projectPath): ?string
    {
        foreach (self::LOADERS as $candidate) {
            if (is_file($projectPath . '/' . $candidate)) {
                return $projectPath . '/' . $candidate;
            }
        }

        return null;
    }

    /**
     * Request defaults for a CLI process, so WordPress and plugins find the usual
     * $_SERVER keys. A multisite's main site is taken from DOMAIN_CURRENT_SITE when
     * wp-config.php defines it literally; otherwise set $_SERVER['HTTP_HOST'] in a project
     * driver before calling parent::bootstrap().
     */
    protected function prepareRequest(string $configFile): void
    {
        $host = 'localhost';
        $path = '/';
        $config = (string) @file_get_contents($configFile);
        if (preg_match('/define\(\s*[\'"]DOMAIN_CURRENT_SITE[\'"]\s*,\s*[\'"]([^\'"]+)[\'"]/', $config, $match)) {
            $host = $match[1];
            if (preg_match('/define\(\s*[\'"]PATH_CURRENT_SITE[\'"]\s*,\s*[\'"]([^\'"]+)[\'"]/', $config, $match)) {
                $path = $match[1];
            }
        }
        $defaults = [
            'HTTP_HOST' => $host,
            'SERVER_NAME' => $host,
            'REQUEST_URI' => $path,
            'REQUEST_METHOD' => 'GET',
            'SERVER_PROTOCOL' => 'HTTP/1.1',
            'SERVER_PORT' => '80',
            'REMOTE_ADDR' => '127.0.0.1',
            'HTTP_USER_AGENT' => 'Runlet',
        ];
        foreach ($defaults as $key => $value) {
            if (!isset($_SERVER[$key])) {
                $_SERVER[$key] = $value;
            }
        }
    }

    /**
     * Filters registered before WordPress loads (WordPress turns pre-filled $wp_filter
     * entries into hooks). Returns the bootstrap-only nocache_headers guard.
     */
    private function installBootstrapHooks(): \Closure
    {
        $false = static function (): bool {
            return false;
        };
        // WordPress's own fatal-error handler would print an HTML error page, pause the
        // plugin, and possibly email a recovery-mode link after a snippet's fatal error.
        self::addFilter('wp_fatal_error_handler_enabled', $false);
        // Page-cache drop-ins and maintenance mode can serve a page and exit.
        self::addFilter('enable_loading_advanced_cache_dropin', $false);
        self::addFilter('enable_maintenance_mode', $false);
        self::addFilter('ms_site_check', static function (): bool {
            return true;
        });
        // A run should not spawn WP-Cron (an HTTP request to the site and a lock write at
        // shutdown, or a redirect with ALTERNATE_WP_CRON). Snippets can still call wp_cron().
        self::addFilter('muplugins_loaded', static function (): void {
            remove_action('init', 'wp_cron');
        });
        // wp_die() prints an HTML page and exits; report its message as an exception instead.
        self::addFilter('wp_die_handler', static function () {
            return static function ($message, $title = '', $args = []): void {
                if (is_object($message) && method_exists($message, 'get_error_message')) {
                    $message = $message->get_error_message();
                }
                $text = is_scalar($message) ? (string) $message : '';
                if ($text === '' && is_scalar($title)) {
                    $text = (string) $title;
                }
                $text = trim(html_entity_decode(strip_tags($text), ENT_QUOTES));

                throw new \RuntimeException('wp_die(): ' . ($text === '' ? 'WordPress stopped the request.' : $text));
            };
        });
        // While loading, nocache_headers() means WordPress is about to redirect and exit
        // because its database is unreachable or it is not installed.
        $guard = static function ($headers) {
            $wpdb = $GLOBALS['wpdb'] ?? null;
            if (is_object($wpdb) && !empty($wpdb->error)) {
                $error = $wpdb->error;
                if (is_object($error) && method_exists($error, 'get_error_message')) {
                    $error = $error->get_error_message();
                }
                throw new \RuntimeException('WordPress could not use its database: ' . trim(strip_tags(is_scalar($error) ? (string) $error : 'unknown error')));
            }
            $installing = function_exists('wp_installing') && wp_installing();
            if (!$installing && function_exists('is_blog_installed') && !is_blog_installed()) {
                throw new \RuntimeException('WordPress is not installed in its database yet. Finish the installation first (for example with `wp core install`).');
            }

            return $headers;
        };
        self::addFilter('nocache_headers', $guard);

        return $guard;
    }

    private static function addFilter(string $hook, callable $callback): void
    {
        if (function_exists('add_filter')) {
            add_filter($hook, $callback, 10, 1);

            return;
        }
        $GLOBALS['wp_filter'][$hook][10][] = ['function' => $callback, 'accepted_args' => 1];
    }

    /** Mirrors wp-load.php's lookup: ABSPATH/wp-config.php, or one level up (Bedrock). */
    private static function configFile(string $abspath): ?string
    {
        if (is_file($abspath . '/wp-config.php')) {
            return $abspath . '/wp-config.php';
        }
        $parent = dirname($abspath);
        if (is_file($parent . '/wp-config.php') && !is_file($parent . '/wp-settings.php')) {
            return $parent . '/wp-config.php';
        }

        return null;
    }

    private static function load(string $__runletLoader): void
    {
        foreach (self::WORDPRESS_GLOBALS as $__runletName) {
            global $$__runletName;
        }
        unset($__runletName);
        $__runletBefore = get_defined_vars();

        require $__runletLoader;

        // Anything else WordPress, wp-config.php, or a plugin defined at "file scope" would
        // have been global in a web request.
        foreach (get_defined_vars() as $__runletName => $__runletValue) {
            if ($__runletName !== '__runletBefore' && !array_key_exists($__runletName, $__runletBefore)) {
                $GLOBALS[$__runletName] = $__runletValue;
            }
        }
    }
}

/**
 * Symfony (Flex skeleton or classic): loads the .env files like the Runtime component,
 * then boots the kernel. Snippets get $kernel and $container.
 */
class SymfonyDriver extends ComposerDriver
{
    /** @var object|null The booted kernel. */
    protected $kernel;

    public function name(): string
    {
        return 'Symfony';
    }

    public function canBootstrap(string $projectPath): bool
    {
        return is_file($projectPath . '/bin/console')
            && (is_file($projectPath . '/src/Kernel.php') || is_file($projectPath . '/config/bundles.php'));
    }

    public function bootstrap(string $projectPath): void
    {
        $this->requireAutoloader($projectPath);
        $this->loadEnvironment($projectPath);

        $class = $this->kernelClass($projectPath);
        $environment = (string) ($_SERVER['APP_ENV'] ?? $_ENV['APP_ENV'] ?? 'dev');
        $debug = $_SERVER['APP_DEBUG'] ?? $_ENV['APP_DEBUG'] ?? ($environment !== 'prod');
        $kernel = new $class($environment, (bool) $debug);
        $kernel->boot();
        $this->kernel = $kernel;
    }

    /** @return array<string, mixed> */
    public function variables(): array
    {
        if (!is_object($this->kernel)) {
            return [];
        }

        return ['kernel' => $this->kernel, 'container' => $this->kernel->getContainer()];
    }

    public function version(): ?string
    {
        $constant = 'Symfony\Component\HttpKernel\Kernel::VERSION';

        return defined($constant) ? (string) constant($constant) : null;
    }

    /** Every visible `bin/console` command of the booted kernel, as `php bin/console <name>`. */
    public function commands(): array
    {
        $application = 'Symfony\Bundle\FrameworkBundle\Console\Application';
        if (!is_object($this->kernel) || !class_exists($application)) {
            return [];
        }
        $console = new $application($this->kernel);

        return $this->consoleCommands($console->all(), 'php bin/console');
    }

    /** Loads .env, .env.local, .env.<env>, ... (Symfony 5.1+ bootEnv; config/bootstrap.php on 4.x). */
    protected function loadEnvironment(string $projectPath): void
    {
        if (is_file($projectPath . '/config/bootstrap.php')) {
            require $projectPath . '/config/bootstrap.php';

            return;
        }
        $dotenv = 'Symfony\Component\Dotenv\Dotenv';
        if (!class_exists($dotenv) || (!is_file($projectPath . '/.env') && !is_file($projectPath . '/.env.dist'))) {
            return;
        }
        if (method_exists($dotenv, 'bootEnv')) {
            (new $dotenv())->bootEnv($projectPath . '/.env');
        } elseif (method_exists($dotenv, 'loadEnv')) {
            (new $dotenv())->loadEnv($projectPath . '/.env');
        }
    }

    /** The kernel class declared in src/Kernel.php (App\Kernel by default). */
    protected function kernelClass(string $projectPath): string
    {
        $source = @file_get_contents($projectPath . '/src/Kernel.php');
        if (is_string($source) && preg_match('/^\s*namespace\s+([A-Za-z0-9_\\\\]+)\s*;/m', $source, $match) && class_exists($match[1] . '\Kernel')) {
            return $match[1] . '\Kernel';
        }
        if (class_exists('App\Kernel')) {
            return 'App\Kernel';
        }

        throw new \RuntimeException('Runlet could not find the Symfony kernel (expected App\Kernel in src/Kernel.php). Add a project driver in .runlet/ to boot this application.');
    }
}
