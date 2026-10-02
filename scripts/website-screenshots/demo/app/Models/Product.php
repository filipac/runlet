<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;

class Product extends Model
{
    protected $guarded = [];

    protected function casts(): array
    {
        return ['price_cents' => 'integer', 'stock' => 'integer'];
    }

    /** @param Builder<Product> $query */
    public function scopeInStock(Builder $query): void
    {
        $query->where('stock', '>', 0);
    }

    public function price(): string
    {
        return '$' . number_format($this->price_cents / 100, 2);
    }
}
