<?php

namespace Shop\Models;

use Illuminate\Database\Eloquent\Model;

class Customer extends Model
{
    public $timestamps = false;
    protected $guarded = [];

    public function orders()
    {
        return $this->hasMany(Order::class);
    }
}
