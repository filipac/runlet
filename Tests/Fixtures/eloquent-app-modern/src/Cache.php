<?php

namespace Shop;

/** An in-memory cache that reports every hit, miss, and write to one listener. */
final class Cache
{
    /** @var array<string, mixed> */
    private static $items = [];
    /** @var callable|null */
    private static $listener;

    public static function listen(callable $listener): void
    {
        self::$listener = $listener;
    }

    /** @return mixed */
    public static function remember(string $key, callable $compute)
    {
        if (array_key_exists($key, self::$items)) {
            self::notify('hit', $key, self::$items[$key]);

            return self::$items[$key];
        }
        self::notify('miss', $key, null);
        self::$items[$key] = $compute();
        self::notify('write', $key, self::$items[$key]);

        return self::$items[$key];
    }

    /** @param mixed $value */
    private static function notify(string $operation, string $key, $value): void
    {
        if (self::$listener !== null) {
            (self::$listener)($operation, $key, $value);
        }
    }
}
