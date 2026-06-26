# shellcheck shell=sh
# lib/gui.sh — bootstrap a graphical desktop inside the chroot.
# Two paths: a VNC server (works with any Android VNC viewer) or X11 over a
# local socket/TCP for Termux:X11. Also wires up PulseAudio for sound.

# write a launcher script INSIDE the chroot and make it executable
_write_in_chroot() {
	_rfs=$1; _path=$2
	mkdir -p "$_rfs$(dirname "$_path")" 2>/dev/null
	cat > "$_rfs$_path" || return 1
	chmod 755 "$_rfs$_path" 2>/dev/null
}

cmd_gui() {
	_name=$1; _mode=${2:-vnc}
	require_chroot "$_name"
	_rfs=$(rootfs_path "$_name")
	case "$_mode" in
		vnc) _gui_vnc "$_name" "$_rfs" ;;
		x11) _gui_x11 "$_name" "$_rfs" ;;
		audio) _gui_audio "$_name" "$_rfs" ;;
		*) die "usage: achroot gui NAME [vnc|x11|audio]" ;;
	esac
}

_gui_vnc() {
	_name=$1; _rfs=$2
	log_step "Setting up VNC for '$_name'"
	_write_in_chroot "$_rfs" /usr/local/bin/vnc <<'EOF'
#!/bin/sh
# achroot VNC launcher. Edit DISPLAY/geometry/depth as you like.
: "${DISP:=1}"
: "${GEOMETRY:=1280x720}"
: "${DEPTH:=24}"
export HOME=/root USER=root
mkdir -p "$HOME/.vnc"
# pick whatever VNC server is installed
if command -v vncserver >/dev/null 2>&1; then
	vncserver -kill ":$DISP" >/dev/null 2>&1
	exec vncserver ":$DISP" -geometry "$GEOMETRY" -depth "$DEPTH" -localhost no
elif command -v tigervncserver >/dev/null 2>&1; then
	exec tigervncserver ":$DISP" -geometry "$GEOMETRY" -depth "$DEPTH" -localhost no
elif command -v Xtigervnc >/dev/null 2>&1; then
	exec Xtigervnc ":$DISP" -geometry "$GEOMETRY" -depth "$DEPTH" -rfbport $((5900+DISP)) -SecurityTypes None
else
	echo "No VNC server installed inside the chroot."
	echo "  Debian/Kali/Ubuntu : apt install tigervnc-standalone-server xfce4 xfce4-goodies dbus-x11"
	echo "  Arch               : pacman -S tigervnc xfce4"
	echo "  Alpine             : apk add tigervnc xfce4"
	exit 1
fi
EOF
	# a default xstartup launching XFCE if present, else a terminal
	_write_in_chroot "$_rfs" /root/.vnc/xstartup <<'EOF'
#!/bin/sh
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
[ -r /etc/X11/Xresources ] && xrdb /etc/X11/Xresources 2>/dev/null
export XDG_RUNTIME_DIR=/tmp/runtime-root
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
if command -v startxfce4 >/dev/null 2>&1; then exec dbus-launch --exit-with-session startxfce4
elif command -v startlxqt >/dev/null 2>&1; then exec startlxqt
elif command -v startlxde >/dev/null 2>&1; then exec startlxde
elif command -v xterm >/dev/null 2>&1; then exec xterm
else exec /bin/sh; fi
EOF
	log_ok "wrote /usr/local/bin/vnc and ~/.vnc/xstartup inside '$_name'"
	cat >&2 <<EOF
${C_BOLD}Next steps:${C_RESET}
  1. achroot enter $_name
  2. install a desktop + VNC server, e.g. (Debian/Kali):
       apt update && apt install -y tigervnc-standalone-server xfce4 xfce4-goodies dbus-x11
  3. run:  vnc            (sets a password the first time)
  4. on Android, open a VNC viewer and connect to ${C_CYN}127.0.0.1:5901${C_RESET}
EOF
}

_gui_x11() {
	_name=$1; _rfs=$2
	log_step "Setting up X11 (Termux:X11 / external Xserver) for '$_name'"
	_write_in_chroot "$_rfs" /usr/local/bin/gui-x11 <<'EOF'
#!/bin/sh
# Point at an X server reachable from the chroot.
# Termux:X11 listens on a unix socket; the abstract socket is shared via /tmp/.X11-unix.
: "${DISPLAY:=:0}"
export DISPLAY
export XDG_RUNTIME_DIR=/tmp/runtime-root
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null
export PULSE_SERVER="${PULSE_SERVER:-tcp:127.0.0.1:4713}"
if command -v startxfce4 >/dev/null 2>&1; then exec dbus-launch --exit-with-session startxfce4
elif command -v xterm >/dev/null 2>&1; then exec xterm
else echo "Install a desktop first (e.g. apt install xfce4)"; exec /bin/sh; fi
EOF
	# make sure the X11 unix-socket dir can be bind-mounted in; suggest extra bind
	log_ok "wrote /usr/local/bin/gui-x11 inside '$_name'"
	cat >&2 <<EOF
${C_BOLD}To share the X socket${C_RESET}, add a bind mount so the chroot sees Termux:X11:
  achroot config set ACH_EXTRA_BINDS '\$PREFIX/tmp/.X11-unix:/tmp/.X11-unix'
  achroot stop $_name && achroot start $_name
Then inside: ${C_CYN}export DISPLAY=:0 && gui-x11${C_RESET}
(Install the Termux:X11 app + 'termux-x11' on the Termux side.)
EOF
}

_gui_audio() {
	_name=$1; _rfs=$2
	log_step "Configuring PulseAudio (network sink) for '$_name'"
	_write_in_chroot "$_rfs" /etc/profile.d/01-achroot-audio.sh <<'EOF'
# route audio to a PulseAudio server on the Android side (e.g. Termux pulseaudio)
export PULSE_SERVER="${PULSE_SERVER:-tcp:127.0.0.1:4713}"
EOF
	log_ok "audio will use PULSE_SERVER=tcp:127.0.0.1:4713"
	cat >&2 <<EOF
On the Android/Termux side, start a network-accessible PulseAudio, e.g.:
  pulseaudio --start --load="module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1" --exit-idle-time=-1
EOF
}
