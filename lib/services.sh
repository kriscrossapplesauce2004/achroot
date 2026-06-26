# shellcheck shell=sh
# lib/services.sh — SSH-in, boot autostart, and process inspection.

# --- SSH server ------------------------------------------------------------

ssh_package() {
	case "$1" in
		apt-get) echo openssh-server ;;
		pacman)  echo openssh ;;
		apk)     echo openssh ;;
		dnf|yum) echo openssh-server ;;
		xbps-install) echo openssh ;;
		zypper)  echo openssh ;;
		*) echo openssh-server ;;
	esac
}

# achroot ssh NAME [start|stop|info]
cmd_ssh() {
	_name=${1:-}; _action=${2:-start}
	require_chroot "$_name"
	need_root
	_rfs=$(rootfs_path "$_name")
	_port=${ACH_SSH_PORT:-8022}
	_pass=${ACH_SSH_PASS:-achroot}
	case "$_action" in
		stop)
			run_in_chroot "$_name" 'pkill -x sshd 2>/dev/null; true'
			log_ok "sshd stopped in '$_name'"; return ;;
		info)
			_ip=$(device_ip)
			printf '  connect:  ssh root@%s -p %s\n' "${_ip:-<device-ip>}" "$_port"
			printf '  password: %s  (ACH_SSH_PASS to change)\n' "$_pass"; return ;;
	esac

	is_started "$_name" || start_chroot "$_name"
	# install sshd if missing
	if [ ! -x "$_rfs/usr/sbin/sshd" ] && [ ! -x "$_rfs/usr/bin/sshd" ]; then
		_pm=$(pkgmgr_of "$_rfs") || die "no package manager — install openssh manually"
		log_info "installing $(ssh_package "$_pm")"
		cmd_pkg "$_name" "$(ssh_package "$_pm")" || die "could not install sshd"
	fi
	log_step "Configuring sshd in '$_name' (port $_port, root login enabled)"
	run_in_chroot "$_name" "
		mkdir -p /run/sshd /var/run/sshd /var/empty 2>/dev/null
		ssh-keygen -A >/dev/null 2>&1
		cfg=/etc/ssh/sshd_config
		if [ -f \"\$cfg\" ]; then
			sed -i 's/^#\\?Port .*/Port $_port/' \"\$cfg\" 2>/dev/null
			sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin yes/' \"\$cfg\" 2>/dev/null
			grep -q '^Port ' \"\$cfg\" || echo 'Port $_port' >> \"\$cfg\"
			grep -q '^PermitRootLogin yes' \"\$cfg\" || echo 'PermitRootLogin yes' >> \"\$cfg\"
		fi
		echo 'root:$_pass' | chpasswd 2>/dev/null
	" || log_warn "ssh config step had warnings"
	# launch (sshd self-daemonises)
	run_in_chroot "$_name" 'pkill -x sshd 2>/dev/null; sleep 1; /usr/sbin/sshd 2>/dev/null || sshd' \
		&& log_ok "sshd running" || die "sshd failed to start"
	_ip=$(device_ip)
	cat >&2 <<EOF
${C_GRN}SSH ready.${C_RESET} From your PC (same network):
    ${C_BOLD}ssh root@${_ip:-<device-ip>} -p ${_port}${C_RESET}
    password: ${C_BOLD}${_pass}${C_RESET}
Stop with:  achroot ssh $_name stop
EOF
}

# --- boot autostart (Magisk / KernelSU / APatch service.d) -----------------

_boot_service_dir() {
	for _d in /data/adb/service.d /data/adb/post-fs-data.d; do
		[ -d "$_d" ] && { printf '%s\n' "$_d"; return 0; }
	done
	return 1
}

# achroot boot NAME [enable|disable|status]
cmd_boot() {
	_name=${1:-}; _action=${2:-status}
	require_chroot "$_name"
	_sd=$(_boot_service_dir) || die "no boot-script dir (/data/adb/service.d). Needs Magisk/KernelSU/APatch."
	_script="$_sd/achroot-$_name.sh"
	case "$_action" in
		enable|on)
			need_root
			# the checkout must live on /data so it's readable early at boot
			case "$ACH_HOME" in
				/data/*|/system/*) : ;;
				*) log_warn "checkout ($ACH_HOME) may not be readable at early boot — move it under /data for reliable autostart." ;;
			esac
			{
				printf '#!/system/bin/sh\n'
				printf '# achroot boot autostart for "%s" — delete this file to disable.\n' "$_name"
				printf 'export ACH_YES=1 ACH_MANAGE_SELINUX=%s\n' "${ACH_MANAGE_SELINUX:-auto}"
				printf 'until [ -d "%s" ]; do sleep 5; done\n' "$(rootfs_path "$_name")"
				printf 'mkdir -p "%s" 2>/dev/null\n' "$ACH_LOGDIR"
				printf '/system/bin/sh "%s" --base "%s" start "%s" >> "%s/boot-%s.log" 2>&1\n' \
					"$ACH_HOME/achroot" "$ACH_BASE" "$_name" "$ACH_LOGDIR" "$_name"
				if [ "${ACH_BOOT_SSH:-0}" = 1 ]; then
					printf '/system/bin/sh "%s" --base "%s" ssh "%s" start >> "%s/boot-%s.log" 2>&1\n' \
						"$ACH_HOME/achroot" "$ACH_BASE" "$_name" "$ACH_LOGDIR" "$_name"
				fi
			} > "$_script" || die "could not write $_script"
			chmod 755 "$_script" 2>/dev/null
			mkdir -p "$ACH_LOGDIR" 2>/dev/null
			log_ok "boot autostart enabled: $_script"
			log_info "(set ACH_BOOT_SSH=1 before enabling to also start sshd at boot)"
			;;
		disable|off)
			need_root
			rm -f "$_script" && log_ok "boot autostart disabled for '$_name'" ;;
		status|"")
			if [ -f "$_script" ]; then log_ok "enabled  ($_script)"; else log_info "disabled"; fi ;;
		*) die "usage: achroot boot NAME [enable|disable|status]" ;;
	esac
}

# --- process inspection ----------------------------------------------------

# achroot ps NAME — list processes running inside the chroot
cmd_ps() {
	_name=${1:-}
	require_chroot "$_name"
	_rfs=$(_realpath "$(rootfs_path "$_name")")
	_n=0
	printf '  %-8s %s\n' PID COMMAND
	for _p in /proc/[0-9]*; do
		_root=$(readlink "$_p/root" 2>/dev/null) || continue
		case "$_root" in
			"$_rfs"|"$_rfs"/*)
				_pid=$(basename "$_p"); [ "$_pid" = "$$" ] && continue
				_cmd=$(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null)
				[ -z "$_cmd" ] && _cmd="[$(cat "$_p/comm" 2>/dev/null)]"
				printf '  %-8s %s\n' "$_pid" "$_cmd"; _n=$((_n+1)) ;;
		esac
	done
	[ "$_n" = 0 ] && log_info "no processes running inside '$_name'"
}
