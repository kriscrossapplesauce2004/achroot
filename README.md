# achroot

**A friendly, powerful chroot manager for rooted Android — `git clone` and `sh`.**

You're on a rooted phone with a root shell (Magisk / KernelSU / APatch). You want
a *real* Linux distro — Debian, Ubuntu, Kali, Arch, Alpine, Fedora, Void… — running
in a chroot, with networking, storage, optionally a desktop, optionally running a
*foreign* CPU architecture. `achroot` does all of it, detects your device, and works
around the Android-specific traps that make this annoying by hand.

```sh
git clone <repo> achroot
cd achroot
su -c 'sh achroot doctor'          # scan the device
su -c 'sh achroot install debian'  # download + unpack Debian
su -c 'sh achroot enter debian'    # you're in
```

No dependencies beyond what a rooted Android already has (a shell, `mount`,
`chroot`, `tar`, and `curl`/`wget` — busybox/toybox cover these). Pure POSIX `sh`,
so it runs under mksh, toybox sh, or busybox ash.

---

## Why it's not just "another chroot script"

Most copy-paste chroot scripts break on real devices. `achroot` handles the parts
that actually bite you:

- **The vanishing-chroot bug.** Magisk/KernelSU usually drop your `su` shell into a
  **private mount namespace**. Mounts you make there are invisible to everything
  else and disappear when the shell exits. `achroot` detects this and performs the
  mounts **and the final `chroot`** inside *init's* namespace via `nsenter -t 1 -m`,
  so your chroot is global and persistent. No `--mount-master` gymnastics required.
- **SELinux Enforcing.** Detected, and optionally flipped to Permissive only while a
  chroot is running (your choice; restored on stop).
- **noexec / FAT / exFAT storage.** Detected. If your target can't store unix perms
  or symlinks, `achroot` tells you to use **image mode** (a loop-mounted ext4 image).
- **DNS that doesn't exist.** Pulled from Android's `getprop net.dns*`, with public
  fallbacks, written into the chroot's `resolv.conf`.
- **Clean teardown.** `stop` signals processes still rooted inside the chroot, then
  unmounts deepest-first, with a lazy-unmount fallback so nothing wedges.

## Features

- **One-command distro install** with auto architecture detection:
  `alpine ubuntu debian devuan kali arch fedora void rocky alma opensuse gentoo mint`
  (Kali uses the Android-tuned NetHunter rootfs; Arch uses ArchLinuxARM on ARM.)
- **`doctor`** — a deep diagnostic: device, CPU/arch (incl. 32-on-64 detection),
  Android/API level, root solution, mount namespace, SELinux, kernel features
  (loop, binfmt_misc, devpts, fuse, tun, overlayfs), tooling, storage health,
  connectivity, and your installed chroots — with red-flagged issues.
- **Foreign-architecture chroots** via QEMU user-mode + `binfmt_misc`
  (e.g. run an **amd64** Kali on an **arm64** phone).
- **Storage passthrough** — internal storage at `/sdcard`, external/OTG at
  `/storage`, plus arbitrary `ACH_EXTRA_BINDS`.
- **GUI bootstrap** — VNC, X11 (Termux:X11), and PulseAudio launchers written
  straight into the chroot.
- **Image mode** — fixed-size ext4 loop images, ideal for FAT/exFAT SD cards.
- **Backup / restore / clone** with automatic best-available compression.
- **Multiple chroots side by side**, each with metadata and per-chroot start hooks.
- **Safe by default** — won't delete a mounted chroot, prompts before destructive
  actions (override with `-y`), `--dry-run` to preview every command.

## Quick start

```sh
# 1) inspect the device and catch problems early
su -c 'sh achroot doctor'

# 2) see what you can install
su -c 'sh achroot list'

# 3) install + enter (install auto-detects your CPU arch)
su -c 'sh achroot install ubuntu'
su -c 'sh achroot enter ubuntu'

# inside the chroot:
apt update && apt install -y neofetch && neofetch
```

