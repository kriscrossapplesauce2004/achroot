# shellcheck shell=sh
# lib/distros.sh — distro catalog, rootfs URL resolution, download, install,
# import, remove, and ext4-image creation.

# --- HTTP helpers ----------------------------------------------------------

http_get() {
	# fetch a URL to stdout (used for directory-listing discovery)
	_url=$1
	if have curl; then curl -fsSL --max-time 30 "$_url" 2>/dev/null; return $?; fi
	if have wget; then wget -qO- -T30 "$_url" 2>/dev/null; return $?; fi
	return 1
}

http_download() {
	# http_download URL DEST — with a progress bar where possible
	_url=$1; _dest=$2
	log_info "downloading: $_url"
	if have curl; then
		if [ -t 2 ]; then run curl -fL --retry 3 --connect-timeout 20 -# -o "$_dest" "$_url"
		else run curl -fsL --retry 3 --connect-timeout 20 -o "$_dest" "$_url"; fi
		return $?
	fi
	if have wget; then
		if [ -t 2 ]; then run wget -O "$_dest" -T30 -t3 "$_url"
		else run wget -qO "$_dest" -T30 -t3 "$_url"; fi
		return $?
	fi
	die "need curl or wget to download (none found)"
}

# --- arch mapping ----------------------------------------------------------

# images.linuxcontainers.org / Debian-style arch names
lxc_arch() {
	case "$(detect_arch)" in
		arm64) echo arm64 ;; armhf) echo armhf ;;
		amd64) echo amd64 ;; i386) echo i386 ;;
		*) detect_arch ;;
	esac
}

# --- source resolvers: each echoes "<url> <decompressor>" ------------------
# decompressor is one of: gz xz zst

# given a .../default/ index URL, echo "<url> xz" for the newest build, or fail
_lxc_build_url() {
	_b=$1
	_l=$(http_get "$_b") || return 1
	# directory autoindex lists build dirs like  20240607_07%3A42/
	_h=$(printf '%s\n' "$_l" \
		| grep -oE 'href="20[0-9]{6}_[0-9A-Za-z:%]+/"' \
		| sed 's/^href="//; s/"$//' | sort | tail -1)
	[ -n "$_h" ] || return 1
	printf '%s %s\n' "${_b}${_h}rootfs.tar.xz" xz
}

# images.linuxcontainers.org — universal source (debian, ubuntu, fedora, ...)
src_lxc() {
	_distro=$1; _release=$2; _arch=$(lxc_arch)
	# 1) try the requested release
	if _u=$(_lxc_build_url "https://images.linuxcontainers.org/images/$_distro/$_release/$_arch/default/"); then
		printf '%s\n' "$_u"; return 0
	fi
	# 2) fallback: auto-pick the newest release that exists for this distro
	#    (future-proofs numeric releases like fedora/rocky when versions bump)
	dbg "lxc: '$_release' not found for $_distro/$_arch; auto-detecting newest release"
	_rel2=$(http_get "https://images.linuxcontainers.org/images/$_distro/" \
		| grep -oE 'href="[^"/]+/"' | sed 's/^href="//; s|/"$||' \
		| grep -v '^\.' | sort -V | tail -1)
	[ -n "$_rel2" ] || return 1
	_lxc_build_url "https://images.linuxcontainers.org/images/$_distro/$_rel2/$_arch/default/"
}

# Arch Linux ARM (stable "latest" tarballs; best for ARM phones)
src_arch() {
	case "$(detect_arch)" in
		arm64) printf '%s %s\n' "http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz" gz ;;
		armhf) printf '%s %s\n' "http://os.archlinuxarm.org/os/ArchLinuxARM-armv7-latest.tar.gz" gz ;;
		amd64|i386) src_lxc archlinux current ;;  # x86 -> LXC image
		*) return 1 ;;
	esac
}

