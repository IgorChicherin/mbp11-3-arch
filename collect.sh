#!/usr/bin/env bash
# Copy this machine's live configuration into the repo (system/). Run after any change:
#   ./collect.sh            # files readable as the user
#   sudo -v && ./collect.sh # also the root-only rEFInd config on the ESP
# Never collects secrets: NetworkManager system-connections, keys and *.bak files are skipped.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
files=(
  /etc/reclocked.conf
  /etc/systemd/system/reclocked.service
  /etc/systemd/system/bcm5974-resume.service
  /etc/NetworkManager/conf.d/wifi-powersave.conf
  /etc/modprobe.d/nouveau-runpm.conf
  /etc/dracut.conf.d/zfs.conf
  /etc/zfsbootmenu/config.yaml
  /etc/zfsbootmenu/dracut.conf.d/azfs.conf
  /etc/zfsbootmenu/dracut.conf.d/omit-drivers.conf
  /etc/zfsbootmenu/dracut.conf.d/zfsbootmenu.conf
  /etc/systemd/zram-generator.conf
  /boot/refind_linux.conf
)
# rEFInd lives on the root-only ESP; its directory differs between installs (EFI/refind, EFI/BOOT).
refind=$(sudo -n find /boot/efi/EFI -maxdepth 2 -name refind.conf 2>/dev/null | head -1 || true)
[[ -n $refind ]] && files+=("$refind") || echo "skip refind.conf (ESP is root-only: run 'sudo -v' first)"

grab() {  # grab <src>: copy to system/<src>, via sudo -n when not readable
  local src=$1 dst=$here/system$1
  mkdir -p "$(dirname "$dst")"
  if cat "$src" >"$dst" 2>/dev/null || sudo -n cat "$src" >"$dst" 2>/dev/null; then
    echo "ok   $src"
  else
    rm -f "$dst"
    echo "skip $src (missing, or root-only: run 'sudo -v' first)"
  fi
}
for f in "${files[@]}"; do grab "$f"; done
# state/ (packages, units, ZFSBootMenu properties) is curated by hand and never touched here.
