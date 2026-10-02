<?php

namespace Acme;

class Greeter
{
    /** @var string */
    private $greeting;

    public function __construct(string $greeting = 'Hello')
    {
        $this->greeting = $greeting;
    }

    public function greet(string $name): string
    {
        return $this->greeting . ', ' . $name . '!';
    }
}
