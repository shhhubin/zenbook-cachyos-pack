# Red team: неочевидные тесты автоинсталлятора — 2026-08-12

## Метод
Атака на autoinstall.sh в реальной QEMU-установке (не unit-тесты):
прерывание, повторный запуск, зеркальные сбои, отсутствие пакетов, PGP-ключи.

## Результаты

| Тест | Сценарий | Результат | Фикс |
|---|---|---|---|
| RT-A | Ctrl+C на pacstrap | PASS: pacman чисто остановился, /mnt не повреждён | — (штатно) |
| RT-B | повторный запуск после Ctrl+C | FAIL: отказ «диск примонтирован», нужен ручной umount | идемпотентный umount -R /mnt в preflight |
| RT-C1 | verify на пустой машине | PASS: честно FAIL'ит при отсутствии ryzenadj | — |
| RT-C2 | watchdog с не-zen ядром | PASS: страж срабатывает | — |
| RT-D | LUKS header backup в tmpfs | FAIL: backup в live-памяти теряется при reboot | WARN + явная инструкция копировать |
| RT-E | LUKS-код целостность | PASS: P1/P2 определены до LUKS | — |
| RT-F | пароль с `'` или `:` | FAIL: ломал chpasswd (shell injection) | валидация: запрет `'` и `:` |
| RT-G | зеркало 404 (нестабильное) | FAIL: set -e убивал установку без retry | pacretry: 3 попытки на pacman |
| RT-H | yabsnap/paru «target not found» | FAIL: pacstrap не копирует [cachyos] в chroot | добавить [cachyos] repo в chroot |
| RT-H2 | PGP «unknown trust» | FAIL: без lsign-key база cachyos невалидна | cachyos-keyring + --lsign-key CachyOS |
| RT-H3 | полный KDE-проход | PASS: 20/20 hooks, UFW active, bootctl default | — |

## Итог
6 реальных багов найдено и исправлено (RT-B, RT-D, RT-F, RT-G, RT-H, RT-H2).
Финальная установка в VM: KDE установлен, UFW active, linux-zen default — работает.
Unit red-team: 11/11 (scripts/redteam-unit.sh).

## Evidence
- Скриншоты/OCR: /tmp/rt*.ppm|png|ocr.txt (сессия)
- qcow2: /home/totem/vm-cachyos/redteam.qcow2
- Лог: /root/autoinstall.log в VM (1405+ строк)
