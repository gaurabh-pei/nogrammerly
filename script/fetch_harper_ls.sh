#!/usr/bin/env bash
# Downloads the pinned harper-ls release into Vendor/harper-ls/bin and verifies both checksums.
# Idempotent: exits early when the verified binary is already in place.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT_DIR/Vendor/harper-ls"
# bash 3.2 (macOS /bin/bash) cannot `source <(...)`, so eval the pinned KEY=value lines.
eval "$(grep -E '^HARPER_[A-Z0-9_]+=' "$VENDOR/harper-ls.pin")"
BIN="$VENDOR/bin/harper-ls"
if [[ -x "$BIN" ]] && [[ "$(shasum -a 256 "$BIN" | cut -d' ' -f1)" == "$HARPER_BINARY_SHA256" ]]; then
  echo "harper-ls $HARPER_VERSION already present: $BIN"; exit 0
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl --fail --location --silent --show-error --output "$TMP/$HARPER_ASSET" "$HARPER_URL"
echo "$HARPER_TARBALL_SHA256  $TMP/$HARPER_ASSET" | shasum -a 256 --check --status || { echo "error: tarball sha256 mismatch" >&2; exit 1; }
mkdir -p "$TMP/x" "$VENDOR/bin"
tar -xzf "$TMP/$HARPER_ASSET" -C "$TMP/x" harper-ls
echo "$HARPER_BINARY_SHA256  $TMP/x/harper-ls" | shasum -a 256 --check --status || { echo "error: binary sha256 mismatch" >&2; exit 1; }
install -m 0755 "$TMP/x/harper-ls" "$BIN"
echo "harper-ls $HARPER_VERSION installed: $BIN"
