#!/usr/bin/env bash
# dGPU power events and errors in this boot's kernel log: how many gmux power cycles, nouveau/gmux warnings. Asks for sudo.
sudo -v || exit 1
echo "gmux power-cycles: $(sudo journalctl -k -b --no-pager | grep -c 'Discrete card was power-cycled')"
echo "--- nouveau/gmux/switcheroo errors and warnings"
sudo journalctl -k -b -p warning --no-pager -o short-iso | grep -iE 'nouveau|gmux|switcheroo|pcieport|BUG|hung|timeout' | grep -v 'fake finger' | tail -20
echo "--- last power events"
sudo journalctl -k -b --no-pager -o short-iso | grep -iE 'gmux|switcheroo|nouveau.*(devinit|resum|suspend)' | tail -8
