#!/usr/bin/env bash
# Stress-test on-demand dGPU wake/sleep (runtime PM). No sudo needed. Log: tools/cycle-test.log
#   ./cycle-test.sh          # 10 rounds
#   ./cycle-test.sh 30       # 30 rounds
# Each round: Vulkan load (vkcube 10 s) -> glxinfo right after (card still awake) -> wait for suspend ->
# glxinfo from suspended (kernel wake). Any client that takes longer than 20 s is reported with its kernel
# wait channel and the dGPU runtime state, then killed.
set -uo pipefail

rounds=${1:-10}
log=$(dirname "$0")/cycle-test.log
rt() { cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status; }
fail=0

run() {  # run <label> <seconds> <cmd...>: run a dGPU client, watch it, report a stall
  local label=$1 max=$2; shift 2
  local t0=$SECONDS
  DRI_PRIME=1 "$@" >/dev/null 2>&1 &
  local p=$!
  while kill -0 "$p" 2>/dev/null; do
    if (( SECONDS - t0 > max + 20 )); then
      echo "STALL $label after $((SECONDS - t0))s: stat=$(awk '{print $3}' /proc/$p/stat 2>/dev/null)" \
           "wchan=$(cat /proc/$p/wchan 2>/dev/null) dGPU=$(rt)"
      kill -9 "$p" 2>/dev/null; fail=$((fail + 1)); break
    fi
    sleep 0.5
  done
  wait "$p" 2>/dev/null
  echo "$label ok in $((SECONDS - t0))s, dGPU=$(rt)"
}

wait_suspend() {  # up to 30 s
  local t0=$SECONDS
  while [[ $(rt) != suspended ]] && (( SECONDS - t0 < 30 )); do sleep 1; done
  echo "suspend after $((SECONDS - t0))s: $(rt)"
  [[ $(rt) == suspended ]] || fail=$((fail + 1))
}

{
  echo "=== $(date -Is) $(uname -r), $rounds rounds"
  for r in $(seq 1 "$rounds"); do
    echo "--- round $r"
    run vkcube 10 timeout 10 vkcube
    run glxinfo-after-load 0 glxinfo -B
    wait_suspend
    run glxinfo-from-suspend 0 glxinfo -B
    wait_suspend
  done
  echo "=== done, failures: $fail"
} 2>&1 | tee "$log"
