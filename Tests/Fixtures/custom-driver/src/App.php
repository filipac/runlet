<?php

namespace Acme;

/** A tiny Slim-like application: a name and a route table. */
final class App
{
    /** @var string */
    private $name;
    /** @var array<string, callable> */
    private $routes = [];
    /** @var \PDO|null */
    private $database;

    public function __construct(string $name)
    {
        $this->name = $name;
    }

    public function name(): string
    {
        return $this->name;
    }

    public function get(string $path, callable $handler): self
    {
        $this->routes['GET ' . $path] = $handler;

        return $this;
    }

    /** @return mixed */
    public function handle(string $method, string $path)
    {
        $key = strtoupper($method) . ' ' . $path;
        if (!isset($this->routes[$key])) {
            throw new \RuntimeException('No route for ' . $key);
        }

        return ($this->routes[$key])();
    }

    /** @return string[] */
    public function routes(): array
    {
        return array_keys($this->routes);
    }

    /** The app's database: in-memory SQLite, created and seeded on first use. */
    public function database(): \PDO
    {
        if ($this->database === null) {
            $pdo = new \PDO('sqlite::memory:');
            $pdo->exec('CREATE TABLE leases (id INTEGER PRIMARY KEY, tenant TEXT NOT NULL, rent INTEGER NOT NULL)');
            $pdo->exec("INSERT INTO leases (tenant, rent) VALUES ('Ada', 1200), ('Grace', 950), ('Linus', 1500)");
            $this->database = $pdo;
        }

        return $this->database;
    }
}
