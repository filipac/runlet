#!/usr/bin/env bash
# Xcode build phase: copies the PHP runner, the pinned Laravel sandbox, the PHPantom and Mago
# binaries, and third-party license notices into the app bundle, then signs the helpers with the
# app's identity.
set -euo pipefail
ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
RES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
HELPERS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"

mkdir -p "$RES/Runner" "$RES/Sandbox" "$RES/Licenses" "$HELPERS"
cp "$ROOT/Resources/Runner/dist/runlet-runner.php" "$RES/Runner/runlet-runner.php"

if [[ ! -f "$ROOT/Resources/Sandbox/laravel/vendor/autoload.php" ]]; then
    echo "error: Sandbox dependencies missing. Run scripts/build-sandbox.sh" >&2
    exit 1
fi
rsync -a --delete \
    --exclude '.env' --exclude 'node_modules' --exclude '.git' --exclude 'tests' \
    --exclude 'storage/logs/*.log' --exclude 'storage/framework/views/*.php' \
    --exclude 'storage/framework/sessions/*' --exclude 'storage/framework/cache/data/*' \
    --exclude 'bootstrap/cache/*.php' \
    "$ROOT/Resources/Sandbox/laravel/" "$RES/Sandbox/laravel/"
# Package discovery caches are regenerated in the user's writable copy on first run.

if [[ ! -x "$ROOT/Resources/LSP/phpantom_lsp" ]]; then
    "$ROOT/scripts/fetch-phpantom.sh"
fi
cp "$ROOT/Resources/LSP/phpantom_lsp" "$HELPERS/phpantom_lsp"
chmod 755 "$HELPERS/phpantom_lsp"

# Format Code (#36): the Mago formatter, run on the snippet's text (never on files).
if [[ ! -x "$ROOT/Resources/Formatter/mago" ]]; then
    "$ROOT/scripts/fetch-mago.sh"
fi
cp "$ROOT/Resources/Formatter/mago" "$HELPERS/mago"
chmod 755 "$HELPERS/mago"

cp "$ROOT/Resources/LSP/LICENSE-phpantom.txt" "$RES/Licenses/PHPantom-LICENSE.txt"
cp "$ROOT/Resources/Formatter/LICENSE-mago.txt" "$RES/Licenses/Mago-LICENSE.txt"
cp "$ROOT/Resources/Runner/LICENSE-php-parser.txt" "$RES/Licenses/PHP-Parser-LICENSE.txt"
cp "$ROOT/Resources/Licenses/LICENSE-SwiftTerm.txt" "$RES/Licenses/SwiftTerm-LICENSE.txt"
cp "$ROOT/Resources/Licenses/LICENSE-Sparkle.txt" "$RES/Licenses/Sparkle-LICENSE.txt"
cp "$ROOT/Resources/Sandbox/laravel/vendor/laravel/framework/LICENSE.md" "$RES/Licenses/Laravel-LICENSE.md" 2>/dev/null || true

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]]; then
    codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$HELPERS/phpantom_lsp"
    codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$HELPERS/mago"
fi
