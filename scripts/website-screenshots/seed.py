#!/usr/bin/env python3
"""Writes a scratch Runlet data folder with demo content for the website screenshots.

Usage: seed.py <data dir> <fake docker CLI> <demo project path>
Never touches ~/Library/Application Support/Runlet. See shoot.sh.
"""
import json
import os
import sys
import time
import uuid

data, fake_docker, project_path = sys.argv[1], sys.argv[2], sys.argv[3]
state = os.path.join(data, "State")
os.makedirs(state, exist_ok=True)
now = time.time() - 978307200  # Foundation reference date


def write(name, value):
    with open(os.path.join(state, name + ".json"), "w") as f:
        json.dump({"schemaVersion": 1, "savedAt": now, "data": value}, f, indent=2)


def ref(kind, ident=None):
    return {kind: {}} if ident is None else {kind: {"_0": ident}}


local_id, docker_id, staging_id, prod_id = (str(uuid.uuid4()).upper() for _ in range(4))

write("settings", {
    "appearance": "light",
    "tabLayout": "vertical",
    "verticalTabsWidth": 214,
    "libraryPanelWidth": 330,
    "editorSplitRight": 0.46,
    "dockerExecutable": fake_docker,
    "interceptMail": False,
    "fontSize": 13,
    "terminalHeight": 290,
})

write("targets", {
    "localProjects": [{
        "id": local_id, "name": "acme-shop", "path": project_path, "interceptMail": True,
        "revision": 1, "lastOpenedAt": now - 60,
    }],
    "dockerProfiles": [{
        "id": docker_id, "name": "acme-shop (Docker)",
        "identity": {"composeProject": "acme-shop", "composeService": "app", "lastImage": "acme/shop-php:8.3"},
        "workingDirectory": "/var/www/html", "phpExecutable": "php", "temporaryDirectory": "/tmp",
        "localSourcePath": project_path, "autoResolve": False, "revision": 1, "lastOpenedAt": now - 120,
    }],
    "sshProfiles": [
        {"id": staging_id, "name": "staging", "host": "app.example.com", "remoteDirectory": "/home/runlet/site/current",
         "phpExecutable": "php", "authentication": "automatic", "keepAliveMinutes": 10, "compression": True,
         "environment": "staging", "checkDrift": False, "revision": 1, "lastOpenedAt": now - 180},
        {"id": prod_id, "name": "production", "host": "shop.example.com", "remoteDirectory": "/home/runlet/site/current",
         "phpExecutable": "php", "authentication": "automatic", "keepAliveMinutes": 10, "compression": True,
         "environment": "production", "checkDrift": False, "revision": 1, "lastOpenedAt": now - 240},
    ],
})

