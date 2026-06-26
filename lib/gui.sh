# shellcheck shell=sh
# lib/gui.sh — graphical desktop support inside the chroot.
#   achroot gui NAME setup [de]     install a desktop + VNC server automatically
#   achroot gui NAME start [vnc|x11] start the session, print connect info
#   achroot gui NAME stop           stop the session
#   achroot gui NAME vnc|x11|audio  just (re)write launcher scripts
#
# VNC works with any Android VNC viewer (connect to 127.0.0.1:5901).
# X11 targets Termux:X11. PulseAudio routes sound to the Android side.

cmd_gui() {
	_name=${1:-}; _action=${2:-start}; _extra=${3:-}
	require_chroot "$_name"
	need_root
	_rfs=$(rootfs_path "$_name")
	is_started "$_name" || start_chroot "$_name"
	case "$_action" in
		setup)  _gui_setup "$_name" "${_extra:-xfce}" ;;
		start)  _gui_start "$_name" "${_extra:-vnc}" ;;
		stop)   _gui_stop  "$_name" ;;
		vnc)    _gui_vnc_scripts "$_rfs"; _gui_vnc_help "$_name" ;;
		x11)    _gui_x11 "$_name" "$_rfs" ;;
		audio)  _gui_audio "$_name" "$_rfs" ;;
		*) die "usage: achroot gui NAME [setup [de]|start [vnc|x11]|stop|vnc|x11|audio]" ;;
	esac
}

# --- desktop-environment package maps --------------------------------------

de_packages() {
	_pm=$1; _de=$2
	case "$_de" in
		xfce)
			case "$_pm" in
				apt-get) echo 'xfce4 xfce4-terminal dbus-x11 x11-xserver-utils' ;;
				pacman)  echo 'xfce4 xfce4-terminal' ;;
				apk)     echo 'xfce4 xfce4-terminal dbus-x11 xfce4-screensaver' ;;
				dnf|yum) echo 'xfce4-session xfce4-panel xfwm4 xfdesktop xfce4-terminal dbus-x11' ;;
				xbps-install) echo 'xfce4 xfce4-terminal' ;;
				zypper)  echo 'xfce4-session xfce4-panel xfce4-terminal' ;;
			esac ;;
		lxqt)
			case "$_pm" in
				apt-get) echo 'lxqt-core qterminal dbus-x11' ;;
				pacman)  echo 'lxqt qterminal' ;;
				apk)     echo 'lxqt qterminal dbus-x11' ;;
				dnf|yum) echo '@lxqt-desktop qterminal' ;;
				xbps-install) echo 'lxqt qterminal' ;;
				zypper)  echo 'lxqt qterminal' ;;
			esac ;;
		lxde)
			case "$_pm" in
				apt-get) echo 'lxde-core lxterminal dbus-x11' ;;
				pacman)  echo 'lxde lxterminal' ;;
				apk)     echo 'lxde lxterminal dbus-x11' ;;
				dnf|yum) echo '@lxde-desktop lxterminal' ;;
				xbps-install) echo 'lxde lxterminal' ;;
				zypper)  echo 'lxde lxterminal' ;;
			esac ;;
		mate)
			case "$_pm" in
				apt-get) echo 'mate-desktop-environment-core mate-terminal dbus-x11' ;;
				pacman)  echo 'mate mate-terminal' ;;
				apk)     echo 'mate-desktop mate-terminal dbus-x11' ;;
				dnf|yum) echo '@mate-desktop mate-terminal' ;;
				xbps-install) echo 'mate mate-terminal' ;;
				zypper)  echo 'mate mate-terminal' ;;
			esac ;;
		*) return 1 ;;
	esac
}

vnc_packages() {
	case "$1" in
		apt-get) echo 'tigervnc-standalone-server' ;;
		pacman)  echo 'tigervnc' ;;
		apk)     echo 'tigervnc' ;;
		dnf|yum) echo 'tigervnc-server' ;;
		xbps-install) echo 'tigervnc' ;;
		zypper)  echo 'tigervnc' ;;
	esac
}

