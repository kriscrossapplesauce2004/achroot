#!/bin/sh
# install.sh — optional: put `achroot` on your PATH so you can call it directly.
# Totally optional — you can always just `sh achroot ...` from the clone.
set -u

SRC=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

is_root() { [ "$(id -u 2>/dev/null || echo 1)" = 0 ]; }

# pick a bin dir on PATH that we can write to
pick_bindir() {
	for d in /data/local/bin /system/xbin /usr/local/bin "$HOME/.local/bin"; do
		case ":$PATH:" in *":$d:"*) ;; *) continue ;; esac
		[ -d "$d" ] || mkdir -p "$d" 2>/dev/null || continue
		[ -w "$d" ] && { printf '%s\n' "$d"; return 0; }
	done
	# fall back to /data/local/bin even if not on PATH (common on Android)
	mkdir -p /data/local/bin 2>/dev/null && { printf '%s\n' /data/local/bin; return 0; }
	return 1
}

BIN=$(pick_bindir) || { echo "install: no writable bin dir found; run as root or add ~/.local/bin to PATH" >&2; exit 1; }

# we ship as a directory of modules, so install a thin launcher that points back
# at this checkout (keeps `update`/git working and avoids copying lib/).
LAUNCHER="$BIN/achroot"
cat > "$LAUNCHER" <<EOF
#!/bin/sh
# achroot launcher (installed by install.sh) -> $SRC
exec sh "$SRC/achroot" "\$@"
EOF
chmod 755 "$LAUNCHER" 2>/dev/null || { echo "install: could not chmod $LAUNCHER" >&2; exit 1; }
chmod 755 "$SRC/achroot" 2>/dev/null

echo "Installed launcher: $LAUNCHER"
case ":$PATH:" in
	*":$BIN:"*) echo "You can now run:  achroot doctor" ;;
	*) echo "Add $BIN to your PATH, then run:  achroot doctor" ;;
esac