# Kali NetHunter rootfs — purpose-built for running on Android
src_kali() {
	case "$(detect_arch)" in
		arm64) _a=arm64 ;; armhf) _a=armhf ;; amd64) _a=amd64 ;; i386) _a=i386 ;;
		*) return 1 ;;
	esac
	printf '%s %s\n' "https://kali.download/nethunter-images/current/rootfs/kalifs-$_a-minimal.tar.xz" xz
}

# Alpine minirootfs — tiny (~3 MB); we discover the current version from the CDN
src_alpine() {
	case "$(detect_arch)" in
		arm64) _a=aarch64 ;; armhf) _a=armv7 ;; amd64) _a=x86_64 ;; i386) _a=x86 ;;
		*) return 1 ;;
	esac
	_base="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$_a/"
	_file=$(http_get "$_base" \
		| grep -oE "alpine-minirootfs-[0-9.]+-$_a\.tar\.gz" | sort -V | tail -1)
	[ -n "$_file" ] || return 1
	printf '%s %s\n' "${_base}${_file}" gz
}

# Void Linux rootfs
src_void() {
	case "$(detect_arch)" in
		arm64) _a=aarch64 ;; armhf) _a=armv7l ;; amd64) _a=x86_64 ;; i386) _a=i686 ;;
		*) return 1 ;;
	esac
	_base="https://repo-default.voidlinux.org/live/current/"
	_file=$(http_get "$_base" \
		| grep -oE "void-$_a-ROOTFS-[0-9]+\.tar\.xz" | sort | tail -1)
	[ -n "$_file" ] || return 1
	printf '%s %s\n' "${_base}${_file}" xz
}

# --- the catalog -----------------------------------------------------------
# distro_resolve ID [RELEASE]  ->  echoes "<url> <decompressor>"

distro_resolve() {
	_id=$1; _rel=$2
	case "$_id" in
		alpine)   src_alpine ;;
		ubuntu)   src_lxc ubuntu     "${_rel:-noble}" ;;
		debian)   src_lxc debian      "${_rel:-bookworm}" ;;
		devuan)   src_lxc devuan       "${_rel:-daedalus}" ;;
		kali)     src_kali ;;
		arch)     src_arch ;;
		fedora)   src_lxc fedora      "${_rel:-43}" ;;
		void)     src_void ;;
		rocky)    src_lxc rockylinux  "${_rel:-9}" ;;
		alma)     src_lxc almalinux   "${_rel:-9}" ;;
		opensuse) src_lxc opensuse    "${_rel:-tumbleweed}" ;;
		gentoo)   src_lxc gentoo      "${_rel:-current}" ;;
		mint)     src_lxc mint        "${_rel:-virginia}" ;;
		*) return 2 ;;
	esac
}

distro_list() {
	log_step "Available distros  (host arch: $(detect_arch))"
	printf '  %-10s %-28s %s\n' ID DEFAULT-RELEASE SOURCE
	printf '  %-10s %-28s %s\n' alpine    latest-stable          "Alpine CDN (tiny, musl)"
	printf '  %-10s %-28s %s\n' ubuntu    noble                  "linuxcontainers.org"
	printf '  %-10s %-28s %s\n' debian    bookworm               "linuxcontainers.org"
	printf '  %-10s %-28s %s\n' devuan    daedalus               "linuxcontainers.org"
	printf '  %-10s %-28s %s\n' kali      current                "Kali NetHunter (Android-tuned)"
	printf '  %-10s %-28s %s\n' arch      latest                 "ArchLinuxARM / Arch bootstrap"
	printf '  %-10s %-28s %s\n' fedora    43                     "linuxcontainers.org"
	printf '  %-10s %-28s %s\n' void      current                "Void repo (xbps)"
	printf '  %-10s %-28s %s\n' rocky     9                      "linuxcontainers.org"
	printf '  %-10s %-28s %s\n' alma      9                      "linuxcontainers.org"
	printf '  %-10s %-28s %s\n' opensuse  tumbleweed             "linuxcontainers.org"
	printf '  %-10s %-28s %s\n' gentoo    current                "linuxcontainers.org"
	printf '  %-10s %-28s %s\n' mint      virginia               "linuxcontainers.org"
	printf '\n'
	printf '  install:  achroot install <id>[:release] [name]\n'
	printf '  example:  achroot install debian        # -> chroot named "debian"\n'
	printf '            achroot install ubuntu:jammy my-ubuntu\n'
}

