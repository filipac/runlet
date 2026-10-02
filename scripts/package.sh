#!/usr/bin/env bash
# Builds an installable universal (arm64 + x86_64) Runlet.app into dist/, with a zip and a
# DMG, then verifies signature, architectures, bundled resources, and runs the packaged
# app's headless self-test.
#
# Signing: ad-hoc by default (local/test installs). For distribution set
#   RUNLET_SIGN_IDENTITY="Developer ID Application: …"  (and optionally RUNLET_NOTARY_PROFILE
#   for `xcrun notarytool submit --keychain-profile`).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
IDENTITY="${RUNLET_SIGN_IDENTITY:--}"
DD="$ROOT/build/Release-DerivedData"
DIST="$ROOT/dist"

[[ -f Resources/Sandbox/laravel/vendor/autoload.php ]] || scripts/build-sandbox.sh
scripts/fetch-phpantom.sh
xcodegen generate >/dev/null

xcodebuild -project Runlet.xcodeproj -scheme Runlet -configuration Release \
    -derivedDataPath "$DD" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="$IDENTITY" OTHER_CODE_SIGN_FLAGS="--timestamp=none" build | tail -3

rm -rf "$DIST" && mkdir -p "$DIST"
ditto "$DD/Build/Products/Release/Runlet.app" "$DIST/Runlet.app"
APP="$DIST/Runlet.app"

echo "== Verifying package"
codesign --verify --deep --strict "$APP"
lipo -info "$APP/Contents/MacOS/Runlet"
lipo -info "$APP/Contents/Helpers/phpantom_lsp"
for path in Contents/Resources/Runner/runlet-runner.php Contents/Resources/Sandbox/laravel/runlet-sandbox.json \
            Contents/Resources/Sandbox/laravel/vendor/autoload.php Contents/Resources/Licenses/PHPantom-LICENSE.txt; do
    [[ -e "$APP/$path" ]] || { echo "missing $path" >&2; exit 1; }
done
[[ ! -e "$APP/Contents/Resources/Sandbox/laravel/.env" ]] || { echo "sandbox .env must not be bundled" >&2; exit 1; }
du -sh "$APP"

echo "== Packaged self-test"
SELFTEST_DIR="$(mktemp -d)"
RUNLET_DATA_DIR="$SELFTEST_DIR" "$APP/Contents/MacOS/Runlet" --self-test ${RUNLET_SELFTEST_DOCKER:+--docker} | tee "$DIST/self-test.json"
rm -rf "$SELFTEST_DIR"

(cd "$DIST" && ditto -c -k --keepParent Runlet.app Runlet.zip)
hdiutil create -quiet -volname Runlet -srcfolder "$APP" -ov -format UDZO "$DIST/Runlet.dmg"

if [[ "$IDENTITY" != "-" && -n "${RUNLET_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DIST/Runlet.dmg" --keychain-profile "$RUNLET_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DIST/Runlet.dmg"
fi
ls -lh "$DIST"
echo "Packaged: $APP"
