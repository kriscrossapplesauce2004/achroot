# shellcheck shell=sh
# lib/snapshot.sh — backup / restore / clone a chroot as a compressed tarball.

# choose the best compressor available, preferring fast+small
_pick_compressor() {
	if have zstd; then echo "zstd zst"; return; fi
	if have xz;   then echo "xz xz"; return; fi
	if have gzip; then echo "gzip gz"; return; fi
	echo "cat tar"
}

cmd_backup() {
	need_root
	_name=$1; _out=$2
	require_chroot "$_name"
	# don't back up a live, bind-mounted rootfs — we'd recurse into /dev, /sdcard!
	if is_started "$_name"; then
		log_warn "'$_name' is mounted; stopping it so the backup excludes bind mounts"
		cmd_stop "$_name"
	fi
	set -- $(_pick_compressor); _comp=$1; _ext=$2
	: "${_out:=$ACH_BASE/${_name}-$(date +%Y%m%d-%H%M%S).tar.$_ext}"
	_rfs=$(rootfs_path "$_name")
	log_step "Backing up '$_name' -> $_out"
	if [ "$_comp" = cat ]; then
		( cd "$_rfs" && tar -cpf - . ) > "$_out" || die "backup failed"
	else
		( cd "$_rfs" && tar -cpf - . ) | $_comp -c > "$_out" || die "backup failed"
	fi
	log_ok "backup written: $_out ($(human_bytes "$(wc -c < "$_out" 2>/dev/null || echo 0)"))"
}

cmd_restore() {
	need_root
	_file=$1; _name=$2
	[ -f "$_file" ] || die "usage: achroot restore <backup.tar.*> <name>"
	[ -n "$_name" ] || die "give a target name: achroot restore $_file <name>"
	chroot_exists "$_name" && die "'$_name' already exists; remove it first"
	cmd_import "$_file" "$_name"   # import handles all the compression formats
	meta_set "$_name" distro restored
	log_ok "restored '$_name' from $_file"
}

cmd_clone() {
	need_root
	_src=$1; _dst=$2
	require_chroot "$_src"
	[ -n "$_dst" ] || die "usage: achroot clone <src> <dst>"
	chroot_exists "$_dst" && die "'$_dst' already exists"
	is_started "$_src" && cmd_stop "$_src"
	log_step "Cloning '$_src' -> '$_dst'"
	mkdir -p "$(chroot_dir "$_dst")"
	( cd "$(rootfs_path "$_src")" && tar -cpf - . ) \
		| ( mkdir -p "$(rootfs_path "$_dst")" && cd "$(rootfs_path "$_dst")" && tar -xpf - ) \
		|| die "clone failed"
	cp "$(meta_path "$_src")" "$(meta_path "$_dst")" 2>/dev/null
	meta_set "$_dst" created "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
	log_ok "cloned to '$_dst'"
}
