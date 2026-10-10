#!/usr/bin/env bash
# Installs apple-music-tui on macOS (Apple silicon).
#   curl -fsSL https://raw.githubusercontent.com/lynicis/apple-music-tui/master/install.sh | bash
set -euo pipefail

REPO="lynicis/apple-music-tui"
ASSET="apple-music-tui-macos-arm64.tar.gz"
URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"

fail() { echo "apple-music-tui: $1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "this app only runs on macOS."
[ "$(uname -m)" = "arm64" ] || fail "this build is Apple silicon only (this Mac reports $(uname -m))."

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
curl -fsSL "$URL" -o "$TMP/$ASSET" || fail "download failed: $URL"
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