TABS = [
    ("Scratch", ref("sandbox"), """use App\\Models\\User;
use Illuminate\\Support\\Str;

// The bundled Laravel sandbox: a fresh app on SQLite.
User::factory()->count(5)->create();

$users = User::latest('id')->take(5)->get();

dump("{$users->count()} users created");

$users->map(fn (User $user) => [
    'name' => $user->name,
    'handle' => '@' . Str::slug($user->name),
    'email' => $user->email,
]);
"""),
    ("Recent orders", ref("local", local_id), """use App\\Models\\Order;
use App\\Models\\Product;
use Illuminate\\Support\\Facades\\Cache;

$featured = Cache::remember('catalog:featured', 600,
    fn () => Product::inStock()->take(3)->pluck('name'));

$orders = Order::latest()->take(6)->get();

// No eager loading: every row queries again.
$orders->map(fn (Order $order) => [
    'number' => $order->number,
    'customer' => $order->customer->name,
    'items' => $order->items->count(),
    'total' => $order->total(),
]);
"""),
    ("Shipping mail", ref("local", local_id), """use App\\Mail\\OrderShipped;
use App\\Models\\Order;
use Illuminate\\Support\\Facades\\Mail;

$order = Order::with('customer', 'items.product')
    ->whereNotNull('shipped_at')
    ->latest()
    ->firstOrFail();

// Intercepted: recorded and previewed, never sent.
Mail::to($order->customer)
    ->send(new OrderShipped($order));

$order->only('number', 'status', 'shipped_at');
"""),
    # Database tabs (#246): SQL on the demo's own SQLite database, Redis (not run), and MongoDB on
    # a saved connection to the runlet-fixtures `mongo` container, which steps.txt saves with
    # `db-new` (seed-databases.sh seeds its `shop_demo` database).
    ("Customers", ref("local", local_id), """-- The shop's own database, through the app's connection.
-- @param :status text shipped
-- @param :since text 2026-09-20
SELECT users.name AS customer,
       COUNT(*) AS orders,
       printf('%.2f', SUM(orders.total_cents) / 100.0) AS revenue
FROM orders
JOIN users ON users.id = orders.customer_id
WHERE orders.status = :status
  AND orders.created_at >= :since
GROUP BY users.id
ORDER BY SUM(orders.total_cents) DESC
LIMIT 5;
""", "sql"),
    ("Cart cache", ref("local", local_id), """# ⌘R runs the caret's line; Run All runs every line.
GET shop:catalog:featured
HGETALL shop:cart:1042
ZREVRANGE shop:bestsellers 0 4 WITHSCORES
TTL shop:session:9f2c
""", "redis"),
    ("Reviews", ref("local", local_id), """{
  "collection": "reviews",
  "operation": "find",
  "filter": {
    "rating": { "$gte": 4 },
    "verified": true
  },
  "projection": {
    "_id": 0, "product": 1,
    "rating": 1, "title": 1,
    "posted_at": 1
  },
  "sort": { "posted_at": -1 },
  "limit": 20
}
""", "mongodb"),
    ("Queue health", ref("docker", docker_id), """use Illuminate\\Support\\Facades\\DB;
use Illuminate\\Support\\Facades\\Queue;

[
    'pending' => Queue::size('default'),
    'failed' => DB::table('failed_jobs')->count(),
    'oldest' => DB::table('jobs')->min('created_at'),
];
"""),
    ("Server check", ref("ssh", staging_id), """// Runs with the server's own PHP, in the app's folder.
// Nothing is uploaded: the runner streams over stdin.
[
    'php' => PHP_VERSION,
    'os' => PHP_OS_FAMILY,
    'release' => realpath('.'),
    'memory_limit' => ini_get('memory_limit'),
    'extensions' => count(get_loaded_extensions()),
];
"""),
    ("Unshipped orders", ref("ssh", prod_id), """use App\\Models\\Order;

// Production asks before every run.
Order::where('status', 'paid')
    ->whereNull('shipped_at')
    ->count();
"""),
]

tabs = []
for index, (title, target, code, *language) in enumerate(TABS):
    tabs.append({
        "id": str(uuid.uuid4()).upper(), "title": title, "code": code, "target": target,
        "selection": {"location": len(code), "length": 0}, "createdAt": now - 600 + index,
        **({"language": language[0]} if language else {}),
    })
write("session", {"windows": [{"id": str(uuid.uuid4()).upper(), "tabs": tabs, "selectedTabId": tabs[0]["id"], "workspaceEdited": False}]})

snippets = [
    ("Find a customer by email", "use App\\Models\\User;\n\nUser::firstWhere('email', 'ada@example.com')?->load('orders');\n", None),
    ("Failed jobs, newest first", "DB::table('failed_jobs')->latest('failed_at')->take(10)->get(['uuid', 'queue', 'failed_at']);\n", None),
    ("Clear every cache", "Artisan::call('optimize:clear');\n\nArtisan::output();\n", None),
    ("Low stock products", "use App\\Models\\Product;\n\nProduct::where('stock', '<', 20)->orderBy('stock')->get(['sku', 'name', 'stock']);\n", ref("local", local_id)),
]
write("snippets", [{
    "id": str(uuid.uuid4()).upper(), "label": label, "code": code, "createdAt": now - 3600 * (i + 1),
    "updatedAt": now - 3600 * (i + 1), **({"target": target, "targetLabel": "acme-shop"} if target else {}),
} for i, (label, code, target) in enumerate(snippets)])

print(f"seeded {data}")
