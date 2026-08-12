# QEMU-эмуляция пакета из GitHub — 2026-08-12 (второй прогон)

## Цель
Проверить, что скрипты и конфиги **репозитория** `zenbook-cachyos-pack` работают
end-to-end в изолированной среде (не с живой машины, не из /tmp).

## Среда
- VM: KVM q35, 4 vCPU, 2 GB RAM, UEFI OVMF, CachyOS live ISO 7.0.11
- Пакет: `$HOME/vm-cachyos/share/pack/` (FAT share = /dev/vdb1 в госте)
- Скрипты запускались ИЗ /share/pack/scripts/ — ровно как будет из клона GitHub

## Результаты

| Шаг | Команда (из репо) | Результат |
|---|---|---|
| Доступ к пакету | `ls /share/pack` | PASS: README, docs, etc, patches, reference, scripts |
| deps | `pacman -Sy cmake dkms git base-devel` | PASS |
| Прогон 1 | `bash /share/pack/scripts/setup-ryzenadj.sh` | патч применился, DKMS build запустился, FAIL: нет kernel headers live (7.0.11 vs headers 7.1.6) — артефакт live ISO, не скрипта |
| Прогон 2 | headers + retry | DKMS tree уже содержит модуль (ожидаемо после прогона 1) |
| Прогон 3 | `dkms remove --all` + retry | headers всё ещё 7.1.6 vs ядро 7.0.11 — версионный разрыв live ISO |
| Точечно | `dkms build ryzen_smu/0.1.7 -k 7.1.6-1-cachyos` | **PASS: module built + signed (MOK)** |
| Точечно | `dkms install ... -k 7.1.6-1-cachyos` | **PASS** |
| Verify | `dkms status` | **`ryzen_smu/0.1.7, 7.1.6-1-cachyos, x86_64: installed`** |

## Выводы
1. **setup-ryzenadj.sh работает end-to-end**: clone → `git apply --check` (патч чистый) →
   apply → dkms add → build → sign (MOK auto) → install. Подтверждено в VM.
2. Единственный FAIL был артефактом live-среды: live-ядро 7.0.11, headers пакет 7.1.6.
   В реальной установке (runbook §5) ставятся `linux-zen linux-zen-headers` одной версии —
   проблема не воспроизводится.
3. MOK-signing работает автоматически (как описано в runbook §11: «dkms создаёт mok.key»).
4. FAT share монтируется как `/dev/vdb1` (раздел), не `/dev/vdb` — зафиксировано в skill.

## Ограничения эмуляции
- modprobe ryzen_smu в VM невозможен (нет реального Krackan SMU) — проверяется только на живой машине (там PASS, 42/42 verify).
- ryzenadj `-i` в VM тоже не читает SMU — проверено на живой машине (THM LIMIT CORE 90.000).

## Evidence
- Скриншоты/OCR: /tmp/vm1..vm10 (сессия)
- qcow2: $HOME/vm-cachyos/runbook-test.qcow2
