---
type: fresh-install-runbook
title: Zenbook UM3406KA — CachyOS с нуля: пошаговый zero-trust runbook
status: VERIFIED-2026-08-12; live-факты сняты с рабочего экземпляра
subject: ASUS Zenbook 14 UM3406KA_UM3406KA (SKU 90NB14U1-M00AL0)
purpose: воспроизводимая установка CachyOS на чистый ноутбук с полным стеком (GPU/NPU/AI/CPU-тюнинг) и проверкой каждого шага; переживает год и переустановку
method: zero trust — каждый шаг имеет команду, ожидаемый результат, verify и rollback; LIVE/VENDOR/HOLD разделены
---

# Zenbook UM3406KA — CachyOS с нуля (fresh install runbook)

## 0. Как читать этот файл

- `LIVE` — проверено на этом экземпляре 2026-08-12; `VENDOR` — спецификация семейства; `HOLD` — требует теста на новой машине; `WARN` — известная ловушка.
- Каждый шаг: **команда → ожидаемый результат → verify → rollback**. Ничего не пропускай «потому что и так понятно».
- Все команды в `root`-shell (`sudo -i`) если не сказано иначе; пользовательские пути — под своим пользователем.
- После установки ДОЛЖЕН полностью пройти раздел 13 (чеклист). Любой FAIL — стоп, чини по rollback, не продолжай.
- Прошивка/BIOS, ядро и версии пакетов со временем меняются — сверяй `uname -r`, `pacman -Q` и BIOS-версию с разделом 1 перед началом.
- **Проверено эмуляцией**: логика установки (разметка → subvolumes → pacstrap → bootloader → linux-zen) прогнана в QEMU VM 2026-08-12; найденные расхождения исправлены в этом файле. Детали: `04-experiments/runbook-qemu-emulation-2026-08-12.md`.

### Что ты увидишь на каждом этапе (краткая карта для непрофессионала)

| Этап | Что должно произойти | Что НЕ должно быть |
|---|---|---|
| BIOS | загрузка с USB, установщик | зависание на логотипе |
| §4 установка | прогресс-бар Calamares, потом «Reboot» | ошибки разметки |
| §5 linux-zen + APST | после reboot: рабочий стол, быстрый NVMe | крах/фриз при загрузке |
| §7 GPU | Wayland-сессия, плавный интерфейс | чёрный экран |
| §8 CPU | `powerprofilesctl get` → performance, tctl 90 | троттлинг до 2.4 GHz на 16T |
| §9 AI | все три lane отвечают `391` на oracle-тест | «421»/ошибки |
| §13 чеклист | `ALL PASS` (37/37) | любой FAIL |

## 1. Идентичность целевой машины (LIVE, сними до стирания)

| Параметр | Значение | Статус |
|---|---|---|
| Модель (DMI) | `ASUSTeK COMPUTER INC. ASUS Zenbook 14 UM3406KA_UM3406KA`, product `1.0` | LIVE |
| SKU | `90NB14U1-M00AL0` | по исходному запросу |
| BIOS на рабочем экземпляре | `UM3406KA.306`, 06/03/2026 | LIVE |
| CPU | AMD Ryzen AI 7 350, 8C/16T, 4×Zen 5 (до 5.0 GHz) + 4×Zen 5c (3.5 GHz), Krackan Point | VENDOR |
| RAM | 32 GB LPDDR5x-7500 (soldered, 4×8 GiB, SMBIOS) | LIVE |
| GPU | Radeon 860M (RDNA 3.5, `1002:1114`, gfx1152, RADV KRACKAN1) | LIVE |
| NPU | XDNA 2 (`1022:17f0`, 50 TOPS маркетинг; FastFlowLM lane работает) | LIVE |
| SSD | WD_BLACK SN850X 2 TB (fw `620361WD`) — ОБЯЗАТЕЛЕН APST-fix, см. §5 | LIVE |
| Дисплей | OLED 14" 2880×1800 120 Hz 10bpc (Samsung ATNA40CT02-0 по семейству) | VENDOR |
| Wi-Fi | MediaTek MT7922 (`mt7921e`) | LIVE |
| Батарея | design 75 Wh, BMS `energy_full` ~68 Wh (cycle 0 — BMS estimate, НЕ диагноз) | LIVE |

**Перед стиранием диска**: сделай внешний backup всего важного (раздел 2). Этот ноутбук физически имеет один NVMe (2 TB), второй M.2 слот в сервисной документации Zenbook 14 не подтверждён — не планируй второй диск без evidence.

## 2. Pre-flight: backup и custody (ДО ВСЕГО)

1. Внешний накопитель ≥ 1 TB, Btrfs или ext4 (LIVE: USB `/dev/sda2`, mount `/mnt/usb-backup`).
2. Скопируй критичные данные и ВЕСЬ `~/obsidian`:
   ```bash
   sudo mount /dev/sdX2 /mnt/usb-backup
   rsync -aHAX --info=progress2 $HOME/obsidian /mnt/usb-backup/obsidian-pre-reinstall/
   rsync -aHAX --info=progress2 $HOME/ai-projects /mnt/usb-backup/ai-projects-pre-reinstall/   # модели, llama.cpp, fastflowlm
   rsync -aHAX --info=progress2 $HOME/.ssh /mnt/usb-backup/dot-ssh-pre-reinstall/
   sudo umount /mnt/usb-backup
   ```
3. Проверь restore-путь на ДРУГОЙ машине (не на той, что стираешь): открыть 1 файл из backup — это proof, что backup читается.
4. Запиши пароли/ключи: LUKS (если шифруешь, §4), wifi, API-токены (хранятся вне backup-копии).
5. Скачай ISO CachyOS (KDE) с https://cachyos.org/download/ и запиши на USB ≥ 4 GB:
   ```bash
   # на любой Linux-машине
   sudo dd if=cachyos.iso of=/dev/sdX bs=4M status=progress conv=fsync
   ```
   Verify: `sha256sum cachyos.iso` сверь с официальным (страница download). WARN: не верь зеркалам без подписи.

