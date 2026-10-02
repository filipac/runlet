#!/usr/bin/env bash
# Prepares disposable integration-test fixtures. Never touches user projects.
#   scripts/setup-fixtures.sh          # Composer autoloaders + Laravel fixture app
#   scripts/setup-fixtures.sh docker   # also starts the Docker fixture containers
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/Tests/Fixtures"

composer dump-autoload --working-dir="$FIX/composer" --quiet

# Laravel fixture app: a copy of the pinned sandbox template plus a model with fixture data.
APP="$FIX/laravel-app"
if [[ ! -f "$APP/artisan" ]]; then
    rm -rf "$APP"
    cp -R "$ROOT/Resources/Sandbox/laravel" "$APP"
    cp "$APP/.env.example" "$APP/.env"
    sed -i '' 's/^APP_NAME=.*/APP_NAME="Runlet Fixture"/' "$APP/.env"
    sed -i '' 's/^SESSION_DRIVER=.*/SESSION_DRIVER=array/; s/^CACHE_STORE=.*/CACHE_STORE=array/; s/^QUEUE_CONNECTION=.*/QUEUE_CONNECTION=sync/' "$APP/.env"
    rm -f "$APP/database/database.sqlite" "$APP/runlet-sandbox.json"
    mkdir -p "$APP/app/Services"
    cat > "$APP/app/Models/Widget.php" <<'PHP'
<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class Widget extends Model
{
    protected $fillable = ['name', 'price'];

    protected function casts(): array
    {
        return ['price' => 'integer'];
    }

    public function scopeExpensive($query)
    {
        return $query->where('price', '>', 100);
    }
}
PHP
    cat > "$APP/app/Services/PriceFormatter.php" <<'PHP'
<?php

namespace App\Services;

class PriceFormatter
{
    public function format(int $cents): string
    {
        return '$' . number_format($cents / 100, 2);
    }
}
PHP
    cat > "$APP/database/migrations/2026_01_01_000000_create_widgets_table.php" <<'PHP'
<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void
    {
        Schema::create('widgets', function (Blueprint $table) {
            $table->id();
            $table->string('name');
            $table->integer('price');
            $table->timestamps();
        });
    }
};
PHP
    cat > "$APP/database/seeders/DatabaseSeeder.php" <<'PHP'
<?php

namespace Database\Seeders;

use App\Models\Widget;
use Illuminate\Database\Seeder;

class DatabaseSeeder extends Seeder
{
    public function run(): void
    {
        Widget::create(['name' => 'Sprocket', 'price' => 250]);
        Widget::create(['name' => 'Gear', 'price' => 90]);
        Widget::create(['name' => 'Flywheel', 'price' => 1200]);
    }
}
PHP
    touch "$APP/database/database.sqlite"
    (cd "$APP" && php artisan migrate --seed --force --quiet)
fi

if [[ "${1:-}" == "docker" ]]; then
    docker compose -f "$FIX/docker/compose.yml" up -d --quiet-pull
fi
echo "Fixtures ready."
