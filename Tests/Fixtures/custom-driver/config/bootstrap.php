<?php

// The application's own bootstrap. It loads Composer itself (with a plain `require`), so it
// runs again even though Runlet already loaded vendor/autoload.php before the driver.
use Acme\App;
use Acme\DI;

require BASE_PATH . '/vendor/autoload.php';

$app = new App(getenv('APP_NAME') ?: 'Acme API');
$app->get('/health', function () {
    return ['status' => 'ok'];
});
DI::set(App::class, $app);

return $app;
