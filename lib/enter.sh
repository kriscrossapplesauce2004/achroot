# shellcheck shell=sh
# lib/enter.sh — entering the chroot and running commands inside it.

# pick the best available login shell inside a rootfs
find_shell() {
	_rfs=$1
	if [ -n "${ACH_DEFAULT_SHELL:-}" ] && [ -x "$_rfs$ACH_DEFAULT_SHELL" ]; then
		printf '%s\n' "$ACH_DEFAULT_SHELL"; return 0
	fi
	for _s in /bin/bash /usr/bin/bash /bin/zsh /usr/bin/zsh /bin/ash /bin/sh /usr/bin/sh; do
		[ -x "$_rfs$_s" ] && { printf '%s\n' "$_s"; return 0; }
	done
	return 1
}

# locate the chroot binary on the host (toybox provides one on modern Android)
_chroot_bin() { first_of chroot busybox || echo chroot ; }

# build & exec the chroot. Runs inside init's mount namespace when needed so it
# can see the mounts we made (see lib/mount.sh for the why).
#
# usage: enter_chroot NAME [--user USER] [-- COMMAND...]
enter_chroot() {
	_name=$1; shift
	require_chroot "$_name"
	need_root

	_user=root
	while [ $# -gt 0 ]; do
		case "$1" in
			--user|-u) _user=$2; shift 2 ;;
			--) shift; break ;;
			*) break ;;
		esac
	done
	# remaining args ("$@") are the command to run, if any

	# auto-start if not already mounted
	is_started "$_name" || start_chroot "$_name"

	_rfs=$(rootfs_path "$_name")
	_shell=$(find_shell "$_rfs") || die "no shell found inside '$_name' rootfs (looked for bash/sh/ash)"

	# environment the chrooted process inherits
	HOME=/root TERM=${TERM:-xterm-256color} \
		PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
		export HOME TERM PATH
	[ "$_user" != root ] && HOME="/home/$_user"

	_cbin=$(_chroot_bin)
	_have_su=0
	[ -x "$_rfs/bin/su" ] || [ -x "$_rfs/usr/bin/su" ] && _have_su=1

	if [ $# -gt 0 ]; then
		# run a specific command, then exit
		dbg "exec command in '$_name' as $_user: $*"
		if [ "$_user" != root ] && [ "$_have_su" = 1 ]; then
			# shellcheck disable=SC2046,SC2086
			exec $(ns_prefix) "$_cbin" "$_rfs" /bin/su - "$_user" -c "$*"
		fi
		# shellcheck disable=SC2046
		exec $(ns_prefix) "$_cbin" "$_rfs" "$_shell" -lc "$*"
	fi

	# interactive login shell
	log_info "entering '$_name' (shell: $_shell, user: $_user) — type 'exit' to leave"
	if [ "$_user" != root ] && [ "$_have_su" = 1 ]; then
		# shellcheck disable=SC2046
		exec $(ns_prefix) "$_cbin" "$_rfs" /bin/su - "$_user"
	fi
	# shellcheck disable=SC2046
	exec $(ns_prefix) "$_cbin" "$_rfs" "$_shell" -l
}

cmd_enter() { enter_chroot "$@" ; }

# `achroot run NAME -- cmd...`  (non-interactive convenience wrapper)
cmd_run() {
	_name=$1; shift
	[ "${1:-}" = "--" ] && shift
	[ $# -gt 0 ] || die "usage: achroot run NAME -- COMMAND [ARGS...]"
	enter_chroot "$_name" -- "$@"
}

# `achroot login USER NAME`  — enter as a non-root user
cmd_login() {
	_user=$1; _name=$2
	[ -n "$_user" ] && [ -n "$_name" ] || die "usage: achroot login USER NAME"
	enter_chroot "$_name" --user "$_user"
}
