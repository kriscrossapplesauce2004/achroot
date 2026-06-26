# shellcheck shell=sh
# lib/detect.sh — the detection engine. Figures out everything about the host
# (arch, Android version, root solution, SELinux, namespaces, kernel features,
# storage) so the rest of the tool can make smart decisions automatically.

# --- CPU architecture ------------------------------------------------------

# Canonical arch used internally: arm64 | armhf | amd64 | i386 | <raw>
detect_arch() {
	_m=$(uname -m 2>/dev/null)
	case "$_m" in
		aarch64|arm64|armv8b|armv8l*) echo arm64 ;;
		armv7*|armv6*|armeabi*|arm)   echo armhf ;;
		x86_64|amd64)                 echo amd64 ;;
		i386|i486|i586|i686|x86)      echo i386 ;;
		*) echo "$_m" ;;
	esac
}

# Some 64-bit phones run a 32-bit userspace (uname -m = armv8l). Detect the
# real CPU capability so we can warn / pick the right rootfs.
detect_cpu_bits() {
	if grep -qi 'aarch64\|x86_64\|Architecture.*8\|fpu.*aes' /proc/cpuinfo 2>/dev/null; then :; fi
	case "$(uname -m)" in
		aarch64|x86_64) echo 64 ;;
		armv8l) echo "32 (on 64-bit CPU)" ;;
		*) echo 32 ;;
	esac
}

# --- root / superuser solution --------------------------------------------

# echoes one of: magisk | kernelsu | apatch | supersu | generic | none
detect_su() {
	have su || { echo none; return; }
	_v=$(su -v 2>/dev/null; su -V 2>/dev/null)
	case "$_v" in
		*MAGISK*|*magisk*) echo magisk; return ;;
		*KernelSU*|*KSU*)  echo kernelsu; return ;;
		*APatch*|*apatch*) echo apatch; return ;;
		*SUPERSU*)         echo supersu; return ;;
	esac
	# fall back to filesystem markers
	if [ -e /data/adb/ksud ] || [ -d /data/adb/ksu ]; then echo kernelsu; return; fi
	if [ -e /data/adb/apd ] || [ -d /data/adb/ap ]; then echo apatch; return; fi
	if [ -e /data/adb/magisk ] || have magisk; then echo magisk; return; fi
	echo generic
}

# the flag a given su uses to drop into the global mount namespace, if any
su_mount_master_flag() {
	case "$(detect_su)" in
		magisk|kernelsu|apatch) echo "--mount-master" ;;
		*) echo "" ;;
	esac
}

# --- SELinux ---------------------------------------------------------------

selinux_status() {
	if have getenforce; then getenforce 2>/dev/null; return; fi
	if [ -r /sys/fs/selinux/enforce ]; then
		case "$(cat /sys/fs/selinux/enforce 2>/dev/null)" in
			1) echo Enforcing ;; 0) echo Permissive ;; *) echo Unknown ;;
		esac
	else
		echo Disabled
	fi
}

# --- mount namespaces (the Magisk gotcha) ----------------------------------

# True when our mount namespace differs from init's. If so, mounts we make are
# invisible to the rest of the system (and other su sessions) unless we mount
# inside init's namespace. This is THE classic "my chroot vanished" bug.
mnt_ns_differs() {
	_a=$(readlink /proc/self/ns/mnt 2>/dev/null) || return 1
	_b=$(readlink /proc/1/ns/mnt 2>/dev/null) || return 1
	[ -n "$_a" ] && [ -n "$_b" ] && [ "$_a" != "$_b" ]
}

# --- kernel feature probes -------------------------------------------------

has_binfmt()  { [ -d /proc/sys/fs/binfmt_misc ] ; }
has_loop()    { [ -e /dev/block/loop0 ] || [ -e /dev/loop0 ] || have losetup ; }
has_fuse()    { [ -e /dev/fuse ] ; }
has_tun()     { [ -e /dev/tun ] || [ -e /dev/net/tun ] ; }
has_overlay() { grep -qw overlay /proc/filesystems 2>/dev/null ; }
has_devpts()  { grep -qw devpts /proc/filesystems 2>/dev/null ; }

