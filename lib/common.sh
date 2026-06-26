# shellcheck shell=sh
# lib/common.sh — logging, colors, and small helpers shared by every module.
# POSIX sh only (must run under mksh / toybox sh / busybox ash on Android).

# ---------------------------------------------------------------------------
# Colors (auto-detected; honor ACH_COLOR=off and non-tty output)
# ---------------------------------------------------------------------------
_ach_setup_colors() {
	C_RESET='' C_DIM='' C_BOLD='' C_RED='' C_GRN='' C_YEL='' C_BLU='' C_CYN='' C_MAG=''
	case "${ACH_COLOR:-auto}" in
		off|no|0|false) return 0 ;;
	esac
	# only colorize when stderr is a terminal (logs go to stderr)
	[ -t 2 ] || { [ "${ACH_COLOR:-auto}" = "always" ] || return 0; }
	[ "${TERM:-dumb}" != "dumb" ] || return 0
	C_RESET=$(printf '\033[0m')
	C_DIM=$(printf '\033[2m')
	C_BOLD=$(printf '\033[1m')
	C_RED=$(printf '\033[31m')
	C_GRN=$(printf '\033[32m')
	C_YEL=$(printf '\033[33m')
	C_BLU=$(printf '\033[34m')
	C_MAG=$(printf '\033[35m')
	C_CYN=$(printf '\033[36m')
}
_ach_setup_colors

# ---------------------------------------------------------------------------
# Logging (everything goes to stderr so stdout stays machine-parseable)
# ---------------------------------------------------------------------------
log_step() { printf '%s\n' "${C_BOLD}${C_BLU}::${C_RESET} ${C_BOLD}$*${C_RESET}" >&2 ; }
log_info() { printf '%s\n' "${C_CYN}  ->${C_RESET} $*" >&2 ; }
log_ok()   { printf '%s\n' "${C_GRN}  ok${C_RESET} $*" >&2 ; }
log_warn() { printf '%s\n' "${C_YEL}warn${C_RESET} $*" >&2 ; }
log_err()  { printf '%s\n' "${C_RED}fail${C_RESET} $*" >&2 ; }
dbg()      { [ -n "${ACH_DEBUG:-}" ] && printf '%s\n' "${C_DIM}dbg  $*${C_RESET}" >&2 ; return 0 ; }

die() { log_err "$*"; exit 1 ; }

# ---------------------------------------------------------------------------
# Tiny helpers
# ---------------------------------------------------------------------------

# have CMD — is a command available?
have() { command -v "$1" >/dev/null 2>&1 ; }

# first_of CMD... — echo the first command that exists, return 1 if none
first_of() {
	for _c in "$@"; do
		if command -v "$_c" >/dev/null 2>&1; then printf '%s\n' "$_c"; return 0; fi
	done
	return 1
}

is_root() { [ "$(id -u 2>/dev/null || echo 1)" = "0" ] ; }

# echo the best privilege-escalation command for the current host
root_hint() {
	_c="sh ${ACH_SELF:-achroot} ${ACH_ARGV:-doctor}"
	if have sudo; then printf 'sudo %s\n' "$_c"
	elif have doas; then printf 'doas %s\n' "$_c"
	elif have su; then printf "su -c '%s'\n" "$_c"
	else printf '(become root, then) %s\n' "$_c"; fi
}

need_root() {
	is_root && return 0
	die "this needs root. Re-run as root, e.g.:  $(root_hint)"
}

# run CMD... — log then execute (honors ACH_DRYRUN)
run() {
	dbg "run: $*"
	if [ -n "${ACH_DRYRUN:-}" ]; then
		printf '%s\n' "${C_DIM}would run:${C_RESET} $*" >&2
		return 0
	fi
	"$@"
}

# confirm "question" — yes/no prompt, auto-yes when ACH_YES set or no tty
confirm() {
	[ -n "${ACH_YES:-}" ] && return 0
	if [ ! -t 0 ]; then
		log_warn "no terminal for prompt; assuming NO for: $1 (use --yes to auto-confirm)"
		return 1
	fi
	printf '%s %s' "${C_YEL}??${C_RESET}" "$1 [y/N] " >&2
	read -r _ans || return 1
	case "$_ans" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

# ask "prompt" "default" — read a line with a default; echoes result
ask() {
	_q=$1; _def=${2:-}
	if [ ! -t 0 ]; then printf '%s\n' "$_def"; return 0; fi
	if [ -n "$_def" ]; then printf '%s [%s] ' "${C_CYN}>>${C_RESET} $_q" "$_def" >&2
	else printf '%s ' "${C_CYN}>>${C_RESET} $_q" >&2; fi
	read -r _a || _a=
	[ -z "$_a" ] && _a=$_def
	printf '%s\n' "$_a"
}

# human-readable byte count from a number of bytes
human_bytes() {
	_b=${1:-0}
	awk -v b="$_b" 'BEGIN{
		split("B KiB MiB GiB TiB PiB", u, " ");
		i=1; while (b>=1024 && i<6){ b/=1024; i++ }
		if (i==1) printf("%d %s", b, u[i]); else printf("%.1f %s", b, u[i]);
	}' 2>/dev/null || printf '%s B' "$_b"
}

# free space in bytes for a given path's filesystem
free_bytes() {
	_p=$1
	# df -k is the most portable; column positions vary, so grab the 4th-from-end-ish.
	df -k "$_p" 2>/dev/null | awk 'NR>1{print $(NF-2)*1024; exit}' 2>/dev/null || echo 0
}

# a writable scratch dir for downloads/temp work
ach_tmpdir() {
	_t="${ACH_BASE:-/data/local/achroot}/tmp"
	mkdir -p "$_t" 2>/dev/null
	printf '%s\n' "$_t"
}

# trim leading/trailing whitespace from $1
trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' ; }

# getprop wrapper that never fails
gp() { getprop "$1" 2>/dev/null || true ; }

# join the rest of "$@" after the first arg with that arg as separator (unused-safe)
# (kept minimal; modules use it for PATH-ish lists)