## 3. BIOS настройки (до загрузки с USB)

Вход: F2 при включении.

| Параметр | Значение | Зачем |
|---|---|---|
| Secure Boot | **Disabled** | ryzen_smu (out-of-tree DKMS) и ryzenadj без подписи; на рабочем экземпляре off (LIVE) |
| Fast Boot | Disabled | иначе USB может не загрузиться |
| AMD SVM (virtualization) | Enabled | QEMU/VMs |
| USB boot order | USB первым (одноразово F8 → выбрать USB) | установка |

WARN: НЕ меняй ничего про память/питание в BIOS без evidence. APST/ASPM решается на уровне ядра (см. §5), не BIOS.

## 4. Установка CachyOS (Calamares)

1. Загрузись с USB (F8 → USB). Выбери «Boot CachyOS (default)».
2. Welcome → Next. **Выбери профиль: KDE Plasma 6 / Wayland** (LIVE-рабочий экземпляр — KDE Plasma 6 + Wayland, не Hyprland/Noctalia; Niri/Noctalia — отдельный целевой десктоп, НЕ часть этого runbook, см. §14).
3. Разметка диска (Manual):
   - `/dev/nvme0n1` полностью стереть (GPT).
   - ESP: 4 GiB, VFAT, mount `/boot` (рабочий экземпляр: 2 GiB `6399-32D0` — работает, но wiki CachyOS 2026 рекомендует ≥ 4096 MiB для systemd-boot; при свежей установке ставь 4 GiB). WARN: vfat не поддерживает `chattr +i` — backup файлов ESP обычным копированием.
   - Root: остаток, Btrfs, mount `/`.
   - Calamares создаст subvolumes автоматически. Проверь после установки (LIVE-эталон):
     ```
     @  /        @home  /home   @root  /root   @srv  /srv
     @cache  /var/cache   @tmp  /var/tmp   @log  /var/log
     ```
   - LUKS: **рекомендуется** (zero-trust); на рабочем экземпляре LUKS НЕ включён (исторический факт, не эталон). Если выбираешь LUKS — запиши passphrase в 2 местах.
4. Пользователь: `totem`, hostname `zenbook` (рабочий: hostname `zenbook` LIVE).
5. Графика: выбирай «AMD / open source» (amdgpu). Драйвер `xf86-video-amdgpu` ставится по умолчанию — это норм (LIVE), но нужен только для legacy X; Wayland-сессия работает через kernel mode setting.
6. Дождись конца, выключи, вытащи USB, включи.

**После первого boot** — не логинись в GUI до проверок §5 (проще в TTY или сразу в терминале KDE).

## 5. CRITICAL FIX #1 — ядро linux-zen + APST (обязательно, без этого NVMe умирает)

