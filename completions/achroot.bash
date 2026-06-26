# bash completion for achroot — source this file or drop it in bash-completion.d
_achroot() {
    local cur prev cmds
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    cmds="doctor list installed install import create-image start stop stopall \
          enter run login status remove backup restore clone binfmt gui selinux \
          config update version help"

    # complete installed-chroot names for commands that take one
    local base="${ACH_BASE:-/data/local/achroot}"
    local names=""
    [ -d "$base/distros" ] && names=$(ls -1 "$base/distros" 2>/dev/null)

    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
        return
    fi

    case "$prev" in
        enter|start|stop|status|remove|rm|backup|run|login|clone|gui)
            COMPREPLY=( $(compgen -W "$names" -- "$cur") ); return ;;
        install|add)
            COMPREPLY=( $(compgen -W "alpine ubuntu debian devuan kali arch fedora void rocky alma opensuse gentoo mint" -- "$cur") ); return ;;
        binfmt)
            COMPREPLY=( $(compgen -W "status on off" -- "$cur") ); return ;;
        selinux)
            COMPREPLY=( $(compgen -W "status permissive enforcing" -- "$cur") ); return ;;
        config)
            COMPREPLY=( $(compgen -W "show init set edit path" -- "$cur") ); return ;;
    esac
    COMPREPLY=( $(compgen -W "$names" -- "$cur") )
}
complete -F _achroot achroot