# --- extraction ------------------------------------------------------------

_extract_rootfs() {
	# _extract_rootfs FILE DECOMP DESTDIR
	_file=$1; _decomp=$2; _dest=$3
	mkdir -p "$_dest"
	log_info "extracting into $_dest"
	have tar || die "tar not found (install busybox or toybox)"
	case "$_decomp" in
		gz)
			if have gzip; then gzip -dc "$_file" | run tar -xp -C "$_dest" -f -
			else run tar -xpzf "$_file" -C "$_dest"; fi ;;
		xz)
			if have xz; then xz -dc "$_file" | run tar -xp -C "$_dest" -f -
			elif tar --help 2>&1 | grep -q -- '-J'; then run tar -xpJf "$_file" -C "$_dest"
			else die "no xz decompressor (install xz or a busybox with xz support)"; fi ;;
		zst)
			have zstd || die "no zstd decompressor available"
			zstd -dc "$_file" | run tar -xp -C "$_dest" -f - ;;
		*) # let tar autodetect
			run tar -xpf "$_file" -C "$_dest" ;;
	esac
}

# many tarballs (Arch ARM, some LXC) wrap everything; if rootfs ended up one
# level deep, flatten it.
_flatten_if_nested() {
	_dest=$1
	[ -d "$_dest/bin" ] || [ -d "$_dest/usr" ] || [ -d "$_dest/etc" ] && return 0
	_sub=$(find "$_dest" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -2)
	_count=$(printf '%s\n' "$_sub" | grep -c . )
	if [ "$_count" = 1 ] && [ -d "$_sub/bin" -o -d "$_sub/usr" ]; then
		log_info "flattening nested rootfs ($_sub)"
		(cd "$_sub" && tar -cpf - .) | (cd "$_dest" && tar -xpf -) 2>/dev/null
		rm -rf "$_sub"
	fi
}

# --- install ---------------------------------------------------------------

