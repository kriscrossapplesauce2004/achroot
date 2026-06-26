#!/bin/sh
# achroot bootstrap installer.
#
#   curl -fsSL https://raw.githubusercontent.com/kriscrossapplesauce2004/achroot/master/get.sh | sh
#
# Detects your environment (root / sudo / doas / su, Android vs Linux vs Termux,
# downloader, tar), fetches achroot, installs it somewhere persistent + executable,
# and drops a launcher on your PATH. Non-interactive; tweak via env vars below.
#
#   ACHROOT_DIR    where to install      (default: /data/local/achroot-src on Android)
#   ACHROOT_BRANCH branch/tag to fetch   (default: master)
#   ACHROOT_TOKEN  GitHub token          (only needed if the repo is private)
#   ACHROOT_NO_PATH=1   skip creating the PATH launcher
set -u

REPO="kriscrossapplesauce2004/achroot"
BRANCH="${ACHROOT_BRANCH:-master}"
ARCHIVE_URL="https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH"

# --- pretty output ---------------------------------------------------------
if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then
	c_r=$(printf '\033[0m'); c_b=$(printf '\033[1m'); c_g=$(printf '\033[32m')
	c_y=$(printf '\033[33m'); c_c=$(printf '\033[36m'); c_red=$(printf '\033[31m')
else c_r=; c_b=; c_g=; c_y=; c_c=; c_red=; fi
step() { printf '%s\n' "${c_b}${c_c}::${c_r} ${c_b}$*${c_r}" >&2 ; }
info() { printf '   %s\n' "$*" >&2 ; }
ok()   { printf '%s %s\n' "${c_g}ok${c_r}" "$*" >&2 ; }
warn() { printf '%s %s\n' "${c_y}warn${c_r}" "$*" >&2 ; }
die()  { printf '%s %s\n' "${c_red}fail${c_r}" "$*" >&2 ; exit 1 ; }

have() { command -v "$1" >/dev/null 2>&1 ; }
is_root() { [ "$(id -u 2>/dev/null || echo 1)" = 0 ] ; }

printf '%s\n' "${c_b}achroot installer${c_r} — chroot manager for rooted Android" >&2

# --- privilege detection (sudo / doas / su / already-root) -----------------
ELEVATE=none
detect_elevate() {
	if is_root; then ELEVATE=none; return; fi
	if have sudo; then ELEVATE=sudo; return; fi
	if have doas; then ELEVATE=doas; return; fi
	if have su;   then ELEVATE=su;   return; fi
	ELEVATE=none
}
detect_elevate

# single-quote each argument so it survives `su -c "<string>"`
_qargs() {
	_s=''
	for _a in "$@"; do
		_e=$(printf '%s' "$_a" | sed "s/'/'\\\\''/g")
		_s="$_s '$_e'"
	done
	printf '%s' "$_s"
}

# R CMD... — run a command as root using whatever we detected
R() {
	case "$ELEVATE" in
		none) "$@" ;;
		sudo) sudo "$@" ;;
		doas) doas "$@" ;;
		su)   su -c "$(_qargs "$@")" ;;
	esac
}

is_root && info "running as root"

# --- environment detection -------------------------------------------------
OS=linux; FLAVOR=generic
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-/nonexistent}" ] && case "${PREFIX:-}" in */com.termux/*) true ;; *) false ;; esac; then
	FLAVOR=termux; OS=android
elif [ -d /system/bin ] && have getprop; then
	OS=android; FLAVOR=android
fi
ARCH=$(uname -m 2>/dev/null || echo unknown)
info "environment: ${c_b}$OS${c_r} ($FLAVOR), arch $ARCH"
[ "$OS" = android ] && ! is_root && [ "$ELEVATE" = none ] && \
	warn "achroot needs root to run on Android — install will succeed, but run it from a root shell"

# --- prerequisites ---------------------------------------------------------
DL=""
if have curl; then DL=curl; elif have wget; then DL=wget; else
	die "need curl or wget (none found). On Termux/Android: pkg install curl"
fi
have tar  || die "need tar (try: pkg install tar, or install busybox/toybox)"
have gzip || have busybox || warn "no gzip found; relying on tar's built-in gzip support"

fetch() { # fetch URL DEST
	_u=$1; _d=$2
	_auth=""; [ -n "${ACHROOT_TOKEN:-}" ] && _auth="Authorization: Bearer $ACHROOT_TOKEN"
	if [ "$DL" = curl ]; then
		# clean progress bar on a tty, otherwise quiet (but still report errors)
		if [ -t 2 ]; then _p="-#"; else _p="-sS"; fi
		if [ -n "$_auth" ]; then curl -fL $_p --retry 3 -H "$_auth" -o "$_d" "$_u"
		else curl -fL $_p --retry 3 -o "$_d" "$_u"; fi
	else
		if [ -n "$_auth" ]; then wget --header="$_auth" -O "$_d" "$_u"
		else wget -O "$_d" "$_u"; fi
	fi
}

