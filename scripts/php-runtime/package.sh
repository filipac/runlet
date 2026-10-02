#!/usr/bin/env bash
# Packages a static-php-cli build as Runlet's PHP archive (#2):
#   php-<version>-<build>/bin/php, licenses/, README.txt  →  runlet-php-<version>-<build>-macos-<arch>.tar.gz (+ .sha256)
#
# Usage: scripts/php-runtime/package.sh <spc-dir> <version> <build> <arch> <out-dir>
#   <spc-dir>  folder holding ./spc, craft.yml, and buildroot/bin/php after `./spc craft`
#   <arch>     arm64 or x86_64
set -euo pipefail
SPC_DIR="$1"; VERSION="$2"; BUILD="$3"; ARCH="$4"; OUT="$5"
NAME="php-$VERSION-$BUILD"
STAGE="$(mktemp -d)"
ROOT="$STAGE/$NAME"
mkdir -p "$ROOT/bin" "$OUT"

cp "$SPC_DIR/buildroot/bin/php" "$ROOT/bin/php"
chmod 755 "$ROOT/bin/php"
# Apple silicon refuses unsigned code; an ad-hoc signature is enough for a downloaded CLI.
codesign --force --sign - "$ROOT/bin/php"

"$ROOT/bin/php" -v | head -1 | grep -q "PHP $VERSION " || { echo "built PHP is not $VERSION" >&2; exit 1; }
EXTENSIONS="$(sed -n 's/^extensions: *"\(.*\)"/\1/p' "$SPC_DIR/craft.yml")"
(cd "$SPC_DIR" && ./spc dump-license --for-extensions="$EXTENSIONS" --dump-dir="$ROOT/licenses" >/dev/null)

cat > "$ROOT/README.txt" <<EOF
Runlet's PHP $VERSION ($BUILD), macOS $ARCH
Static PHP CLI built with static-php-cli (https://github.com/crazywhalecc/static-php-cli)
for Runlet (https://github.com/filipac/runlet), downloaded on request and used only when
no installed PHP fits. PHP is distributed under the PHP License; bundled libraries keep
their own licenses (see licenses/).

Extensions: $EXTENSIONS
EOF

ARCHIVE="$OUT/runlet-$NAME-macos-$ARCH.tar.gz"
tar -czf "$ARCHIVE" -C "$STAGE" "$NAME"
(cd "$OUT" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
rm -rf "$STAGE"
echo "$ARCHIVE"
cat "$ARCHIVE.sha256"