cmd_install() {
	need_root
	_spec=$1; _name=$2
	[ -n "$_spec" ] || { distro_list; exit 1; }
	# split id:release
	_id=$(printf '%s' "$_spec" | cut -d: -f1)
	_rel=$(printf '%s' "$_spec" | cut -s -d: -f2)
	: "${_name:=$_id}"

	chroot_exists "$_name" && die "chroot '$_name' already exists (remove it first, or pick another name)"

	log_step "Resolving rootfs for '$_id'${_rel:+:$_rel}"
	net_reachable || log_warn "no internet detected — download will likely fail"
	_res=$(distro_resolve "$_id" "$_rel")
	_rc=$?
	[ "$_rc" = 2 ] && die "unknown distro '$_id' (see: achroot list)"
	[ -n "$_res" ] || die "could not resolve a rootfs URL for '$_id' on arch $(detect_arch)"
	_url=$(printf '%s' "$_res" | awk '{print $1}')
	_decomp=$(printf '%s' "$_res" | awk '{print $2}')
	log_info "url: $_url"

	# storage sanity: directory rootfs needs a unix-capable, exec-able FS
	_cdir=$(chroot_dir "$_name")
	mkdir -p "$ACH_DISTROS" || die "cannot create $ACH_DISTROS"
	if ! fs_supports_unix "$ACH_DISTROS"; then
		log_warn "$ACH_DISTROS is on $(fs_type_of "$ACH_DISTROS"); it can't store unix perms/symlinks."
		log_warn "Use image mode instead:  achroot create-image $_name <size>  then  achroot install ..."
		confirm "Continue with a plain directory anyway (likely to break)?" || exit 1
	fi
	if is_noexec "$ACH_DISTROS"; then
		log_warn "$ACH_DISTROS is mounted noexec — binaries inside the chroot will NOT run."
		log_warn "Pick a different ACH_BASE (achroot config set ACH_BASE /data/local/achroot)."
		confirm "Continue anyway?" || exit 1
	fi

	_tmp=$(ach_tmpdir)
	_tarball="$_tmp/${_name}.rootfs"
	http_download "$_url" "$_tarball" || die "download failed"
	_sz=$(wc -c < "$_tarball" 2>/dev/null || echo 0)
	log_ok "downloaded $(human_bytes "$_sz")"

	mkdir -p "$_cdir"
	_rfs=$(rootfs_path "$_name")
	_extract_rootfs "$_tarball" "$_decomp" "$_rfs" || { rm -rf "$_cdir"; die "extraction failed"; }
	_flatten_if_nested "$_rfs"
	rm -f "$_tarball"

	# record metadata
	meta_set "$_name" distro  "$_id"
	meta_set "$_name" release "${_rel:-default}"
	meta_set "$_name" arch    "$(detect_arch)"
	meta_set "$_name" mode    "directory"
	meta_set "$_name" source  "$_url"
	meta_set "$_name" created "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"

	log_ok "installed '$_name' ($(du -sh "$_rfs" 2>/dev/null | cut -f1) on disk)"
	# foreign-arch heads-up
	_rootfs_arch_note "$_name"
	log_info "next:  achroot start $_name  &&  achroot enter $_name"
}

# warn (and offer binfmt) if the rootfs arch can't run natively
_rootfs_arch_note() {
	_harch=$(detect_arch)
	_darch=$(meta_get "$1" arch 2>/dev/null)
	# only relevant when user imported a foreign tarball; native installs match
	return 0
}

# --- import a local tarball ------------------------------------------------

cmd_import() {
	need_root
	_file=$1; _name=$2
	[ -f "$_file" ] || die "usage: achroot import <rootfs.tar[.gz|.xz|.zst]> <name>"
	[ -n "$_name" ] || die "give a name: achroot import $_file <name>"
	chroot_exists "$_name" && die "chroot '$_name' already exists"
	case "$_file" in
		*.tar.gz|*.tgz) _decomp=gz ;;
		*.tar.xz|*.txz) _decomp=xz ;;
		*.tar.zst)      _decomp=zst ;;
		*) _decomp=auto ;;
	esac
	_cdir=$(chroot_dir "$_name"); _rfs=$(rootfs_path "$_name")
	mkdir -p "$_cdir"
	_extract_rootfs "$_file" "$_decomp" "$_rfs" || { rm -rf "$_cdir"; die "extraction failed"; }
	_flatten_if_nested "$_rfs"
	meta_set "$_name" distro imported
	meta_set "$_name" arch "$(detect_arch)"
	meta_set "$_name" mode directory
	meta_set "$_name" source "$_file"
	meta_set "$_name" created "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
	log_ok "imported '$_name' from $_file"
}

# --- ext4 loop image (for FAT/exFAT SD cards or fixed-size sandboxes) -------

