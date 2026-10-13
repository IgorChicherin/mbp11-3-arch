#!/usr/bin/env bash
# After patch 0018 with split_speakers=1: do the two speaker pairs play two independent PCM devices? (no sudo)
#   1  HIGH tone (1 kHz) on hw:PCH,0 only    -> first pair  ("Speaker")
#   2  LOW tone (500 Hz) on hw:PCH,2 only    -> second pair ("Bass Speaker")
#   3  both at once                          -> both tones together
# Straight to ALSA with PipeWire's card profile off; restores the profile, also on Ctrl+C.
#   ./speaker-split-test.sh
set -euo pipefail
card=alsa_card.pci-0000_00_1b.0
p=/sys/module/snd_hda_codec_cs420x/parameters/split_speakers
[[ -r $p ]] || { echo "ERROR: this kernel has no patch 0018 ($p missing)" >&2; exit 1; }
[[ $(<"$p") == Y ]] || { echo "ERROR: split_speakers is off (see /etc/modprobe.d/cs4208-split.conf)" >&2; exit 1; }
aplay -l | grep -q 'card 1: PCH.*device 2' || { echo "ERROR: no PCM device 2 on the PCH card:"; aplay -l | grep PCH; exit 1; } >&2
old=$(pactl list cards | awk -v c="$card" '$1=="Name:"{p=($2==c)} p&&/Active Profile:/{print $3; exit}')
tmp=$(mktemp -d)
trap 'pactl set-card-profile "$card" "$old" || true; rm -rf "$tmp"; echo "profile restored: $old"' EXIT

python3 - "$tmp" <<'PY'
import math, struct, sys, wave
rate, amp = 48000, 0.4
for name, hz in (("high", 1000), ("low", 500)):
    w = wave.open(f"{sys.argv[1]}/{name}.wav", "wb")
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate)
    n = rate * 3
    frames = bytearray()
    for i in range(n):
        fade = min(1.0, i / 2400, (n - i) / 2400)
        v = int(32767 * amp * fade * math.sin(2 * math.pi * hz * i / rate))
        frames += struct.pack("<2h", v, v)
    w.writeframes(bytes(frames)); w.close()
PY

aplay -l | grep 'card 1: PCH'
pactl set-card-profile "$card" off
sleep 1
echo "1  HIGH tone on device 0 (first pair only)"
aplay -q -D plughw:PCH,0 "$tmp/high.wav"; sleep 0.7
echo "2  LOW tone on device 2 (second pair only)"
aplay -q -D plughw:PCH,2 "$tmp/low.wav"; sleep 0.7
echo "3  both at once"
aplay -q -D plughw:PCH,0 "$tmp/high.wav" & aplay -q -D plughw:PCH,2 "$tmp/low.wav"; wait
echo "Report: step 1 high tone? step 2 low tone? step 3 both?"
