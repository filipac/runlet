<?php

namespace Acme;

/** An amount of money in cents: a value object whose properties alone read poorly. */
class Money
{
    /** @var int */
    private $cents;
    /** @var string */
    private $currency;

    public function __construct(int $cents, string $currency)
    {
        $this->cents = $cents;
        $this->currency = $currency;
    }

    public function cents(): int
    {
        return $this->cents;
    }

    public function currency(): string
    {
        return $this->currency;
    }

    public function format(): string
    {
        return number_format($this->cents / 100, 2) . ' ' . $this->currency;
    }
}
