#!/bin/sh
# Regenerates the website's screenshots (website/assets/shots/*.webp, light and dark) and its Open
# Graph image from a Debug build of Runlet with demo content.
#
#   scripts/website-screenshots/shoot.sh [steps file]     (default: steps.txt next to this script)
#
# It touches only:
# - build/website-shots/: the build, the demo Laravel project (a copy of the bundled sandbox plus
#   demo/), a scratch RUNLET_DATA_DIR, a throwaway SSH key and config, and the raw PNGs;
# - ~/Sites/acme-shop: a symlink to the demo project while the app runs, so its path reads
#   ~/Sites/acme-shop; removed at the end (with ~/Sites, if this script created it);
# - the disposable runlet-fixtures `ssh` service (127.0.0.1:2222): the throwaway key goes into
#   /home/runlet/.ssh/authorized_keys2, which the SSH tests (they rewrite authorized_keys) leave alone;
# - the disposable runlet-fixtures `mongo` service (scripts/setup-fixtures.sh databases): its
#   `shop_demo` database, which seed-databases.sh seeds for the MongoDB shot and drops at the end.
# It never reads ~/.ssh, never lists or execs into your containers (Runlet gets a fake docker CLI),
# and never opens your Runlet data. The app is built with its own bundle identifier, launched
# hidden and in the background, and its first step (`ghost`) keeps its windows invisible and
# click-through with no Dock icon, so nothing appears on screen and the keyboard stays yours.
# The steps are DEBUG-only (Runlet/App/DebugSteps.swift); the app quits after the last one.
#
# Needs Xcode, PHP 8.3+, Docker, cwebp, the runlet-fixtures `mongo` container running, and
# scripts/build-sandbox.sh and scripts/fetch-phpantom.sh to have run.
set -e
TOOLS="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TOOLS/../.." && pwd)"
WORK="$ROOT/build/website-shots"
STEPS="${1:-$TOOLS/steps.txt}"
SITE="$ROOT/website"
DEMO="$WORK/acme-shop"
SITES_LINK="$HOME/Sites/acme-shop"
mkdir -p "$WORK"

[ -f "$ROOT/Resources/Sandbox/laravel/vendor/autoload.php" ] || { echo "Run scripts/build-sandbox.sh first." >&2; exit 1; }
command -v cwebp >/dev/null || { echo "cwebp is missing (brew install webp)." >&2; exit 1; }

echo "== Building Runlet (Debug, bundle id dev.runlet.Runlet.websiteshots)"
xcodebuild -quiet -project "$ROOT/Runlet.xcodeproj" -scheme Runlet -configuration Debug \
  -derivedDataPath "$WORK/DerivedData" PRODUCT_BUNDLE_IDENTIFIER=dev.runlet.Runlet.websiteshots build
APP="$WORK/DerivedData/Build/Products/Debug/Runlet.app"

echo "== Demo project"
rm -rf "$DEMO"
cp -cR "$ROOT/Resources/Sandbox/laravel" "$DEMO" 2>/dev/null || cp -R "$ROOT/Resources/Sandbox/laravel" "$DEMO"
rm -f "$DEMO/runlet-sandbox.json" "$DEMO/AGENTS.md" "$DEMO/CLAUDE.md" "$DEMO/.env" "$DEMO/database/database.sqlite" \
  "$DEMO/tests/Unit/ExampleTest.php" "$DEMO/tests/Feature/ExampleTest.php" "$DEMO"/bootstrap/cache/*.php
cp -R "$TOOLS/demo/." "$DEMO/"
sed -e 's/^APP_NAME=.*/APP_NAME="Acme Shop"/' -e 's#^APP_URL=.*#APP_URL=https://shop.example.com#' \
  -e 's/^MAIL_MAILER=.*/MAIL_MAILER=log/' -e 's/^MAIL_FROM_ADDRESS=.*/MAIL_FROM_ADDRESS="orders@shop.example.com"/' \
  -e 's/^CACHE_STORE=.*/CACHE_STORE=file/' "$DEMO/.env.example" > "$DEMO/.env"
