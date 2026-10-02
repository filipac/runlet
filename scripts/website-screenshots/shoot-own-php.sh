#!/bin/sh
# Regenerates the website's "Runlet's own PHP" collage (website/assets/shots/own-php-{light,dark}-
# {1200,2400}.webp, #67) from a Debug build of Runlet on a Mac that seems to have no PHP and no
# Docker: the banner, the download in progress, Settings ▸ PHP after the install, and a run.
#
#   scripts/website-screenshots/shoot-own-php.sh [steps file]   (default: own-php-steps.txt here)
#
# It touches only:
# - build/website-shots/: the build (DerivedData, shared with shoot.sh) and own-php/: the PHP
#   archive (downloaded once from the php-8.5.8-r1 release and checked against its .sha256), the
#   raw PNGs, and the composed collages;
# - /Users/Shared/Library/Application Support/Runlet: the scratch RUNLET_DATA_DIR. Settings ▸ PHP
#   shows its path, so it is a neutral one with no user name. It is created fresh for each
#   appearance and removed at the end (with /Users/Shared/Library, if this script created it).
#   The script refuses to run if that folder exists and isn't one it left behind.
# - 127.0.0.1:<port>: slow-serve.py serves the archive at about 2 MB/s, so the download can be
#   caught in progress (RUNLET_DEBUG_PHP_URL; the checksum pinned in the app still has to match).
#   It is stopped at the end.
# RUNLET_DEBUG_HIDE_SYSTEM_PHP=1 hides installed PHP, and no-docker stands in for the Docker CLI,
# so it never lists or execs into your containers. It never reads ~/.ssh or opens your Runlet
# data. The app is built with its own bundle identifier, launched hidden and in the background,
# and its first step (`ghost`) keeps its windows invisible and click-through with no Dock icon, so
# nothing appears on screen and the keyboard stays yours. The steps are DEBUG-only
# (Runlet/App/DebugSteps.swift); the app quits after the last one. own-php-collage.swift then
# lays the shots out, and cwebp converts them.
#
# Needs Xcode, Python 3, curl, cwebp, and scripts/build-sandbox.sh and scripts/fetch-phpantom.sh
# to have run. Apple silicon or Intel: it shoots this Mac's archive.
set -e
TOOLS="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TOOLS/../.." && pwd)"
WORK="$ROOT/build/website-shots/own-php"
STEPS="${1:-$TOOLS/own-php-steps.txt}"
SITE="$ROOT/website"
DATA_PARENT="/Users/Shared/Library/Application Support"
DATA="$DATA_PARENT/Runlet"
MARKER=".runlet-website-shots"
RELEASE="php-8.5.8-r1"
ARCH="$(sysctl -n hw.optional.arm64 2>/dev/null | grep -q 1 && echo arm64 || echo x86_64)"
ARCHIVE="runlet-$RELEASE-macos-$ARCH.tar.gz"
mkdir -p "$WORK"

[ -f "$ROOT/Resources/Sandbox/laravel/vendor/autoload.php" ] || { echo "Run scripts/build-sandbox.sh first." >&2; exit 1; }
command -v cwebp >/dev/null || { echo "cwebp is missing (brew install webp)." >&2; exit 1; }
if [ -e "$DATA" ] && [ ! -e "$DATA/$MARKER" ]; then
  echo "$DATA exists and wasn't made by this script; not touching it." >&2
  exit 1
fi

echo "== Building Runlet (Debug, bundle id dev.runlet.Runlet.websiteshots)"
xcodebuild -quiet -project "$ROOT/Runlet.xcodeproj" -scheme Runlet -configuration Debug \
  -derivedDataPath "$ROOT/build/website-shots/DerivedData" PRODUCT_BUNDLE_IDENTIFIER=dev.runlet.Runlet.websiteshots build
APP="$ROOT/build/website-shots/DerivedData/Build/Products/Debug/Runlet.app"