# --- storage ---------------------------------------------------------------

# filesystem type backing a path (ext4, f2fs, fuse, vfat, exfat, ...)
fs_type_of() {
	_p=$1
	[ -e "$_p" ] || _p=$(dirname "$_p")
	if have findmnt; then findmnt -n -o FSTYPE --target "$_p" 2>/dev/null && return; fi
	# fall back to /proc/mounts: find the longest mountpoint that prefixes $p
	_rp=$(_realpath "$_p")
	awk -v p="$_rp" '
		{ mp=$2; fst=$3;
		  if (index(p, mp)==1 && length(mp) > best) { best=length(mp); type=fst } }
		END { if (type!="") print type }' /proc/mounts 2>/dev/null
}

# is a path on a filesystem mounted noexec? (binaries can't run there)
is_noexec() {
	_p=$1; [ -e "$_p" ] || _p=$(dirname "$_p")
	_rp=$(_realpath "$_p")
	awk -v p="$_rp" '
		{ mp=$2; opt=$4;
		  if (index(p, mp)==1 && length(mp) > best) { best=length(mp); o=opt } }
		END { if (o ~ /(^|,)noexec(,|$)/) exit 0; else exit 1 }' /proc/mounts 2>/dev/null
}

# can a filesystem at this path store unix permissions & symlinks?
# (FAT/exFAT/some FUSE can't -> we must use a loop-mounted ext4 image)
fs_supports_unix() {
	case "$(fs_type_of "$1")" in
		ext2|ext3|ext4|f2fs|btrfs|xfs|reiserfs) return 0 ;;
		*) return 1 ;;
	esac
}

# minimal realpath that works without the realpath/readlink -f binary
_realpath() {
	_t=$1
	if have realpath; then realpath "$_t" 2>/dev/null && return; fi
	if have readlink && readlink -f "$_t" >/dev/null 2>&1; then readlink -f "$_t"; return; fi
	# best-effort manual canonicalization
	case "$_t" in
		/*) : ;;
		*) _t="$(pwd)/$_t" ;;
	esac
	printf '%s\n' "$_t"
}

# detect internal storage source for binding /sdcard into the chroot
detect_sdcard() {
	[ -n "${ACH_SDCARD_SRC:-}" ] && { printf '%s\n' "$ACH_SDCARD_SRC"; return; }
	for _d in /storage/emulated/0 /sdcard /mnt/sdcard /storage/self/primary; do
		[ -d "$_d" ] && { printf '%s\n' "$_d"; return; }
	done
	return 1
}

# --- DNS -------------------------------------------------------------------

# echo one resolver IP per line, best effort
detect_dns() {
	if [ "${ACH_DNS:-auto}" != "auto" ] && [ -n "${ACH_DNS:-}" ]; then
		for _ip in $ACH_DNS; do printf '%s\n' "$_ip"; done
		return
	fi
	_got=0
	for _prop in net.dns1 net.dns2 net.dns3 net.dns4; do
		_v=$(gp "$_prop")
		case "$_v" in
			*.*.*.*|*:*) printf '%s\n' "$_v"; _got=1 ;;
		esac
	done
	if [ "$_got" = 0 ] && [ -r /etc/resolv.conf ]; then
		awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null && _got=1
	fi
	if [ "$_got" = 0 ]; then
		# sensible public fallbacks
		printf '1.1.1.1\n8.8.8.8\n'
	fi
}

# --- shells & tooling on the host ------------------------------------------

host_busybox() { first_of busybox 2>/dev/null ; }
host_downloader() { first_of curl wget ; }
host_tar() { first_of tar ; }

# Quick connectivity probe (returns 0 if we can likely reach the internet)
net_reachable() {
	if have ping; then ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && return 0; fi
	_dl=$(host_downloader) || return 1
	case "$_dl" in
		curl) curl -fsI --max-time 5 https://1.1.1.1 >/dev/null 2>&1 ;;
		wget) wget -q -T5 -t1 --spider https://1.1.1.1 >/dev/null 2>&1 ;;
	esac
}