(cd "$DEMO" && php <<'PHP'
<?php
$composer = json_decode(file_get_contents('composer.json'), true);
$composer['name'] = 'acme/shop';
$composer['description'] = "Acme's online shop.";
$composer['scripts']['lint'] = 'pint --test';
$composer['scripts']['format'] = 'pint';
file_put_contents('composer.json', json_encode($composer, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
PHP
)
touch "$DEMO/database/database.sqlite"
(cd "$DEMO" && php artisan key:generate --force --quiet && php artisan migrate:fresh --seed --force --quiet)

echo "== SSH fixture"
CONTAINER="$(docker compose -p runlet-fixtures ps -q ssh 2>/dev/null || true)"
if [ -z "$CONTAINER" ]; then
  docker compose -p runlet-fixtures -f "$ROOT/Tests/Fixtures/docker/compose.yml" up -d ssh
  CONTAINER="$(docker compose -p runlet-fixtures ps -q ssh)"
fi
SSH_DIR="$WORK/ssh"
mkdir -p "$SSH_DIR"
[ -f "$SSH_DIR/id_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -C runlet-website-shots -f "$SSH_DIR/id_ed25519"
docker exec -i "$CONTAINER" sh -c 'cat > /home/runlet/.ssh/authorized_keys2 && chown runlet:runlet /home/runlet/.ssh/authorized_keys2 && chmod 600 /home/runlet/.ssh/authorized_keys2' < "$SSH_DIR/id_ed25519.pub"
HOSTKEY=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  HOSTKEY="$(docker exec "$CONTAINER" cat /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | cut -d' ' -f1-2)" && [ -n "$HOSTKEY" ] && break
  sleep 1
done
echo "[127.0.0.1]:2222 $HOSTKEY" > "$SSH_DIR/known_hosts"
for HOST in app.example.com shop.example.com; do
  printf 'Host %s\n    HostName 127.0.0.1\n    Port 2222\n    User runlet\n    IdentityFile %s\n    IdentitiesOnly yes\n    IdentityAgent none\n    PasswordAuthentication no\n    UserKnownHostsFile %s\n    GlobalKnownHostsFile /dev/null\n\n' \
    "$HOST" "$SSH_DIR/id_ed25519" "$SSH_DIR/known_hosts"
done > "$SSH_DIR/config"
ssh -F "$SSH_DIR/config" -o BatchMode=yes -o LogLevel=ERROR app.example.com true

echo "== MongoDB fixture (shop_demo)"
MONGO_PORT="$(sh "$TOOLS/seed-databases.sh" seed)"

echo "== Shooting (the app runs hidden; about five minutes)"
CREATED_SITES=""
[ -d "$HOME/Sites" ] || { mkdir "$HOME/Sites"; CREATED_SITES=1; }
[ ! -e "$SITES_LINK" ] || [ -L "$SITES_LINK" ] || { echo "$SITES_LINK exists and isn't a symlink; not touching it." >&2; exit 1; }
ln -sfn "$DEMO" "$SITES_LINK"
cleanup() {
  rm -f "$SITES_LINK"
  if [ -n "$CREATED_SITES" ]; then rmdir "$HOME/Sites" 2>/dev/null || true; fi
  sh "$TOOLS/seed-databases.sh" clean || true
}
trap cleanup EXIT

DATA="$WORK/data-$(date +%s)"
OUT="$WORK/out"
rm -rf "$OUT"
mkdir -p "$OUT"
python3 "$TOOLS/seed.py" "$DATA" "$TOOLS/fake-docker" "$SITES_LINK"
STEP_LIST="$(grep -v '^[[:space:]]*#' "$STEPS" | grep -v '^[[:space:]]*$' | sed "s/{mongo-port}/$MONGO_PORT/g" | paste -sd, -)"
open -g -j -n -W \
  --env RUNLET_DATA_DIR="$DATA" \
  --env RUNLET_SNAPSHOT_DIR="$OUT" \
  --env RUNLET_DEBUG_STEPS="$STEP_LIST" \
  --env RUNLET_SSH_CONFIG="$SSH_DIR/config" \
  --env ZDOTDIR="$TOOLS/zdotdir" \
  --env PATH="$PATH" \
  --env SSH_AUTH_SOCK= \
  --stderr "$OUT/stderr.log" \
  "$APP"
grep -q "RUNLET_DEBUG_STEPS: done" "$OUT/stderr.log" || { echo "The app quit early; see $OUT/stderr.log" >&2; exit 1; }

echo "== Converting"
mkdir -p "$SITE/assets/shots"
for f in "$OUT"/*.png; do
  name="$(basename "$f" .png)"
  cwebp -quiet -q 80 -m 6 -sharp_yuv -resize 2400 0 "$f" -o "$SITE/assets/shots/$name-2400.webp"
  cwebp -quiet -q 82 -m 6 -sharp_yuv -resize 1200 0 "$f" -o "$SITE/assets/shots/$name-1200.webp"
done
swiftc -O -o "$WORK/brand" "$TOOLS/brand.swift" 2>/dev/null
"$WORK/brand" "$SITE" "$OUT/hero-light.png"
echo "Done. Check every image in $OUT before committing: no real names, paths, hosts, or containers."
