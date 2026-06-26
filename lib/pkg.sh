# shellcheck shell=sh
# lib/pkg.sh — package-manager abstraction. Lets the rest of the tool install
# software (desktops, sshd, ...) and upgrade without caring which distro it is.

# detect the package manager binary present inside a rootfs
pkgmgr_of() {
	_rfs=$1
	for _pm in apt-get pacman apk dnf yum xbps-install zypper emerge; do
		for _bd in usr/bin bin sbin usr/sbin; do
			[ -x "$_rfs/$_bd/$_pm" ] && { printf '%s\n' "$_pm"; return 0; }
		done
	done
	return 1
}

# friendly name for messages
pkgmgr_distro() {
	case "$1" in
		apt-get) echo "Debian/Ubuntu (apt)" ;; pacman) echo "Arch (pacman)" ;;
		apk) echo "Alpine (apk)" ;; dnf|yum) echo "Fedora/RHEL ($1)" ;;
		xbps-install) echo "Void (xbps)" ;; zypper) echo "openSUSE (zypper)" ;;
		emerge) echo "Gentoo (portage)" ;; *) echo "$1" ;;
	esac
}

pkg_refresh_cmd() {
	case "$1" in
		apt-get) echo 'apt-get update' ;;
		pacman)  echo 'pacman -Sy --noconfirm' ;;
		apk)     echo 'apk update' ;;
		dnf|yum) echo "$1 -y makecache" ;;
		xbps-install) echo 'xbps-install -S' ;;
		zypper)  echo 'zypper -n refresh' ;;
		emerge)  echo 'emerge --sync' ;;
	esac
}

pkg_install_cmd() {
	_pm=$1; shift; _pkgs="$*"
	case "$_pm" in
		apt-get) echo "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $_pkgs" ;;
		pacman)  echo "pacman -S --needed --noconfirm $_pkgs" ;;
		apk)     echo "apk add $_pkgs" ;;
		dnf|yum) echo "$_pm install -y $_pkgs" ;;
		xbps-install) echo "xbps-install -y $_pkgs" ;;
		zypper)  echo "zypper -n install $_pkgs" ;;
		emerge)  echo "emerge --noreplace $_pkgs" ;;
	esac
}

pkg_upgrade_cmd() {
	case "$1" in
		apt-get) echo 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade' ;;
		pacman)  echo 'pacman -Syu --noconfirm' ;;
		apk)     echo 'apk update && apk upgrade' ;;
		dnf|yum) echo "$1 -y upgrade" ;;
		xbps-install) echo 'xbps-install -Suy' ;;
		zypper)  echo 'zypper -n dup' ;;
		emerge)  echo 'emerge -uDN @world' ;;
	esac
}

# Arch (incl. ArchLinuxARM) needs its keyring initialised before the first
# install or every download fails signature checks. Echo the prep command once.
pkg_keyring_prep() {
	_pm=$1; _rfs=$2
	[ "$_pm" = pacman ] || return 0
	# already populated? (gnupg dir has key material)
	[ -s "$_rfs/etc/pacman.d/gnupg/pubring.gpg" ] && return 0
	echo 'pacman-key --init && pacman-key --populate'
}

# --- subcommands -----------------------------------------------------------

cmd_pkg() {
	need_root
	_name=${1:-}; [ $# -gt 0 ] && shift
	require_chroot "$_name"
	[ "${1:-}" = "--" ] && shift
	[ $# -gt 0 ] || die "usage: achroot pkg <name> <package>..."
	is_started "$_name" || start_chroot "$_name"
	_rfs=$(rootfs_path "$_name")
	_pm=$(pkgmgr_of "$_rfs") || die "no known package manager found inside '$_name'"
	log_step "Installing into '$_name' [$(pkgmgr_distro "$_pm")]: $*"
	_pre=$(pkg_keyring_prep "$_pm" "$_rfs")
	_cmd="$(pkg_refresh_cmd "$_pm"); $(pkg_install_cmd "$_pm" "$@")"
	[ -n "$_pre" ] && _cmd="$_pre; $_cmd"
	run_in_chroot "$_name" "$_cmd" && log_ok "installed" || die "package install failed"
}

cmd_upgrade() {
	need_root
	_name=${1:-}
	require_chroot "$_name"
	is_started "$_name" || start_chroot "$_name"
	_rfs=$(rootfs_path "$_name")
	_pm=$(pkgmgr_of "$_rfs") || die "no known package manager found inside '$_name'"
	log_step "Upgrading '$_name' [$(pkgmgr_distro "$_pm")]"
	_pre=$(pkg_keyring_prep "$_pm" "$_rfs")
	_cmd=$(pkg_upgrade_cmd "$_pm")
	[ -n "$_pre" ] && _cmd="$_pre; $_cmd"
	run_in_chroot "$_name" "$_cmd" && log_ok "up to date"
}
