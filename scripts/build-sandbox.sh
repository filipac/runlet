#!/usr/bin/env bash
# Installs the pinned Laravel sandbox dependencies (from composer.lock) and builds its
# pre-migrated SQLite database. Run on the build machine; end users never need Composer.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$ROOT/Resources/Sandbox/laravel"

composer install --working-dir="$SANDBOX" --no-interaction --prefer-dist --no-progress --quiet
rm -f "$SANDBOX/database/database.sqlite"
touch "$SANDBOX/database/database.sqlite"
# A throwaway key just for the build-time migration; the installed sandbox gets its own .env.
(cd "$SANDBOX" && APP_KEY="base64:$(head -c 32 /dev/urandom | base64)" DB_CONNECTION=sqlite php artisan migrate --force --quiet)
rm -f "$SANDBOX"/storage/logs/*.log "$SANDBOX"/storage/framework/views/*.php
echo "Sandbox ready: Laravel $(cd "$SANDBOX" && php artisan --version | awk '{print $3}')"
