#!/usr/bin/env bash
# Watch dGPU power state and the SMC GPU temperature sensors (no sudo). A dGPU whose power is really cut cools
# toward the case temperature; one only in D3hot stays warm (57-62 C seen before patch 0016).
#   ./gpu-temps.sh        # 3 minutes, a line every 10 s
#   ./gpu-temps.sh 600    # 10 minutes
dur=${1:-180}
d=/sys/devices/platform/applesmc.768
t() { local f; for f in "$d"/temp*_label; do [[ $(<"$f") == "$1" ]] && { echo $(( $(<"${f%_label}_input") / 1000 )); return; }; done; echo '?'; }
echo "time      dGPU       TG0D TG1D  case(Ts0S)  CPU(TC0P)  fan1"
end=$((SECONDS + dur))
while (( SECONDS < end )); do
  printf '%s  %-9s  %3s  %3s   %3s         %3s        %s\n' "$(date +%T)" \
    "$(cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status)" "$(t TG0D)" "$(t TG1D)" "$(t Ts0S)" "$(t TC0P)" \
    "$(cat $d/fan1_input)"
  sleep 10
done
