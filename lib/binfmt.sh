# shellcheck shell=sh
# lib/binfmt.sh — run foreign-architecture chroots via QEMU user-mode emulation.
# e.g. an amd64 Kali rootfs on an arm64 phone. Registers binfmt_misc handlers
# and copies the static qemu binary into the target rootfs.

# magic/mask pairs for the common ELF arches (binfmt_misc format)
_binfmt_entry() {
	case "$1" in
		amd64|x86_64)
			echo ':qemu-x86_64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:QEMU:' ;;
		i386|x86)
			echo ':qemu-i386:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x03\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:QEMU:' ;;
		arm64|aarch64)
			echo ':qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:QEMU:' ;;
		armhf|arm)
			echo ':qemu-arm:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:QEMU:' ;;
		*) return 1 ;;
	esac
}

_qemu_name() {
	case "$1" in
		amd64|x86_64) echo qemu-x86_64 ;;
		i386|x86)     echo qemu-i386 ;;
		arm64|aarch64) echo qemu-aarch64 ;;
		armhf|arm)    echo qemu-arm ;;
		*) return 1 ;;
	esac
}

binfmt_mounted() { mountpoint -q /proc/sys/fs/binfmt_misc 2>/dev/null || [ -e /proc/sys/fs/binfmt_misc/register ] ; }

binfmt_mount() {
	has_binfmt || die "kernel has no binfmt_misc support (CONFIG_BINFMT_MISC)"
	[ -e /proc/sys/fs/binfmt_misc/register ] && return 0
	log_info "mounting binfmt_misc"
	m mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null \
		|| die "could not mount binfmt_misc"
}

# locate a static qemu-user binary on the host
_find_qemu() {
	_q=$1
	for _p in "$_q-static" "$_q"; do
		_full=$(command -v "$_p" 2>/dev/null) && { printf '%s\n' "$_full"; return 0; }
	done
	for _d in /usr/bin /system/bin /data/local/bin /data/adb/modules/*/system/bin; do
		[ -x "$_d/$_q-static" ] && { printf '%s\n' "$_d/$_q-static"; return 0; }
		[ -x "$_d/$_q" ] && { printf '%s\n' "$_d/$_q"; return 0; }
	done
	return 1
}

cmd_binfmt() {
	_action=${1:-status}; [ $# -gt 0 ] && shift
	case "$_action" in
		status|"")
			log_step "binfmt_misc status"
			has_binfmt || { log_warn "no binfmt_misc support in kernel"; return 0; }
			binfmt_mounted || { log_info "binfmt_misc not mounted (run: achroot binfmt on <arch>)"; return 0; }
			_n=0
			for _e in /proc/sys/fs/binfmt_misc/qemu-*; do
				[ -e "$_e" ] || continue
				_n=$((_n+1))
				printf '  %-16s %s\n' "$(basename "$_e")" "$(grep -m1 enabled "$_e" 2>/dev/null || echo '?')"
			done
			[ "$_n" = 0 ] && log_info "no qemu handlers registered"
			;;
		on|register)
			need_root
			_arch=${1:-}
			[ -n "$_arch" ] || die "usage: achroot binfmt on <arch>  (amd64|i386|arm64|armhf) [chroot-name]"
			_name=${2:-}
			binfmt_mount
			_qn=$(_qemu_name "$_arch") || die "unsupported arch '$_arch'"
			_qbin=$(_find_qemu "$_qn") || die "static $_qn not found on host. Install qemu-user-static (e.g. a Magisk module) and retry."
			_entry=$(_binfmt_entry "$_arch")
			if [ -e "/proc/sys/fs/binfmt_misc/$_qn" ]; then
				log_info "$_qn already registered"
			else
				printf '%b\n' "$_entry" > /proc/sys/fs/binfmt_misc/register 2>/dev/null \
					&& log_ok "registered $_qn (interpreter: $_qbin)" \
					|| die "failed to register handler"
			fi
			# copy the interpreter into the target rootfs so it's reachable post-chroot
			if [ -n "$_name" ] && chroot_exists "$_name"; then
				_rfs=$(rootfs_path "$_name")
				mkdir -p "$_rfs/usr/bin"
				cp "$_qbin" "$_rfs/usr/bin/$_qn" 2>/dev/null && chmod 755 "$_rfs/usr/bin/$_qn" \
					&& log_ok "copied $_qn into $_name:/usr/bin"
			else
				log_info "tip: pass a chroot name to also copy qemu inside it: achroot binfmt on $_arch <name>"
			fi
			;;
		off|unregister)
			need_root
			_arch=${1:-}
			if [ -n "$_arch" ]; then
				_qn=$(_qemu_name "$_arch") || die "unsupported arch '$_arch'"
				[ -e "/proc/sys/fs/binfmt_misc/$_qn" ] && \
					printf -- '-1' > "/proc/sys/fs/binfmt_misc/$_qn" 2>/dev/null \
					&& log_ok "unregistered $_qn" || log_info "$_qn not registered"
			else
				for _e in /proc/sys/fs/binfmt_misc/qemu-*; do
					[ -e "$_e" ] && printf -- '-1' > "$_e" 2>/dev/null
				done
				log_ok "unregistered all qemu handlers"
			fi
			;;
		*) die "usage: achroot binfmt [status|on <arch> [name]|off [arch]]" ;;
	esac
}
