<?php

// Boots the app the way its front controller does: a service container with Eloquent set
// up through Capsule (no Laravel) and a Doctrine DBAL connection for reports. Both use
// in-memory SQLite, seeded on every boot, so each run starts from the same data.

use Doctrine\DBAL\DriverManager;
use Illuminate\Database\Capsule\Manager as Capsule;
use Shop\Container;
use Shop\Models\Customer;

$container = new Container();

$capsule = new Capsule();
$capsule->addConnection(['driver' => 'sqlite', 'database' => ':memory:', 'prefix' => '']);
if (getenv('SHOP_EVENTS') === '1' && class_exists(\Illuminate\Events\Dispatcher::class)) {
    // Some apps give Capsule an event dispatcher for model events.
    $capsule->setEventDispatcher(new \Illuminate\Events\Dispatcher(new \Illuminate\Container\Container()));
}
$capsule->setAsGlobal();
$capsule->bootEloquent();

$schema = $capsule->getConnection()->getSchemaBuilder();
$schema->create('customers', function ($table) {
    $table->increments('id');
    $table->string('name');
});
$schema->create('orders', function ($table) {
    $table->increments('id');
    $table->integer('customer_id');
    $table->integer('total');
});
foreach (['Ada', 'Grace', 'Linus'] as $index => $name) {
    $customer = Customer::create(['name' => $name]);
    $customer->orders()->create(['total' => 100 * ($index + 1)]);
    $customer->orders()->create(['total' => 50]);
}
$container->set('db', function () use ($capsule) {
    return $capsule;
});

$container->set('reports', function () {
    $connection = DriverManager::getConnection(['driver' => 'pdo_sqlite', 'memory' => true]);
    $connection->executeStatement('CREATE TABLE reports (id INTEGER PRIMARY KEY, name TEXT NOT NULL)');
    $connection->executeStatement("INSERT INTO reports (name) VALUES ('daily'), ('weekly')");

    return $connection;
});

return $container;
