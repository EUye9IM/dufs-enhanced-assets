#!/bin/sh
# Bake each mutable asset's mtime into index.html as its cache-busting version.
#
# Why: dufs serves everything under --assets with
#   Cache-Control: public, max-age=31536000, immutable
# and ignores query strings, so a deployed index.js would keep running from cache for up to a
# year. index.html itself is `no-cache`, so it is always fresh and can point at a new URL.
#
# Run this after editing assets/index.css or assets/index.js, before committing.
# index.html, movi.js/movi.wasm, favicon.ico and trust/ are deliberately left unversioned.
set -eu
cd "$(dirname "$0")"

STAMP=assets/index.html

for name in index.css index.js; do
  file="assets/$name"
  [ -f "$file" ] || { echo "bump-assets: missing $file" >&2; exit 1; }
  version=$(date -r "$file" +%s)
  # temp file + mv: `sed -i` is not portable across GNU and BSD userlands
  sed "s|\\(__ASSETS_PREFIX__$name\\)?v=[0-9]*|\\1?v=$version|" "$STAMP" > "$STAMP.tmp"
  mv "$STAMP.tmp" "$STAMP"
  printf '%-10s %s\n' "$name" "$version"
done

echo
echo "Now commit assets/index.html with the change, and deploy it too."
