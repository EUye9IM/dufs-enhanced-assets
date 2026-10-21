#!/usr/bin/env bash
# Re-download movi-player's slim dist into this repository.
#
#   ./sync-movi.sh            # sync the version pinned in this script
#   ./sync-movi.sh 0.4.2      # sync a specific version
#
# Only movi.js and movi.wasm are written. Never edit either file by hand: they must stay
# byte-identical to upstream so that a version bump is a plain diff.
set -euo pipefail

PINNED_VERSION="0.4.1"
VERSION="${1:-${MOVI_VERSION:-$PINNED_VERSION}}"

REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"
TARBALL="$REGISTRY/movi-player/-/movi-player-$VERSION.tgz"
DIST_JS="package/dist/element.slim.global.js"
DIST_WASM="package/dist/movi.wasm"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> movi-player@$VERSION"
echo "    $TARBALL"

curl -fsSL --retry 3 --max-time 300 -o "$WORK_DIR/movi-player.tgz" "$TARBALL"

# List the archive once. Do not pipe `tar` into `grep -q`: with `pipefail` the
# early grep exit sends SIGPIPE to tar and the pipeline reports failure.
LISTING="$WORK_DIR/listing.txt"
tar tzf "$WORK_DIR/movi-player.tgz" > "$LISTING"

# Fail loudly if upstream ever renames the dist files.
for required in "$DIST_JS" "$DIST_WASM"; do
  if ! grep -qxF "$required" "$LISTING"; then
    echo "error: $required missing from the tarball — upstream layout changed" >&2
    exit 1
  fi
done

tar xzf "$WORK_DIR/movi-player.tgz" -C "$WORK_DIR" "$DIST_JS" "$DIST_WASM"

# Sanity checks before overwriting the committed copies.
for pair in "$WORK_DIR/$DIST_JS:$REPO_DIR/movi.js" "$WORK_DIR/$DIST_WASM:$REPO_DIR/movi.wasm"; do
  src="${pair%%:*}"
  dst="${pair##*:}"
  size=$(wc -c < "$src")
  if [ "$size" -lt 1000000 ]; then
    echo "error: $(basename "$src") is only $size bytes — refusing to install" >&2
    exit 1
  fi
  cp "$src" "$dst"
  printf '    %-12s %10s bytes  %s\n' "$(basename "$dst")" "$size" "$(sha256sum "$dst" | cut -d' ' -f1)"
done

cat <<EOF

==> Done. Next steps:
    git diff --stat                 # expect exactly movi.js + movi.wasm
    # serve and check one HEVC-in-mkv and one MPEG-4-in-avi still play and seek
    # then update UPSTREAM.md (version, sizes, sha256) and the pin in this script
EOF
