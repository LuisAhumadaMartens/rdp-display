#!/bin/bash
# Install rdp-display into the current user's home. No root required.
set -euo pipefail

BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

missing=()
for cmd in xdotool ss python3; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
python3 -c "import gi" 2>/dev/null || missing+=("python3-gi")
if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing dependencies: ${missing[*]}" >&2
    echo "  sudo apt install xdotool python3-gi iproute2" >&2
    exit 1
fi

if [ "${XDG_SESSION_TYPE:-}" != "x11" ]; then
    echo "Warning: session type is '${XDG_SESSION_TYPE:-unknown}', not x11." >&2
    echo "The confirmation keystroke uses xdotool and will not work on Wayland." >&2
fi

mkdir -p "$BIN_DIR" "$UNIT_DIR"
install -m 755 "$SRC/rdp-display" "$BIN_DIR/rdp-display"
install -m 644 "$SRC/rdp-display.service" "$UNIT_DIR/rdp-display.service"
systemctl --user daemon-reload

echo "Installed:"
echo "  $BIN_DIR/rdp-display"
echo "  $UNIT_DIR/rdp-display.service"
echo
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "Note: $BIN_DIR is not on your PATH." ; echo ;;
esac
echo "Next:"
echo "  rdp-display modes                        # find your mode IDs"
echo "  \$EDITOR $BIN_DIR/rdp-display            # set PROFILES"
echo "  systemctl --user enable --now rdp-display"
