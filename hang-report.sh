#!/usr/bin/env bash
# Collect logs for desktop stalls (the Wayland compositor freezing for seconds) into ~/hang-report.txt.
#   ./hang-report.sh        # current boot
#   ./hang-report.sh -1     # previous boot
# Run as your user (not with sudo): compositor logs are in the user journal; it asks for sudo for the kernel log.
set -uo pipefail   # no -e: an empty grep in the report must not abort it

boot=${1:-0}
out=$HOME/hang-report.txt
[[ $EUID -ne 0 ]] || { echo "run as your user, not root: the compositor log is in your user journal" >&2; exit 1; }
sudo -v || exit 1

# Stall markers: libinput (inside the compositor) reports its timers firing late = the compositor was blocked.
stalls=$(journalctl --user -b "$boot" --no-pager -q -o short-iso \
  | grep -E 'lagging behind by|scheduled expiry is in the past' | cut -c1-16 | uniq || true)

{
  echo "=== $(date -Is)  kernel $(uname -r)  boot $boot"
  echo "=== compositor stalls (libinput, user journal)"
  journalctl --user -b "$boot" --no-pager -q -o short-iso \
    | grep -E 'lagging behind by|scheduled expiry is in the past' | cut -c1-220 || echo "(none)"

  echo "=== kernel warnings/errors (trackpad 'fake finger' spam removed)"
  sudo journalctl -k -b "$boot" -p warning --no-pager -o short-iso | grep -v 'fake finger' | tail -200

  # One window per stall minute: from 30 s before the minute to 15 s after it ends.
  for t in $stalls; do
    t="${t/T/ }:00"
    echo "=== kernel around $t"
    sudo journalctl -k -b "$boot" --no-pager -o short-iso \
      --since "$(date -d "$t 30 sec ago" '+%F %T')" --until "$(date -d "$t 75 sec" '+%F %T')" \
      | grep -v 'fake finger'
  done

  echo "=== suspend/resume"
  sudo journalctl -b "$boot" --no-pager -o short-iso | grep -E 'PM: suspend (entry|exit)|PM: Waking' | tail -30

  echo "=== reclocked"
  sudo journalctl -u reclocked -b "$boot" --no-pager -o short-iso | tail -80

  echo "=== NetworkManager / wl"
  sudo journalctl -u NetworkManager -b "$boot" --no-pager -o short-iso | grep -iE 'wlp3s0|state change|disconnect|powersave' | tail -40

  echo "=== state now"
  cat /run/reclocked/status 2>/dev/null; echo
  sudo cat /sys/kernel/debug/vgaswitcheroo/switch
  iw dev wlp3s0 get power_save 2>&1
} >"$out" 2>&1

echo "wrote $out ($(wc -l <"$out") lines, $(grep -c '^=== kernel around' "$out") stall windows)"
