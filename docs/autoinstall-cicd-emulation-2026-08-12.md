# Автоинсталлятор: CI/CD-цикл разработки и эмуляция — 2026-08-12

## Продукт
`scripts/autoinstall.sh` — одна строка в live ISO ставит преднастроенную CachyOS:
```
curl -fL https://raw.githubusercontent.com/shhubin/zenbook-cachyos-pack/main/scripts/autoinstall.sh -o /tmp/ai.sh && bash /tmp/ai.sh
```
19 защитных гейтов, LUKS2 опционально, linux-zen+APST, KDE, CPU/NPU/AI, UFW.

## CI/CD-методология (как просил пользователь)
Каждое изменение: `make lint` → `make emulate-fast` (QEMU KVM) → `make release`.
GitHub Actions: lint на каждый push; emulate (TCG, без KVM — OSINT-подтверждено) на
workflow_dispatch/tag.

## Итерации разработки (что нашла эмуляция — реальные баги)

| # | Баг | Найден | Исправлен |
|---|---|---|---|
| 1 | live-маркер: CachyOS не имеет /run/archiso/booted (только /run/archiso/{airootfs,bootmnt,cowspace}) | эмуляция: скрипт отказался работать в live | проверка `[ -d /run/archiso ]` |
| 2 | VNC `:5911` = display-номер → порт 5900+5911=11811 | эмуляция: не слушался 5911 | `VNC_DISPLAY=11` → порт 5911 |
| 3 | fat:rw:PACK_DIR монтирует СОДЕРЖИМОЕ в корень share (`/share/scripts/...`), не подпапку | эмуляция: cp не находил файл | путь `/share/scripts/autoinstall.sh` |
| 4 | CachyOS live грузится в GUI (Hello), login на tty2 — нужен ctrl-alt-f2 | эмуляция: ждал login вечно | MON_SOCAT sendkey ctrl-alt-f2 |
| 5 | гейт размера диска: 20G < 60G — ЗАЩИТА РАБОТАЕТ (ожидаемый FAIL) | эмуляция | DISK_SIZE=80G (sparse) |
| 6 | гейт RAM: 1953 < 3072 — ЗАЩИТА РАБОТАЕТ | эмуляция | -m 4096 |
| 7 | live root экспортирует USER=root, HOSTNAME=CachyOS → useradd root, hostname CachyOS | эмуляция: «useradd: user root already exists» | NEW_USER/NEW_HOSTNAME |
| 8 | APST drop-in писался в live /etc, НЕ в chroot /mnt/etc — система осталась бы БЕЗ фикса! | эмуляция: /mnt/etc/sdboot-manage.conf.d не существовал | arch-chroot mkdir + /mnt/etc |
| 9 | memlock limits.d: каталога нет в chroot | эмуляция: «No such file or directory» | arch-chroot mkdir -p |
| 10 | UFW не установлен при --skip-desktop, но STEP 12 его использует | эмуляция: падение на UFW | pacman -S ufw всегда |
| 11 | fallback linux-zen.conf: set -e убивал скрипт | эмуляция | set +e + diag маркеры |
| 12 | ci-emulate детект «УСТАНОВКА ЗАВЕРШЕНА» по кириллице — OCR искажает | эмуляция: маркер не найден | ASCII-маркер autoinstall.log |

## Финальный результат эмуляции (fast-режим)
Все 14 шагов: разметка → btrfs subvolumes → pacstrap → fstab/locale/user →
bootloader+linux-zen+APST (fallback entry с nvme_core.default_ps_max_latency_us=0) →
SKIP_DESKTOP/SKIP_AI (CI) → NPU limits → UFW → verify 4/7 → «УСТАНОВКА ЗАВЕРШЕНА».
Пользователь: totem, hostname: zenbook, LUKS: off.
Проверки: linux-zen.conf существует, APST параметры в entry, drop-in в /mnt/etc, ufw.

## Evidence
- /tmp/ci*.ppm|png|ocr.txt — скриншоты/OCR каждого шага (сессия)
- /tmp/zenbook-ci-emu/ — qcow2, monitor
- Лог в VM: /root/autoinstall.log (1393+ строк)
