<?php

namespace Database\Seeders;

use App\Models\Order;
use App\Models\Product;
use App\Models\User;
use Illuminate\Database\Seeder;
use Illuminate\Support\Carbon;

class DatabaseSeeder extends Seeder
{
    public function run(): void
    {
        $customers = collect([
            'Ada Lovelace', 'Grace Hopper', 'Alan Turing', 'Katherine Johnson', 'Linus Pauling',
            'Margaret Hamilton', 'Edsger Dijkstra', 'Hedy Lamarr', 'Barbara Liskov', 'Dennis Ritchie',
        ])->map(fn (string $name) => User::create([
            'name' => $name,
            'email' => str($name)->before(' ')->lower() . '@example.com',
            'password' => 'secret-demo-password',
        ]));

        $products = collect([
            ['TEE-ORG', 'Organic cotton tee', 2400, 120],
            ['MUG-ENM', 'Enamel camp mug', 1800, 64],
            ['BAG-CNV', 'Canvas tote bag', 2900, 41],
            ['CAP-WOL', 'Wool beanie', 3200, 0],
            ['SOC-MRN', 'Merino socks (2 pack)', 1900, 230],
            ['BTL-STL', 'Steel water bottle', 3400, 18],
            ['NTB-DOT', 'Dot grid notebook', 1500, 87],
            ['PIN-SET', 'Enamel pin set', 1200, 0],
        ])->map(fn (array $row) => Product::create([
            'sku' => $row[0], 'name' => $row[1], 'price_cents' => $row[2], 'stock' => $row[3],
        ]));

        mt_srand(2026);
        $start = Carbon::parse('2026-09-14 09:00');
        foreach (range(1, 24) as $index) {
            $placed = $start->copy()->addHours($index * 13);
            $order = Order::create([
                'number' => sprintf('AC-%05d', 10230 + $index),
                'customer_id' => $customers[mt_rand(0, $customers->count() - 1)]->id,
                'status' => $index > 20 ? 'paid' : 'shipped',
                'total_cents' => 0,
                'shipped_at' => $index > 20 ? null : $placed->copy()->addDay(),
                'created_at' => $placed,
                'updated_at' => $placed,
            ]);
            $total = 0;
            foreach ($products->random(mt_rand(1, 3)) as $product) {
                $quantity = mt_rand(1, 3);
                $order->items()->create(['product_id' => $product->id, 'quantity' => $quantity, 'price_cents' => $product->price_cents]);
                $total += $quantity * $product->price_cents;
            }
            $order->update(['total_cents' => $total]);
        }
    }
}
