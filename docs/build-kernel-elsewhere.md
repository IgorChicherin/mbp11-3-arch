# Building `linux-lts-mbp` on another machine

**English** | [Русский](build-kernel-elsewhere.ru.md) · [Back to the README](../README.md#5-patched-kernel-linux-lts-mbp)

The patched kernel takes 1.5–3 h to build on the MacBook. Any faster x86_64 machine can build it instead: an Arch
Linux box, or any Linux with Docker or Podman using the `archlinux:base-devel` container. Only the two finished
packages travel back to the laptop.

## The one requirement: the same gcc

On the laptop, DKMS compiles `zfs` and `wl` against `linux-lts-mbp-headers` with the **laptop's** gcc. If that gcc
differs from the one that built the kernel, kbuild warns that the compiler differs, and the module build can fail.
So update both machines right before building, and compare:

```sh
sudo pacman -Syu && pacman -Q gcc      # on the laptop
sudo pacman -Syu && pacman -Q gcc      # on the build machine (or inside the container)
```

The versions must match. Keep the laptop from updating gcc again until the kernel is installed.

## Option A: an Arch Linux machine

```sh
sudo pacman -S --needed base-devel git
git clone -b patch/linux-6.18.54-kernel https://github.com/IgorChicherin/reclocked.git
cd reclocked/pkgbuild
./mkpkgbuild.sh --prepare                         # same tag as the laptop's linux-lts; pass it if they differ
cd linux-lts-mbp && MAKEFLAGS="-j$(nproc)" makepkg -sfC
ls *.pkg.tar.zst
```

`makepkg -s` installs the build dependencies (including `rust`, `rust-bindgen`, `rust-src`). Run it as a normal
user: makepkg refuses root.

## Option B: a container (any Linux with Docker or Podman)

```sh
mkdir -p out
docker run --rm -it -v "$PWD/out:/out" archlinux:base-devel bash     # or: podman run ...
```

Inside the container:

```sh
pacman -Syu --noconfirm git sudo
pacman -Q gcc                                     # must match the laptop
useradd -m builder && echo 'builder ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/builder
su - builder
git clone -b patch/linux-6.18.54-kernel https://github.com/IgorChicherin/reclocked.git
cd reclocked/pkgbuild
./mkpkgbuild.sh --prepare
cd linux-lts-mbp && MAKEFLAGS="-j$(nproc)" makepkg -sfC --noconfirm
sudo cp linux-lts-mbp-*.pkg.tar.zst /out/
exit; exit
```

The packages land in `out/` on the host. `--rm` deletes the container afterwards, with its build tree (about
15–25 GB: keep that much free).

## Which kernel version

`./mkpkgbuild.sh --prepare` builds Arch's latest `linux-lts` tag. If the laptop runs a different `linux-lts`, pass
its version so the headers match the stock fallback kernel's series:

```sh
pacman -Q linux-lts                    # on the laptop, e.g. linux-lts 6.18.55-1
./mkpkgbuild.sh --prepare 6.18.55-1    # on the build machine
```

## Install on the laptop

Copy the two packages over (the docs package isn't built):

```sh
scp out/linux-lts-mbp-[0-9]*.pkg.tar.zst out/linux-lts-mbp-headers-*.pkg.tar.zst <laptop>:/tmp/
```

On the laptop, take a snapshot, install, and check DKMS **before rebooting**:

```sh
sudo zfs snapshot zroot/arch0/root@pre-linux-lts-mbp-$(date +%F)
sudo pacman -U /tmp/linux-lts-mbp-[0-9]*.pkg.tar.zst /tmp/linux-lts-mbp-headers-*.pkg.tar.zst
dkms status                              # zfs and broadcom-wl: installed for *-lts-mbp
ls /boot/vmlinuz-linux-lts-mbp /boot/initramfs-linux-lts-mbp.img
```

If DKMS fails for `*-lts-mbp`, don't boot it: the stock `linux-lts` stays the ZBM default. Check
`/var/lib/dkms/<module>/<version>/build/make.log`; a gcc mismatch is the usual cause. Then continue with
[README step 5](../README.md#5-patched-kernel-linux-lts-mbp): test with Ctrl+K, and switch the default yourself.
