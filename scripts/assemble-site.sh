#!/bin/sh
# Assembles the published site (#287): the landing page (website/) at the root and the built docs
# (docs/.vitepress/dist, from `npm run docs:build`) under docs/. The Website workflow deploys this
# folder to GitHub Pages, and the Docs workflow uploads it from pull requests.
#
#   scripts/assemble-site.sh <folder>      # e.g. build/site; the folder is replaced
set -eu

out="${1:?usage: scripts/assemble-site.sh <folder>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
dist="$root/docs/.vitepress/dist"

if [ ! -f "$dist/index.html" ]; then
  echo "assemble-site: $dist has no build; run npm run docs:build first." >&2
  exit 1
fi
if [ -e "$root/website/docs" ]; then
  echo "assemble-site: website/docs would collide with the docs at /docs/." >&2
  exit 1
fi

rm -rf "$out"
mkdir -p "$out"
cp -R "$root/website/." "$out/"
cp -R "$dist" "$out/docs"
# GitHub Pages serves /404.html for every missing page; the docs' one links back to /docs/.
[ -e "$out/404.html" ] || cp "$dist/404.html" "$out/404.html"
echo "assemble-site: $out (landing page at /, docs at /docs/)"