# --- choose install dir ----------------------------------------------------
choose_dest() {
	[ -n "${ACHROOT_DIR:-}" ] && { printf '%s\n' "$ACHROOT_DIR"; return; }
	if [ "$FLAVOR" = termux ]; then printf '%s\n' "$HOME/.local/share/achroot"; return; fi
	# Android: /data is persistent + executable; needs root (we have it or can elevate)
	if [ "$OS" = android ] && { is_root || [ "$ELEVATE" != none ]; }; then
		printf '%s\n' "/data/local/achroot-src"; return
	fi
	if [ -d /data/local ] && { is_root || [ "$ELEVATE" != none ]; }; then
		printf '%s\n' "/data/local/achroot-src"; return
	fi
	printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/achroot"
}
DEST=$(choose_dest)

# Only escalate privileges when the install location actually requires it.
# (On an Android root shell you're already root; on Linux/Termux the default
#  dir is user-writable, so no sudo prompt is triggered.)
need_priv_for() {
	_d=$1
	while [ ! -e "$_d" ] && [ "$_d" != / ] && [ "$_d" != . ]; do _d=$(dirname "$_d"); done
	[ -w "$_d" ] && return 1 || return 0
}
USE_ROOT=0
if need_priv_for "$DEST"; then
	if is_root; then USE_ROOT=0
	elif [ "$ELEVATE" != none ]; then USE_ROOT=1; info "using ${c_b}$ELEVATE${c_r} (need root to write $DEST)"
	else die "need root to write $DEST and no sudo/doas/su found — set ACHROOT_DIR to a writable path, or run as root"
	fi
fi
maybe_root() { if [ "$USE_ROOT" = 1 ]; then R "$@"; else "$@"; fi ; }

# --- download + extract ----------------------------------------------------
step "Downloading achroot ($BRANCH)"
TMP="${TMPDIR:-/tmp}/achroot-install.$$"
mkdir -p "$TMP" 2>/dev/null || { TMP="./.achroot-install.$$"; mkdir -p "$TMP"; }
trap 'rm -rf "$TMP"' EXIT INT TERM
fetch "$ARCHIVE_URL" "$TMP/src.tar.gz" || die "download failed ($ARCHIVE_URL).  If the repo is private, set ACHROOT_TOKEN."
ok "downloaded $(wc -c < "$TMP/src.tar.gz" 2>/dev/null || echo '?') bytes"

step "Installing to $DEST"
tar -xzf "$TMP/src.tar.gz" -C "$TMP" || die "extraction failed (corrupt download?)"
SRCDIR=$(ls -d "$TMP"/${REPO##*/}-* 2>/dev/null | head -1)
[ -d "$SRCDIR" ] || SRCDIR=$(find "$TMP" -maxdepth 1 -type d -name 'achroot-*' 2>/dev/null | head -1)
[ -d "$SRCDIR" ] && [ -f "$SRCDIR/achroot" ] || die "unexpected archive layout"

if [ -d "$DEST/lib" ]; then info "updating existing install"; fi
maybe_root mkdir -p "$DEST" || die "could not create $DEST"
maybe_root cp -a "$SRCDIR"/. "$DEST"/ || die "could not copy files into $DEST (permissions?)"
maybe_root chmod 755 "$DEST/achroot" "$DEST/install.sh" "$DEST/get.sh" 2>/dev/null
ok "files installed in $DEST"

# --- launcher on PATH ------------------------------------------------------
LAUNCHER=""
if [ "${ACHROOT_NO_PATH:-0}" != 1 ]; then
	step "Creating launcher on PATH"
	if maybe_root sh "$DEST/install.sh" >/tmp/achroot-install.log 2>&1; then
		LAUNCHER=$(grep -m1 'Installed launcher:' /tmp/achroot-install.log 2>/dev/null | sed 's/.*: //')
		ok "launcher created${LAUNCHER:+: $LAUNCHER}"
	else
		warn "couldn't place a launcher on PATH (that's fine — use the full path below)"
	fi
	rm -f /tmp/achroot-install.log 2>/dev/null
fi

# --- verify ----------------------------------------------------------------
if sh "$DEST/achroot" version >/dev/null 2>&1; then
	VER=$(sh "$DEST/achroot" version 2>/dev/null)
	ok "installed: ${c_b}$VER${c_r}"
else
	warn "installed, but a quick self-check didn't run cleanly — try it manually below"
fi

# --- next steps ------------------------------------------------------------
RUN="sh $DEST/achroot"
[ -n "$LAUNCHER" ] && case ":$PATH:" in *":$(dirname "$LAUNCHER"):"*) RUN="achroot" ;; esac

printf '\n' >&2
step "Done. Next steps"
if [ "$OS" = android ] && ! is_root; then
	info "open your ${c_b}root shell${c_r} (su), then:"
	info "  ${c_b}$RUN doctor${c_r}            # scan the device"
	info "  ${c_b}$RUN install alpine${c_r}    # tiny first test"
	info "  ${c_b}$RUN enter alpine${c_r}"
else
	info "  ${c_b}$RUN doctor${c_r}            # scan the device"
	info "  ${c_b}$RUN install debian${c_r}    # download + unpack a distro"
	info "  ${c_b}$RUN enter debian${c_r}"
fi
[ "$RUN" = "achroot" ] || info "(add $(dirname "${LAUNCHER:-/data/local/bin/x}") to PATH to drop the 'sh ... ' prefix)"