# --- automatic setup -------------------------------------------------------

_gui_setup() {
	_name=$1; _de=$2
	_rfs=$(rootfs_path "$_name")
	_pm=$(pkgmgr_of "$_rfs") || die "no package manager in '$_name' (can't auto-install)"
	_depkgs=$(de_packages "$_pm" "$_de") || die "unknown desktop '$_de' (try: xfce, lxqt, lxde, mate)"
	_vnc=$(vnc_packages "$_pm")
	log_step "Installing the $_de desktop + VNC into '$_name'  (grab a coffee — this downloads a lot)"
	# shellcheck disable=SC2086
	cmd_pkg "$_name" $_depkgs $_vnc dbus || die "desktop install failed"
	_gui_vnc_scripts "$_rfs"
	_setup_vnc_pass "$_name" "${VNC_PASS:-achroot}"
	log_ok "Desktop '$_de' installed."
	log_info "start it with:  achroot gui $_name start"
}

# write a default VNC password (non-interactively) inside the chroot
_setup_vnc_pass() {
	_name=$1; _pass=$2
	run_in_chroot "$_name" "mkdir -p \$HOME/.vnc; \
		if command -v tigervncpasswd >/dev/null 2>&1; then PW=tigervncpasswd; \
		elif command -v vncpasswd >/dev/null 2>&1; then PW=vncpasswd; else PW=; fi; \
		[ -n \"\$PW\" ] && printf '%s\n' '$_pass' | \$PW -f > \$HOME/.vnc/passwd 2>/dev/null && chmod 600 \$HOME/.vnc/passwd; true" \
		>/dev/null 2>&1
	log_info "VNC password set to: ${_pass}  (override with VNC_PASS=... on setup)"
}

# --- start / stop ----------------------------------------------------------

_gui_start() {
	_name=$1; _mode=$2
	case "$_mode" in
		x11) run_in_chroot "$_name" '/usr/local/bin/gui-x11 &'; log_ok "X11 session launched (DISPLAY=:0)"; return ;;
	esac
	# vnc
	_rfs=$(rootfs_path "$_name")
	[ -x "$_rfs/usr/local/bin/vnc" ] || _gui_vnc_scripts "$_rfs"
	log_step "Starting VNC in '$_name'"
	run_in_chroot "$_name" 'vncserver -kill :1 >/dev/null 2>&1; rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null; export USER=root HOME=/root; /usr/local/bin/vnc' \
		|| { log_warn "VNC didn't start — is a server installed? Try: achroot gui $_name setup"; return 1; }
	cat >&2 <<EOF
${C_GRN}VNC is up.${C_RESET} Connect an Android VNC viewer (bVNC, AVNC, ...) to:
    ${C_BOLD}127.0.0.1:5901${C_RESET}     (display :1)
    password: ${C_BOLD}${VNC_PASS:-achroot}${C_RESET}
Stop it later with:  achroot gui $_name stop
EOF
}

_gui_stop() {
	_name=$1
	log_step "Stopping graphical session in '$_name'"
	run_in_chroot "$_name" 'vncserver -kill :1 >/dev/null 2>&1; pkill -x Xtigervnc 2>/dev/null; pkill -x Xvnc 2>/dev/null; pkill -x Xorg 2>/dev/null; true'
	log_ok "stopped"
}

# --- launcher scripts (written inside the rootfs) --------------------------

_write_in_chroot() {
	_rfs=$1; _path=$2
	mkdir -p "$_rfs$(dirname "$_path")" 2>/dev/null
	cat > "$_rfs$_path" || return 1
	chmod 755 "$_rfs$_path" 2>/dev/null
}

