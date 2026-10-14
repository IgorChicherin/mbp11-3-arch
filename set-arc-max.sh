#!/usr/bin/env bash
# Set the ZFS ARC (file cache) limit: live now, in /etc/modprobe.d/zfs-arc.conf, and in every initramfs.
#   ./set-arc-max.sh 1G         # size in bytes or with a K/M/G suffix (powers of 1024)
#   ./set-arc-max.sh default    # remove the limit: OpenZFS default (RAM - 1 GiB), fully after a reboot
# The repo copy (system/etc/modprobe.d/zfs-arc.conf) is written too: commit it to keep the value.
# Run as your user; it calls sudo. Snapshots zroot/arch0/root first.
set -euo pipefail

usage() { echo "usage: set-arc-max.sh <size: 1G, 512M, bytes> | default" >&2; exit 1; }
[[ $# -eq 1 ]] || usage
[[ $EUID -ne 0 ]] || { echo "run as your user, not root" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
ds=zroot/arch0/root
conf=/etc/modprobe.d/zfs-arc.conf
src=$here/system$conf
param=/sys/module/zfs/parameters/zfs_arc_max
rebuild() { ls /usr/lib/modules/*/pkgbase | sed 's|^/||' | sudo /usr/local/bin/dracut-install.sh; }

if [[ $1 == default ]]; then
  bytes=0
else
  bytes=$(numfmt --from=iec "${1^^}" 2>/dev/null) || usage
  # ZFS ignores a limit at or below arc_c_min (1/32 of RAM by default) or at or above RAM.
  cmin=$(awk '$1 == "c_min" {print $3}' /proc/spl/kstat/zfs/arcstats)
  ram=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) * 1024 ))
  if (( bytes <= cmin || bytes >= ram )); then
    echo "size must be above c_min ($(numfmt --to=iec --format=%.1f "$cmin")) and below RAM ($(numfmt --to=iec --format=%.1f "$ram"))" >&2
    exit 1
  fi
fi

sudo -v
snap=$ds@pre-arc-max-$(date +%Y%m%d-%H%M%S)
sudo zfs snapshot "$snap" && echo "ok   snapshot $snap"

if (( bytes == 0 )); then
  rm -f "$src"
  sudo rm -f "$conf" && echo "ok   removed $conf and its repo copy"
else
  cat >"$src" <<EOF
# Cap the ZFS ARC (file cache) at $(numfmt --to=iec-i --suffix=B "$bytes"). OpenZFS 2.3+ defaults to RAM - 1 GiB (14.5 of 15 GiB here), a
# storage-server default: on a laptop it crowds out applications and shrinks slowly under memory pressure.
# zfs loads from the initramfs, so rebuild it after changing this. Live value: /sys/module/zfs/parameters/zfs_arc_max
# Change it with set-arc-max.sh in the mbp11-3-arch repo: it rewrites this file and rebuilds the initramfs.
options zfs zfs_arc_max=$bytes
EOF
  sudo install -m644 "$src" "$conf" && echo "ok   $conf: zfs_arc_max=$bytes"
fi

echo "$bytes" | sudo tee "$param" >/dev/null
cmax=$(awk '$1 == "c_max" {print $3}' /proc/spl/kstat/zfs/arcstats)
echo "ok   live: zfs_arc_max=$(<"$param"), ARC c_max $(numfmt --to=iec-i --suffix=B "$cmax")" \
  "(the ARC shrinks as programs ask for memory)"

echo "== rebuilding the initramfs of every kernel (zfs reads the limit from it at boot)"
rebuild
echo "done. After a reboot check: cat $param"
