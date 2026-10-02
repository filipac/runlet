<?php

namespace Acme;

/** A minimal static service container, like the ones many Slim-style apps use. */
final class DI
{
    /** @var array<string, object> */
    private static $entries = [];

    public static function set(string $id, object $entry): void
    {
        self::$entries[$id] = $entry;
    }

    public static function get(string $id): object
    {
        if (!isset(self::$entries[$id])) {
            throw new \RuntimeException('Nothing is registered for ' . $id . '. Was config/bootstrap.php loaded?');
        }

        return self::$entries[$id];
    }
}
