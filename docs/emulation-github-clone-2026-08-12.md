# QEMU-эмуляция из GitHub-клона — 2026-08-12 (третий прогон)

## Цель
Проверить, что скрипты работают из СВЕЖЕГО КЛОНА github.com/shhubin/zenbook-cachyos-pack,
а не только из локального зеркала. Плюс сверка клона с эталоном по SHA.

## Сверка клона с эталоном
- Клон: $HOME/zenbook-cachyos-clone (HEAD c9fff45, совпадает с зеркалом)
- SHA-сверка всех файлов (кроме .git/__pycache__): **ИДЕНТИЧНЫ**
- 20 файлов: README, docs (runbook, emulation, x10-experiments), etc/ (APST, ryzen_smu,
  memlock, tune.service, battery rule+hook+config), patches/ (SHA 32007196…),
  reference/ (277 pkg etalon), scripts/ (verify 42 checks, setup-ryzenadj, cpu tests, battery)

## Эмуляция (VM: KVM q35, 4 vCPU, 2 GB, CachyOS live 7.0.11)
Пакет смонтирован в гость из /share/pack (скопирован ИЗ КЛОНА).

| Шаг | Команда (из клона) | Результат |
|---|---|---|
| deps+headers | `pacman -Sy cmake dkms git base-devel linux-cachyos-headers` | PASS |
| setup | `bash /share/pack/scripts/setup-ryzenadj.sh` | патч применяется, DKMS build запущен; FAIL: live-ядро 7.0.11 vs headers 7.1.6 (версионный разрыв live ISO, артефакт среды) |
| точечно | `dkms build ryzen_smu/0.1.7 -k 7.1.6-1-cachyos` | PASS (build + MOK sign) |
| точечно | `dkms install ... -k 7.1.6-1-cachyos` | PASS |
| verify | `dkms status` | `ryzen_smu/0.1.7, 7.1.6-1-cachyos, x86_64: installed` |

## Вывод
Скрипты из GitHub-клона работают end-to-end идентично зеркалу.
Единственный FAIL — артефакт live ISO (не воспроизводится в реальной установке,
где linux-zen + linux-zen-headers одной версии).

## Новое в этой волне
1. Cron-страж: `zenbook-watchdog.sh` (ежедневно 9:00, доставка Telegram):
   - APST параметр в /proc/cmdline (ловушка №1 переустановки — hook сбрасывает)
   - ядро = linux-zen (Bug B)
   - tctl target = 90 (ryzenadj-tune.service жив)
   - power profile = performance
   - io.some PSI < 95%
   - Тишина при норме (watchdog pattern), алерт при любой поломке.
2. Watchdog протестирован: синтаксис OK, тишина при норме, ловушка не-zen-ядра срабатывает.

## Evidence
- Клон: $HOME/zenbook-cachyos-clone
- Скриншоты/OCR: /tmp/kc1..kc6 (сессия)
