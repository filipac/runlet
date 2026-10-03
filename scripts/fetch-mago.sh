#!/usr/bin/env bash
# Downloads the pinned Mago release (the PHP formatter behind Format Code, #36) for both macOS
# architectures, verifies checksums, and produces a universal binary at Resources/Formatter/mago.
# Mago is dual-licensed MIT OR Apache-2.0; Resources/Formatter/LICENSE-mago.txt is its MIT text.
set -euo pipefail

VERSION="1.51.2"
SHA_ARM64="13125481a4a039b92d520c04d4f395c90dd0223284c976c1c3e447b0bbdbda07"
SHA_X86_64="bcbac16d24ef6c6b7df951ecfac2064954bd900292ae7c8afb5222cdd7fe753d"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Resources/Formatter"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ -x "$OUT/mago" ]] && "$OUT/mago" --version 2>/dev/null | grep -q " $VERSION\$"; then
    echo "Mago $VERSION already present"
    exit 0
fi

fetch() {
    local arch="$1" sha="$2"
    local name="mago-$VERSION-$arch-apple-darwin"
    curl -fsSL -o "$WORK/$arch.tar.gz" "https://github.com/carthage-software/mago/releases/download/$VERSION/$name.tar.gz"
    echo "$sha  $WORK/$arch.tar.gz" | shasum -a 256 -c - >/dev/null
    mkdir -p "$WORK/$arch"
    tar -xzf "$WORK/$arch.tar.gz" -C "$WORK/$arch"
    mv "$WORK/$arch/$name/mago" "$WORK/$arch/mago"
}

fetch aarch64 "$SHA_ARM64"
fetch x86_64 "$SHA_X86_64"
mkdir -p "$OUT"
lipo -create "$WORK/aarch64/mago" "$WORK/x86_64/mago" -output "$OUT/mago"
chmod 755 "$OUT/mago"
echo "Mago $VERSION universal binary: $OUT/mago"
