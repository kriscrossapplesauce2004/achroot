# shellcheck shell=sh
# lib/mount.sh — bind/loop mount management with namespace awareness.
#
# Key Android insight: Magisk/KernelSU often place your su shell in a PRIVATE
# mount namespace. Mounts you make there are invisible elsewhere and disappear
# when the shell exits. We fix this transparently: when our namespace differs
# from init's and nsenter is available, we perform mounts AND the final chroot
# inside init's namespace (nsenter -t 1 -m). No --mount-master juggling needed.

# echo the command prefix needed to act in init's mount namespace (may be empty)
ns_prefix() {
	case "${ACH_GLOBAL_MOUNT:-auto}" in
		off|no|0|false) return 0 ;;
		on|yes|1|true)
			if have nsenter; then printf 'nsenter -t 1 -m --'; fi
			return 0 ;;
	esac
	# auto
	if have nsenter && mnt_ns_differs; then printf 'nsenter -t 1 -m --'; fi
}

# m CMD... — run a (privileged) command in the global mount namespace if needed
m() {
	# shellcheck disable=SC2046
	run $(ns_prefix) "$@"
}

# choose a mount binary (busybox mount is the most forgiving on Android)
_mount_bin() { first_of mount busybox || echo mount ; }

_do_mount() {
	# _do_mount <args...> — picks busybox if plain mount lacks features
	if have mount; then m mount "$@"; return $?; fi
	_bb=$(host_busybox) || die "no 'mount' or 'busybox' available"
	m "$_bb" mount "$@"
}

_do_umount() {
	if have umount; then m umount "$@"; return $?; fi
	_bb=$(host_busybox) || { m busybox umount "$@"; return $?; }
	m "$_bb" umount "$@"
}

# --- loop image support ----------------------------------------------------

# mount the rootfs.img (ext4 loop) onto the rootfs dir if this chroot uses
# image mode and it isn't already mounted.
ensure_image_mounted() {
	_name=$1
	[ "$(meta_get "$_name" mode 2>/dev/null)" = "image" ] || return 0
	_img=$(image_path "$_name"); _rfs=$(rootfs_path "$_name")
	[ -f "$_img" ] || die "image missing: $_img"
	mkdir -p "$_rfs"
	if _path_is_mounted "$_rfs"; then dbg "image already mounted at $_rfs"; return 0; fi
	log_info "mounting ext4 image -> $_rfs"
	_do_mount -o loop,rw "$_img" "$_rfs" 2>/dev/null \
		|| _do_mount -t ext4 -o loop,rw "$_img" "$_rfs" \
		|| die "failed to loop-mount $_img (need loop device + ext4 support)"
}

# --- helpers ---------------------------------------------------------------

# true if a path appears as a mountpoint in /proc/mounts
_path_is_mounted() {
	_rp=$(_realpath "$1")
	awk -v p="$_rp" '$2==p{f=1} END{exit f?0:1}' /proc/mounts 2>/dev/null
}

# list every mountpoint at or under a rootfs, deepest first (for clean umount)
chroot_mounts() {
	_rfs=$(_realpath "$(rootfs_path "$1")")
	awk -v base="$_rfs" '
		{ mp=$2 }
		mp==base || index(mp, base"/")==1 { print length(mp), mp }
	' /proc/mounts 2>/dev/null | sort -rn | cut -d' ' -f2-
}

# is the chroot "started" (its key API filesystems mounted)?
is_started() {
	_rfs=$(_realpath "$(rootfs_path "$1")")
	_path_is_mounted "$_rfs/proc" || _path_is_mounted "$_rfs/dev"
}

# --- the main mount routine ------------------------------------------------

