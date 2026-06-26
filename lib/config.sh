# shellcheck shell=sh
# lib/config.sh — configuration defaults, persistence, and path helpers.

# Default base directory. /data is the only large, exec-capable area on most
# Android devices, and survives reboots. Overridable via $ACH_BASE / --base / config.
_ach_default_base() {
	for _b in /data/local/achroot /data/achroot /data/local/tmp/achroot; do
		_d=$(dirname "$_b")
		if [ -d "$_d" ] && [ -w "$_d" ] 2>/dev/null; then printf '%s\n' "$_b"; return 0; fi
	done
	printf '%s\n' "/data/local/achroot"
}

ach_set_defaults() {
	: "${ACH_BASE:=$(_ach_default_base)}"
	ACH_DISTROS="$ACH_BASE/distros"
	ACH_LOGDIR="$ACH_BASE/logs"
	# Behavior knobs (config file or env can override)
	: "${ACH_GLOBAL_MOUNT:=auto}"   # auto|on|off  -> mount in init's namespace via nsenter
	: "${ACH_BIND_SDCARD:=on}"      # bind internal storage into the chroot
	: "${ACH_SDCARD_SRC:=}"         # autodetected if empty
	: "${ACH_BIND_EXTERNAL:=on}"    # bind /storage (external SD / usb-otg) if present
	: "${ACH_EXTRA_BINDS:=}"        # space-separated  src:dst[:ro]  list
	: "${ACH_DNS:=auto}"            # auto|<ip>[ <ip>...]
	: "${ACH_HOSTNAME:=localhost}"
	: "${ACH_DEFAULT_SHELL:=}"      # empty -> autodetect inside rootfs
	: "${ACH_MANAGE_SELINUX:=ask}"  # ask|auto|off  -> set permissive while mounting
	: "${ACH_COLOR:=auto}"
}

ach_config_file() { printf '%s\n' "${ACH_CONFIG:-$ACH_BASE/config}" ; }

load_config() {
	ach_set_defaults
	_cf=$(ach_config_file)
	if [ -f "$_cf" ]; then
		dbg "loading config $_cf"
		# config is a sourced sh fragment of KEY=VALUE lines
		# shellcheck disable=SC1090
		. "$_cf"
	fi
	# Recompute derived paths in case ACH_BASE changed in the file.
	ACH_DISTROS="$ACH_BASE/distros"
	ACH_LOGDIR="$ACH_BASE/logs"
}

save_config() {
	_cf=$(ach_config_file)
	mkdir -p "$(dirname "$_cf")" 2>/dev/null || die "cannot create $(dirname "$_cf")"
	{
		printf '# achroot config — edit freely (sh KEY=VALUE syntax)\n'
		printf 'ACH_BASE=%s\n'           "$(_q "$ACH_BASE")"
		printf 'ACH_GLOBAL_MOUNT=%s\n'   "$(_q "$ACH_GLOBAL_MOUNT")"
		printf 'ACH_BIND_SDCARD=%s\n'    "$(_q "$ACH_BIND_SDCARD")"
		printf 'ACH_SDCARD_SRC=%s\n'     "$(_q "$ACH_SDCARD_SRC")"
		printf 'ACH_BIND_EXTERNAL=%s\n'  "$(_q "$ACH_BIND_EXTERNAL")"
		printf 'ACH_EXTRA_BINDS=%s\n'    "$(_q "$ACH_EXTRA_BINDS")"
		printf 'ACH_DNS=%s\n'            "$(_q "$ACH_DNS")"
		printf 'ACH_HOSTNAME=%s\n'       "$(_q "$ACH_HOSTNAME")"
		printf 'ACH_DEFAULT_SHELL=%s\n'  "$(_q "$ACH_DEFAULT_SHELL")"
		printf 'ACH_MANAGE_SELINUX=%s\n' "$(_q "$ACH_MANAGE_SELINUX")"
		printf 'ACH_COLOR=%s\n'          "$(_q "$ACH_COLOR")"
	} > "$_cf" || die "cannot write $_cf"
	log_ok "wrote config: $_cf"
}

# shell-quote a value for the config file
_q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ; }

# --- per-chroot path & metadata helpers ------------------------------------

