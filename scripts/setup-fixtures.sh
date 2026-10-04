#!/usr/bin/env bash
# Prepares disposable integration-test fixtures. Never touches user projects.
#   scripts/setup-fixtures.sh          # Composer autoloaders + Laravel, WordPress, Symfony fixtures
#   scripts/setup-fixtures.sh docker   # also starts the Docker fixture containers
#   scripts/setup-fixtures.sh databases  # also starts MariaDB, PostgreSQL, Redis, and MongoDB (plain, TLS, replica set) for live database tests
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

# Project-driver fixture (.runlet/AcmeApiDriver.php); only its autoloader is generated.
composer dump-autoload --working-dir="$FIX/custom-driver" --quiet

# Run inspector fixtures: a Slim-style app with Eloquent through Capsule (no Laravel) and a
# Doctrine DBAL connection, booted by .runlet/ShopDriver.php. eloquent-app pins packages that
# run on PHP 7.4 (illuminate 8 with illuminate/events, DBAL 3); eloquent-app-modern uses
# current ones without illuminate/events (query-log fallback, DBAL 4). Needs the network the
# first time; when an install fails, that fixture's tests skip.
for app in eloquent-app eloquent-app-modern; do
    if [[ ! -f "$FIX/$app/vendor/autoload.php" ]]; then
        composer install --working-dir="$FIX/$app" --no-interaction --quiet \
            || echo "$app fixture skipped (composer install failed); its tests will skip." >&2
    fi
done

# WordPress fixture: latest WordPress on SQLite (the official SQLite Database Integration
# drop-in, so no MySQL), installed non-interactively with WP-CLI. Needs the network; when a
# step fails the fixture is removed and the WordPress tests skip.
WP_DIR="$FIX/wordpress"
setup_wordpress() {
    local tmp
    tmp="$(mktemp -d)" || return 1
    curl -fsSL https://wordpress.org/latest.tar.gz -o "$tmp/wordpress.tar.gz" || return 1
    curl -fsSL https://downloads.wordpress.org/plugin/sqlite-database-integration.latest-stable.zip -o "$tmp/sqlite.zip" || return 1
    curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o "$tmp/wp-cli.phar" || return 1
    rm -rf "$WP_DIR"
    tar -xzf "$tmp/wordpress.tar.gz" -C "$tmp" || return 1
    mv "$tmp/wordpress" "$WP_DIR" || return 1
    unzip -q "$tmp/sqlite.zip" -d "$WP_DIR/wp-content/plugins" || return 1
    sed 's#{SQLITE_PLUGIN}#sqlite-database-integration/load.php#g' \
        "$WP_DIR/wp-content/plugins/sqlite-database-integration/db.copy" > "$WP_DIR/wp-content/db.php" || return 1
    local wp=(php "$tmp/wp-cli.phar" --path="$WP_DIR" --quiet)
    # DB_* values are unused placeholders: the SQLite drop-in stores wp-content/database/.ht.sqlite.
    "${wp[@]}" config create --dbname=wordpress --dbuser=runlet --dbpass=runlet --dbprefix=rl_ --skip-check || return 1
    "${wp[@]}" core install --url=http://localhost --title='Runlet WordPress Fixture' --admin_user=runlet \
        --admin_password="$(openssl rand -hex 16)" --admin_email=runlet@example.test --skip-email || return 1
    "${wp[@]}" post create --post_status=publish --post_title='Hello from Runlet' --post_content='Fixture post.' || return 1
    touch "$WP_DIR/.runlet-fixture-ready"
    rm -rf "$tmp"
}
if [[ ! -f "$WP_DIR/.runlet-fixture-ready" ]]; then
    if ! setup_wordpress; then
        rm -rf "$WP_DIR"
        echo "WordPress fixture skipped (download or install failed); WordPress tests will skip." >&2
    fi
fi

# Symfony fixture: the current symfony/skeleton. --no-scripts skips only the cache:clear
# auto-script (Flex recipes still apply); Runlet's driver builds the cache on first boot.
SF_DIR="$FIX/symfony-app"
if [[ ! -f "$SF_DIR/vendor/autoload.php" ]]; then
    rm -rf "$SF_DIR"
    if ! composer create-project symfony/skeleton "$SF_DIR" --no-interaction --no-scripts --quiet; then
        rm -rf "$SF_DIR"
        echo "Symfony fixture skipped (composer create-project failed); Symfony tests will skip." >&2
    fi
fi

if [[ "${1:-}" == "docker" ]]; then
    docker compose -f "$FIX/docker/compose.yml" up -d --quiet-pull
