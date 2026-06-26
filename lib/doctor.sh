# shellcheck shell=sh
# lib/doctor.sh — deep environment diagnostics with health checks and hints.

_row()  { printf '  %-22s %s\n' "$1" "$2" ; }
_good() { printf '  %-22s %b%s%b\n' "$1" "$C_GRN" "$2" "$C_RESET" ; }
_bad()  { printf '  %-22s %b%s%b\n' "$1" "$C_RED" "$2" "$C_RESET" ; }
_warnrow() { printf '  %-22s %b%s%b\n' "$1" "$C_YEL" "$2" "$C_RESET" ; }

cmd_doctor() {
	_issues=0

	log_step "Device"
	_row "Model"        "$(gp ro.product.brand) $(gp ro.product.model) ($(gp ro.product.device))"
	_row "Android"      "$(gp ro.build.version.release)  (API $(gp ro.build.version.sdk))"
	_row "Build"        "$(gp ro.build.display.id)"
	_row "Kernel"       "$(uname -r 2>/dev/null)"
	_row "Uptime"       "$(cut -d. -f1 /proc/uptime 2>/dev/null | awk '{printf "%dh %dm", $1/3600, ($1%3600)/60}')"

	log_step "CPU / Memory"
	_row "uname -m"     "$(uname -m)"
	_row "Canonical arch" "$(detect_arch)"
	_row "CPU bits"     "$(detect_cpu_bits)"
	_row "Cores"        "$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null)"
	_row "Hardware"     "$(gp ro.hardware) / $(gp ro.board.platform)"
	if [ -r /proc/meminfo ]; then
		_mt=$(awk '/MemTotal/{print $2*1024}' /proc/meminfo)
		_ma=$(awk '/MemAvailable/{print $2*1024}' /proc/meminfo)
		_row "RAM"       "$(human_bytes "$_ma") free of $(human_bytes "$_mt")"
	fi

	log_step "Root / superuser"
	if is_root; then _good "Running as" "root (uid 0) — good"; else
		_bad "Running as" "uid $(id -u) — NOT root"; _issues=$((_issues+1))
		_row "" "re-run from your root shell: su -c 'sh $ACH_SELF doctor'"
	fi
	_su=$(detect_su)
	case "$_su" in
		none) _bad "su binary" "not found"; _issues=$((_issues+1)) ;;
		generic) _warnrow "su solution" "present (unknown vendor)" ;;
		*) _good "su solution" "$_su" ;;
	esac
	_mm=$(su_mount_master_flag); [ -n "$_mm" ] && _row "mount-master flag" "$_mm (available)"

	log_step "Mount namespace  (the classic chroot-vanishes trap)"
	if mnt_ns_differs; then
		_warnrow "Namespace" "PRIVATE (differs from init)"
		if have nsenter; then
			_good "Mitigation" "nsenter present — achroot will mount in init's namespace automatically"
		else
			_bad "Mitigation" "nsenter MISSING — install util-linux/toybox, or use 'su --mount-master'"
			_issues=$((_issues+1))
		fi
	else
		_good "Namespace" "global (mounts will be visible everywhere)"
	fi

	log_step "SELinux"
	_se=$(selinux_status)
	case "$_se" in
		Enforcing) _warnrow "Status" "Enforcing (some chroot ops may be denied)";
			have setenforce && _row "" "achroot can set Permissive on start (ACH_MANAGE_SELINUX)";;
		Permissive) _good "Status" "Permissive" ;;
		Disabled) _good "Status" "Disabled" ;;
		*) _row "Status" "$_se" ;;
	esac
	have setenforce && _row "setenforce" "available" || _row "setenforce" "not available"

	log_step "Kernel features"
	has_loop    && _good "loop devices" "yes (image-mode chroots OK)"   || _warnrow "loop devices" "none found"
	has_binfmt  && _good "binfmt_misc"  "yes (foreign-arch via QEMU OK)" || _row "binfmt_misc" "no"
	has_devpts  && _good "devpts"       "yes (ptys / login / tmux OK)"   || _warnrow "devpts" "no"
	has_fuse    && _row  "fuse (/dev/fuse)" "yes" || _row "fuse" "no"
	has_tun     && _row  "tun (/dev/net/tun)" "yes (VPN in chroot OK)" || _row "tun" "no"
	has_overlay && _row  "overlayfs" "yes" || _row "overlayfs" "no"

	log_step "Required & helpful tools"
	for _t in mount umount chroot tar; do
		if have "$_t"; then _good "$_t" "$(command -v "$_t")"; else
			# busybox may still provide it
			if host_busybox >/dev/null && busybox "$_t" --help >/dev/null 2>&1; then
				_good "$_t" "via busybox"
			else _bad "$_t" "MISSING"; _issues=$((_issues+1)); fi
		fi
	done
	for _t in nsenter unshare setenforce losetup mkfs.ext4 ip; do
		if have "$_t"; then _good "$_t" "$(command -v "$_t")"; else _row "$_t" "absent (optional)"; fi
	done
	_bb=$(host_busybox) && _good "busybox" "$_bb ($(busybox 2>&1 | head -1 | cut -c1-30))" || _warnrow "busybox" "not installed (recommended on Android)"
	_dl=$(host_downloader) && _good "downloader" "$_dl" || { _bad "downloader" "no curl/wget — can't fetch rootfs"; _issues=$((_issues+1)); }
	for _xz in xz zstd gzip; do have "$_xz" && _row "$_xz" "yes"; done

	log_step "Storage"
	_row "ACH_BASE" "$ACH_BASE"
	if [ -d "$ACH_BASE" ] || mkdir -p "$ACH_BASE" 2>/dev/null; then
		_fst=$(fs_type_of "$ACH_BASE")
		if fs_supports_unix "$ACH_BASE"; then _good "Base FS" "$_fst (supports unix perms/symlinks)"
		else _warnrow "Base FS" "$_fst — needs IMAGE mode (achroot create-image)"; fi
		if is_noexec "$ACH_BASE"; then _bad "exec" "noexec! binaries won't run here"; _issues=$((_issues+1))
		else _good "exec" "executable filesystem"; fi
		_row "Free space" "$(human_bytes "$(free_bytes "$ACH_BASE")")"
	else
		_bad "ACH_BASE" "cannot create $ACH_BASE"; _issues=$((_issues+1))
	fi
	if _sd=$(detect_sdcard); then _good "Internal storage" "$_sd -> /sdcard"; else _row "Internal storage" "not detected"; fi

	log_step "Network / DNS"
	if net_reachable; then _good "Connectivity" "internet reachable"; else _warnrow "Connectivity" "no internet (downloads will fail)"; fi
	_row "Resolvers" "$(detect_dns | tr '\n' ' ')"

	log_step "Installed chroots"
	if [ -d "$ACH_DISTROS" ] && [ -n "$(ls -A "$ACH_DISTROS" 2>/dev/null)" ]; then
		for _d in "$ACH_DISTROS"/*/; do
			[ -d "$_d" ] || continue
			_n=$(basename "$_d")
			is_started "$_n" && _good "$_n" "running" || _row "$_n" "stopped"
		done
	else
		_row "(none)" "install one:  achroot install alpine"
	fi

	printf '\n'
	if [ "$_issues" = 0 ]; then
		log_ok "No blocking issues detected — you're good to go."
	else
		log_warn "$_issues potential issue(s) flagged above (in red). Address those first."
	fi
}
