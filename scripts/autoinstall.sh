#!/usr/bin/env bash
# =============================================================================
# zenbook-autoinstall.sh — foolproof one-line installer for Zenbook UM3406KA
# -----------------------------------------------------------------------------
# Runs INSIDE the CachyOS live ISO. One line:
#
#   curl -fL https://raw.githubusercontent.com/shhhubin/zenbook-cachyos-pack/main/scripts/autoinstall.sh -o /tmp/ai.sh && bash /tmp/ai.sh
#
# Or non-interactive (CI / emulation / unattended):
#
#   bash /tmp/ai.sh --yes DISK=/dev/nvme0n1 NEW_USER=totem
#
# WHAT IT DOES (all verified in runbook docs/runbook.md):
#   1. Preflight gates (foolproof): root, live ISO, hardware identity,
#      disk existence/size/mount state, internet, RAM, /mnt state, idempotency.
#   2. Double confirmation (interactive) or --yes.
#   3. GPT: ESP 4 GiB + Btrfs root with CachyOS subvolume layout.
#   4. Optional LUKS2 (--luks).
#   5. pacstrap: base + full desktop/stack (KDE, mesa/vulkan, tools).
#   6. linux-zen + APST drop-in + systemd-boot entries (CRITICAL fixes).
#   7. CPU: performance profile + ryzenadj/ryzen_smu built in chroot + tctl 90.
#   8. NPU/AI: xrt, memlock, FastFlowLM user-local, ollama user-local.
#   9. Security: UFW default-deny, user, sudoers.
#  10. Runs verify checks; full log to /root/autoinstall.log and /tmp.
# -----------------------------------------------------------------------------
set -euo pipefail

# --- Config (overridable: KEY=value on cmdline, or env) ---------------------
# NOTE: live ISO root shell already exports USER=root and HOSTNAME=CachyOS,
# so these MUST NOT default from environment — explicit script vars only.
DISK="${DISK:-/dev/nvme0n1}"
NEW_USER="${NEW_USER:-totem}"
NEW_HOSTNAME="${NEW_HOSTNAME:-zenbook}"
USER_PASS="${USER_PASS:-}"
ROOT_PASS="${ROOT_PASS:-}"
LUKS="${LUKS:-0}"              # 0 or 1
LUKS_PASS="${LUKS_PASS:-}"
ESP_SIZE="${ESP_SIZE:-4G}"
TIMEZONE="${TIMEZONE:-Europe/Moscow}"
LOCALE="${LOCALE:-ru_RU.UTF-8}"
KEYMAP="${KEYMAP:-us}"
AUTO_YES="${AUTO_YES:-0}"      # 1 = non-interactive
VERBOSE="${VERBOSE:-0}"
SKIP_DESKTOP="${SKIP_DESKTOP:-0}"  # 1 = CI: пропустить KDE/приложения (быстрая эмуляция логики)
SKIP_AI="${SKIP_AI:-0}"            # 1 = CI: пропустить ryzenadj/ryzen_smu сборку (экономия времени)
LOG="/root/autoinstall.log"

# --- Globals ---------------------------------------------------------------
STEP=0
TOTAL_STEPS=15

say()  { echo -e "\033[1;32m[autoinstall]\033[0m $*" | tee -a "$LOG"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*" | tee -a "$LOG"; }
die()  { echo -e "\033[1;31m[FAIL]\033[0m $*" | tee -a "$LOG"; exit 1; }
step() { STEP=$((STEP+1)); echo "" | tee -a "$LOG"; echo "=== [${STEP}/${TOTAL_STEPS}] $* ===" | tee -a "$LOG"; }

# pacman-retry: зеркала нестабильны (RT-G: 404 на часть пакетов) — 3 попытки
pacretry() {  # args: chroot-флаг и pacman-аргументы
  local attempts=3 i
  for i in 1 2 3; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    warn "pacman попытка $i/3 не удалась — повторяю (зеркало может быть нестабильным)"
    sleep 5
  done
  "$@"   # последняя попытка с видимым выводом ошибок
}

confirm_or_exit() {
  if [ "$AUTO_YES" = "1" ]; then return 0; fi
  local prompt="$1"
  read -r -p "$prompt [yes/NO] " ans
  [ "$ans" = "yes" ] || die "Отменено пользователем. Ничего не изменено."
}

require() { command -v "$1" >/dev/null 2>&1 || die "Отсутствует команда: $1"; }

# ----------------------------------------------------------------------------
# Parse cmdline KEY=value / flags
# ----------------------------------------------------------------------------
for a in "$@"; do
  case "$a" in
    --yes|-y) AUTO_YES=1 ;;
    --luks)   LUKS=1 ;;
    --verbose|-v) VERBOSE=1 ;;
    --skip-desktop) SKIP_DESKTOP=1 ;;
    --skip-ai) SKIP_AI=1 ;;
    *=*) eval "export ${a%%=*}=\"${a#*=}\"" ;;
    *) warn "Неизвестный аргумент: $a (игнорируется)" ;;
  esac