echo "== Runlet's PHP archive ($ARCH)"
if [ ! -f "$WORK/$ARCHIVE" ]; then
  curl -fsSL -o "$WORK/$ARCHIVE.part" "https://github.com/filipac/runlet/releases/download/$RELEASE/$ARCHIVE"
  curl -fsSL -o "$WORK/$ARCHIVE.sha256" "https://github.com/filipac/runlet/releases/download/$RELEASE/$ARCHIVE.sha256"
  [ "$(shasum -a 256 "$WORK/$ARCHIVE.part" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$WORK/$ARCHIVE.sha256")" ] \
    || { echo "The archive doesn't match its .sha256." >&2; rm -f "$WORK/$ARCHIVE.part"; exit 1; }
  mv "$WORK/$ARCHIVE.part" "$WORK/$ARCHIVE"
fi

PORT=18767
while lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; do PORT=$((PORT + 1)); done
# In a subshell, so stopping it later doesn't print a job notice.
(python3 "$TOOLS/slow-serve.py" "$WORK/$ARCHIVE" "$PORT" 2000000 2>"$WORK/serve.log" & echo $! >"$WORK/serve.pid")
SERVER="$(cat "$WORK/serve.pid")"
CREATED_LIBRARY=""
[ -d /Users/Shared/Library ] || CREATED_LIBRARY=1
cleanup() {
  kill "$SERVER" 2>/dev/null || true
  [ -e "$DATA/$MARKER" ] && rm -rf "$DATA"
  if [ -n "$CREATED_LIBRARY" ]; then
    rmdir "$DATA_PARENT" /Users/Shared/Library 2>/dev/null || true
  fi
}
trap cleanup EXIT
sleep 1

OUT="$WORK/out"
rm -rf "$OUT"
mkdir -p "$OUT"
for APPEARANCE in light dark; do
  echo "== Shooting $APPEARANCE (the app runs hidden; about a minute)"
  [ -e "$DATA/$MARKER" ] && rm -rf "$DATA"
  mkdir -p "$DATA"
  touch "$DATA/$MARKER"
  python3 "$TOOLS/own-php-seed.py" "$DATA" "$TOOLS/no-docker"
  STEP_LIST="$(grep -v '^[[:space:]]*#' "$STEPS" | grep -v '^[[:space:]]*$' | sed "s/{appearance}/$APPEARANCE/g" | paste -sd, -)"
  open -g -j -n -W \
    --env RUNLET_DATA_DIR="$DATA" \
    --env RUNLET_SNAPSHOT_DIR="$OUT" \
    --env RUNLET_DEBUG_HIDE_SYSTEM_PHP=1 \
    --env RUNLET_DEBUG_PHP_URL="http://127.0.0.1:$PORT/$ARCHIVE" \
    --env RUNLET_DEBUG_STEPS="$STEP_LIST" \
    --env SSH_AUTH_SOCK= \
    --stderr "$OUT/stderr-$APPEARANCE.log" \
    "$APP"
  grep -q "RUNLET_DEBUG_STEPS: done" "$OUT/stderr-$APPEARANCE.log" || { echo "The app quit early; see $OUT/stderr-$APPEARANCE.log" >&2; exit 1; }
  [ -f "$OUT/settings-installed-$APPEARANCE.png" ] && [ -f "$OUT/run-$APPEARANCE.png" ] || { echo "Shots are missing; see $OUT/stderr-$APPEARANCE.log" >&2; exit 1; }
done

echo "== Composing and converting"
swiftc -O -o "$WORK/own-php-collage" "$TOOLS/own-php-collage.swift" 2>/dev/null
mkdir -p "$SITE/assets/shots"
for APPEARANCE in light dark; do
  "$WORK/own-php-collage" "$OUT" "$APPEARANCE" "$OUT/own-php-$APPEARANCE.png"
  cwebp -quiet -q 82 -m 6 -sharp_yuv -resize 2400 0 "$OUT/own-php-$APPEARANCE.png" -o "$SITE/assets/shots/own-php-$APPEARANCE-2400.webp"
  cwebp -quiet -q 84 -m 6 -sharp_yuv -resize 1200 0 "$OUT/own-php-$APPEARANCE.png" -o "$SITE/assets/shots/own-php-$APPEARANCE-1200.webp"
done
echo "Done. Check every image in $OUT before committing: no real names, paths, hosts, or containers."
