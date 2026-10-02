<x-mail::message>
# Your order is on its way

Hi {{ str($order->customer->name)->before(' ') }}, good news: order **{{ $order->number }}** left our warehouse today.

<x-mail::table>
| Item | Qty | Price |
|:-----|:---:|------:|
@foreach ($order->items as $item)
| {{ $item->product->name }} | {{ $item->quantity }} | ${{ number_format($item->price_cents / 100, 2) }} |
@endforeach
| **Total** | | **{{ $order->total() }}** |
</x-mail::table>

<x-mail::button :url="'https://shop.example.com/orders/'.$order->number">
Track your package
</x-mail::button>

Thanks for shopping with us,<br>
{{ config('app.name') }}
</x-mail::message>