### Почему (LIVE + VENDOR, 2026-08-11)
- **Bug A (firmware)**: WD_BLACK SN850X APST broken — exit latency 45.7 ms, контроллер не выходит из не-operational состояния → NVMe reset fail → крах системы. Затрагивает ВСЕ ядра (Bugzilla #219852). Fix: `nvme_core.default_ps_max_latency_us=0`.
- **Bug B (kernel)**: CachyOS PREEMPT_FULL + EEVDF + Clang -O3/LTO — гонки на Krackan Point (CachyOS #913: vanilla стабилен, cachyos-ядро падает). Fix: `linux-zen`.
- Оба фикса нужны. APST-параметр сам по себе не спасает от Bug B, и наоборот.

### Шаги (в root shell или sudo)
```bash
# 1. Установить linux-zen и заголовки
sudo pacman -S --needed linux-zen linux-zen-headers

# 2. APST drop-in через sdboot-manage (ДОЛГОВЕЧНЫЙ источник; НЕ /etc/kernel/cmdline!)
#    sdboot-kernel-update hook перегенерирует entries при каждом обновлении ядра.
sudo mkdir -p /etc/sdboot-manage.conf.d
sudo tee /etc/sdboot-manage.conf.d/90-apst.conf > /dev/null << 'EOF'
# SN850X APST/ASPM fix (Bugzilla #219852): protect WD_BLACK SN850X
# from NVMe APST deep-power-stall death. Survives kernel updates.
LINUX_OPTIONS="${LINUX_OPTIONS} nvme_core.default_ps_max_latency_us=0 pcie_port_pm=off pcie_aspm=off"
EOF

# 3. Перегенерировать boot entries (каноническая команда — gen)
sudo sdboot-manage gen

# 4. Проверка ДО ребута: параметры в entry
sudo sh -c 'grep options /boot/loader/entries/linux-zen.conf'
#    ОЖИДАЕМО: ... nvme_core.default_ps_max_latency_us=0 pcie_port_pm=off pcie_aspm=off

# 5. КРИТИЧЕСКАЯ проверка (найдено эмуляцией 2026-08-12):
#    linux-zen.conf ДОЛЖЕН существовать, иначе система загрузит старое ядро
#    или не загрузится вовсе.
sudo ls /boot/loader/entries/linux-zen.conf || echo "ENTRY MISSING — см. Fallback ниже"

# 6. Сделать linux-zen default
sudo bootctl set-default linux-zen.conf

# 7. Reboot
sudo reboot
```

**Fallback (если `linux-zen.conf` не создался)** — в чистой Arch-среде `pacman -S linux-zen` создаёт только initramfs, но НЕ entry (проверено в QEMU 2026-08-12). На CachyOS это делает sdboot-manage, но проверяй:
```bash
# Создать entry вручную:
sudo cp /boot/loader/entries/linux-cachyos.conf /boot/loader/entries/linux-zen.conf
sudo sed -i 's/vmlinuz-linux-cachyos/vmlinuz-linux-zen/; s/initramfs-linux-cachyos/initramfs-linux-zen/' /boot/loader/entries/linux-zen.conf
sudo bootctl list   # обе записи видны
```

### Verify после ребута
```bash
uname -r                                   # 7.1.x-zen1-1-zen (НЕ linux-cachyos)
cat /proc/cmdline                          # содержит nvme_core.default_ps_max_latency_us=0 ...
cat /sys/module/nvme_core/parameters/default_ps_max_latency_us   # 0
sudo dmesg | grep -i aspm                  # "PCIe ASPM is disabled" (ожидаемо при pcie_aspm=off)
sudo smartctl -a /dev/nvme0n1 | grep -E "Critical|Percentage used|Media"  # здоровые значения
```

### Rollback
```bash
sudo rm /etc/sdboot-manage.conf.d/90-apst.conf && sudo sdboot-manage gen
sudo bootctl set-default linux-cachyos.conf   # вернуть старое ядро
sudo reboot
```

WARN (проверено 2026-08-11): после КАЖДОГО обновления ядра проверяй `/proc/cmdline` — hook `sdboot-kernel-update` сбрасывает options на vendor-строку, если drop-in отсутствует. Drop-in выше это чинит.

## 6. Базовые пакеты и настройки (LIVE-эталон рабочего экземпляра)

### 6.1 Полный список explicit-пакетов рабочего экземпляра (2026-08-12)
Сохрани как эталон для сверки (см. §13.3) — эталон ДОЛЖЕН лежать в obsidian-проекте, иначе через год на новой машине его не будет:
```bash
pacman -Qeq > $HOME/pacman-explicit-reference.txt
cp $HOME/pacman-explicit-reference.txt $HOME/$HOME/zenbook-cachyos-pack/reference/pacman-explicit-reference.txt
```
Рабочий список (сокращённо, полный в evidence): `base base-devel linux-zen linux-zen-headers amd-ucode mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon lib32-opencl-mesa opencl-mesa xf86-video-amdgpu plasma-desktop powerdevil power-profiles-daemon kscreen dolphin konsole kate ark spectacle gwenview kcalc keepassxc telegram-desktop brave-bin obsidian ghostty git github-cli yay paru ufw networkmanager wpa_supplicant iwd btrfs-progs btrfsmaintenance smartmontools yabsnap fwupd cachyos-kernel-manager cachyos-rate-mirrors restic rclone syncthing typst libdvdcss ffmpeg vlc-plugins-all haruna libreoffice-fresh qemu-desktop stress openssh openssl python python-pip python-numpy sshpass rsync ripgrep nmap filezilla zoom anytype-bin bitwarden-bin xrt xrt-plugin-amdxdna cmake dkms cpupower lm_sensors sysfsutils ...` (см. §13.3 для полной сверки)
WARN: `systemd-resolved`, `fstrim.timer`, `powertop` — НЕ пакеты (юниты/встроенные в systemd/util-linux); не ищи их в pacman.

### 6.2 Установка обязательных (после первого boot)
```bash
sudo pacman -S --needed base-devel git cmake dkms cpupower lm_sensors smartmontools \
  btrfs-progs btrfsmaintenance yabsnap fwupd ufw openssh \
  ghostty ripgrep rsync openssl python python-pip python-numpy stress \
  mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon opencl-mesa lib32-opencl-mesa \
  kio-admin kde-gtk-config power-profiles-daemon
```
WARN (проверено 2026-08-12): `fstrim` — НЕ пакет (входит в `util-linux`, уже в системе); `systemd-resolved` — НЕ пакет (входит в `systemd`). НЕ добавляй их в pacman — получишь «пакет не найден».

### 6.3 AUR-хелпер (paru/yay)
```bash
sudo pacman -S --needed paru      # или yay
paru -Syu                          # первый запуск: инициализация
```
WARN: AUR-пакеты проверяй глазами (PKGBUILD) перед сборкой. На рабочем экземпляре foreign: `anytype-bin bitwarden-bin gruvbox-plus-icon-theme splix squashfs-tools-git zoom`.

### 6.4 Сеть: NetworkManager + UFW (LIVE: UFW active, default deny incoming)
```bash
sudo systemctl enable --now NetworkManager systemd-resolved
sudo ufw default deny incoming && sudo ufw default allow outgoing && sudo ufw enable
sudo systemctl enable --now ufw
sudo ufw status verbose    # Status: active; Default: deny (incoming), allow (outgoing)
```
WARN: не открывай порты без нужды. KDE Connect / LocalSend / Docker-порты на рабочем экземпляре ОТКЛЮЧЕНЫ (см. §14, «что НЕ ставить»).

## 7. GPU / Wayland / дисплей

```bash
# Verify: Wayland-сессия (не X11)
echo $XDG_SESSION_TYPE     # wayland
echo $WAYLAND_DISPLAY      # wayland-0

# Verify: GPU-стек
lspci -nnk | grep -A3 VGA          # 1002:1114, driver amdgpu
vulkaninfo --summary | grep -E "deviceName|driverName"   # AMD Radeon 860M Graphics (RADV KRACKAN1)
glxinfo -B 2>/dev/null | grep -E "OpenGL renderer|OpenGL version" || echo "glxinfo не нужен на Wayland"
```
Ожидаемо: Mesa 26.x, RADV `KRACKAN1` (gfx1152), OpenGL 4.6 Compatibility. Если RADV не KRACKAN1 — обнови `mesa` и `linux-firmware` (`sudo pacman -Syu linux-firmware`), Bug C (MES hang) лечится именно свежим firmware.

## 8. CPU по-максимуму: performance + tctl 90 °C (LIVE, 2026-08-12)

### 8.1 Почему (кратко)
- Фабричный tctl target = 85 °C (SMU). sustained 16T: 2.46 GHz.
- `performance` профиль: +6.7% (2.62 GHz). Плюс tctl 90: **2.76–2.83 GHz (+12–15% от stock)**. tctl 93 — НЕСТАБИЛЬНО (просадки до 1.5 GHz), не использовать.
- Тонкий корпус (1.2 kg, один вентилятор) — 90 °C это потолок надёжности. WARN: при 93 система нестабильна.

### 8.2 Шаг 1 — профиль performance на AC (безопасно, обратимо)
```bash
powerprofilesctl set performance
# KDE PowerDevil: сделать постоянным после событий KDE
# правка ~/.config/powerdevilrc:
#   [AC][Performance]
#   PowerProfile=performance
# backup перед правкой: cp ~/.config/powerdevilrc ~/.config/powerdevilrc.bak && sudo chattr +i ~/.config/powerdevilrc.bak
# (Battery остаётся balanced — батарею не жжём)
```

### 8.3 Шаг 2 — ryzenadj + ryzen_smu (Krackan support)
ВАЖНО (LIVE-факт): тег `v0.19.0` ryzenadj НЕ знает Krackan. Нужен **master** (PR #343/#368). Модуль `ryzen_smu` 0.1.7 из amkillam fork БЕЗ патча не создаёт pm_table для 0x650005 — нужен **адаптированный патч** (сохранён: `02-evidence/ryzen_smu-krackan-full-adapted.patch`, SHA `32007196…`; исходный upstream PR #24 — `ryzen_smu-krackan-pr24.patch`, справка).

```bash
# 1. Собрать ryzenadj из master
git clone --depth 1 https://github.com/FlyGoat/RyzenAdj /tmp/ryzenadj
cd /tmp/ryzenadj && cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j$(nproc)
sudo cp build/ryzenadj /usr/local/bin/ryzenadj

# 2. Модуль ryzen_smu + патч (адаптированный, проверен на чистом клоне 2026-08-12)
git clone --depth 1 https://github.com/amkillam/ryzen_smu /tmp/ryzen_smu
cd /tmp/ryzen_smu
# ПРИМЕНИТЬ патч: 02-evidence/ryzen_smu-krackan-full-adapted.patch
# SHA-256: 32007196a9aa9c7c0f42aef3b0e9716b027778e798695f7aa435800cc7f67e68
# (добавляет CODENAME_KRACKANPOINT, case 0x60, PM table 0x650005 → 0x1000; git apply --check PASS на чистом main)
git apply $HOME/$HOME/zenbook-cachyos-pack/patches/ryzen_smu-krackan-full-adapted.patch
sudo make dkms-install        # требует dkms (уже установлен)
sudo modprobe ryzen_smu
ls /sys/kernel/ryzen_smu_drv/pm_table    # ДОЛЖЕН существовать (без патча его нет!)

# 3. Автозагрузка модуля при boot
sudo tee /etc/modules-load.d/ryzen_smu.conf > /dev/null << 'EOF'
# Load ryzen_smu kernel module at boot (SMU access for ryzenadj on Krackan Point)
ryzen_smu
EOF

# 4. Проверить доступ к SMU
sudo ryzenadj -i | head -12
#    ОЖИДАЕМО: CPU Family: Krackan Point; PM Table Version: 650005; THM LIMIT CORE 85.000
```

### 8.4 Шаг 3 — постоянный tctl 90 на AC
```bash
sudo tee /etc/systemd/system/ryzenadj-tune.service > /dev/null << 'EOF'
[Unit]
Description=RyzenAdj CPU thermal target (Krackan Point, UM3406KA)
After=multi-user.target
ConditionACPower=true

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ryzenadj -f 90

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload && sudo systemctl enable --now ryzenadj-tune.service
```

### 8.5 Verify (после reboot)
```bash
sudo ryzenadj -i | grep -E "THM LIMIT CORE|STAPM LIMIT|PPT LIMIT FAST"
#    THM LIMIT CORE 90.000; STAPM ~47 W; PPT FAST ~51 W
powerprofilesctl get                 # performance (на AC)
# sustained-тест (опционально): 16 потоков 60s
python3 /tmp/cpu_sustained_test.py 60   # avg ~2.7–2.8 GHz при Tctl ~90
```

### 8.6 Rollback (полный)
```bash
powerprofilesctl set balanced
sudo systemctl disable --now ryzenadj-tune.service
sudo rm /etc/modules-load.d/ryzen_smu.conf
sudo dkms remove ryzen_smu/0.1.7 --all
sudo rm /usr/local/bin/ryzenadj
sudo reboot        # tctl вернётся в 85 (BIOS/SMU default)
```

### 8.7 Полный CPU-стек (что ещё настроено на эталоне, LIVE 2026-08-12)

Пользовательский запрос «нет настроек для улучшения CPU» — ниже полный список того, что реально работает:

| Слой | Значение на эталоне | Команда проверки | Зачем |
|---|---|---|---|
| governor | `performance` (после powerprofilesctl) | `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor` | amd-pstate-epp + performance |
| EPP | `performance` | `cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference` | max boost preference |
| amd-pstate | `active` | `cat /sys/devices/system/cpu/amd_pstate/status` | активный режим pstate |
| platform_profile | `performance` (AC) | `powerprofilesctl get` | верхний слой политики |
| tctl target | `90.000` | `sudo ryzenadj -i \| grep THM` | +12–15% sustained |
| sched-ext | **inactive** (scx_loader disabled) | `systemctl is-active scx_loader` | CachyOS по умолчанию НЕ запускает; bpfland не нужен — штатный EEVDF/zen ok |
| ananicy-cpp | **active** | `systemctl is-active ananicy-cpp` | авто-приоритеты процессов (desktop/LLM) |
| NMI watchdog | off (cachyos-settings) | `cat /proc/sys/kernel/nmi_watchdog` | меньше прерываний |

WARN (LIVE 2026-08-12): на этом экземпляре sched-ext НЕ активен и не требуется — не включай bpfland/scx_loader «для галочки»; ananicy-cpp уже управляет приоритетами. Проверяй `systemctl is-active ananicy-cpp` после установки.

### 8.8 Батарея: лимит заряда 80% (правило в системе; ЗНАЧЕНИЕ — решение пользователя)
```bash
# Файлы уже на эталоне (проверено 2026-08-12):
cat /etc/asus-battery-charge-limit              # ВНИМАНИЕ: на эталоне СЕЙЧАС 100 (лимит отключён)
cat /etc/udev/rules.d/99-asus-battery-charge-limit.rules
cat /usr/local/sbin/asus-battery-charge-limit.sh
ls /usr/lib/systemd/system-sleep/asus-battery-charge-limit   # sleep hook (resume) есть
# Установить 80% (рекомендуется для долгой жизни батареи):
sudo sh -c 'echo 80 > /etc/asus-battery-charge-limit'
sudo sh /usr/local/sbin/asus-battery-charge-limit.sh
cat /sys/class/power_supply/BAT0/charge_control_end_threshold   # 80
```
WARN (ArchWiki, LIVE): `charge_control_end_threshold` сбрасывается на 100 при power cycle и после hibernate; переживает suspend-to-RAM. udev-rule (boot) + systemd-sleep hook (resume) переприменяют. НО: конфиг `/etc/asus-battery-charge-limit` на эталоне = 100 (был 80 по verified-facts 08-10, изменён позже) — проверяй фактическое значение перед переустановкой. В пакете по умолчанию 80.

## 9. NPU + локальный AI стек (LIVE, 2026-08-12)

### 9.1 Почему / что есть
- NPU: `/dev/accel/accel0` (amdxdna, XDNA 2), драйвер в ядре с 6.14, firmware `amdnpu/17f0_10/npu_7.sbin`.
- Три lane (все проверены): CPU (llama.cpp), GPU Vulkan (llama.cpp/ollama), NPU (FastFlowLM, Qwen3-4B-NPU2 q4nx @ ~23 t/s).
- ROCm для gfx1152 НЕ в списке ollama — рабочий путь **Vulkan**, не ROCm (документировано AMD: «Additional AMD GPU support provided by Vulkan Library»).

### 9.2 Системные требования NPU (LIVE)
```bash
# memlock unlimited (NPU BAR mmap требует > 8 MB)
sudo tee /etc/security/limits.d/99-npu-memlock.conf > /dev/null << 'EOF'
# AMD NPU / XRT / FastFlowLM: NPU BAR requires MAP_LOCKED > 8MB default
*    soft    memlock    unlimited
*    hard    memlock    unlimited
EOF

# pam_limits активен
grep pam_limits /etc/pam.d/system-login    # session    optional    pam_limits.so (если нет — добавить)

# setcap для xrt-smi (user mmap NPU BAR)
sudo setcap cap_ipc_lock+ep /usr/bin/xrt-smi

# Пакеты XRT
sudo pacman -S --needed xrt xrt-plugin-amdxdna
```

### 9.3 FastFlowLM (NPU lane, user-local, НЕ системный пакет)
```bash
mkdir -p $HOME/ai-projects && cd $HOME/ai-projects
# скачать FastFlowLM v1.0.1 (см. SHA в evidence §13.4), распаковать
# структура: fastflowlm/{flm, flm-real, lib, model_info.json, Qwen3-4B-NPU2/}
# модель уже в комплекте Qwen3-4B-NPU2 (q4nx)
# запуск: ./flm serve :18600
```
Verify:
```bash
$HOME/ai-projects/fastflowlm/flm validate   # PASS
curl -s http://127.0.0.1:18600/v1/models | head -c 300
```
WARN (LIVE): NPU reasoning-задачам нужен `max_tokens ≥ 200` (при 30–100 — «340»-сбой, артефакт truncation). Oracle-тест: `Answer with exactly one number: 17*23=` → `391`, 5/5 при max_tokens=1000.

### 9.4 Ollama (GPU Vulkan lane) — user-local, НЕ системный пакет
ВАЖНО (LIVE 2026-08-12): рабочий ollama — **user-local** `$HOME/ai-projects/ollama-official/bin/ollama serve` (Vulkan RADV), НЕ `pacman ollama` и НЕ systemd-сервис. Системный пакет `ollama` существует в репо, но на эталоне НЕ используется (сервис inactive). Причина: полный контроль версии и lane.

```bash
mkdir -p $HOME/ai-projects/ollama-official
# скачать официальный tarball ollama (см. SHA в evidence §13.4: 5d747a43…), распаковать сюда
cd $HOME/ai-projects/ollama-official
# запуск (Vulkan backend — НЕ ROCm, gfx1152 не поддержан):
./bin/ollama serve
# модели: OLLAMA_MODELS=$HOME/ai-projects/ollama-models
```
Verify GPU lane (Vulkan, не CPU):
```bash
# llama.cpp user-local (см. 9.5) — самый честный замер:
llama-bench -m <model.gguf> -p 512 -n 128 -t 8 -r 5 -o json
# GPU: pp ~245 t/s (7B Q4), tg ~18.5 t/s; CPU: pp ~60, tg ~13.1 (LIVE, эталон)
```

### 9.5 llama.cpp (CPU + Vulkan, user-local)
```bash
cd $HOME/ai-projects
# скачать официальный release llama-bNNN-bin-ubuntu-vulkan-x64.tar.gz
# (SHA в evidence §13.4), распаковать в llama-bNNN-vulkan/
# verify: ./llama-bench --list-devices → "Vulkan0: AMD Radeon 860M Graphics (RADV KRACKAN1)"
```
WARN (LIVE): не меряй one-shot через `llama-cli -p ... -n ...` в терминале — это REPL, зальёт stdout. Используй `llama-bench`; для oracle-теста — `timeout 60 llama-cli ... </dev/null` и парси первую строку.

### 9.6 AI rollback (всё user-local или pacman -R)
```bash
sudo pacman -R xrt xrt-plugin-amdxdna
rm -rf $HOME/ai-projects/*        # ollama user-local + fastflowlm + llama.cpp (после backup моделей!)
rm /etc/security/limits.d/99-npu-memlock.conf
sudo setcap -r /usr/bin/xrt-smi
```
WARN: ollama на эталоне — user-local, НЕ пакет; `pacman -R ollama` НЕ нужен (и упадёт, если системный пакет не ставился).

## 10. Обслуживание: snapshots, btrfs, sysctl

### 10.1 yabsnap (НЕ snapper! Два snapshot-менеджера на одном Btrfs = конфликт)
```bash
yabsnap list            # снапшоты при каждой pacman-операции
yabsnap set-ttl <ts> <ttl>
```
WARN (LIVE): `@home` НЕ снапшотится (root.conf только) — user data через backup/restic, не снапшоты.

### 10.2 fstrim / btrfsmaintenance
```bash
sudo systemctl enable --now fstrim.timer
sudo systemctl list-timers | grep -E "fstrim|btrfs|yabsnap"   # все активны
```

### 10.3 sysctl (эталон рабочего экземпляра)
```bash
# /etc/sysctl.d/99-cachyos-custom.conf (LIVE)
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 5
vm.dirty_background_ratio = 3
# /etc/sysctl.d/99-bbr.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# /etc/sysctl.d/90-disable-ipv6.conf (опционально, LIVE)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
```
WARN (LIVE, проверено 2026-08-12): **udev-правило CachyOS (`/usr/lib/udev/rules.d/30-zram.rules`) ставит `vm.swappiness=150` при активации zram0** и перебивает `99-cachyos-custom.conf` (10). Это штатно для zram (высокий swappiness + zram = правильная пара). НЕ борись с этим; zram 30.5 GiB zstd — эталон (LIVE). Если хочешь 10 — правь udev-правило, но это НЕ рекомендуется: с zram 150 лучше.

### 10.4 btrfs scrub / integrity (HOLD — только после 2 независимых backup)
```bash
sudo btrfs scrub start /
sudo btrfs device stats /    # все 5 счётчиков должны быть 0
```
WARN: на рабочем экземпляре scrub НЕ выполнялся (HOLD). Нулевые счётчики — состояние, не гарантия.

## 11. Безопасность (zero-trust baseline)

| Контроль | Команда | Ожидание |
|---|---|---|
| UFW | `sudo ufw status verbose` | active, deny incoming |
| Secure Boot | BIOS | disabled (требование ryzen_smu) |
| TPM | `ls /dev/tpmrm0` | присутствует |
| Failed units | `systemctl --failed` | пусто |
| Firewall logs | `sudo journalctl -u ufw --since today` | нет подозрительных allow |
| Обновления | `sudo pacman -Syu` еженедельно; `sudo cachyos-kernel-manager` для ядра | актуальные |

WARN (LIVE-факт): рабочий экземпляр имеет `kernel lockdown=none`, без LUKS — это исторические решения, не эталон. Для zero-trust fresh install: LUKS включить (§4), после установки Secure Boot оставить disabled только ради ryzen_smu — альтернатива: подписать модуль MOK (dkms делает сам, §8.3 — sign-ключ `mok.key` создаётся при DKMS build).

## 12. Приложения (рабочий набор, Wayland-first)

```bash
sudo pacman -S --needed obsidian typst libreoffice-fresh haruna vlc-plugins-all \
  telegram-desktop qemu-desktop filezilla syncthing restic rclone nmap openssh
paru -S --needed brave-bin anytype-bin bitwarden-bin zoom   # AUR (проверить PKGBUILD)
```
WARN (LIVE-политика): Wayland-only, без X11/XWayland-приложений без нужды; Electron через `ELECTRON_OZONE_PLATFORM_HINT=wayland`; AppImage/Flatpak когда нативный пакет тащит X11-хвосты.

## 13. Финальный чеклист верификации (ПОЛНЫЙ прогон после установки)

Быстрый автономный прогон (37 проверок, PASS/FAIL, эталон 2026-08-12: 37/37):
```bash
bash $HOME/$HOME/zenbook-cachyos-pack/scripts/verify-install.sh
```
Детальные проверки ниже — для ручной диагностики каждого пункта.

### 13.1 Железо
```bash
# CPU identity
lscpu | grep -E "Model name|CPU\(s\)|Thread|Core"      # Ryzen AI 7 350, 8C/16T
# RAM
free -h                                                 # ~31 GiB
# GPU
lspci -nnk | grep -A3 -i "vga"                          # 1002:1114 amdgpu
vulkaninfo --summary | grep -E "deviceName|driverName"  # RADV KRACKAN1
# NPU
ls /dev/accel/accel0                                    # существует
ls /sys/kernel/ryzen_smu_drv/pm_table                   # существует (после §8.3)
# SSD
sudo smartctl -a /dev/nvme0n1 | grep -E "Model|Critical|Percentage used|Media and Data" # SN850X, 0%, 0 errors
cat /proc/cmdline | grep nvme_core                      # default_ps_max_latency_us=0
# Батарея
cat /sys/class/power_supply/BAT0/energy_full_design     # ~75001000 (75 Wh)
```

### 13.2 Система/службы
```bash
uname -r                                                # 7.1.x-zen1-1-zen
echo $XDG_SESSION_TYPE                                  # wayland
powerprofilesctl get                                    # performance
sudo ryzenadj -i | grep "THM LIMIT CORE"                # 90.000
systemctl --failed                                      # пусто
systemctl --user --failed                               # пусто
sudo ufw status verbose                                 # active, deny incoming
yabsnap list                                            # есть свежий snapshot
```

### 13.3 Сверка пакетов с эталоном
```bash
# Эталон сохранён в проекте (277 пакетов, SHA c96def61…):
#   $HOME/zenbook-cachyos-pack/reference/pacman-explicit-reference.txt
# Сравнение новой машины с эталоном:
comm -23 <(pacman -Qeq | sort) <(sort $HOME/$HOME/zenbook-cachyos-pack/reference/pacman-explicit-reference.txt)
# вывод = пакеты, которых нет в эталоне (могут быть новее — это ок, если осознанно)
```

### 13.4 AI-стек
```bash
# CPU lane
$HOME/ai-projects/llama-bNNN-vulkan/llama-bench -m <7B.q4.gguf> -p 512 -n 128 -t 8 -r 3 -o json
#    CPU pp ~60 t/s, tg ~13 t/s (эталон)
# GPU lane (та же команда, Vulkan билд)
#    pp ~245 t/s, tg ~18.5 t/s (эталон)
# NPU lane
$HOME/ai-projects/fastflowlm/flm validate                       # PASS
curl -s http://127.0.0.1:18600/v1/chat/completions -d '{"model":"Qwen3-4B-NPU2","messages":[{"role":"user","content":"Answer with exactly one number: 17*23="}],"max_tokens":1000}' | grep -o "391"
# Ollama GPU
curl -s http://127.0.0.1:11434/api/chat -d '{"model":"qwen2.5:7b","messages":[{"role":"user","content":"Answer with exactly one number: 17*23="}]}' | tail -1 | grep -o "391"
```
Шаги с SHA артефактов (LIVE, 2026-08-12): FastFlowLM tarball `bd3936cb…`, Qwen2.5-VL-7B Q4_K_M `9258bf05…`, llama-bench Vulkan `4f1fb5eb…` (полные в `02-evidence/ai-*`). Сверяй скачанное: `sha256sum <file>`.

### 13.5 Нагрузочный smoke (после §8)
```bash
# 16 потоков 60s: ожидай avg ~2.7–2.8 GHz, Tctl ~90 (скрипт из 04-experiments)
# 4 потока: avg ~3.7–3.8 GHz
# 1 поток: avg ~4.2 GHz
```

## 14. Что НЕ ставить / не делать (WARN, LIVE-уроки)

1. **Не ставить `snapper`/`cachyos-snapper-support`** поверх yabsnap (конфликт владельцев Btrfs-снапшотов).
2. **Не ставить `linux-cachyos` вместо linux-zen** (Bug B, §5).
3. **Не править `/etc/kernel/cmdline`** для APST — сбросится hook'ом; только `/etc/sdboot-manage.conf.d/` (проверено 2026-08-11).
4. **Не использовать `pcie_aspm=off` как «отключение ASPM»** — этот параметр НЕ трогает firmware-ASPM; реальное отключение = `pcie_aspm.policy=performance`. Для защиты SN850X достаточно `default_ps_max_latency_us=0`.
5. **Не трогать `processor.max_cstate=1`** — Krackan C-states мелкие, это не нужно.
6. **Не ставить Hyprland/Noctalia в этот runbook** — целевой десктоп по профилю пользователя: CachyOS+Niri+Noctalia (отдельный слой, см. skill `noctalia-v5-config`), KDE — rescue. Данный runbook даёт рабочую KDE-базу; переход на Niri/Noctalia — отдельный план.
7. **Не ставить WARP/Avahi/Docker/SearXNG/LocalSend/KDE Connect на постоянку** — рабочий экземпляр их отключил (2026-08-12) как неиспользуемые LAN-слушатели; нужное (SearXNG) поднимается точечно.
8. **Не выводить NPU TOPS → tok/s, GPU FLOPS → tok/s** — разные вещи (zero-trust).
9. **Не называть «cycle 0» батареи здоровьем** — BMS estimate, может быть сброшен EC.
10. **Не мерять GPU одним прогоном llama-cli** — REPL-ловушка (см. §9.5).
11. **PBI (plasma-browser-integration-host) — известная проблема**: 42 краша/день (LIVE 2026-08-12, аудит C28). Причина: запуск с xcb-плагином без display в Wayland. НЕ ставь X11/xcb-зависимости «для фикса» (R20 аудита). Если мешает — отключи расширение Chrome «Plasma Integration» или юнит, НЕ добавляй XWayland.
12. **KWin offscreen framebuffer errors** — 41+ в boot (LIVE): `GL_INVALID_VALUE`, incomplete attachment. Correlation с дефектом драйвера НЕ установлена (R11 аудита). Не «чини» amdgpu-параметрами (R12). Собирай reproducer перед любым выводом.
13. **sched-ext НЕ включать по умолчанию** — на эталоне inactive, штатный планировщик ок (см. §8.7). Проверено A/B (2026-08-12): bpfland на смешанной нагрузке хуже EEVDF (request p99 23 ms vs 17 ms, max 66 ms vs 39 ms) — не включать без чистого бенча на целевой нагрузке.
14. **НЕ включать `amd_pstate/dynamic_epp`** (эксперимент 2026-08-12): конфликтует с power-profiles-daemon — governor падает в powersave, EPP перестаёт писаться («Device busy»), platform_profile=custom. Откат: `echo 0 > .../dynamic_epp` + restart power-profiles-daemon + `powerprofilesctl set performance`.
15. **prefcore (amd-pstate) — readonly, не рычаг**: `hw_prefcore=disabled` из-за CONFIG_AMD_HFI (ядро выбирает HFI вместо prefcore). sysfs prefcore не пишется, параметра модуля нет. P-ядра (Zen 5) 196–208 rank vs E-ядра (Zen 5c) 135 — планировщик и так видит разницу частот.
16. **PSI-gate перед замерами**: две сессии Hermes в Ghostty дают io.some 76–80% — любые CPU/GPU-бенчи в таком фоне НЕдостоверны. Проверяй `/proc/pressure/io` (avg10 < 30%) или останавливай сессии перед тестами. В verify-install.sh есть предупреждение.

## 15. Индекс evidence (файлы проекта, все с SHA в своих манифестах)

| Файл | Роль |
|---|---|
| `03-analysis/zenbook-single-source-of-truth-2026-08-12.md` | единый сводный файл всех фактов |
| `03-analysis/zenbook-universal-comparison-passport-2026-08-12.md` | паспорт, SHA `b15c695f…` |
| `04-experiments/cpu-sustained-red-team-2026-08-12.md` | CPU A/B, tctl 85/90/93, методология |
| `04-experiments/runbook-qemu-emulation-2026-08-12.md` | QEMU-проверка логики установки; найденные расхождения исправлены |
| `02-evidence/pacman-explicit-reference-2026-08-12.txt` | эталон explicit-пакетов (277 шт., SHA `c96def61…`) |
| `04-experiments/zenbook-install-verify.sh` | автономный verify-скрипт (37 проверок; эталон 37/37 PASS) |
| `04-experiments/final-zero-trust-verdict-and-bounded-protocol-2026-08-12.md` | bounded protocol |
| `02-evidence/ryzen_smu-krackan-full-adapted.patch` | **обязательный патч для ryzen_smu** (SHA `32007196…`, git apply PASS на чистом main) |
| `02-evidence/ryzen_smu-krackan-pr24.patch` | исходный upstream PR #24 (справка) |
| `02-evidence/ai-comparison-osint-raw-20260812/`, `…-addendum/` | OSINT raw |
| `04-experiments/local/ai-p0-cpu-20260812/` | AI bench + SHA256SUMS (chattr +i) |

## 16. Сводная таблица: дополнительные пакеты и настройки (зачем/почему)

### Пакеты (сверх базового KDE-профиля CachyOS)

| Пакет | Зачем / почему | Критичность | Rollback |
|---|---|---|---|
| `linux-zen` + `linux-zen-headers` | Bug B на Krackan: cachyos-ядро падает (CachyOS #913); zen стабилен. Headers нужны для DKMS (ryzen_smu) | **CRITICAL** | `bootctl set-default linux-cachyos.conf` |
| `dkms`, `cmake` | сборка ryzen_smu (DKMS) и ryzenadj (cmake) | critical для §8 | `pacman -R` |
| `xrt`, `xrt-plugin-amdxdna` | NPU runtime (FastFlowLM) | critical для NPU | `pacman -R` |
| `ollama` (user-local `$HOME/ai-projects/ollama-official/`) | GPU Vulkan lane локального AI (не ROCm — gfx1152 не поддержан; user-local даёт контроль версии) | critical для AI | удалить dir |
| `mesa`, `lib32-mesa`, `vulkan-radeon`, `lib32-vulkan-radeon`, `opencl-mesa`, `lib32-opencl-mesa` | RADV KRACKAN1 (gfx1152); Vulkan нужен ollama/llama.cpp; 32-bit для Steam-совместимости | critical | `pacman -R` |
| `xf86-video-amdgpu` | legacy X (не для Wayland), ставится по умолчанию — можно удалить | low | `pacman -Rns` |
| `btrfs-progs`, `btrfsmaintenance` | btrfs integrity + scrub/defrag таймеры | medium | `pacman -R` |
| `yabsnap` | снапшоты при pacman-операциях (не snapper!) | medium | `pacman -R` (сначала snapshots) |
| `smartmontools`, `lm_sensors`, `cpupower` | SMART-здоровье NVMe, сенсоры, power-профили (powertop НЕ нужен — не установлен на эталоне) | medium | `pacman -R` |
| `ufw` | firewall default-deny | **CRITICAL** (zero-trust) | `systemctl disable ufw` |
| `fwupd` | обновление прошивок (BIOS/SSD) — проверить до BIOS-флэша | medium | `pacman -R` |
| `cachyos-kernel-manager`, `cachyos-rate-mirrors` | управление ядрами, зеркала | medium | `pacman -R` |
| `ghostty`, `ripgrep`, `git`, `github-cli`, `openssh`, `rsync`, `python`, `python-pip`, `python-numpy`, `stress` | рабочий инструментарий + нагрузочные тесты | medium | `pacman -R` |
| `paru`/`yay` | AUR (brave-bin, bitwarden-bin и др.) | medium | `pacman -R` |
| `obsidian`, `typst`, `libreoffice-fresh`, `telegram-desktop`, `haruna`, `vlc-plugins-all`, `syncthing`, `restic`, `rclone` | приложения/синк/бэкап | low | `pacman -R` |

### Настройки

| Настройка | Файл | Зачем / почему | Критичность | Rollback |
|---|---|---|---|---|
| APST fix | `/etc/sdboot-manage.conf.d/90-apst.conf` | SN850X может умереть от deep-power-stall (Bugzilla #219852); параметр выживает kernel updates | **CRITICAL** | `rm drop-in + sdboot-manage gen` |
| tctl 90 + performance | `ryzenadj-tune.service`, `powerdevilrc` | +12–15% sustained, стабильно; 93 нестабилен | high | `disable service`, `set balanced` |
| ryzen_smu module | `/etc/modules-load.d/ryzen_smu.conf` + DKMS | доступ к SMU для ryzenadj; без патча PR#24 нет pm_table | high | `rm conf`, `dkms remove` |
| memlock unlimited | `/etc/security/limits.d/99-npu-memlock.conf` | NPU BAR mmap | high (NPU) | `rm file` |
| setcap xrt-smi | `cap_ipc_lock+ep` | user mmap NPU | high (NPU) | `setcap -r` |
| zram (CachyOS default) | `/usr/lib/systemd/zram-generator.conf` | 30.5G zstd swap, swappiness 150 через udev — НЕ менять | medium | — |
| sysctl custom | `/etc/sysctl.d/99-cachyos-custom.conf` | SSD/desktop tweaks; НО swappiness перебивается udev (150) — ожидаемо | low | `rm file` |
| UFW default deny | `ufw` | zero-trust сеть | **CRITICAL** | `ufw disable` |
| LUKS (рекоменд.) | Calamares | шифрование диска | high | переустановка |

## 17. Хронология проверки (после каждого шага — следующий)

1. §3 BIOS → §4 install → **reboot**
2. §5 kernel+APST → **reboot** → verify §5
3. §6 пакеты/сеть → verify §13.1–13.2
4. §7 GPU → verify vulkaninfo
5. §8 CPU → **reboot** → verify §8.5 → нагрузочный smoke §13.5
6. §9 AI → verify §13.4 (все три lane!)
7. §10 обслуживание → §13.2 timers
8. §11 безопасность → §13.2 ufw
9. Полный §13 чеклист → PASS/FAIL на каждый пункт → записать в Obsidian

## 18. Что останется HOLD/UNKNOWN после установки (честно)

- MemTest86 (нужен отдельный USB/custody) — RAM 32 GB живёт по SMBIOS, целостность не проверена.
- `btrfs scrub` — только после 2 независимых backup (custody gate).
- Battery rundown / PD contract / dock / Wi-Fi roaming — не тестировались.
- Долговременная надёжность — только лог эксплуатации.
- LUKS на рабочем экземпляре отсутствует — fresh install решает сам.