mount_chroot() {
	_name=$1
	require_chroot "$_name"
	ensure_image_mounted "$_name"
	_rfs=$(rootfs_path "$_name")
	[ -d "$_rfs" ] || die "rootfs not found: $_rfs"

	# create the standard mountpoints inside the rootfs
	for _d in dev dev/pts dev/shm proc sys tmp; do
		mkdir -p "$_rfs/$_d" 2>/dev/null
	done

	# /dev (bind) — gives access to null, zero, urandom, ptmx, block devices...
	_path_is_mounted "$_rfs/dev" || _do_mount -o bind /dev "$_rfs/dev"
	# /dev/pts — pseudo terminals (so tmux, ssh, sudo, login work)
	if has_devpts; then
		_path_is_mounted "$_rfs/dev/pts" || \
			_do_mount -t devpts -o mode=0620,gid=5 devpts "$_rfs/dev/pts" 2>/dev/null || \
			_do_mount -o bind /dev/pts "$_rfs/dev/pts" 2>/dev/null || true
	fi
	# /dev/shm — POSIX shared memory (needed by many GUI apps / browsers)
	_path_is_mounted "$_rfs/dev/shm" || \
		_do_mount -t tmpfs -o mode=1777 tmpfs "$_rfs/dev/shm" 2>/dev/null || true
	# /proc
	_path_is_mounted "$_rfs/proc" || _do_mount -t proc proc "$_rfs/proc" 2>/dev/null \
		|| _do_mount -o bind /proc "$_rfs/proc"
	# /sys
	_path_is_mounted "$_rfs/sys" || _do_mount -o bind /sys "$_rfs/sys"
	# /sys/fs/selinux (some tools probe it)
	if [ -d /sys/fs/selinux ]; then
		mkdir -p "$_rfs/sys/fs/selinux" 2>/dev/null
		_path_is_mounted "$_rfs/sys/fs/selinux" || \
			_do_mount -o bind /sys/fs/selinux "$_rfs/sys/fs/selinux" 2>/dev/null || true
	fi

	# internal storage -> /sdcard inside the chroot
	if [ "${ACH_BIND_SDCARD:-on}" = "on" ]; then
		if _sd=$(detect_sdcard); then
			mkdir -p "$_rfs/sdcard" 2>/dev/null
			_path_is_mounted "$_rfs/sdcard" || _do_mount -o bind "$_sd" "$_rfs/sdcard" 2>/dev/null \
				&& dbg "bound $_sd -> /sdcard"
		fi
	fi
	# external storage / OTG -> /storage inside the chroot
	if [ "${ACH_BIND_EXTERNAL:-on}" = "on" ] && [ -d /storage ]; then
		mkdir -p "$_rfs/storage" 2>/dev/null
		_path_is_mounted "$_rfs/storage" || _do_mount -o bind /storage "$_rfs/storage" 2>/dev/null || true
	fi

	# user-defined extra binds:  src:dst[:ro]  (space-separated)
	for _spec in ${ACH_EXTRA_BINDS:-}; do
		_src=$(printf '%s' "$_spec" | cut -d: -f1)
		_dst=$(printf '%s' "$_spec" | cut -d: -f2)
		_ro=$(printf '%s'  "$_spec" | cut -d: -f3)
		[ -n "$_src" ] && [ -n "$_dst" ] || continue
		[ -e "$_src" ] || { log_warn "extra bind source missing: $_src"; continue; }
		mkdir -p "$_rfs$_dst" 2>/dev/null
		if ! _path_is_mounted "$_rfs$_dst"; then
			_do_mount -o bind "$_src" "$_rfs$_dst" 2>/dev/null || log_warn "bind failed: $_spec"
			[ "$_ro" = "ro" ] && _do_mount -o remount,ro,bind "$_rfs$_dst" 2>/dev/null
		fi
	done
}

umount_chroot() {
	_name=$1
	require_chroot "$_name"
	_any=0
	# deepest-first so children unmount before parents
	for _mp in $(chroot_mounts "$_name"); do
		_any=1
		if ! _do_umount "$_mp" 2>/dev/null; then
			# busy? try lazy detach so we never leave a wedged mount
			_do_umount -l "$_mp" 2>/dev/null || log_warn "could not unmount $_mp"
		fi
	done
	[ "$_any" = 0 ] && dbg "nothing mounted for $_name"
	# if image mode, the rootfs itself may still be loop-mounted; it's included
	# in chroot_mounts() above, so it's already handled.
	return 0
}
