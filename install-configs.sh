#!/usr/bin/env bash
# Install the config files from system/ to their real paths (system/etc/x → /etc/x) on a fresh install.
#   ./install-configs.sh             # everyday configs: show the diff, ask per file
#   ./install-configs.sh --yes       # everyday configs without asking
#   ./install-configs.sh --boot      # also boot files (rEFInd, ZFSBootMenu, dracut); these always ask
#   ./install-configs.sh --dry-run   # only show what differs
# Run as your user; it calls sudo. Every replaced file is kept as <file>.bak-<timestamp>.
# It never rebuilds the initramfs or ZFSBootMenu itself: after boot files change it prints the commands.
set -uo pipefail

yes=0 boot=0 dry=0
for a in "$@"; do
  case $a in
    --yes) yes=1 ;;
    --boot) boot=1 ;;
    --dry-run) dry=1 ;;
    *) echo "usage: install-configs.sh [--yes] [--boot] [--dry-run]" >&2; exit 1 ;;
  esac
done
[[ $EUID -ne 0 ]] || { echo "run as your user, not root" >&2; exit 1; }
sudo -v || exit 1

here=$(cd "$(dirname "$0")" && pwd)
stamp=$(date +%Y%m%d-%H%M%S)
installed=()

is_boot() { [[ $1 == /boot/* || $1 == /etc/zfsbootmenu/* || $1 == /etc/dracut.conf.d/* ]]; }

ask() {  # ask <question>: yes/no from the terminal
  local r
  read -r -p "$1 [y/N] " r </dev/tty
  [[ $r == [yY]* ]]
}

while IFS= read -r -d '' src; do
  dst=${src#"$here/system"}
  if is_boot "$dst" && (( !boot )); then
    echo "skip $dst (boot file: rerun with --boot)"
    continue
  fi
  if [[ $dst == /boot/efi/EFI/refind/* ]] && ! sudo test -d /boot/efi/EFI/refind; then
    echo "skip $dst (no rEFInd on the ESP: run refind-install first)"
    continue
  fi

  if sudo test -e "$dst"; then
    if sudo cmp -s "$src" "$dst"; then
      echo "same $dst"
      continue
    fi
    echo "=== $dst differs (- installed, + repo)"
    sudo diff -u "$dst" "$src" | tail -n +3
  else
    echo "=== $dst is new"
  fi
  (( dry )) && continue

  if is_boot "$dst"; then
    echo "!!! Boot file: a wrong value here can make the Mac unbootable. Keep 'spoof_osx_version 10.9' in refind.conf."
    ask "install $dst?" || { echo "kept $dst"; continue; }
  elif (( !yes )); then
    ask "install $dst?" || { echo "kept $dst"; continue; }
  fi

  if sudo test -e "$dst"; then
    sudo cp -a "$dst" "$dst.bak-$stamp" && echo "backup $dst.bak-$stamp"
  fi
  sudo install -D -m644 "$src" "$dst" && echo "ok   $dst" && installed+=("$dst")
done < <(find "$here/system" -type f -print0 | sort -z)

(( ${#installed[@]} )) || { echo "nothing installed"; exit 0; }

# Follow-up for what was installed.
units=() boot_changed=0 modprobe_changed=0
for f in "${installed[@]}"; do
  case $f in
    /etc/systemd/system/*.service) units+=("$(basename "$f")") ;;
    /etc/NetworkManager/conf.d/*) sudo nmcli general reload conf && echo "ok   NetworkManager config reloaded" ;;
    /etc/modprobe.d/*) modprobe_changed=1 ;;
    /etc/reclocked.conf)
      if systemctl is-active -q reclocked; then
        sudo systemctl restart reclocked && echo "ok   reclocked restarted with the new config"
      fi ;;
  esac
  is_boot "$f" && boot_changed=1
done

if (( ${#units[@]} )); then
  sudo systemctl daemon-reload
  for u in "${units[@]}"; do
    if [[ $u == reclocked.service && ! -x /usr/local/bin/reclocked ]]; then
      echo "skip enabling $u: /usr/local/bin/reclocked missing (README step 6 builds it)"
      continue
    fi
    if [[ $u == reclocked.service ]]; then
      sudo systemctl enable --now "$u" && echo "ok   enabled and started $u"
    else
      sudo systemctl enable "$u" && echo "ok   enabled $u"   # bcm5974-resume runs only after a resume
    fi
  done
fi

if (( boot_changed )); then
  cat <<'EOF'
Boot files changed. Nothing was rebuilt. When you're ready (snapshot first):
  sudo zfs snapshot zroot/arch0/root@pre-configs-$(date +%F)
  ls /usr/lib/modules/*/pkgbase | sed 's|^/||' | sudo /usr/local/bin/dracut-install.sh   # dracut.conf.d changed
  sudo azfs-update-zbm                                                                   # zfsbootmenu/ changed
refind.conf takes effect on the next boot, no rebuild needed.
EOF
fi

if (( modprobe_changed )); then
  echo "/etc/modprobe.d changed. nouveau loads from the initramfs: rebuild the linux-lts-mbp one, then reboot"
  echo "(snapshot first):"
  for d in /usr/lib/modules/*/; do
    [[ -r $d/pkgbase && $(<"$d/pkgbase") == linux-lts-mbp ]] &&
      echo "  echo ${d#/}pkgbase | sudo /usr/local/bin/dracut-install.sh"
  done
fi
