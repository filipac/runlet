<?php

namespace App;

class Thing
{
    /**
     * Only defined in project B.
     */
    public function onlyInProjectB(int $count, string $label = 'x'): int
    {
        return $count;
    }
}
