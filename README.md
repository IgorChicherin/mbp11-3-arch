# Arch Linux on MacBook Pro 11,3 (A1398): reinstall runbook

**English** | [Русский](README.ru.md)

How to bring this 15" Retina MacBook Pro (Late 2013 / Mid 2014) back to its tuned state after a fresh
[archinstall_zfs](https://github.com/okhsunrog/archinstall_zfs) install: ZFS root, ZFSBootMenu, dracut, Intel
iGPU on the panel, NVIDIA dGPU powered off until needed. Only hardware, boot and power setup: the desktop
environment and applications are up to you.
The commands assume the installer's defaults on this machine: pool `zroot`, prefix `arch0`, kernel `linux-lts`,
initramfs dracut.

`system/` mirrors the tuned files by absolute path (`system/etc/reclocked.conf` → `/etc/reclocked.conf`).
`state/` holds what isn't a file: ZFSBootMenu properties, package list, enabled units; it is curated by hand.
`collect.sh` refreshes `system/` from a running system. Nothing is applied automatically: every step below is a command you run.

| Part | Model | Driver |
|---|---|---|
| CPU | Core i7 Haswell (Crystal Well) | `intel_cpufreq` + schedutil |
| iGPU | Intel Iris Pro 5200 | `i915`, drives the internal eDP panel |
| dGPU | NVIDIA GT 750M (GK107, Kepler) | `nouveau` + NVK, PRIME offload only |
| GPU mux | apple-gmux | `apple_gmux`, `vga_switcheroo` |
| Wi-Fi | Broadcom BCM4360 | `broadcom-wl-dkms` (`wl`) |
| SSD | Apple SM0512F (SATA AHCI) | `ahci` |
| Fans, sensors | Apple SMC | `applesmc`, driven by `reclocked` |
| Trackpad | bcm5974 (USB) | `bcm5974` |

Target boot chain:

```
Mac EFI → rEFInd (spoof_osx_version 10.9) → ZFSBootMenu → linux-lts-mbp → i915 → internal panel
```

**`spoof_osx_version 10.9` is load-bearing.** Apple's EFI powers the Intel iGPU only when it thinks macOS is
booting. Without the spoof, the iGPU stays off. Never remove it.

---

## 1. rEFInd with the iGPU spoof

Do this right after archinstall_zfs finishes, **before the first reboot**, from the installer's chroot
(`arch-chroot /mnt` if the target is still mounted). The installer boots ZFSBootMenu directly, which skips the
spoof: the iGPU stays off and the panel can stay black. Put rEFInd in front of ZFSBootMenu:

```sh
pacman -S --needed refind linux-lts-headers broadcom-wl-dkms git base-devel   # rEFInd, Wi-Fi driver, build tools
refind-install                                   # installs to /boot/efi/EFI/refind, adds an NVRAM entry
```

Enable the spoof in the fresh config (the default file has it commented out):

```sh
f=/boot/efi/EFI/refind/refind.conf
sed -i 's/^#*[[:space:]]*spoof_osx_version.*/spoof_osx_version 10.9/' "$f"
grep -q '^spoof_osx_version' "$f" || echo 'spoof_osx_version 10.9' >> "$f"
grep -n '^spoof_osx_version' "$f"   # must print: spoof_osx_version 10.9
```

The tuned `refind.conf` from this repo comes in step 7. It adds an explicit ZFSBootMenu entry
(`\EFI\ZBM\vmlinuz.EFI`), `timeout 2` and `use_nvram false`, and turns off scanning of the internal disk.
Until then rEFInd finds `EFI/zbm/vmlinuz.EFI` by scanning. Check that rEFInd comes first in the boot order:

```sh
efibootmgr                    # rEFInd's Boot#### must lead BootOrder
efibootmgr -o XXXX,YYYY       # if not: rEFInd first, then ZBM
```

If the Mac still boots straight into ZBM, hold **Option (⌥)** at the chime and pick rEFInd. Then fix the order
from Linux. Never replace rEFInd with GRUB or systemd-boot.

Reboot: Mac EFI → rEFInd → ZFSBootMenu → Arch.

## 2. First boot: iGPU mode, Wi-Fi, repos

```sh
git clone https://github.com/0xbb/gpu-switch /tmp/gpu-switch
sudo install -m755 /tmp/gpu-switch/gpu-switch /usr/bin/gpu-switch
sudo gpu-switch -i            # iGPU drives the panel from the next boot on (no-op if already set)

nmcli device wifi connect "<SSID>" --ask
iw dev wlp3s0 info            # wl driver is up

mkdir -p ~/Projects && cd ~/Projects
git clone -b patch/linux-6.18.54-kernel https://github.com/IgorChicherin/reclocked.git
git clone <this repo's remote> mbp11-3-arch
```

Reboot once. `cat /proc/fb` should now show `i915drmfb`: the iGPU drives the panel.

## 3. Packages

`install-packages.sh` installs everything from `state/packages-repo.txt` with pacman. No AUR packages are needed:
`zfsbootmenu` comes with archinstall_zfs. pacman still asks before installing and on conflicts.

```sh
cd ~/Projects/mbp11-3-arch
./install-packages.sh --dry-run    # see the lists first
./install-packages.sh
```

It skips `zfs-dkms` (step 4) and `linux-lts-mbp*` (step 5), and never installs `mbpfan`, proprietary NVIDIA
drivers or mainline `linux`, even if a list names them. Packages no longer in the Arch repos are reported and
skipped. `packages-repo.txt` holds only what this configuration needs (boot, kernel and DKMS, Wi-Fi, graphics,
build tools, power), grouped with comments. No desktop environment or applications: install those yourself.

## 4. ZFS from DKMS

The prebuilt `zfs-linux-lts` only matches Arch's stock kernel. The patched kernel needs `zfs-dkms`. Snapshot
first, then swap:

```sh
sudo zfs snapshot zroot/arch0/root@pre-zfs-dkms-$(date +%F)
sudo pacman -S zfs-dkms                 # replaces zfs-linux-lts; needs linux-lts-headers
dkms status                             # zfs: installed for the linux-lts kernel
```

DKMS rebuilds don't trigger the dracut hook. Rebuild the initramfs and the ZBM image by hand:

```sh
ls /usr/lib/modules/*/pkgbase | sed 's|^/||' | sudo /usr/local/bin/dracut-install.sh
sudo azfs-update-zbm
```

Reboot and check `zfs version` (userland and kmod must match).

## 5. Patched kernel `linux-lts-mbp`

Arch's `linux-lts` plus reclocked's gmux/nouveau power-cycle patches (0002–0015) and our 0016–0017. Without them,
powering the dGPU back on can hang this model; 0016 makes on-demand power really cut it through gmux, 0017
adds the `dgpu_disabled` switch behind `reclockctl dgpu-off`. The build takes 1.5–3 h on this laptop. To build it on a faster machine (Arch or a container) and bring the
packages over, see [docs/build-kernel-elsewhere.md](docs/build-kernel-elsewhere.md).

```sh
cd ~/Projects/reclocked/pkgbuild
./mkpkgbuild.sh --prepare               # clone Arch's linux-lts, apply patches, stop on any failure
cd linux-lts-mbp && MAKEFLAGS="-j$(nproc)" makepkg -sfC
# interrupted? resume with: MAKEFLAGS="-j$(nproc)" makepkg -sef   (never -C when resuming)
# progress/ETA from another terminal: ~/Projects/reclocked/build-progress.sh
sudo pacman -U linux-lts-mbp-[0-9]*.pkg.tar.zst linux-lts-mbp-headers-*.pkg.tar.zst
```

Before rebooting, check that DKMS built zfs and wl for it, and that the hooks made its images:

```sh
dkms status                              # zfs and broadcom-wl: installed for *-lts-mbp too
ls /boot/vmlinuz-linux-lts-mbp /boot/initramfs-linux-lts-mbp.img
```

The ZFSBootMenu default stays stock `linux-lts` (`state/zfs-zbm-properties.txt`). Test the new kernel first:
reboot, press Ctrl+K in the ZBM menu, pick `linux-lts-mbp`, and check that `uname -r` ends in `-lts-mbp`. When it
works, switch the default yourself. Keep the `$` anchor: the property is a partial match.

```sh
sudo zfs set org.zfsbootmenu:kernel='vmlinuz-linux-lts-mbp$' zroot/arch0/root
zfs get org.zfsbootmenu:kernel,org.zfsbootmenu:commandline zroot/arch0/root
```

Stock `linux-lts` stays installed as the fallback, one Ctrl+K away.

## 6. dGPU daemon `reclocked` (power, clocks, fans)

Build and install the binaries. Step 8 installs its config and unit, and starts it.

```sh
cd ~/Projects/reclocked/src && make
sudo install -m755 reclocked reclockctl /usr/local/bin/
sudo install -m755 ../scripts/pstate.sh /usr/local/bin/pstate.sh
```

**Never install `mbpfan`.** It and reclocked both write `applesmc` `fanN_manual`/`fanN_output` and fight over the
fans. If reclocked stops, the fans fall back to Apple SMC auto control.

## 7. Configs

`install-configs.sh` copies every file from `system/` to its real path. For each file that differs, it shows a
diff, asks, and keeps the old file as `<file>.bak-<timestamp>`. Then it enables the installed units (and starts
`reclocked`), reloads NetworkManager, and restarts reclocked if its config changed.

```sh
cd ~/Projects/mbp11-3-arch
./install-configs.sh --dry-run    # see the diffs first
./install-configs.sh              # everyday configs: reclocked, trackpad fix, Wi-Fi power save, zram
./install-configs.sh --boot       # also rEFInd, ZFSBootMenu and dracut configs; each one always asks
reclockctl status && reclockctl switch-status   # topology igd, dGPU off
```

What it installs:

| File | Purpose |
|---|---|
| `/etc/reclocked.conf`, `reclocked.service` | dGPU power off, pstates, fan curves |
| `/etc/modprobe.d/nouveau-runpm.conf` | on-demand dGPU power (`runpm=1` on `*-lts-mbp`); the script prints the initramfs rebuild |
| `bcm5974-resume.service` | reloads the trackpad driver after every resume (see "Known issues") |
| `/etc/NetworkManager/conf.d/wifi-powersave.conf` | Wi-Fi power save; check: `iw dev wlp3s0 get power_save` |
| `/etc/systemd/zram-generator.conf` | zram, same as the installer's default |
| `--boot`: `refind.conf`, `refind_linux.conf` | spoof, ZFSBootMenu entry, 2 s timeout |
| `--boot`: `/etc/dracut.conf.d/`, `/etc/zfsbootmenu/` | initramfs and ZBM image settings |

Take a snapshot before installing boot files. The script never rebuilds anything itself: after dracut or
ZFSBootMenu files change, it prints the snapshot, `dracut-install.sh` and `azfs-update-zbm` commands to run.
A changed `refind.conf` works from the next boot.

### Boot splash (plymouth)

The splash needs three things: the `plymouth` package (step 3), dracut's plymouth module in the initramfs (this
repo's `/etc/dracut.conf.d/zfs.conf` no longer omits it; install it with `--boot` above), and `quiet splash` on
the kernel command line. The installer's command line may not have `splash`; set the one from
`state/zfs-zbm-properties.txt`, then rebuild the initramfs:

```sh
sudo zfs set org.zfsbootmenu:commandline='spl.spl_hostid=0x00bab10c zswap.enabled=0 rw quiet splash loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0' zroot/arch0/root
sudo plymouth-set-default-theme <theme>   # optional: plymouth-set-default-theme -l lists them; don't use -R
ls /usr/lib/modules/*/pkgbase | sed 's|^/||' | sudo /usr/local/bin/dracut-install.sh
```

### Power profile

On battery, switch the power profile to power-saver (your desktop's power settings may do this for you):

```sh
powerprofilesctl set power-saver
```

Video decoding goes through VA-API (`libva-intel-driver`, i965). Haswell decodes H.264 in hardware, not VP9 or AV1.

## 8. Services, final checks, snapshot

`install-packages.sh` ends by listing the units from `state/enabled-units.txt` that aren't enabled yet;
enable the ones you want with `sudo systemctl enable <unit>`.

```sh
uname -r                                  # *-lts-mbp, once you've switched the default
dkms status                               # zfs + broadcom-wl for every kernel
reclockctl switch-status                  # igd, dGPU off
systemctl --failed
sudo zfs snapshot zroot/arch0/root@tuned-$(date +%F)
```

---

# Daily use

**dGPU power.** The panel always runs on the iGPU, and the dGPU is powered off while nothing uses it, as on
macOS. Start an app with `DRI_PRIME=1` (or "run on the discrete GPU" in your desktop's menu) and the kernel powers
the dGPU on in about a second; 5–7 s after the last app stops using it, gmux cuts its power again. This is nouveau
runtime PM: `/etc/modprobe.d/nouveau-runpm.conf` loads nouveau with `runpm=1` on `*-lts-mbp` kernels only,
`[dpower] backend = runpm` in `/etc/reclocked.conf` lets reclocked follow those wakes, and patch 0016 makes the
sleep a real power cut. Anything that lists GPUs (any Vulkan app) wakes the card briefly.

| Command | dGPU |
|---|---|
| `sudo reclockctl dgpu-auto` (default) | on demand: `DRI_PRIME=1` apps wake it, gmux cuts power 5–7 s after the last one |
| `sudo reclockctl dgpu-on` | held powered (no wake delay, e.g. for a long game); rendering still only for `DRI_PRIME=1` apps, the desktop stays on the iGPU |
| `sudo reclockctl dgpu-off` | locked off: new apps can't open it (`DRI_PRIME=1` GL and Vulkan fall back to the iGPU), and gmux cuts power once apps already on it exit |

`dgpu-off` uses the kernel switch from patch 0017 (`/sys/bus/pci/devices/0000:01:00.0/dgpu_disabled`); apps that
already have the dGPU open, and the compositor, keep working. Overrides last until reboot or the next command;
stopping reclocked unlocks the dGPU. Vulkan apps need `vulkan-intel` (hasvk) to fall back to the iGPU.
`tools/lock-test.sh` checks `dgpu-off`/`dgpu-auto` end to end.

**Lock the dGPU on low battery.** Desktop power profiles run scripts as your user, with no password prompt, so
`tools/setup-lowbattery.sh` first installs `/etc/sudoers.d/reclockctl` (checked with `visudo -c`, mode 0440): only
`reclockctl dgpu-off|dgpu-auto|dgpu-on` become passwordless. Then set the low-battery profile to run
`sudo -n /usr/local/bin/reclockctl dgpu-off` when it starts and `sudo -n /usr/local/bin/reclockctl dgpu-auto` when
it ends (KDE: System Settings → Power Management → On Low Battery → Run custom script). Overrides don't survive a
reboot: the lock comes back only when the profile is entered again.

Checking that it's really off: `tools/gpu-temps.sh` prints the dGPU state and the SMC GPU sensors. A powered-off
dGPU shows `suspended` and `TG1D` = `-127` (no reading); a card that is only asleep but still powered stays at
55–60 °C. `tools/cycle-test.sh 10` stress-tests it (Vulkan load, wake from off, sleep; no sudo) and
`tools/kernel-check.sh` counts the gmux power cycles and shows nouveau/gmux warnings.
`cat /run/reclocked/status` shows `"open_lock"`: 1 locked (`dgpu-off`), 0 open, -1 kernel without 0017.

Pstates `07`/`0a`/`0e` only. **Never `0f`**: it locks up Kepler. All of this needs the patched kernel: on a stock
kernel never run `dgpu-on`, reboot instead. On the stock fallback kernel the modprobe rule doesn't apply, so the
dGPU just stays powered there.

**After every Arch `linux-lts` update**, rebuild the patched kernel: step 5, from `./mkpkgbuild.sh --prepare` on.
Snapshot first, and check `dkms status` before rebooting. A new LTS series (e.g. 6.24) needs a new port of patch
0005: see `~/Projects/reclocked/pkgbuild/README.md`.

# Battery

Measured idle on battery at ~40% brightness: **~33 W** with the dGPU powered (idle at `07`), **~24–29 W** with it
off. Forum reports for this model are 9–12 W with the dGPU off, so more is left to find:
`sudo powertop --time=30` with the dGPU off shows whether the package reaches PC6/PC7.

Checked and not applied:

- SATA link power management: the Apple SSD controller doesn't support it (`ahci_host_caps=c3349f80`: SALP, SSC
  and PSC all 0).
- PCIe ASPM `powersave`: BCM4360 has known ASPM problems; ~0.5 W isn't worth losing Wi-Fi.
- i915 FBC/PSR: FBC is off by default on Haswell after black-screen and lockup bugs; about 0.4 W.
- `powertop --auto-tune`: it autosuspends the internal USB keyboard/trackpad (`1-12`); keep that device's
  `power/control` at `on`.

# Known issues

- **The desktop freezes for 5–15 s after resume.** The `bcm5974` trackpad can come back from S3 out of multitouch mode. It
  then floods libinput with `bcm5974: kernel bug: Invalid fake finger state`, 1000+ times a minute, and the Wayland compositor stalls while it reads them.
  `bcm5974-resume.service` (step 7) reloads the driver after every resume. Manual fix:
  `sudo modprobe -r bcm5974 && sudo modprobe bcm5974`. `./hang-report.sh` collects compositor and kernel logs around
  stalls into `~/hang-report.txt`.
- Every resume logs `nouveau 0000:01:00.0: Unable to change power state from D0 to D3hot, device inaccessible`.
  gmux has cut the dGPU's power; this is harmless.
- Every dGPU wake logs `apple_gmux: Discrete card was power-cycled, client reinit required`: that is
  the power cut working. A kernel built with an early 0016 also logs `Unable to change power state from D3cold to
  D0, device inaccessible` on each wake: harmless (nouveau waits for the PCIe link and recovers); the current 0016
  waits first, so the next rebuild drops it.
- Without 0016, runtime PM only puts the dGPU in PCI D3hot: it stays powered and warm (`TG1D` 57–62 °C, fans up),
  and after dozens of fast wake/sleep cycles KWin froze. Always build `linux-lts-mbp` with 0016.
- The `wl` driver taints the kernel and logs a `field-spanning write` warning at load. It does no harm.

# Rules

- Keep rEFInd → ZFSBootMenu → dracut. No GRUB, no systemd-boot, no mkinitcpio.
- Snapshot before changes to the bootloader, initramfs, kernel, ZFS, fstab or GPU driver.
- After any kernel or ZFS update, `dkms status` must list zfs and wl for every kernel before you reboot.
- Never power the dGPU on with a stock kernel, and never use pstate `0f`.

# Updating this repo

```sh
sudo -v && ./collect.sh   # sudo only for the root-only rEFInd config on the ESP
git diff                  # review, then commit
```

`collect.sh` never copies secrets: Wi-Fi profiles (`/etc/NetworkManager/system-connections`) and `*.bak` files
aren't in its list.
# mbp11-3-arch
