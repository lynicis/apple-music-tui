#!/usr/bin/env bash
# Installs apple-music-tui on macOS (Apple silicon and Intel).
#   curl -fsSL https://raw.githubusercontent.com/lynicis/apple-music-tui/master/install.sh | bash
set -euo pipefail

REPO="lynicis/apple-music-tui"
ASSET="apple-music-tui-macos-universal.tar.gz"
SUMS="checksums.txt"
BASE="https://github.com/${REPO}/releases/latest/download"

fail() { echo "apple-music-tui: $1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "this app only runs on macOS."
case "$(uname -m)" in
  arm64 | x86_64) ;;
  *) fail "this build supports Apple silicon and Intel Macs (this Mac reports $(uname -m))." ;;
esac

INSTALL_DIR="${APPLE_MUSIC_TUI_INSTALL_DIR:-}"
if [ -z "$INSTALL_DIR" ]; then
  if [ -w /usr/local/bin ]; then
    INSTALL_DIR=/usr/local/bin
  else
    INSTALL_DIR="$HOME/.local/bin"
  fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading apple-music-tui from the latest release…"
curl -fsSL "$BASE/$ASSET" -o "$TMP/$ASSET" || fail "download failed: $BASE/$ASSET"
curl -fsSL "$BASE/$SUMS" -o "$TMP/$SUMS" || fail "could not download $SUMS"

expected="$(awk -v asset="$ASSET" '$2 == asset { print $1 }' "$TMP/$SUMS")"
[ -n "$expected" ] || fail "no checksum published for $ASSET"
actual="$(shasum -a 256 "$TMP/$ASSET" | awk '{ print $1 }')"
if [ "$expected" != "$actual" ]; then
  fail "checksum mismatch for $ASSET
  expected $expected
  actual   $actual
Refusing to install a corrupted or tampered download."
fi
echo "Checksum verified ($actual)."

tar -xzf "$TMP/$ASSET" -C "$TMP" || fail "could not unpack $ASSET"

mkdir -p "$INSTALL_DIR"
install -m 755 "$TMP/apple-music-tui" "$INSTALL_DIR/apple-music-tui"
install -m 644 "$TMP/libMediaRemoteAdapter.dylib" "$INSTALL_DIR/libMediaRemoteAdapter.dylib"

echo "Installed $INSTALL_DIR/apple-music-tui"
case ":$PATH:" in
  *":$INSTALL_DIR:"*)
    echo "Run it with: apple-music-tui"
    ;;
  *)
    echo
    echo "Add it to your PATH first:"
    echo "  echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
    echo "Then run: apple-music-tui"
    ;;
esac
