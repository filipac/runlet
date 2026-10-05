<?php

namespace Acme;

/** A validated email address. */
final class EmailAddress
{
    /** @var string */
    private $value;

    public function __construct(string $value)
    {
        if (filter_var($value, FILTER_VALIDATE_EMAIL) === false) {
            throw new \InvalidArgumentException('Not an email address: ' . $value);
        }
        $this->value = strtolower($value);
    }

    public function value(): string
    {
        return $this->value;
    }
}
