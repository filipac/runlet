<?php

namespace Shop;

/** A tiny service container, standing in for PHP-DI or Pimple in a Slim app. */
final class Container
{
    /** @var array<string, callable> */
    private $factories = [];
    /** @var array<string, mixed> */
    private $instances = [];

    public function set(string $id, callable $factory): void
    {
        $this->factories[$id] = $factory;
        unset($this->instances[$id]);
    }

    /** @return mixed */
    public function get(string $id)
    {
        if (!array_key_exists($id, $this->instances)) {
            if (!isset($this->factories[$id])) {
                throw new \InvalidArgumentException('Unknown service ' . $id);
            }
            $this->instances[$id] = ($this->factories[$id])($this);
        }

        return $this->instances[$id];
    }
}
