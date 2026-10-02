#!/usr/bin/env bash
# Downloads the pinned PHPantom LSP release for both macOS architectures, verifies
# checksums, and produces a universal binary at Resources/LSP/phpantom_lsp.
set -euo pipefail

VERSION="0.10.0"
SHA_ARM64="2f445d9708ed15e1714b48271db43741d13a70c674ef5b3ff1a423e51b4f663b"
SHA_X86_64="b1c8fffbbc34cba2edc42013f4010794179506eab04a49ee15a07364985bd596"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Resources/LSP"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ -x "$OUT/phpantom_lsp" ]] && "$OUT/phpantom_lsp" --version 2>/dev/null | grep -q " $VERSION\$"; then
    echo "PHPantom $VERSION already present"
    exit 0
fi

fetch() {
    local arch="$1" sha="$2"
    local url="https://github.com/PHPantom-dev/phpantom_lsp/releases/download/$VERSION/phpantom_lsp-$arch-apple-darwin.tar.gz"
    curl -fsSL -o "$WORK/$arch.tar.gz" "$url"
    echo "$sha  $WORK/$arch.tar.gz" | shasum -a 256 -c - >/dev/null
    mkdir -p "$WORK/$arch"
    tar -xzf "$WORK/$arch.tar.gz" -C "$WORK/$arch"
}

fetch aarch64 "$SHA_ARM64"
fetch x86_64 "$SHA_X86_64"
mkdir -p "$OUT"
lipo -create "$WORK/aarch64/phpantom_lsp" "$WORK/x86_64/phpantom_lsp" -output "$OUT/phpantom_lsp"
chmod 755 "$OUT/phpantom_lsp"
echo "PHPantom $VERSION universal binary: $OUT/phpantom_lsp"
