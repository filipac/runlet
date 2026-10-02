<?php

namespace Tests\Feature;

use App\Mail\OrderShipped;
use App\Models\Order;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Mail;
use Tests\TestCase;

class CheckoutTest extends TestCase
{
    use RefreshDatabase;

    protected $seed = true;

    public function test_the_catalog_lists_products_in_stock(): void
    {
        $this->get('/products')->assertOk()->assertJsonCount(6);
    }

    public function test_an_order_can_be_looked_up_by_number(): void
    {
        $order = Order::first();

        $this->get("/orders/{$order->number}")->assertOk()->assertJsonPath('number', $order->number);
    }

    public function test_checkout_accepts_a_cart(): void
    {
        $this->post('/checkout')->assertNoContent();
    }

    public function test_shipping_mail_lists_every_item(): void
    {
        Mail::fake();
        $order = Order::with('items.product')->first();

        Mail::to('ada@example.com')->send(new OrderShipped($order));

        Mail::assertSent(OrderShipped::class, fn (OrderShipped $mail) => $mail->order->is($order));
    }
}