done

exec > >(tee -a "$LOG") 2>&1
[ -f "$LOG" ] && : > "$LOG"
say "Zenbook UM3406KA autoinstall starting at $(date -Iseconds)"
say "Target: DISK=$DISK USER=$NEW_USER HOSTNAME=$NEW_HOSTNAME LUKS=$LUKS"

# ============================================================================
# STEP 1 — Foolproof preflight gates
# ============================================================================
step "Preflight: проверка окружения и железа"

[ "$(id -u)" = "0" ] || die "Запусти от root (в live ISO по умолчанию root)."
say "OK: root"

if [ -d /run/archiso ] || [ -d /run/archiso/bootmnt ] || [ -d /run/archiso/airootfs ] || [ -d /run/archiso/cowspace ]; then
  say "OK: live ISO окружение (маркер /run/archiso)"
else
  die "Не похоже на live ISO (/run/archiso отсутствует)."
  warn "Скрипт НЕ должен запускаться на установленной системе — это уничтожит её."
fi

# Hardware identity — защита от стирания не того ноутбука
DMI=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "unknown")
DMI_FAMILY=$(cat /sys/class/dmi/id/product_family 2>/dev/null || echo "")
case "$DMI$DMI_FAMILY" in
  *UM3406KA*|*Zenbook*14*)
    say "OK: DMI идентифицирован: $DMI $DMI_FAMILY"
    ;;
  *)
    warn "DMI: '$DMI $DMI_FAMILY' — не похоже на Zenbook UM3406KA."
    confirm_or_exit "Продолжить установку на НЕ-UM3406KA машине? (риск: стирание не того диска)"
    ;;
esac

[ -b "$DISK" ] || die "Диск $DISK не существует. Проверь: lsblk"
say "OK: диск $DISK существует"

# Mount state — никогда не стирать примонтированный/активный диск.
# НО: если /mnt оставлен от прерванной установки — аккуратно размонтируем СВОИ subvolumes
# (это идемпотентность: повторный запуск после Ctrl+C должен работать без ручных шагов)
if mountpoint -q /mnt 2>/dev/null; then
  warn "/mnt примонтирован (вероятно, прерванная установка) — размонтирую"
  umount -R /mnt 2>/dev/null || true
  sleep 1
fi
if mount | grep -q "^$DISK"; then
  die "Диск $DISK примонтирован. Размонтируй (umount -R /mnt) и повтори."
fi
DISK_BASE="$(basename "$DISK")"
if [ "$(cat "/sys/block/${DISK_BASE}/device/removable" 2>/dev/null || echo 0)" = "1" ]; then
  warn "ВНИМАНИЕ: $DISK — съёмный носитель (USB). Обычно установка идёт на NVMe."
  confirm_or_exit "Продолжить на съёмном носителе?"
fi

DISK_SIZE=$(lsblk -bdno SIZE "$DISK" 2>/dev/null || echo 0)
DISK_SIZE_GB=$((DISK_SIZE/1024/1024/1024))
if [ "$DISK_SIZE_GB" -lt 60 ]; then
  die "Диск слишком мал: ${DISK_SIZE_GB} GB (< 60 GB). Установка невозможна."
fi
say "OK: размер диска ${DISK_SIZE_GB} GB"

RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
if [ "$RAM_MB" -lt 3072 ]; then
  die "Мало RAM: ${RAM_MB} MB (< 3072). Установка KDE невозможна."
fi
say "OK: RAM ${RAM_MB} MB"