chroot_dir()   { printf '%s\n' "$ACH_DISTROS/$1" ; }
rootfs_path()  { printf '%s\n' "$ACH_DISTROS/$1/rootfs" ; }
image_path()   { printf '%s\n' "$ACH_DISTROS/$1/rootfs.img" ; }
meta_path()    { printf '%s\n' "$ACH_DISTROS/$1/meta" ; }

chroot_exists() { [ -d "$(chroot_dir "$1")" ] ; }

require_chroot() {
	[ -n "$1" ] || die "no chroot name given"
	chroot_exists "$1" || die "no such chroot '$1' (try: achroot installed)"
}

meta_get() {
	_mf=$(meta_path "$1")
	[ -f "$_mf" ] || return 1
	# lines look like  key=value
	_v=$(grep "^$2=" "$_mf" 2>/dev/null | head -1 | cut -d= -f2-)
	[ -n "$_v" ] || return 1
	printf '%s\n' "$_v"
}

meta_set() {
	_mf=$(meta_path "$1"); _k=$2; _val=$3
	mkdir -p "$(dirname "$_mf")" 2>/dev/null
	touch "$_mf"
	if grep -q "^$_k=" "$_mf" 2>/dev/null; then
		# rewrite the key (sed in-place isn't universal on Android; do it safely)
		_tmp="$_mf.tmp.$$"
		grep -v "^$_k=" "$_mf" > "$_tmp"
		printf '%s=%s\n' "$_k" "$_val" >> "$_tmp"
		mv "$_tmp" "$_mf"
	else
		printf '%s=%s\n' "$_k" "$_val" >> "$_mf"
	fi
}

# --- `achroot config` subcommand -------------------------------------------
cmd_config() {
	_action=${1:-show}
	case "$_action" in
		show|"")
			log_step "Active configuration"
			printf '  config file : %s%s\n' "$(ach_config_file)" \
				"$( [ -f "$(ach_config_file)" ] && echo '' || echo '  (not yet written — using defaults)')"
			printf '  ACH_BASE          = %s\n' "$ACH_BASE"
			printf '  ACH_GLOBAL_MOUNT  = %s\n' "$ACH_GLOBAL_MOUNT"
			printf '  ACH_BIND_SDCARD   = %s\n' "$ACH_BIND_SDCARD"
			printf '  ACH_SDCARD_SRC    = %s\n' "${ACH_SDCARD_SRC:-(auto)}"
			printf '  ACH_BIND_EXTERNAL = %s\n' "$ACH_BIND_EXTERNAL"
			printf '  ACH_EXTRA_BINDS   = %s\n' "${ACH_EXTRA_BINDS:-(none)}"
			printf '  ACH_DNS           = %s\n' "$ACH_DNS"
			printf '  ACH_HOSTNAME      = %s\n' "$ACH_HOSTNAME"
			printf '  ACH_DEFAULT_SHELL = %s\n' "${ACH_DEFAULT_SHELL:-(auto)}"
			printf '  ACH_MANAGE_SELINUX= %s\n' "$ACH_MANAGE_SELINUX"
			;;
		init|write) save_config ;;
		set)
			shift
			[ -n "${1:-}" ] || die "usage: achroot config set KEY VALUE"
			_key=$1; shift; _val="$*"
			# only allow known keys
			case "$_key" in
				ACH_BASE|ACH_GLOBAL_MOUNT|ACH_BIND_SDCARD|ACH_SDCARD_SRC|ACH_BIND_EXTERNAL|ACH_EXTRA_BINDS|ACH_DNS|ACH_HOSTNAME|ACH_DEFAULT_SHELL|ACH_MANAGE_SELINUX|ACH_COLOR)
					eval "$_key=\$_val"; save_config ;;
				*) die "unknown config key '$_key'" ;;
			esac
			;;
		edit)
			_cf=$(ach_config_file)
			[ -f "$_cf" ] || save_config
			_ed=$(first_of "${EDITOR:-}" nano vi vim) || die "no editor found; set \$EDITOR"
			"$_ed" "$_cf" ;;
		path) ach_config_file ;;
		*) die "usage: achroot config [show|init|set KEY VALUE|edit|path]" ;;
	esac
}
