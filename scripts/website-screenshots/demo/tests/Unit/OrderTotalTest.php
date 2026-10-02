<?php

namespace Tests\Unit;

use App\Models\Order;
use App\Models\Product;
use PHPUnit\Framework\TestCase;

class OrderTotalTest extends TestCase
{
    public function test_totals_are_formatted_in_dollars(): void
    {
        $this->assertSame('$1,234.50', (new Order(['total_cents' => 123450]))->total());
    }

    public function test_prices_are_formatted_in_dollars(): void
    {
        $this->assertSame('$24.00', (new Product(['price_cents' => 2400]))->price());
    }
}
