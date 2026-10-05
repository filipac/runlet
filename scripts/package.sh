#!/usr/bin/env bash
# Builds an installable universal (arm64 + x86_64) Runlet.app into dist/, with a zip and a
# DMG, then verifies signature, architectures, bundled resources, and runs the packaged
# app's headless self-test.
#
# Releasing (version, update signature, appcast, GitHub release): docs/releasing.md. The app's
# in-app updates (#233) need the owner's RUNLET_UPDATE_PUBLIC_KEY in project.yml; the self-test
# says "update key set" when the build has it.
#
# Signing: ad-hoc by default (local/test installs). For distribution set
#   RUNLET_SIGN_IDENTITY="Developer ID Application: …"  (and optionally RUNLET_NOTARY_PROFILE
#   for `xcrun notarytool submit --keychain-profile`).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
IDENTITY="${RUNLET_SIGN_IDENTITY:--}"
DD="$ROOT/build/Release-DerivedData"
# RUNLET_DIST_DIR puts the output elsewhere (a scratch folder for test packaging).
DIST="${RUNLET_DIST_DIR:-$ROOT/dist}"

[[ -f Resources/Sandbox/laravel/vendor/autoload.php ]] || scripts/build-sandbox.sh
scripts/fetch-phpantom.sh
scripts/fetch-mago.sh
xcodegen generate >/dev/null

xcodebuild -project Runlet.xcodeproj -scheme Runlet -configuration Release \
    -derivedDataPath "$DD" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="$IDENTITY" OTHER_CODE_SIGN_FLAGS="--timestamp=none" build | tail -3

rm -rf "$DIST" && mkdir -p "$DIST"
ditto "$DD/Build/Products/Release/Runlet.app" "$DIST/Runlet.app"
APP="$DIST/Runlet.app"

# Stable releases strip local symbols from the app's executables (#253): about 70 MB of the
# app. Betas keep them, so testers' crash logs stay readable. RUNLET_STRIP=1|0 overrides. Mago
# ships stripped already. The dSYM Xcode made for the build goes next to the archives (it isn't
# uploaded). Stripping changes the files, so each is signed again with its own options, then the
# app is sealed again; the checks and the self-test below run on the stripped app.
PRERELEASE="$(/usr/libexec/PlistBuddy -c 'Print RunletPrerelease' "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ -n "${RUNLET_STRIP:-}" ]]; then
    STRIP="$RUNLET_STRIP"
elif [[ -z "$PRERELEASE" ]]; then
    STRIP=1
else
    STRIP=0
fi
if [[ "$STRIP" == 1 ]]; then
    echo "== Stripping symbols"
    if [[ -d "$DD/Build/Products/Release/Runlet.app.dSYM" ]]; then
        ditto "$DD/Build/Products/Release/Runlet.app.dSYM" "$DIST/Runlet.app.dSYM"
    fi
    BEFORE_KB="$(du -sk "$APP" | cut -f1)"
    for path in Contents/Helpers/runlet Contents/Helpers/phpantom_lsp; do
        strip -x "$APP/$path"
        codesign --force --sign "$IDENTITY" --timestamp=none \
            --preserve-metadata=identifier,entitlements,requirements,flags,runtime "$APP/$path"
    done
    strip -x "$APP/Contents/MacOS/Runlet"
    codesign --force --sign "$IDENTITY" --timestamp=none \
        --preserve-metadata=identifier,entitlements,requirements,flags,runtime "$APP"
    echo "Stripped: $(( (BEFORE_KB - $(du -sk "$APP" | cut -f1)) / 1024 )) MB smaller, $(du -sh "$APP" | cut -f1)"
else
    echo "== Keeping symbols (${PRERELEASE:+pre-release $PRERELEASE}${RUNLET_STRIP:+RUNLET_STRIP=$RUNLET_STRIP})"
fi

echo "== Verifying package"
codesign --verify --deep --strict "$APP"
lipo -info "$APP/Contents/MacOS/Runlet"
lipo -info "$APP/Contents/Helpers/phpantom_lsp"
lipo -info "$APP/Contents/Helpers/mago"
for arch in arm64 x86_64; do
    lipo "$APP/Contents/Helpers/mago" -verify_arch "$arch" || { echo "mago lacks $arch" >&2; exit 1; }
done
"$APP/Contents/Helpers/mago" --version
lipo -info "$APP/Contents/Helpers/runlet"
# In-app updates (#233): Sparkle and its installer, universal and signed with the app.
for path in Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate; do
    for arch in arm64 x86_64; do
        lipo "$APP/$path" -verify_arch "$arch" || { echo "$path lacks $arch" >&2; exit 1; }
    done