Optional — put it on your PATH:

```sh
sh install.sh          # creates a launcher in /data/local/bin (or ~/.local/bin)
achroot doctor
```

## Common commands

| Command | What it does |
|---|---|
| `achroot doctor` | full device scan + health checks |
| `achroot list` | installable distros |
| `achroot install <id>[:release] [name]` | download + unpack a distro |
| `achroot import <tarball> <name>` | chroot from a local rootfs tarball |
| `achroot create-image <name> <size>` | ext4 loop image (e.g. `4G`) for FAT/exFAT cards |
| `achroot installed` | list your chroots + state |
| `achroot start \| stop \| stopall <name>` | mount / unmount |
| `achroot enter <name> [-- cmd…]` | interactive shell or run a command |
| `achroot run <name> -- cmd…` | non-interactive command |
| `achroot login <user> <name>` | enter as a non-root user |
| `achroot status [name]` | mounts + metadata |
| `achroot remove <name>` | delete (must be stopped) |
| `achroot backup \| restore \| clone` | snapshots & duplication |
| `achroot binfmt on <arch> [name]` | QEMU foreign-arch support |
| `achroot gui <name> [vnc\|x11\|audio]` | desktop bootstrap |
| `achroot selinux [status\|permissive\|enforcing]` | SELinux control |
| `achroot config [show\|set K V\|edit]` | settings |

## Examples

**Run an amd64 distro on an arm64 phone**
```sh
sh achroot install kali:amd64-ish   # or import an amd64 rootfs
sh achroot binfmt on amd64 mykali    # registers qemu-x86_64 + copies it inside
sh achroot enter mykali
```
*(needs a static `qemu-x86_64` on the device — e.g. a qemu-user-static Magisk module)*

**Desktop over VNC**
```sh
sh achroot install debian
sh achroot gui debian vnc
sh achroot enter debian
apt update && apt install -y tigervnc-standalone-server xfce4 xfce4-goodies dbus-x11
vnc          # then connect a VNC viewer to 127.0.0.1:5901
```

**Use an SD card formatted exFAT**
```sh
sh achroot config set ACH_BASE /storage/XXXX-XXXX/linux
sh achroot create-image arch 6G     # ext4 image lives on exFAT, but the FS inside is ext4
sh achroot install arch arch
```

## Configuration

Settings live in `$ACH_BASE/config` (default base: `/data/local/achroot`). View or change:

```sh
sh achroot config show
sh achroot config set ACH_DNS '1.1.1.1 9.9.9.9'
sh achroot config set ACH_EXTRA_BINDS '/data/music:/mnt/music:ro /sdcard/proj:/root/proj'
```

Key options: `ACH_BASE`, `ACH_GLOBAL_MOUNT` (auto/on/off namespace handling),
`ACH_BIND_SDCARD`, `ACH_BIND_EXTERNAL`, `ACH_EXTRA_BINDS`, `ACH_DNS`,
`ACH_HOSTNAME`, `ACH_DEFAULT_SHELL`, `ACH_MANAGE_SELINUX` (ask/auto/off).

## Per-chroot start hooks

Drop executable scripts in `<base>/distros/<name>/hooks/onstart.d/`; they run on every
`start` with `$ACH_ROOTFS` and `$ACH_NAME` set (handy for starting `sshd`, mounting
extra things, etc.).

## Notes & caveats

- **Root required.** This manipulates mounts and `chroot`; run it from a root shell.
- **systemd as PID 1 doesn't run in a plain chroot.** Use the distro's SysV/OpenRC
  scripts or start daemons directly. (A namespace/`unshare`-based PID-1 mode may come
  later.)
- `achroot` is for **your own device**. It's a power-user tool for running Linux on
  hardware you control.
- Tested against mksh/toybox/busybox shells; on a desktop Linux it also works for
  managing chroots (handy for development).

## License

MIT — see [LICENSE](LICENSE).
