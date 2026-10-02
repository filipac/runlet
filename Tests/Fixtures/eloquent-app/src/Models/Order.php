<?php

namespace Shop\Models;

use Illuminate\Database\Eloquent\Model;

class Order extends Model
{
    public $timestamps = false;
    protected $guarded = [];

    public function customer()
    {
        return $this->belongsTo(Customer::class);
    }
}