cmd_create_image() {
	need_root
	_name=$1; _size=$2
	[ -n "$_name" ] && [ -n "$_size" ] || die "usage: achroot create-image <name> <size, e.g. 4G>"
	chroot_exists "$_name" && die "chroot '$_name' already exists"
	_mkfs=$(first_of mkfs.ext4 mke2fs make_ext4fs) || \
		die "no ext4 formatter (mkfs.ext4/mke2fs/make_ext4fs) found on this device"
	_cdir=$(chroot_dir "$_name"); _img=$(image_path "$_name")
	mkdir -p "$_cdir" "$(rootfs_path "$_name")"
	log_step "Creating $_size ext4 image at $_img"
	# allocate
	if have truncate; then run truncate -s "$_size" "$_img"
	elif have fallocate; then run fallocate -l "$_size" "$_img"
	else die "need truncate or fallocate to allocate the image"; fi
	# format
	case "$_mkfs" in
		make_ext4fs) run make_ext4fs "$_img" ;;
		mkfs.ext4)   run mkfs.ext4 -F -q "$_img" ;;
		mke2fs)      run mke2fs -t ext4 -F -q "$_img" ;;
	esac || die "formatting failed"
	meta_set "$_name" mode  image
	meta_set "$_name" arch  "$(detect_arch)"
	meta_set "$_name" distro empty
	meta_set "$_name" img_size "$_size"
	meta_set "$_name" created "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
	log_ok "image ready. Populate it with:  achroot install <distro> $_name   (it'll extract into the image)"
	log_info "(the image auto-mounts on 'start'; metadata mode=image)"
}

# --- list installed --------------------------------------------------------

cmd_installed() {
	log_step "Installed chroots  (base: $ACH_BASE)"
	[ -d "$ACH_DISTROS" ] || { log_info "none yet"; return 0; }
	_found=0
	printf '  %-16s %-10s %-7s %-9s %s\n' NAME DISTRO ARCH MODE STATUS
	for _d in "$ACH_DISTROS"/*/; do
		[ -d "$_d" ] || continue
		_n=$(basename "$_d"); _found=1
		_distro=$(meta_get "$_n" distro 2>/dev/null || echo "?")
		_arch=$(meta_get "$_n" arch 2>/dev/null || echo "?")
		_mode=$(meta_get "$_n" mode 2>/dev/null || echo dir)
		if is_started "$_n"; then _st="${C_GRN}running${C_RESET}"; else _st="${C_DIM}stopped${C_RESET}"; fi
		printf '  %-16s %-10s %-7s %-9s %b\n' "$_n" "$_distro" "$_arch" "$_mode" "$_st"
	done
	[ "$_found" = 0 ] && log_info "none yet — try: achroot install alpine"
}

# --- remove ----------------------------------------------------------------

cmd_remove() {
	need_root
	_name=$1
	require_chroot "$_name"
	# never delete while mounted (could nuke /dev, /sdcard via bind mounts!)
	if is_started "$_name"; then
		log_warn "'$_name' is still mounted — stopping it first (safety)"
		cmd_stop "$_name"
	fi
	# double-check nothing is still mounted underneath before rm -rf
	if [ -n "$(chroot_mounts "$_name")" ]; then
		die "refusing to delete: '$_name' still has active mounts. Run: achroot stop $_name"
	fi
	_cdir=$(chroot_dir "$_name")
	confirm "Permanently delete '$_name' and everything in $_cdir?" || { log_info "aborted"; return 0; }
	log_info "deleting $_cdir"
	rm -rf "$_cdir" || die "rm failed"
	log_ok "removed '$_name'"
}

cmd_status() {
	_name=$1
	if [ -z "$_name" ]; then cmd_installed; return; fi
	require_chroot "$_name"
	log_step "Status: $_name"
	printf '  distro : %s (%s)\n' "$(meta_get "$_name" distro)" "$(meta_get "$_name" release 2>/dev/null)"
	printf '  arch   : %s\n' "$(meta_get "$_name" arch)"
	printf '  mode   : %s\n' "$(meta_get "$_name" mode)"
	printf '  path   : %s\n' "$(rootfs_path "$_name")"
	printf '  created: %s\n' "$(meta_get "$_name" created 2>/dev/null)"
	if is_started "$_name"; then
		printf '  state  : %brunning%b\n' "$C_GRN" "$C_RESET"
		printf '  mounts :\n'
		chroot_mounts "$_name" | sed 's/^/           /'
	else
		printf '  state  : %bstopped%b\n' "$C_DIM" "$C_RESET"
	fi
}
