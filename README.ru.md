# Arch Linux на MacBook Pro 11,3 (A1398): инструкция по переустановке

[English](README.md) | **Русский**

Как вернуть этот 15" Retina MacBook Pro (Late 2013 / Mid 2014) в настроенное состояние после чистой установки
через [archinstall_zfs](https://github.com/okhsunrog/archinstall_zfs): корень на ZFS, ZFSBootMenu, dracut, экраном
управляет Intel iGPU, а NVIDIA dGPU выключена, пока не понадобится. Только железо, загрузка и питание: окружение
рабочего стола и приложения — на ваш выбор.
Команды рассчитаны на настройки установщика на этой машине: пул `zroot`, префикс `arch0`, ядро `linux-lts`,
initramfs через dracut.

`system/` повторяет настроенные файлы по абсолютным путям (`system/etc/reclocked.conf` → `/etc/reclocked.conf`).
В `state/` лежит то, что не является файлом: свойства ZFSBootMenu, список пакетов, включённые юниты; эту папку
ведут вручную. `collect.sh` обновляет `system/` с работающей системы. Само ничего не применяется: каждый шаг ниже — команда, которую вы
запускаете сами.

| Компонент | Модель | Драйвер |
|---|---|---|
| CPU | Core i7 Haswell (Crystal Well) | `intel_cpufreq` + schedutil |
| iGPU | Intel Iris Pro 5200 | `i915`, выводит на встроенный eDP-экран |
| dGPU | NVIDIA GT 750M (GK107, Kepler) | `nouveau` + NVK, только PRIME offload |
| GPU-мультиплексор | apple-gmux | `apple_gmux`, `vga_switcheroo` |
| Wi-Fi | Broadcom BCM4360 | `broadcom-wl-dkms` (`wl`) |
| SSD | Apple SM0512F (SATA AHCI) | `ahci` |
| Вентиляторы, датчики | Apple SMC | `applesmc`, управляет `reclocked` |
| Тачпад | bcm5974 (USB) | `bcm5974` |

Целевая цепочка загрузки:

```
Mac EFI → rEFInd (spoof_osx_version 10.9) → ZFSBootMenu → linux-lts-mbp → i915 → встроенный экран
```

**`spoof_osx_version 10.9` обязателен.** EFI от Apple включает Intel iGPU, только если считает, что грузится
macOS. Без этой подмены iGPU остаётся выключенным. Никогда не убирайте её.

---

## 1. rEFInd с подменой для iGPU

Выполните это сразу после archinstall_zfs, **до первой перезагрузки**, из chroot установщика
(`arch-chroot /mnt`, если целевая система ещё смонтирована). Установщик загружает ZFSBootMenu напрямую, и подмена
не срабатывает: iGPU остаётся выключенным, а экран может остаться чёрным. Поставьте rEFInd перед ZFSBootMenu:

```sh
pacman -S --needed refind linux-lts-headers broadcom-wl-dkms git base-devel   # rEFInd, драйвер Wi-Fi, сборка
refind-install                                   # ставит в /boot/efi/EFI/refind и добавляет запись в NVRAM
```

Включите подмену в свежем конфиге (в файле по умолчанию строка закомментирована):

```sh
f=/boot/efi/EFI/refind/refind.conf
sed -i 's/^#*[[:space:]]*spoof_osx_version.*/spoof_osx_version 10.9/' "$f"
grep -q '^spoof_osx_version' "$f" || echo 'spoof_osx_version 10.9' >> "$f"
grep -n '^spoof_osx_version' "$f"   # должно вывести: spoof_osx_version 10.9
```

Настроенный `refind.conf` из этого репозитория ставится на шаге 7. В нём явная запись ZFSBootMenu
(`\EFI\ZBM\vmlinuz.EFI`), `timeout 2` и `use_nvram false`, а сканирование внутреннего диска выключено.
До этого rEFInd находит `EFI/zbm/vmlinuz.EFI` сканированием. Проверьте, что rEFInd стоит первым в порядке загрузки:

```sh
efibootmgr                    # запись Boot#### от rEFInd должна быть первой в BootOrder
efibootmgr -o XXXX,YYYY       # если нет: сначала rEFInd, потом ZBM
```

Если Mac всё равно грузится прямо в ZBM, при звуке включения удерживайте **Option (⌥)** и выберите rEFInd. Потом
исправьте порядок из Linux. Никогда не заменяйте rEFInd на GRUB или systemd-boot.

Перезагрузка: Mac EFI → rEFInd → ZFSBootMenu → Arch.

## 2. Первая загрузка: режим iGPU, Wi-Fi, репозитории

```sh
git clone https://github.com/0xbb/gpu-switch /tmp/gpu-switch
sudo install -m755 /tmp/gpu-switch/gpu-switch /usr/bin/gpu-switch
sudo gpu-switch -i            # со следующей загрузки экраном управляет iGPU (если уже так, ничего не меняется)

nmcli device wifi connect "<SSID>" --ask
iw dev wlp3s0 info            # драйвер wl работает

mkdir -p ~/Projects && cd ~/Projects
git clone -b patch/linux-6.18.54-kernel https://github.com/IgorChicherin/reclocked.git
git clone <адрес этого репозитория> mbp11-3-arch
```

Перезагрузитесь один раз. Теперь `cat /proc/fb` должен показывать `i915drmfb`: экраном управляет iGPU.

## 3. Пакеты

`install-packages.sh` ставит всё из `state/packages-repo.txt` через pacman. Пакеты из AUR не нужны: `zfsbootmenu`
ставит archinstall_zfs. pacman всё равно спрашивает подтверждение перед установкой и при конфликтах.

```sh
cd ~/Projects/mbp11-3-arch
./install-packages.sh --dry-run    # сначала посмотреть списки
./install-packages.sh
```

Скрипт пропускает `zfs-dkms` (шаг 4) и `linux-lts-mbp*` (шаг 5). `mbpfan`, проприетарные драйверы NVIDIA и
mainline `linux` он не ставит никогда, даже если они есть в списке. Пакеты, которых больше нет в репозиториях
Arch, скрипт называет и пропускает. В `packages-repo.txt` только то, что нужно для этой конфигурации (загрузка,
ядро и DKMS, Wi-Fi, графика, инструменты сборки, питание), с комментариями по группам. Окружения рабочего стола и
приложений в списке нет: их вы ставите сами.

## 4. ZFS через DKMS

Готовый `zfs-linux-lts` подходит только к стоковому ядру Arch. Патченому ядру нужен `zfs-dkms`. Сначала snapshot,
потом замена:

```sh
sudo zfs snapshot zroot/arch0/root@pre-zfs-dkms-$(date +%F)
sudo pacman -S zfs-dkms                 # заменяет zfs-linux-lts; нужен linux-lts-headers
dkms status                             # zfs: installed для ядра linux-lts
```

Пересборка DKMS не запускает хук dracut. Пересоберите initramfs и образ ZBM вручную:

```sh
ls /usr/lib/modules/*/pkgbase | sed 's|^/||' | sudo /usr/local/bin/dracut-install.sh
sudo azfs-update-zbm
```

Перезагрузитесь и проверьте `zfs version`: версии userland и kmod должны совпадать.

## 5. Патченое ядро `linux-lts-mbp`

Это `linux-lts` из Arch плюс патчи reclocked для gmux и nouveau (0002–0015) и наши 0016–0017. Они позволяют выключать и
включать dGPU; 0016 делает так, что питание по требованию действительно отключается через gmux, а 0017 добавляет
переключатель `dgpu_disabled` для `reclockctl dgpu-off`. Без них повторное включение dGPU может повесить эту модель. Сборка на этом ноутбуке занимает
1,5–3 часа. Как собрать его на более мощной машине (Arch или контейнер) и перенести пакеты, описано в
[docs/build-kernel-elsewhere.ru.md](docs/build-kernel-elsewhere.ru.md).

```sh
cd ~/Projects/reclocked/pkgbuild
./mkpkgbuild.sh --prepare               # клонирует linux-lts из Arch, накладывает патчи, останавливается при ошибке
cd linux-lts-mbp && MAKEFLAGS="-j$(nproc)" makepkg -sfC
# прервалось? продолжить: MAKEFLAGS="-j$(nproc)" makepkg -sef   (при продолжении никогда не добавлять -C)
# прогресс и оставшееся время из другого терминала: ~/Projects/reclocked/build-progress.sh
sudo pacman -U linux-lts-mbp-[0-9]*.pkg.tar.zst linux-lts-mbp-headers-*.pkg.tar.zst
```

До перезагрузки проверьте, что DKMS собрал для него zfs и wl, а хуки создали его образы:

```sh
dkms status                              # zfs и broadcom-wl: installed и для *-lts-mbp
ls /boot/vmlinuz-linux-lts-mbp /boot/initramfs-linux-lts-mbp.img
```

Ядром по умолчанию в ZFSBootMenu остаётся стоковый `linux-lts` (`state/zfs-zbm-properties.txt`). Сначала
проверьте новое ядро: перезагрузитесь, в меню ZBM нажмите Ctrl+K, выберите `linux-lts-mbp` и убедитесь, что
`uname -r` заканчивается на `-lts-mbp`. Если всё работает, переключите ядро по умолчанию сами. Оставьте якорь
`$`: свойство ищет частичное совпадение.

```sh
sudo zfs set org.zfsbootmenu:kernel='vmlinuz-linux-lts-mbp$' zroot/arch0/root
zfs get org.zfsbootmenu:kernel,org.zfsbootmenu:commandline zroot/arch0/root
```

Стоковый `linux-lts` остаётся запасным: до него один Ctrl+K.

## 6. Демон dGPU `reclocked` (питание, частоты, вентиляторы)

Соберите и установите программы. Конфиг и юнит ставит шаг 7, он же запускает сервис.

```sh
cd ~/Projects/reclocked/src && make
sudo install -m755 reclocked reclockctl /usr/local/bin/
sudo install -m755 ../scripts/pstate.sh /usr/local/bin/pstate.sh
```

**Никогда не ставьте `mbpfan`.** Он и reclocked оба пишут в `fanN_manual`/`fanN_output` у `applesmc` и
перебивают друг друга. Если reclocked остановится, вентиляторами снова управляет Apple SMC.

## 7. Конфиги

`install-configs.sh` копирует каждый файл из `system/` по его настоящему пути. Для каждого файла, который
отличается, скрипт показывает diff, спрашивает подтверждение и сохраняет старый файл как `<файл>.bak-<время>`.
Потом включает установленные юниты (и запускает `reclocked`), перечитывает конфиг NetworkManager и
перезапускает reclocked, если его конфиг изменился.

```sh
cd ~/Projects/mbp11-3-arch
./install-configs.sh --dry-run    # сначала посмотреть diff
./install-configs.sh              # обычные конфиги: reclocked, исправление тачпада, энергосбережение Wi-Fi, zram
./install-configs.sh --boot       # плюс конфиги rEFInd, ZFSBootMenu и dracut; про каждый всегда спрашивает
reclockctl status && reclockctl switch-status   # topology igd, dGPU off
```

Что ставится:

| Файл | Назначение |
|---|---|
| `/etc/reclocked.conf`, `reclocked.service` | выключение dGPU, pstate, кривые вентиляторов |
| `/etc/modprobe.d/nouveau-runpm.conf` | питание dGPU по требованию (`runpm=1` на `*-lts-mbp`); скрипт печатает команду пересборки initramfs |
| `bcm5974-resume.service` | перезагрузка драйвера тачпада после каждого пробуждения (см. «Известные проблемы») |
| `/etc/NetworkManager/conf.d/wifi-powersave.conf` | энергосбережение Wi-Fi; проверка: `iw dev wlp3s0 get power_save` |
| `/etc/systemd/zram-generator.conf` | zram, как по умолчанию у установщика |
| `--boot`: `refind.conf`, `refind_linux.conf` | подмена, запись ZFSBootMenu, таймаут 2 с |
| `--boot`: `/etc/dracut.conf.d/`, `/etc/zfsbootmenu/` | настройки initramfs и образа ZBM |

Перед установкой загрузочных файлов сделайте snapshot. Скрипт сам ничего не пересобирает: если изменились файлы dracut или
ZFSBootMenu, он печатает команды для snapshot, `dracut-install.sh` и `azfs-update-zbm`. Изменённый
`refind.conf` начинает действовать со следующей загрузки.

### Заставка загрузки (plymouth)

Для заставки нужны три вещи: пакет `plymouth` (шаг 3), модуль plymouth от dracut в initramfs (в
`/etc/dracut.conf.d/zfs.conf` из этого репозитория он больше не исключён; ставится с `--boot` выше) и
`quiet splash` в командной строке ядра. В командной строке от установщика `splash` может не быть; задайте строку
из `state/zfs-zbm-properties.txt` и пересоберите initramfs:

```sh
sudo zfs set org.zfsbootmenu:commandline='spl.spl_hostid=0x00bab10c zswap.enabled=0 rw quiet splash loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0' zroot/arch0/root
sudo plymouth-set-default-theme <тема>   # необязательно: список — plymouth-set-default-theme -l; без -R
ls /usr/lib/modules/*/pkgbase | sed 's|^/||' | sudo /usr/local/bin/dracut-install.sh
```

### Профиль питания

От батареи переключайте профиль питания на power-saver (настройки питания вашего окружения могут делать это сами):

```sh
powerprofilesctl set power-saver
```

Видео декодируется через VA-API (`libva-intel-driver`, i965). Аппаратно Haswell декодирует H.264, но не VP9 и AV1.

## 8. Сервисы, финальная проверка, snapshot

В конце `install-packages.sh` перечисляет юниты из `state/enabled-units.txt`, которые ещё не включены. Нужные
включите через `sudo systemctl enable <юнит>`.

```sh
uname -r                                  # *-lts-mbp, если вы переключили ядро по умолчанию
dkms status                               # zfs + broadcom-wl для каждого ядра
reclockctl switch-status                  # igd, dGPU off
systemctl --failed
sudo zfs snapshot zroot/arch0/root@tuned-$(date +%F)
```

---

# Повседневная работа

**Питание dGPU.** Экран всегда работает на iGPU, а dGPU обесточена, пока ею никто не пользуется, как в macOS.
Запустите приложение с `DRI_PRIME=1` (или «запустить на дискретной видеокарте» в меню окружения), и ядро включит
dGPU примерно за секунду; через 5–7 с после того, как последнее приложение перестало её использовать, gmux снова
отключает питание. Это runtime PM nouveau: `/etc/modprobe.d/nouveau-runpm.conf` загружает nouveau с `runpm=1`
только на ядрах `*-lts-mbp`, `[dpower] backend = runpm` в `/etc/reclocked.conf` позволяет reclocked отслеживать
пробуждения, а патч 0016 делает засыпание настоящим отключением питания. Всё, что перечисляет GPU (любое
Vulkan-приложение), ненадолго будит карту. 
| Команда | dGPU |
|---|---|
| `sudo reclockctl dgpu-auto` (по умолчанию) | по требованию: приложения с `DRI_PRIME=1` её будят, gmux снимает питание через 5–7 с после последнего |
| `sudo reclockctl dgpu-on` | держится включённой (без задержки пробуждения, например для долгой игры); рендерят на ней всё равно только приложения с `DRI_PRIME=1`, рабочий стол остаётся на iGPU |
| `sudo reclockctl dgpu-off` | заблокирована: новые приложения не могут её открыть (GL с `DRI_PRIME=1` и Vulkan уходят на iGPU), а когда уже работающие на ней приложения закроются, gmux снимает питание |

`dgpu-off` использует переключатель ядра из патча 0017 (`/sys/bus/pci/devices/0000:01:00.0/dgpu_disabled`);
приложения, которые уже открыли dGPU, и композитор продолжают работать. Режим держится до перезагрузки или следующей
команды; остановка reclocked снимает блокировку. Чтобы Vulkan-приложения переходили на iGPU, нужен `vulkan-intel`
(hasvk).

Как проверить, что карта действительно выключена: `tools/gpu-temps.sh` показывает состояние dGPU и датчики GPU
в SMC. Обесточенная dGPU — это `suspended` и `TG1D` = `-127` (нет показаний); карта, которая только спит, но под
напряжением, держит 55–60 °C. `tools/cycle-test.sh 10` — стресс-тест (нагрузка Vulkan, пробуждение,
засыпание; без sudo), `tools/kernel-check.sh` считает циклы питания через gmux и показывает предупреждения
nouveau и gmux. В `cat /run/reclocked/status` поле `"open_lock"`: 1 — заблокирована (`dgpu-off`), 0 — открыта, -1 —
ядро без 0017.

Только pstate `07`/`0a`/`0e`. **Никогда `0f`**: на Kepler это зависание. Всё это требует патченого ядра: на
стоковом ядре никогда не запускайте `dgpu-on`, вместо этого перезагрузитесь. На запасном стоковом ядре правило
modprobe не срабатывает, и dGPU там просто остаётся включённой.

**После каждого обновления `linux-lts` в Arch** пересоберите патченое ядро: шаг 5, начиная с
`./mkpkgbuild.sh --prepare`. Сначала snapshot, перед перезагрузкой проверьте `dkms status`. Для новой серии LTS
(например, 6.24) патч 0005 нужно портировать заново: см. `~/Projects/reclocked/pkgbuild/README.md`.

# Батарея

Замеры в простое от батареи при яркости ~40%: **~33 Вт** с включённой dGPU (простой на `07`), **~24–29 Вт** с
выключенной. Для этой модели на форумах пишут 9–12 Вт с выключенной dGPU, так что резерв ещё есть.
`sudo powertop --time=30` при выключенной dGPU покажет, доходит ли процессор до состояний PC6/PC7.

Проверено и не применено:

- Управление питанием линка SATA: контроллер SSD Apple его не поддерживает (`ahci_host_caps=c3349f80`: биты
  SALP, SSC и PSC равны 0).
- PCIe ASPM `powersave`: у BCM4360 известные проблемы с ASPM; ~0,5 Вт не стоят риска потерять Wi-Fi.
- i915 FBC/PSR: на Haswell FBC по умолчанию выключен из-за чёрных экранов и зависаний; выигрыш около 0,4 Вт.
- `powertop --auto-tune`: он включает автоприостановку для встроенной USB-клавиатуры и тачпада (`1-12`); у этого
  устройства `power/control` должен оставаться `on`.

# Известные проблемы

- **Рабочий стол замирает на 5–15 секунд после пробуждения.** После S3 тачпад `bcm5974` может вернуться не в
  multitouch-режим и засыпает libinput сообщениями `bcm5974: kernel bug: Invalid fake finger state`, больше 1000
  в минуту, и Wayland-композитор подвисает, разбирая их. `bcm5974-resume.service` (шаг 7) перезагружает драйвер после каждого пробуждения. Вручную:
  `sudo modprobe -r bcm5974 && sudo modprobe bcm5974`. `./hang-report.sh` собирает журналы композитора и ядра вокруг
  зависаний в `~/hang-report.txt`.
- При каждом пробуждении в журнале `nouveau 0000:01:00.0: Unable to change power state from D0 to D3hot, device
  inaccessible`. Это gmux отключил питание dGPU, сообщение безвредно.
- При каждом пробуждении dGPU в журнале `apple_gmux: Discrete card was power-cycled, client reinit
  required`: так и должно быть, это работает отключение питания. Ядро с ранней версией 0016 вдобавок пишет при
  каждом пробуждении `Unable to change power state from D3cold to D0, device inaccessible`: это безвредно (nouveau
  дожидается линка PCIe и восстанавливается); текущий 0016 сначала ждёт, и после следующей пересборки сообщение
  пропадёт.
- Без 0016 runtime PM переводит dGPU только в PCI D3hot: она остаётся под напряжением и тёплой (`TG1D`
  57–62 °C, вентиляторы громче), а после десятков быстрых циклов пробуждения и засыпания зависал KWin. Всегда собирайте
  `linux-lts-mbp` с 0016.
- Драйвер `wl` помечает ядро как tainted и при загрузке пишет предупреждение `field-spanning write`. Это ни на
  что не влияет.

# Правила

- Только rEFInd → ZFSBootMenu → dracut. Без GRUB, без systemd-boot, без mkinitcpio.
- Snapshot перед изменениями загрузчика, initramfs, ядра, ZFS, fstab или GPU-драйвера.
- После любого обновления ядра или ZFS `dkms status` должен показывать zfs и wl для каждого ядра, и только
  потом перезагрузка.
- Никогда не включайте dGPU на стоковом ядре и никогда не используйте pstate `0f`.

# Обновление этого репозитория

```sh
sudo -v && ./collect.sh   # sudo нужен только для конфига rEFInd на ESP, доступного лишь root
git diff                  # проверить, затем закоммитить
```

`collect.sh` никогда не копирует секреты: профилей Wi-Fi (`/etc/NetworkManager/system-connections`) и файлов
`*.bak` в его списке нет.
