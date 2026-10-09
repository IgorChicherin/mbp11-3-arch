#!/usr/bin/env bash
# Install this configuration's packages on a fresh archinstall_zfs system, from state/packages-repo.txt.
#   ./install-packages.sh             # install with pacman
#   ./install-packages.sh --dry-run   # only print what would be installed
# No AUR packages: zfsbootmenu comes with archinstall_zfs. Run as your user; it calls sudo for pacman.
# pacman still asks before installing and on conflicts.
#
# Left out on purpose, installed by their own README steps:
#   zfs-dkms                         replaces zfs-linux-lts; needs an initramfs + ZBM rebuild (step 4)
#   linux-lts-mbp, -headers          built locally from ~/Projects/reclocked/pkgbuild (step 5)
#   *-debug                          debug symbols
# Never installed, even if a list names them: mbpfan (fights reclocked over the fans), proprietary nvidia
# drivers (nvidia-470xx has no GBM, so no Wayland compositor on this GPU), mainline linux (patches are LTS-only).
set -euo pipefail

dry=0
for a in "$@"; do
  case $a in
    --dry-run) dry=1 ;;
    *) echo "usage: install-packages.sh [--dry-run]" >&2; exit 1 ;;
  esac
done
[[ $EUID -ne 0 ]] || { echo "run as your user, not root" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
skip='^(zfs-dkms|linux-lts-mbp|linux-lts-mbp-headers|.*-debug)$'
never='^(mbpfan|nvidia.*|lib32-nvidia.*|linux|linux-headers)$'

list() {  # list <file>: package names, minus comments, skipped and forbidden ones
  grep -vE '^\s*(#|$)' "$1" | grep -vE "$skip" | grep -vE "$never" | sort -u
}

# Repo packages: split into available and unknown (renamed or dropped from Arch since the list was made).
mapfile -t want < <(list "$here/state/packages-repo.txt")
(( dry )) || sudo pacman -Sy   # dry run uses the current sync DB, no sudo
mapfile -t known < <(comm -12 <(printf '%s\n' "${want[@]}") <(pacman -Slq | sort -u))
mapfile -t unknown < <(comm -23 <(printf '%s\n' "${want[@]}") <(pacman -Slq | sort -u))

echo "== repo: ${#known[@]} packages"
(( ${#unknown[@]} == 0 )) || echo "   not in any repo, skipped: ${unknown[*]}"
if (( dry )); then
  printf '   %s\n' "${known[@]}"
else
  sudo pacman -Su --needed -- "${known[@]}"
fi

(( dry )) && exit 0

echo "done. Next: README step 4 (zfs-dkms). Units still to enable:"
comm -13 <(systemctl list-unit-files --state=enabled --no-legend | awk '{print $1}' | sort) \
         <(grep -vE '^\s*(#|$)' "$here/state/enabled-units.txt" | sort) | sed 's/^/   /'
