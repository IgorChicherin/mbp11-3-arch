#!/usr/bin/env bash
# Test dgpu-off / dgpu-auto with patch 0017. Asks for sudo (reclockctl).
set -uo pipefail
rt() { cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status; }
gl() { DRI_PRIME=1 timeout 20 glxinfo -B 2>/dev/null | grep -m1 'renderer string' | sed 's/.*: //'; }
vk() { timeout 20 vulkaninfo --summary 2>/dev/null | grep -E 'deviceName' | sed 's/.*= //' | paste -sd, -; }
f=/sys/bus/pci/devices/0000:01:00.0/dgpu_disabled
[[ -e $f ]] || { echo "no $f: the running kernel has no patch 0017" >&2; exit 1; }
sudo -v || exit 1

echo "== dgpu-off"
sudo reclockctl dgpu-off; sleep 3
echo "dgpu_disabled=$(cat $f)  (expect 1)"
for i in $(seq 1 30); do [[ $(rt) == suspended ]] && break; sleep 1; done
echo "dGPU: $(rt)  (expect suspended)"
echo "DRI_PRIME=1 GL renderer: $(gl)  (expect Intel/Haswell, not NVE7)"
echo "Vulkan devices: $(vk)  (expect no NVK GK107)"
sleep 2; echo "dGPU after both: $(rt)  (expect still suspended)"
"$(dirname "$0")"/gpu-temps.sh 1 | tail -1

echo "== dgpu-auto"
sudo reclockctl dgpu-auto; sleep 3
echo "dgpu_disabled=$(cat $f)  (expect 0)"
echo "DRI_PRIME=1 GL renderer: $(gl)  (expect NVE7)"
echo "Vulkan devices: $(vk)  (expect NVK GK107 listed)"
for i in $(seq 1 30); do [[ $(rt) == suspended ]] && break; sleep 1; done
echo "dGPU: $(rt)  (expect suspended again)"
grep -o '"open_lock": [-0-9]*\|"last_error": "[^"]*"' /run/reclocked/status