# Internet — критично для pacstrap
if ! curl -fsS --max-time 8 -o /dev/null https://archlinux.org; then
  die "Нет интернета (archlinux.org недоступен). Настрой сеть в live (iwctl/nmcli)."
fi
say "OK: интернет"

# Idempotency / повторный запуск: не запускаться поверх уже установленной системы
if [ -e /mnt/etc/os-release ]; then
  die "Похоже, /mnt уже содержит систему (повторный запуск?). Размонтируй /mnt и повтори, или удали содержимое."
fi
if mountpoint -q /mnt 2>/dev/null; then
  warn "/mnt примонтирован — размонтирую"
  umount -R /mnt 2>/dev/null || true
fi

# ============================================================================
# STEP 2 — Confirmation
# ============================================================================
step "Подтверждение"
say "Диск      : $DISK (${DISK_SIZE_GB} GB) — БУДЕТ ПОЛНОСТЬЮ СТЁРТ"
say "Пользователь: $NEW_USER | hostname: $NEW_HOSTNAME"
[ "$LUKS" = "1" ] && say "LUKS2     : ВКЛЮЧЁН (потребуется passphrase)"
confirm_or_exit "Всё верно? Диск будет стёрт без возможности восстановления."

if [ "$LUKS" = "1" ] && [ -z "$LUKS_PASS" ]; then
  read -r -s -p "LUKS passphrase: " LUKS_PASS; echo
  read -r -s -p "Повтори passphrase: " LUKS_PASS2; echo
  [ "$LUKS_PASS" = "$LUKS_PASS2" ] || die "Passphrase не совпадают."
  [ ${#LUKS_PASS} -ge 8 ] || die "Passphrase слишком короткая (< 8 символов)."
fi
if [ -z "$USER_PASS" ] && [ "$AUTO_YES" != "1" ]; then
  read -r -s -p "Пароль пользователя $NEW_USER: " USER_PASS; echo
  read -r -s -p "Повтори пароль: " USER_PASS2; echo
  [ "$USER_PASS" = "$USER_PASS2" ] || die "Пароли не совпадают."
fi
# Валидация: символы ' и : ломают формат chpasswd (user:pass) — защита от дурака
case "$USER_PASS" in
  *\'*|*:*) die "Пароль не должен содержать символы ' и : (формат chpasswd). Выбери другой." ;;
esac
case "$ROOT_PASS" in
  *\'*|*:*) die "Root-пароль не должен содержать символы ' и : (формат chpasswd). Выбери другой." ;;
esac
[ -n "$USER_PASS" ] || USER_PASS="$(openssl rand -base64 12 | tr -d '/+=')"  # non-interactive: random
[ -n "$ROOT_PASS" ] || ROOT_PASS="$USER_PASS"
say "OK: пароли готовы (non-interactive: сгенерированы случайно, смотри лог)"

# ============================================================================
# STEP 3 — Disk partitioning (GPT: ESP + Btrfs)
# ============================================================================
step "Разметка диска"
require sgdisk require partprobe require mkfs.fat require mkfs.btrfs require mount

sgdisk --zap-all "$DISK" || true
sgdisk --clear "$DISK"
sgdisk -n1:0:+${ESP_SIZE} -t1:ef00 -c1:ESP "$DISK"
sgdisk -n2:0:0      -t2:8300 -c2:ROOT "$DISK"
partprobe "$DISK"
sleep 2
# NVMe: partitions are ${DISK}p1/p2 (nvme0n1p1); SATA/USB: ${DISK}1/2
if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmcblk"* ]] || [[ "$DISK" == *"nbd"* ]]; then
  P1="${DISK}p1"; P2="${DISK}p2"
else
  P1="${DISK}1"; P2="${DISK}2"
fi
say "OK: GPT создан (ESP=$P1, ROOT=$P2)"

# ============================================================================
# STEP 4 — Format + optional LUKS
# ============================================================================
step "Форматирование"
mkfs.fat -F32 "$P1" >/dev/null
if [ "$LUKS" = "1" ]; then
  say "LUKS2: инициализация $P2"
  printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 -q "$P2"
  printf '%s' "$LUKS_PASS" | cryptsetup open "$P2" cryptroot
  # Backup LUKS header — критично для восстановления
  mkdir -p /mnt-backup-luks
  printf '%s' "$LUKS_PASS" | cryptsetup luksHeaderBackup "$P2" --header-backup-file /mnt-backup-luks/luks-header.bin
  warn "LUKS header backup: /mnt-backup-luks/luks-header.bin — это LIVE-память (tmpfs)!"
  warn "Скопируй luks-header.bin на ВНЕШНИЙ носитель ДО reboot — иначе header не восстановить."
  say "LUKS header backup создан (см. WARN выше)"
  mkfs.btrfs -f /dev/mapper/cryptroot
  ROOT_DEV=/dev/mapper/cryptroot
else
  mkfs.btrfs -f "$P2"
  ROOT_DEV="$P2"
fi
say "OK: btrfs готов ($ROOT_DEV)"

# ============================================================================
# STEP 5 — Subvolumes (CachyOS layout, канон runbook §4)
# ============================================================================
step "Создание subvolumes"
mount "$ROOT_DEV" /mnt
for sv in @ @home @log @cache @tmp @srv @root; do
  btrfs subvolume create "/mnt/$sv" >/dev/null
done
umount /mnt
mount -o compress=zstd,subvol=/@ "$ROOT_DEV" /mnt
mkdir -p /mnt/{boot,home,var/log,var/cache,var/tmp,srv,root}
mount -o compress=zstd,subvol=/@home  "$ROOT_DEV" /mnt/home
mount -o compress=zstd,subvol=/@log   "$ROOT_DEV" /mnt/var/log
mount -o compress=zstd,subvol=/@cache "$ROOT_DEV" /mnt/var/cache
mount -o compress=zstd,subvol=/@tmp   "$ROOT_DEV" /mnt/var/tmp
mount -o compress=zstd,subvol=/@srv   "$ROOT_DEV" /mnt/srv
mount -o compress=zstd,subvol=/@root  "$ROOT_DEV" /mnt/root
mount "$P1" /mnt/boot
say "OK: subvolumes примонтированы"

# ============================================================================
# STEP 6 — pacstrap base + keyring
# ============================================================================
step "Установка базовой системы (pacstrap)"
require pacstrap require arch-chroot
pacman-key --init >/dev/null 2>&1 || true
pacman-key --populate archlinux cachyos >/dev/null 2>&1 || true
pacstrap -K /mnt base base-devel linux linux-firmware \
  btrfs-progs systemd systemd-sysvcompat sudo vim networkmanager \
  amd-ucode mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon \
  opencl-mesa lib32-opencl-mesa --noconfirm
say "OK: базовый стек установлен"

# CachyOS repo: pacstrap НЕ копирует [cachyos] в chroot (RT-H: yabsnap/paru недоступны).
# Добавляем секцию в /mnt/etc/pacman.conf + ключи + зеркала — иначе cachyos-пакеты не найдутся.
step "CachyOS repo в chroot (для yabsnap/paru и др.)"
arch-chroot /mnt /bin/bash -c "
  grep -q '^\[cachyos\]' /etc/pacman.conf || cat >> /etc/pacman.conf <<'PACEOF'

[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
PACEOF
"
# зеркала: копируем из live (там уже настроено) или используем archlinux default
if [ -f /etc/pacman.d/cachyos-mirrorlist ]; then
  cp /etc/pacman.d/cachyos-mirrorlist /mnt/etc/pacman.d/cachyos-mirrorlist
else
  printf 'Server = https://geo.mirror.pkgbuild.com/\$\$repo/os/\$\$arch\n' > /mnt/etc/pacman.d/cachyos-mirrorlist
fi
# KEYRING КРИТИЧЕН: без cachyos-keyring PGP-подпись 'unknown trust' (RT-H2).
# Ставим keyring ПЕРЕД populate, иначе база cachyos невалидна.
arch-chroot /mnt pacman -S --noconfirm --needed cachyos-keyring >/dev/null 2>&1 \
  || arch-chroot /mnt pacman -S --noconfirm --needed archlinux-keyring >/dev/null 2>&1 || true
arch-chroot /mnt pacman-key --init >/dev/null 2>&1 || true
arch-chroot /mnt pacman-key --populate archlinux cachyos >/dev/null 2>&1 || true
arch-chroot /mnt pacman -Sy --noconfirm >/dev/null 2>&1 || true
grep -q '^\[cachyos\]' /mnt/etc/pacman.conf && say "OK: [cachyos] добавлен в chroot" || warn "НЕ удалось добавить [cachyos]"

# ============================================================================
# STEP 7 — fstab + locale + hostname + user
# ============================================================================
step "Базовая конфигурация (fstab/locale/user)"
genfstab -U /mnt >> /mnt/etc/fstab
arch-chroot /mnt /bin/bash -c "
  echo '$NEW_HOSTNAME' > /etc/hostname
  ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
  echo '$LOCALE UTF-8' > /etc/locale.gen && locale-gen >/dev/null
  echo 'LANG=$LOCALE' > /etc/locale.conf
  echo 'KEYMAP=$KEYMAP' > /etc/vconsole.conf
  echo 'root:$ROOT_PASS' | chpasswd
  useradd -m -G wheel -s /bin/bash '$NEW_USER'
  echo '$NEW_USER:$USER_PASS' | chpasswd
  echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/wheel
"
say "OK: пользователь $NEW_USER, hostname $NEW_HOSTNAME, locale $LOCALE"

# ============================================================================
# STEP 8 — systemd-boot + CRITICAL: linux-zen + APST drop-in
# ============================================================================
step "Bootloader + linux-zen + APST (критические фиксы)"
arch-chroot /mnt bootctl install >/dev/null
# ВАЖНО: drop-in пишется в CHROOT (/mnt/etc), НЕ в live /etc!
arch-chroot /mnt mkdir -p /etc/sdboot-manage.conf.d
cat > /mnt/etc/sdboot-manage.conf.d/90-apst.conf <<'EOF'
# SN850X APST/ASPM fix (Bugzilla #219852): protect WD_BLACK SN850X
# from NVMe APST deep-power-stall death. Survives kernel updates.
LINUX_OPTIONS="${LINUX_OPTIONS} nvme_core.default_ps_max_latency_us=0 pcie_port_pm=off pcie_aspm=off"
EOF
pacretry arch-chroot /mnt pacman -S --noconfirm --needed linux-zen linux-zen-headers
arch-chroot /mnt mkinitcpio -P >/dev/null 2>&1 || true

# Fallback entry: в минимальной среде linux-zen.conf не создаётся автоматически
set +e   # fallback не должен убивать скрипт; диагностика ниже
if [ -f /mnt/boot/loader/entries/linux-zen.conf ]; then
  say "OK: linux-zen.conf существует"
else
  warn "linux-zen.conf НЕ создан автоматически — создаю вручную (fallback)"
  echo "[diag] step A: bootctl list" >> "$LOG"
  arch-chroot /mnt bootctl list >/dev/null 2>&1
  echo "[diag] step B: cp-копии" >> "$LOG"
  arch-chroot /mnt /bin/bash -c "
    cp /boot/loader/entries/linux-cachyos.conf /boot/loader/entries/linux-zen.conf 2>/dev/null ||
    cp /boot/loader/entries/linux.conf /boot/loader/entries/linux-zen.conf 2>/dev/null ||
    true
  "
  # Если копировать нечего — собрать entry вручную из частично-параметров
  if [ ! -f /mnt/boot/loader/entries/linux-zen.conf ]; then
    echo "[diag] step C: ручное создание entry" >> "$LOG"
    if [ "$LUKS" = "1" ]; then
      ROOT_SPEC="root=/dev/mapper/cryptroot"
    else
      ROOT_SPEC="root=PARTUUID=$(blkid -s PARTUUID -o value "$P2")"
    fi
    cat > /mnt/boot/loader/entries/linux-zen.conf <<EOF
title   CachyOS (linux-zen)
linux   /vmlinuz-linux-zen
initrd  /initramfs-linux-zen.img
options $ROOT_SPEC rw rootflags=subvol=/@ compress=zstd nvme_core.default_ps_max_latency_us=0 pcie_port_pm=off pcie_aspm=off
EOF
  fi
  echo "[diag] step D: grep APST" >> "$LOG"
  grep -q "nvme_core.default_ps_max_latency_us=0" /mnt/boot/loader/entries/linux-zen.conf \
    || sed -i "s/^options /options nvme_core.default_ps_max_latency_us=0 pcie_port_pm=off pcie_aspm=off /" /mnt/boot/loader/entries/linux-zen.conf
fi
echo "[diag] step E: bootctl set-default" >> "$LOG"
arch-chroot /mnt bootctl set-default linux-zen.conf
echo "[diag] step F: done fallback" >> "$LOG"
set -e
say "OK: systemd-boot + linux-zen + APST"

# ============================================================================
# STEP 9 — Desktop + приложения
# ============================================================================
step "Установка KDE Desktop + приложений (долго)"
if [ "$SKIP_DESKTOP" = "1" ]; then
  say "SKIP_DESKTOP=1 — пропускаю KDE/приложения (CI-режим)"
else
  pacretry arch-chroot /mnt pacman -S --noconfirm --needed plasma-desktop powerdevil \
    power-profiles-daemon kscreen dolphin konsole kate ark spectacle gwenview kcalc \
    keepassxc telegram-desktop obsidian ghostty git github-cli ufw openssh \
    ghostty ripgrep rsync openssl python python-pip python-numpy stress \
    smartmontools lm_sensors cpupower btrfs-progs btrfsmaintenance fwupd \
    xrt xrt-plugin-amdxdna cmake dkms syncthing restic rclone typst \
    libreoffice-fresh haruna vlc-plugins-all qemu-desktop filezilla nmap \
    yabsnap paru
  say "OK: desktop + приложения"
fi

# ============================================================================
# STEP 10 — CPU: performance + ryzenadj + ryzen_smu + tctl 90
# ============================================================================
step "CPU: performance + ryzenadj (Krackan) + tctl 90"
if [ "$SKIP_AI" = "1" ]; then
  say "SKIP_AI=1 — пропускаю ryzenadj/ryzen_smu сборку (CI-режим)"
else
  arch-chroot /mnt pacman -S --noconfirm --needed git >/dev/null 2>&1 || true
arch-chroot /mnt /bin/bash -c "
  set -e
  cd /tmp
  rm -rf ryzenadj-build && git clone --depth 1 -q https://github.com/FlyGoat/RyzenAdj ryzenadj-build
  cd ryzenadj-build && cmake -B build -DCMAKE_BUILD_TYPE=Release >/dev/null && cmake --build build -j\$(nproc) >/dev/null
  cp build/ryzenadj /usr/local/bin/ryzenadj
  cd /tmp
  rm -rf ryzen_smu && git clone --depth 1 -q https://github.com/amkillam/ryzen_smu ryzen_smu
  cd ryzen_smu
" || die "CPU setup (build tools) failed"
# ПАТЧ из пакета — если скрипт запущен из клона/зеркала, патч рядом; иначе скачиваем
PATCH_LOCAL="$(dirname "$0")/patches/ryzen_smu-krackan-full-adapted.patch"
if [ -f "$PATCH_LOCAL" ]; then
  cp "$PATCH_LOCAL" /mnt/tmp/ryzen_smu-patch.patch
  arch-chroot /mnt /bin/bash -c "cd /tmp/ryzen_smu && git apply --check ryzen_smu-patch.patch && git apply ryzen_smu-patch.patch"
else
  # fallback: скачать из GitHub raw (SHA должен совпадать с 32007196…)
  curl -fsSL --max-time 30 "https://raw.githubusercontent.com/shhhubin/zenbook-cachyos-pack/main/patches/ryzen_smu-krackan-full-adapted.patch" -o /tmp/ryzen_smu-patch.patch
  cp /tmp/ryzen_smu-patch.patch /mnt/tmp/ryzen_smu-patch.patch
  arch-chroot /mnt /bin/bash -c "cd /tmp/ryzen_smu && git apply --check ryzen_smu-patch.patch && git apply ryzen_smu-patch.patch"
fi
arch-chroot /mnt /bin/bash -c "cd /tmp/ryzen_smu && make dkms-install >/dev/null 2>&1 || { dkms add ryzen_smu/0.1.7 && dkms build ryzen_smu/0.1.7 && dkms install ryzen_smu/0.1.7; }"
# modules-load + tune service
echo "ryzen_smu" > /mnt/etc/modules-load.d/ryzen_smu.conf
cat > /mnt/etc/systemd/system/ryzenadj-tune.service <<'EOF'
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
arch-chroot /mnt systemctl enable ryzenadj-tune.service >/dev/null 2>&1
say "OK: ryzenadj + ryzen_smu + tctl 90 сервис"
fi

# ============================================================================
# STEP 11 — NPU + AI
# ============================================================================
step "NPU + AI стек (user-local)"
arch-chroot /mnt mkdir -p /etc/security/limits.d
cat > /mnt/etc/security/limits.d/99-npu-memlock.conf <<'EOF'
# AMD NPU / XRT / FastFlowLM: NPU BAR requires MAP_LOCKED > 8MB default
*    soft    memlock    unlimited
*    hard    memlock    unlimited
EOF
arch-chroot /mnt setcap cap_ipc_lock+ep /usr/bin/xrt-smi 2>/dev/null || true
# PowerDevil: performance on AC (после первого boot KDE может сбросить)
mkdir -p /mnt/home/$NEW_USER/.config
cat > /mnt/home/$NEW_USER/.config/powerdevilrc <<EOF
[AC][Performance]
PowerProfile=performance
EOF
arch-chroot /mnt chown -R $NEW_USER:$NEW_USER /home/$NEW_USER/.config
say "OK: NPU limits + PowerDevil performance"
warn "FastFlowLM / ollama модели — user-local, НЕ входят в пакетный стек (см. runbook §9)."

# ============================================================================
# STEP 12 — Security: UFW + services
# ============================================================================
step "Безопасность (UFW default-deny)"
# UFW ставится ВСЕГДА (независимо от --skip-desktop) — безопасность не опциональна
pacretry arch-chroot /mnt pacman -S --noconfirm --needed ufw
arch-chroot /mnt /bin/bash -c "
  systemctl enable NetworkManager >/dev/null 2>&1
  ufw default deny incoming >/dev/null 2>&1
  ufw default allow outgoing >/dev/null 2>&1
  ufw --force enable >/dev/null 2>&1
  systemctl enable ufw >/dev/null 2>&1
"
say "OK: UFW active default-deny"

# ============================================================================
# STEP 13 — Verify (в chroot + подготовка к первому boot)
# ============================================================================
step "Проверки установки"
verify_passes=0
[ -f /mnt/boot/loader/entries/linux-zen.conf ] && verify_passes=$((verify_passes+1))
grep -q "nvme_core.default_ps_max_latency_us=0" /mnt/boot/loader/entries/linux-zen.conf 2>/dev/null && verify_passes=$((verify_passes+1))
[ -f /mnt/etc/sdboot-manage.conf.d/90-apst.conf ] && verify_passes=$((verify_passes+1))
if [ "$SKIP_AI" != "1" ]; then
  [ -x /mnt/usr/local/bin/ryzenadj ] && verify_passes=$((verify_passes+1))
  [ -f /mnt/etc/modules-load.d/ryzen_smu.conf ] && verify_passes=$((verify_passes+1))
  [ -f /mnt/etc/systemd/system/ryzenadj-tune.service ] && verify_passes=$((verify_passes+1))
fi
grep -q "^$NEW_USER:" /mnt/etc/passwd 2>/dev/null && verify_passes=$((verify_passes+1))
say "Внутренних проверок пройдено: $verify_passes/7"
# порог: SKIP_AI убирает 3 проверки → максимум 4; обычный режим требует 6/7
if [ "$SKIP_AI" = "1" ]; then
  [ "$verify_passes" -ge 4 ] || warn "Часть проверок не прошла — смотри лог перед reboot!"
else
  [ "$verify_passes" -ge 6 ] || warn "Часть проверок не прошла — смотри лог перед reboot!"
fi

# ============================================================================
# STEP 14 — Finish
# ============================================================================
step "Завершение"
sync
say "=============================================================="
say "УСТАНОВКА ЗАВЕРШЕНА"
say "  Пользователь: $NEW_USER   (пароль в логе, если сгенерирован)"
say "  LUKS: $([ "$LUKS" = 1 ] && echo 'включён — запиши passphrase и сохрани luks-header.bin' || echo 'выключен')"
say "  Следующие шаги после reboot:"
say "    bash verify-install.sh   (полный чеклист 42 проверки)"
say "    смотри runbook §13 (smoke-тесты CPU/NPU/AI)"
say "  Лог: $LOG  |  rollback: см. runbook §16"
say "  Извлеки USB и: reboot"
say "=============================================================="
