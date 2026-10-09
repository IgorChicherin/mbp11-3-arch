# Сборка `linux-lts-mbp` на другой машине

[English](build-kernel-elsewhere.md) | **Русский** · [Назад к README](../README.ru.md#5-патченое-ядро-linux-lts-mbp)

На MacBook патченое ядро собирается 1,5–3 часа. Вместо этого его можно собрать на любой более быстрой x86_64-машине:
на Arch Linux или на любом Linux с Docker или Podman в контейнере `archlinux:base-devel`. На ноутбук переносятся
только два готовых пакета.

## Единственное требование: та же версия gcc

На ноутбуке DKMS собирает `zfs` и `wl` по `linux-lts-mbp-headers` компилятором **ноутбука**. Если этот gcc
отличается от того, которым собрано ядро, kbuild предупреждает о другом компиляторе, и сборка модулей может
упасть. Поэтому обновите обе машины прямо перед сборкой и сравните версии:

```sh
sudo pacman -Syu && pacman -Q gcc      # на ноутбуке
sudo pacman -Syu && pacman -Q gcc      # на машине сборки (или в контейнере)
```

Версии должны совпадать. Не обновляйте gcc на ноутбуке, пока не установите ядро.

## Вариант A: машина с Arch Linux

```sh
sudo pacman -S --needed base-devel git
git clone -b patch/linux-6.18.54-kernel https://github.com/IgorChicherin/reclocked.git
cd reclocked/pkgbuild
./mkpkgbuild.sh --prepare                         # тот же тег, что у linux-lts на ноутбуке; если отличается, укажите его
cd linux-lts-mbp && MAKEFLAGS="-j$(nproc)" makepkg -sfC
ls *.pkg.tar.zst
```

`makepkg -s` сам ставит зависимости сборки (в том числе `rust`, `rust-bindgen`, `rust-src`). Запускайте от
обычного пользователя: от root makepkg не работает.

## Вариант B: контейнер (любой Linux с Docker или Podman)

```sh
mkdir -p out
docker run --rm -it -v "$PWD/out:/out" archlinux:base-devel bash     # или: podman run ...
```

Внутри контейнера:

```sh
pacman -Syu --noconfirm git sudo
pacman -Q gcc                                     # должна совпадать с ноутбуком
useradd -m builder && echo 'builder ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/builder
su - builder
git clone -b patch/linux-6.18.54-kernel https://github.com/IgorChicherin/reclocked.git
cd reclocked/pkgbuild
./mkpkgbuild.sh --prepare
cd linux-lts-mbp && MAKEFLAGS="-j$(nproc)" makepkg -sfC --noconfirm
sudo cp linux-lts-mbp-*.pkg.tar.zst /out/
exit; exit
```

Пакеты окажутся в `out/` на хост-машине. `--rm` удаляет контейнер вместе с деревом сборки (примерно 15–25 ГБ:
столько места должно быть свободно).

## Какая версия ядра

`./mkpkgbuild.sh --prepare` собирает последний тег `linux-lts` из Arch. Если на ноутбуке другой `linux-lts`,
укажите его версию, чтобы серия совпадала с запасным стоковым ядром:

```sh
pacman -Q linux-lts                    # на ноутбуке, например linux-lts 6.18.55-1
./mkpkgbuild.sh --prepare 6.18.55-1    # на машине сборки
```

## Установка на ноутбук

Скопируйте два пакета (пакет с документацией не собирается):

```sh
scp out/linux-lts-mbp-[0-9]*.pkg.tar.zst out/linux-lts-mbp-headers-*.pkg.tar.zst <ноутбук>:/tmp/
```

На ноутбуке сделайте snapshot, установите и проверьте DKMS **до перезагрузки**:

```sh
sudo zfs snapshot zroot/arch0/root@pre-linux-lts-mbp-$(date +%F)
sudo pacman -U /tmp/linux-lts-mbp-[0-9]*.pkg.tar.zst /tmp/linux-lts-mbp-headers-*.pkg.tar.zst
dkms status                              # zfs и broadcom-wl: installed для *-lts-mbp
ls /boot/vmlinuz-linux-lts-mbp /boot/initramfs-linux-lts-mbp.img
```

Если DKMS не собрался для `*-lts-mbp`, не загружайте это ядро: по умолчанию в ZBM остаётся стоковый `linux-lts`.
Смотрите `/var/lib/dkms/<модуль>/<версия>/build/make.log`; обычно причина в разных версиях gcc. Дальше — по
[шагу 5 README](../README.ru.md#5-патченое-ядро-linux-lts-mbp): проверка через Ctrl+K, и ядро по умолчанию вы
переключаете сами.
