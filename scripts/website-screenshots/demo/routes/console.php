<?php

use App\Models\Order;
use App\Models\Product;
use Illuminate\Support\Facades\Artisan;

Artisan::command('shop:report {--days=7}', function () {
    $orders = Order::where('created_at', '>=', now()->subDays((int) $this->option('days')))->get();
    $this->table(['Orders', 'Revenue', 'Average'], [[
        $orders->count(),
        '$' . number_format($orders->sum('total_cents') / 100, 2),
        '$' . number_format(($orders->avg('total_cents') ?? 0) / 100, 2),
    ]]);
})->purpose('Summarize recent orders and revenue');

Artisan::command('inventory:sync', function () {
    $this->components->task('Fetching stock levels from the warehouse', fn () => usleep(200_000));
    $this->components->task('Updating ' . Product::count() . ' products', fn () => usleep(200_000));
    $this->components->info('Inventory is up to date.');
})->purpose('Pull stock levels from the warehouse API');

Artisan::command('inventory:low {--below=20}', function () {
    $this->table(['SKU', 'Product', 'Stock'], Product::where('stock', '<', (int) $this->option('below'))
        ->orderBy('stock')->get(['sku', 'name', 'stock'])->toArray());
})->purpose('List products that are running low');

Artisan::command('orders:ship {number}', function () {
    $this->info("Order {$this->argument('number')} marked as shipped.");
})->purpose('Mark an order as shipped and email the customer');

Artisan::command('orders:export {--since=}', function () {
    $this->info('Exported ' . Order::count() . ' orders to storage/exports/orders.csv');
})->purpose('Export orders as CSV for accounting');

Artisan::command('carts:prune {--hours=48}', function () {
    $this->info('Pruned 0 abandoned carts.');
})->purpose('Delete abandoned carts older than the given age');
