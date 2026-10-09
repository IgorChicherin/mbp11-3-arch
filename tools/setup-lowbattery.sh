#!/usr/bin/env bash
# Let desktop power profiles (e.g. KDE On Low Battery) run `reclockctl dgpu-off/dgpu-auto/dgpu-on` without a password prompt.
# Installs /etc/sudoers.d/reclockctl (checked with visudo first; a broken sudoers file locks sudo). Asks for sudo.
set -euo pipefail
u=$(id -un)
tmp=$(mktemp)
cat >"$tmp" <<EOT
# Passwordless dGPU power commands, for desktop power-profile scripts (e.g. KDE Power Management -> On Low Battery).
$u ALL=(root) NOPASSWD: /usr/local/bin/reclockctl dgpu-off, /usr/local/bin/reclockctl dgpu-auto, /usr/local/bin/reclockctl dgpu-on
EOT
sudo visudo -cf "$tmp"
sudo install -m 0440 -o root -g root "$tmp" /etc/sudoers.d/reclockctl
rm -f "$tmp"
sudo -k   # drop the cached password so the next line proves the rule works on its own
sudo -n /usr/local/bin/reclockctl dgpu-auto && echo "ok   passwordless reclockctl works"
cat <<'EOT'
Now set your desktop to run these on low battery. KDE: System Settings -> Power Management -> On Low Battery ->
Run custom script:
  When entering:  sudo -n /usr/local/bin/reclockctl dgpu-off
  When leaving:   sudo -n /usr/local/bin/reclockctl dgpu-auto
EOT
