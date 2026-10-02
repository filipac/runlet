<?php

use App\Models\Order;
use App\Models\Product;
use Illuminate\Support\Facades\Route;

Route::get('/', fn () => view('welcome'))->name('home');
Route::get('/products', fn () => Product::inStock()->get())->name('products.index');
Route::get('/products/{product:sku}', fn (Product $product) => $product)->name('products.show');
Route::get('/orders/{order:number}', fn (Order $order) => $order->load('items.product'))->name('orders.show');
Route::post('/checkout', fn () => response()->noContent())->name('checkout');