_gui_vnc_scripts() {
	_rfs=$1
	_write_in_chroot "$_rfs" /usr/local/bin/vnc <<'EOF'
#!/bin/sh
# achroot VNC launcher. Tweak DISP/GEOMETRY/DEPTH as you like.
: "${DISP:=1}"; : "${GEOMETRY:=1280x720}"; : "${DEPTH:=24}"
export HOME=/root USER=root
mkdir -p "$HOME/.vnc"
if command -v vncserver >/dev/null 2>&1; then
	exec vncserver ":$DISP" -geometry "$GEOMETRY" -depth "$DEPTH" -localhost yes
elif command -v tigervncserver >/dev/null 2>&1; then
	exec tigervncserver ":$DISP" -geometry "$GEOMETRY" -depth "$DEPTH" -localhost yes
elif command -v Xtigervnc >/dev/null 2>&1; then
	exec Xtigervnc ":$DISP" -geometry "$GEOMETRY" -depth "$DEPTH" -rfbport $((5900+DISP)) -localhost
else
	echo "No VNC server installed. Run on the host:  achroot gui <name> setup"; exit 1
fi
EOF
	_write_in_chroot "$_rfs" /root/.vnc/xstartup <<'EOF'
#!/bin/sh
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
export XDG_RUNTIME_DIR=/tmp/runtime-root; mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
[ -r /etc/X11/Xresources ] && xrdb /etc/X11/Xresources 2>/dev/null
if command -v startxfce4 >/dev/null 2>&1; then exec dbus-launch --exit-with-session startxfce4
elif command -v startlxqt >/dev/null 2>&1; then exec dbus-launch --exit-with-session startlxqt
elif command -v startlxde >/dev/null 2>&1; then exec dbus-launch --exit-with-session startlxde
elif command -v mate-session >/dev/null 2>&1; then exec dbus-launch --exit-with-session mate-session
elif command -v xterm >/dev/null 2>&1; then exec xterm
else exec /bin/sh; fi
EOF
}

_gui_vnc_help() {
	cat >&2 <<EOF
Wrote VNC launchers into '$1'. To use them:
  achroot gui $1 setup        # auto-install a desktop + VNC server
  achroot gui $1 start        # start it, then connect to 127.0.0.1:5901
EOF
}

_gui_x11() {
	_name=$1; _rfs=$2
	_write_in_chroot "$_rfs" /usr/local/bin/gui-x11 <<'EOF'
#!/bin/sh
# launch a desktop on an external X server (Termux:X11 on :0 by default)
: "${DISPLAY:=:0}"; export DISPLAY
export XDG_RUNTIME_DIR=/tmp/runtime-root; mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null
export PULSE_SERVER="${PULSE_SERVER:-tcp:127.0.0.1:4713}"
if command -v startxfce4 >/dev/null 2>&1; then exec dbus-launch --exit-with-session startxfce4
elif command -v startlxqt >/dev/null 2>&1; then exec dbus-launch --exit-with-session startlxqt
elif command -v xterm >/dev/null 2>&1; then exec xterm
else echo "Install a desktop first:  achroot gui $0 setup"; exec /bin/sh; fi
EOF
	log_ok "wrote /usr/local/bin/gui-x11 inside '$_name'"
	cat >&2 <<EOF
${C_BOLD}Share the X socket${C_RESET} so the chroot can reach Termux:X11:
  achroot config set ACH_EXTRA_BINDS '\$PREFIX/tmp/.X11-unix:/tmp/.X11-unix'
  achroot stop $_name && achroot start $_name
Then:  achroot gui $_name start x11   (or inside: DISPLAY=:0 gui-x11)
EOF
}

_gui_audio() {
	_name=$1; _rfs=$2
	_write_in_chroot "$_rfs" /etc/profile.d/01-achroot-audio.sh <<'EOF'
# route audio to a PulseAudio server on the Android side (e.g. Termux pulseaudio)
export PULSE_SERVER="${PULSE_SERVER:-tcp:127.0.0.1:4713}"
EOF
	log_ok "audio routed to PULSE_SERVER=tcp:127.0.0.1:4713"
	cat >&2 <<EOF
On the Android/Termux side, start a TCP PulseAudio sink:
  pulseaudio --start --load="module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1" --exit-idle-time=-1
EOF
}
