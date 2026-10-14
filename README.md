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

This repo holds only the personal part: configs, units, package lists and this runbook. The hardware work lives
in two other repositories, which the steps below clone and use:

| Repository | What is in it |
|---|---|
| [reclocked](https://github.com/IgorChicherin/reclocked) (fork, branch `patch/linux-6.18.54-kernel`) | everything for the NVIDIA dGPU: the kernel patch series, the `linux-lts-mbp` package generator, the `reclocked` daemon, test tools, and [how the dGPU behaves day to day](https://github.com/IgorChicherin/reclocked/blob/patch/linux-6.18.54-kernel/docs/mbp11-3.md) |
| [mbp11-3-sound](https://github.com/IgorChicherin/mbp11-3-sound) | everything for sound: the two CS4208 kernel patches, the speaker crossover for PipeWire, test scripts |

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

Arch's `linux-lts` plus two patch sets: the dGPU series from reclocked (`patches/kernel/0002–0017`; without it,
powering the dGPU back on can hang this model) and the two sound patches from mbp11-3-sound (separate tweeter
and woofer devices, the headset microphone). The package generator lives in reclocked and takes the sound patches
through `--extra-patches`. The build takes 1.5–3 h on this laptop, about 30 min stripped. To build it on a faster
machine (Arch or a container) and bring the packages over, see
`~/Projects/reclocked/docs/build-kernel-elsewhere.md`.

```sh
git clone https://github.com/IgorChicherin/mbp11-3-sound ~/Projects/mbp11-3-sound    # reclocked itself was cloned in step 2
cd ~/Projects/reclocked/pkgbuild
# clone Arch's linux-lts, apply both patch sets, stop on any failure:
./mkpkgbuild.sh --prepare --extra-patches=$HOME/Projects/mbp11-3-sound/patches
cd linux-lts-mbp && MAKEFLAGS="-j$(nproc)" makepkg -sfC
# interrupted? resume with: MAKEFLAGS="-j$(nproc)" makepkg -sef   (never -C when resuming)
# progress/ETA from another terminal: ~/Projects/reclocked/build-progress.sh
sudo pacman -U linux-lts-mbp-[0-9]*.pkg.tar.zst linux-lts-mbp-headers-*.pkg.tar.zst
```

**Optional: stripped build.** Adding `--stripped` to the `mkpkgbuild.sh` line builds only the modules this MacBook uses
(281 instead of 6410 on 6.18.55), which makes the build far shorter and the install smaller. The list is
`pkgbuild/modules.seen` (run `./update-modules.sh` to add what is loaded now) plus the hand-kept
`pkgbuild/modules.extra` (USB storage and filesystems, Docker, Thunderbolt and external displays, Bluetooth and
USB peripherals). `./check-modules.sh` verifies that every listed module made it into the kernel. A device whose
driver isn't listed is not detected: boot stock `linux-lts` (Ctrl+K), plug it in, run `./update-modules.sh`, and
rebuild. Details: `~/Projects/reclocked/pkgbuild/README.md`.

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
| `/etc/modprobe.d/zfs-arc.conf` | caps the ZFS cache (ARC) at 1 GiB instead of the default RAM − 1 GiB; needs the same initramfs rebuild; another size: `set-arc-max.sh` (below) |
| `/etc/modprobe.d/cs4208-split.conf` | `split_speakers=1`: woofers on their own sound device (needs the sound patches); applies after a reboot |
| `bcm5974-resume.service` | reloads the trackpad driver after every resume (see "Known issues") |
| `/etc/NetworkManager/conf.d/wifi-powersave.conf` | Wi-Fi power save; check: `iw dev wlp3s0 get power_save` |
| `/etc/systemd/zram-generator.conf` | zram, same as the installer's default |
| `--boot`: `refind.conf`, `refind_linux.conf` | spoof, ZFSBootMenu entry, 2 s timeout |
| `--boot`: `/etc/dracut.conf.d/`, `/etc/zfsbootmenu/` | initramfs and ZBM image settings |

Take a snapshot before installing boot files. The script never rebuilds anything itself: after dracut or
ZFSBootMenu files change, it prints the snapshot, `dracut-install.sh` and `azfs-update-zbm` commands to run.
A changed `refind.conf` works from the next boot.

### Sound: speakers and headset microphone

Needs the kernel from step 5, which includes the two sound patches; on stock `linux-lts` sound works as plain
stereo and the headset microphone does not work. Everything about sound lives in
[mbp11-3-sound](https://github.com/IgorChicherin/mbp11-3-sound), cloned in step 5: the patches, the PipeWire setup, the test scripts and the
measurements. For a kernel that is not built with reclocked's generator, its
`apply-patches.sh /path/to/linux` applies the two patches to any 6.18 tree.

Check: `modinfo snd_hda_codec_cs420x | grep parm` lists `split_speakers` and `headset_mic`.

**Speakers.** Stock Linux sends the same signal to the tweeters and the woofers. With
`/etc/modprobe.d/cs4208-split.conf` (installed above) the woofers get their own device, and a per-user PipeWire
service splits the frequencies and adds a limiter. PipeWire, pipewire-pulse and WirePlumber come with the
desktop; `swh-plugins` (the limiter) is in `state/packages-repo.txt`.

```sh
~/Projects/mbp11-3-sound/pipewire/setup.sh    # no sudo: installs ~/.local/bin/mbp-speakers and its user unit
~/Projects/mbp11-3-sound/tools/speaker-split-test.sh   # tweeters, woofers, both
mbp-speakers show                             # tuning values; change with: mbp-speakers tune KEY=VALUE
```

The output to use is "MacBook Speakers". With headphones plugged in, the service switches to "Built-in Audio"
and back by itself. The service starts only when `split_speakers` is on, so the stock kernel is unaffected.

**Headset microphone.** Nothing to configure: the patched driver detects a headset at plug-in, and
PipeWire switches the input to "Microphone". Check with `~/Projects/mbp11-3-sound/tools/headset-mic-test.sh`.
While a headset with a microphone is plugged in, the audio chip does not sleep. To turn this part off:
`echo 'options snd_hda_codec_cs420x headset_mic=0' | sudo tee /etc/modprobe.d/cs4208-headset.conf`, then reboot.

### Boot splash (plymouth)

The splash needs three things: the `plymouth` package (step 3), dracut's plymouth module in the initramfs (this
repo's `/etc/dracut.conf.d/zfs.conf` no longer omits it; install it with `--boot` above), and `quiet splash` on
the kernel command line. The installer's command line may not have `splash`; set the one from
`state/zfs-zbm-properties.txt`, then rebuild the initramfs:

```sh
sudo zfs set org.zfsbootmenu:commandline='spl.spl_hostid=0x00bab10c zswap.enabled=0 rw quiet splash loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 preempt=full' zroot/arch0/root
sudo plymouth-set-default-theme <theme>   # optional: plymouth-set-default-theme -l lists them; don't use -R
ls /usr/lib/modules/*/pkgbase | sed 's|^/||' | sudo /usr/local/bin/dracut-install.sh
```

### Kernel command line: `preempt=full`

The command line above also carries `preempt=full`: the kernel is built with `PREEMPT_DYNAMIC` and defaults to
`voluntary`; `full` keeps the desktop responsive under load (a kernel build, for example) for a small loss of
throughput. Check after a reboot: `sudo cat /sys/kernel/debug/sched/preempt` shows `(full)`.

### ZFS cache (ARC) limit

`/etc/modprobe.d/zfs-arc.conf` caps the ARC at 1 GiB. To set another limit, give `set-arc-max.sh` the size:

```sh
./set-arc-max.sh 1G        # bytes, or a K/M/G suffix (powers of 1024)
./set-arc-max.sh default   # remove the cap: the OpenZFS default, RAM − 1 GiB
```

The script snapshots `zroot/arch0/root`, writes the conf to `system/` in this repo and to `/etc`, applies the limit
now and rebuilds the initramfs of every kernel. zfs loads from the initramfs, so without the rebuild the old limit
comes back at boot. The size must be above `c_min` in `/proc/spl/kstat/zfs/arcstats` (1/32 of RAM, about 500 MiB
here) and below RAM; ZFS ignores anything else. A lower limit doesn't shrink the ARC at once: it gives memory back as
programs ask for it. `default` takes full effect after a reboot. Check: `cat /sys/module/zfs/parameters/zfs_arc_max`.
Commit the changed `system/etc/modprobe.d/zfs-arc.conf`.

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

**dGPU.** The panel always runs on the iGPU; the dGPU is powered off while nothing uses it and wakes for
`DRI_PRIME=1` apps. `sudo reclockctl dgpu-auto`, `dgpu-on` and `dgpu-off` switch between on demand, held on and
locked off. How it works, the low-battery lock, the test tools and the messages it logs are described in
reclocked: `~/Projects/reclocked/docs/mbp11-3.md`. Two rules to remember: pstates `07`/`0a`/`0e` only, **never
`0f`**; and on a stock kernel never run `dgpu-on`, reboot instead.

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
- The `wl` driver taints the kernel and logs a `field-spanning write` warning at load. It does no harm.
- nouveau and apple-gmux log messages at resume and at every dGPU wake. They are expected:
  `~/Projects/reclocked/docs/mbp11-3.md`, "Messages and known issues".

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