fi
if [[ "${1:-}" == "databases" ]]; then
    # MariaDB and PostgreSQL for the live SQL tests (SQLLiveDatabaseTests and the other live suites).
    # Prints the variables those tests read; stop with: docker compose -p runlet-fixtures --profile databases down
    # Running containers are reused, from any worktree. COMPOSE_PROJECT_NAME starts an isolated
    # copy under another project name instead.
    #
    # TLS (#140): a throwaway test CA, a server certificate for localhost / 127.0.0.1, a client
    # certificate, and a second CA that signed nothing (for verification failures), generated
    # once. Both servers offer TLS; neither requires it, so plain connections keep working.
    # The files live in one folder that every worktree of this repository shares (#176):
    # runlet-fixtures/tls in Git's common directory (the main checkout's .git), outside any
    # working tree. compose.yml mounts $RUNLET_FIXTURE_TLS, so a run from another worktree mounts
    # the same folder and leaves the containers alone. Set RUNLET_FIXTURE_TLS to use another
    # folder; outside a Git checkout it is the gitignored Tests/Fixtures/docker/tls. To make new
    # certificates: docker compose -p runlet-fixtures --profile databases down, delete the
    # folder (the printed RUNLET_TEST_TLS), and run this again.
    if [[ -z "${RUNLET_FIXTURE_TLS:-}" ]]; then
        if COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
            RUNLET_FIXTURE_TLS="$COMMON/runlet-fixtures/tls"
        else
            RUNLET_FIXTURE_TLS="$FIX/docker/tls"
        fi
    fi
    [[ "$RUNLET_FIXTURE_TLS" == /* ]] || RUNLET_FIXTURE_TLS="$PWD/$RUNLET_FIXTURE_TLS"
    export RUNLET_FIXTURE_TLS
    TLS="$RUNLET_FIXTURE_TLS"
    # Before #176 each worktree generated its own copy in Tests/Fixtures/docker/tls. The first
    # run takes this worktree's copy, so clients keep trusting the CA they already have.
    LEGACY_TLS="$FIX/docker/tls"
    if [[ ! -f "$TLS/client.key" && -f "$LEGACY_TLS/client.key" && ! "$TLS" -ef "$LEGACY_TLS" ]]; then
        mkdir -p "$TLS"
        cp -p "$LEGACY_TLS"/* "$TLS"/
    fi
    if [[ ! -f "$TLS/client.key" ]]; then
        mkdir -p "$TLS"
        (
            cd "$TLS"
            openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Runlet fixture CA" -keyout ca.key -out ca.crt 2>/dev/null
            openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Runlet other CA" -keyout other-ca.key -out other-ca.crt 2>/dev/null
            printf 'subjectAltName=DNS:localhost,IP:127.0.0.1,DNS:mariadb,DNS:postgres\nextendedKeyUsage=serverAuth\n' > server.ext
            openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" -keyout server.key -out server.csr 2>/dev/null
            openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 3650 -extfile server.ext -out server.crt 2>/dev/null
            printf 'extendedKeyUsage=clientAuth\n' > client.ext
            openssl req -newkey rsa:2048 -nodes -subj "/CN=runlet-fixture-client" -keyout client.key -out client.csr 2>/dev/null
            openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 3650 -extfile client.ext -out client.crt 2>/dev/null
            rm -f ./*.csr ./*.ext ./*.srl other-ca.key
            # The servers read their key as their own user from the read-only mount (PostgreSQL
            # copies it first); libpq and mysqlnd on this Mac read the client key, which libpq
            # wants private.
            chmod 644 server.key
            chmod 600 client.key ca.key
        )
    fi
    COMPOSE=(docker compose -f "$FIX/docker/compose.yml" --profile databases)
    # Redis (#190): redis:7-alpine, no other image.
    "${COMPOSE[@]}" up -d --quiet-pull mariadb postgres redis mongo mongo-tls mongo-rs
    for _ in $(seq 1 60); do
        if "${COMPOSE[@]}" exec -T mariadb mariadb-admin ping -uroot -prunlet-fixture --silent >/dev/null 2>&1 \
            && "${COMPOSE[@]}" exec -T postgres pg_isready -U postgres -d shop >/dev/null 2>&1 \
            && "${COMPOSE[@]}" exec -T redis redis-cli --user default --pass runlet-fixture --no-auth-warning ping >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    MARIADB_PORT="$("${COMPOSE[@]}" port mariadb 3306 | sed 's/.*://')"
    POSTGRES_PORT="$("${COMPOSE[@]}" port postgres 5432 | sed 's/.*://')"
    REDIS_PORT="$("${COMPOSE[@]}" port redis 6379 | sed 's/.*://')"
    REDIS_TLS_PORT="$("${COMPOSE[@]}" port redis 6380 | sed 's/.*://')"
    echo "export RUNLET_TEST_MYSQL='mysql:host=127.0.0.1;port=$MARIADB_PORT;dbname=shop|root|runlet-fixture'"
    echo "export RUNLET_TEST_PGSQL='pgsql:host=127.0.0.1;port=$POSTGRES_PORT;dbname=shop|postgres|runlet-fixture'"
    echo "export RUNLET_TEST_REDIS='redis://:runlet-fixture@127.0.0.1:$REDIS_PORT/0'"
    echo "export RUNLET_TEST_REDIS_TLS='rediss://:runlet-fixture@127.0.0.1:$REDIS_TLS_PORT/0'"
    MONGO_PORT="$("${COMPOSE[@]}" port mongo 27017 | awk -F: '{print $NF}')"
    echo "export RUNLET_TEST_MONGODB='mongodb://127.0.0.1:$MONGO_PORT|runlet|runlet-fixture'"
    # #207: MongoDB with TLS required (X.509 for the fixture's client certificate), and the
    # single-node replica set rs0, which is initiated once (its member is 127.0.0.1:27207).
    MONGO_TLS_PORT="$("${COMPOSE[@]}" port mongo-tls 27017 | awk -F: '{print $NF}')"
    for _ in $(seq 1 60); do
        if "${COMPOSE[@]}" exec -T mongo-rs mongosh --quiet --port 27207 --eval 'db.runCommand({ping: 1}).ok' >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    "${COMPOSE[@]}" exec -T mongo-rs mongosh --quiet --port 27207 --eval 'try { rs.status().ok } catch (e) { rs.initiate({_id: "rs0", members: [{_id: 0, host: "127.0.0.1:27207"}]}).ok }' >/dev/null 2>&1 || true
    echo "export RUNLET_TEST_MONGODB_TLS='mongodb://127.0.0.1:$MONGO_TLS_PORT|runlet|runlet-fixture'"
    echo "export RUNLET_TEST_MONGODB_RS='mongodb://127.0.0.1:27207/?replicaSet=rs0'"
    echo "export RUNLET_TEST_TLS='$TLS'"
fi
echo "Fixtures ready."
