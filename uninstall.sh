#!/usr/bin/env bash
# Removes apple-music-tui installed by install.sh.
#   curl -fsSL https://raw.githubusercontent.com/lynicis/apple-music-tui/master/uninstall.sh | bash
set -euo pipefail

BINARY="apple-music-tui"
LIBRARY="libMediaRemoteAdapter.dylib"
BUNDLE="MediaRemoteAdapter_MediaRemoteAdapter.bundle"

# An explicit override targets exactly one directory; otherwise remove from
# both places install.sh may have used.
if [ -n "${APPLE_MUSIC_TUI_INSTALL_DIR:-}" ]; then
  CANDIDATES=("$APPLE_MUSIC_TUI_INSTALL_DIR")
else
  CANDIDATES=("$HOME/.local/bin" "/usr/local/bin")
fi

removed=0
skipped=0
for dir in "${CANDIDATES[@]}"; do
  [ -n "$dir" ] || continue
  [ -e "$dir/$BINARY" ] || continue
  if [ ! -w "$dir" ]; then
    echo "apple-music-tui: need permission to remove files from $dir; re-run with sudo." >&2
    skipped=1
    continue
  fi
  rm -f "$dir/$BINARY" "$dir/$LIBRARY"
  rm -rf "$dir/$BUNDLE"
  echo "Removed apple-music-tui from $dir"
  removed=1
done

if [ "$removed" = 0 ] && [ "$skipped" = 0 ]; then
  echo "apple-music-tui is not installed in ~/.local/bin or /usr/local/bin."
fi
echo "Left your Music library and the saved theme in ~/.config/apple-music-tui untouched."