done
codesign --verify --strict "$APP/Contents/Frameworks/Sparkle.framework"
# Ad-hoc signatures have no Team ID: without this entitlement the hardened runtime refuses to load
# Sparkle and the app crashes at launch (see project.yml). Developer ID builds don't need it.
if [[ "$IDENTITY" == "-" ]] && ! codesign -d --entitlements - "$APP" 2>/dev/null | grep -q disable-library-validation; then
    echo "ad-hoc build without com.apple.security.cs.disable-library-validation: Sparkle wouldn't load" >&2
    exit 1
fi
"$APP/Contents/Helpers/runlet" --version
for path in Contents/Helpers/runlet Contents/Resources/Runner/runlet-runner.php Contents/Resources/Sandbox/laravel/runlet-sandbox.json \
            Contents/Resources/Sandbox/laravel/vendor/autoload.php Contents/Resources/Licenses/PHPantom-LICENSE.txt \
            Contents/Helpers/mago Contents/Resources/Licenses/Mago-LICENSE.txt \
            Contents/Resources/Licenses/SwiftTerm-LICENSE.txt Contents/Resources/Licenses/Sparkle-LICENSE.txt \
            Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate \
            Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater; do
    [[ -e "$APP/$path" ]] || { echo "missing $path" >&2; exit 1; }
done
[[ ! -e "$APP/Contents/Resources/Sandbox/laravel/.env" ]] || { echo "sandbox .env must not be bundled" >&2; exit 1; }
du -sh "$APP"

# What's New (#232): the release's important features need entries in Runlet/WhatsNew.json.
# Only a warning: the packaged self-test fails on a manifest that doesn't parse.
echo "== What's New"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
MANIFEST="$APP/Contents/Resources/WhatsNew.json"
WHATS_NEW_ENTRY=0
i=0
while RELEASE_VERSION="$(plutil -extract "releases.$i.version" raw -o - "$MANIFEST" 2>/dev/null)"; do
    RELEASE_BUILD="$(plutil -extract "releases.$i.build" raw -o - "$MANIFEST" 2>/dev/null || true)"
    [[ "$RELEASE_VERSION" == "$VERSION" && "$RELEASE_BUILD" == "$BUILD" ]] && WHATS_NEW_ENTRY=1
    i=$((i + 1))
done
if [[ "$WHATS_NEW_ENTRY" == 1 ]]; then
    echo "What's New has an entry for $VERSION ($BUILD)"
else
    echo "warning: What's New has no entry for $VERSION ($BUILD): add the release's important features to Runlet/WhatsNew.json (docs/whats-new.md)" >&2
fi

echo "== Packaged self-test"
SELFTEST_DIR="$(mktemp -d)"
RUNLET_DATA_DIR="$SELFTEST_DIR" "$APP/Contents/MacOS/Runlet" --self-test ${RUNLET_SELFTEST_DOCKER:+--docker} | tee "$DIST/self-test.json"
rm -rf "$SELFTEST_DIR"

(cd "$DIST" && ditto -c -k --keepParent Runlet.app Runlet.zip)
# The DMG shows Runlet.app next to an Applications shortcut, for drag-to-install (#158).
DMG_ROOT="$(mktemp -d)"
ditto "$APP" "$DMG_ROOT/Runlet.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -quiet -volname Runlet -srcfolder "$DMG_ROOT" -ov -format UDZO "$DIST/Runlet.dmg"
rm -rf "$DMG_ROOT"

echo "== Verifying DMG"
DMG_MOUNT="$(mktemp -d)"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$DMG_MOUNT" "$DIST/Runlet.dmg"
DMG_LINK="$(readlink "$DMG_MOUNT/Applications" || true)"
DMG_SIGNED=0
codesign --verify --deep --strict "$DMG_MOUNT/Runlet.app" && DMG_SIGNED=1
hdiutil detach -quiet "$DMG_MOUNT"
rmdir "$DMG_MOUNT"
if [[ "$DMG_LINK" != "/Applications" || "$DMG_SIGNED" != 1 ]]; then
    echo "The DMG is wrong: Applications -> '$DMG_LINK', Runlet.app signature valid: $DMG_SIGNED" >&2
    exit 1
fi
echo "Runlet.app (signature valid) and Applications -> /Applications"

if [[ "$IDENTITY" != "-" && -n "${RUNLET_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DIST/Runlet.dmg" --keychain-profile "$RUNLET_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DIST/Runlet.dmg"
fi
ls -lh "$DIST"
echo "Packaged: $APP"
