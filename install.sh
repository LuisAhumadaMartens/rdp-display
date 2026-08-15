#!/bin/bash
set -euo pipefail

BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rdp-display"
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

if ! python3 -c "import tomllib" 2>/dev/null; then
    echo "Python 3.11 or newer is required (tomllib)." >&2
    echo "  found: $(python3 -V)" >&2
    exit 1
fi

if [ "${XDG_SESSION_TYPE:-}" != "x11" ]; then
    echo "Warning: session type is '${XDG_SESSION_TYPE:-unknown}', not x11." >&2
    echo "The confirmation keystroke uses xdotool and will not work on Wayland." >&2
fi

mkdir -p "$BIN_DIR" "$UNIT_DIR" "$CONF_DIR"
install -m 755 "$SRC/rdp-display" "$BIN_DIR/rdp-display"
install -m 644 "$SRC/rdp-display.service" "$UNIT_DIR/rdp-display.service"

if [ -f "$CONF_DIR/config.toml" ]; then
    echo "Kept existing config: $CONF_DIR/config.toml"
else
    install -m 644 "$SRC/config.example.toml" "$CONF_DIR/config.toml"
    echo "Created config: $CONF_DIR/config.toml"
fi

systemctl --user daemon-reload

echo
echo "Installed:"
echo "  $BIN_DIR/rdp-display"
echo "  $UNIT_DIR/rdp-display.service"
echo
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "Note: $BIN_DIR is not on your PATH."; echo ;;
esac
echo "Next:"
echo "  rdp-display modes                        # find your mode IDs"
echo "  \$EDITOR $CONF_DIR/config.toml           # set your profiles"
echo "  rdp-display config                       # check it parsed"
echo "  systemctl --user enable --now rdp-display"
