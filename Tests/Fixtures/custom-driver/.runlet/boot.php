<?php

// Boots the application like its container entry point does. Paths are relative to this
// folder (not an absolute container path such as /var/www), so the same driver works
// locally and inside Docker.
define('BASE_PATH', dirname(__DIR__));
putenv('APP_NAME=Acme Lease API');

$app = require BASE_PATH . '/config/bootstrap.php';
