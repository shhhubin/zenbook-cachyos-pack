# x10-оптимизации: OSINT + эксперименты 2026-08-12 (вторая волна)

## Контекст измерений (ВАЖНО)
Две активные сессии Hermes Agent в Ghostty создают фоновую нагрузку:
- I/O PSI some avg10 = 76–80%, full = 72% (источник: hermes-процессы, rchar до 304 GB)
- Это НЕ дефект системы; это объясняет шум во всех CPU/GPU-замерах.
- Вывод: все замеры этой волны — структурные (настройки/пакеты), НЕ чистые
  перформанс-бенчи. Для чистых бенчей нужен PSI-gate (< 30%) или остановка сессий.

## Эксперимент 1: bpfland (sched-ext) vs EEVDF — НЕ ВКЛЮЧАТЬ
CachyOS wiki рекомендует bpfland для desktop/gaming, scx-scheds установлен.
A/B на schbench -t 16 -r 90 -w 10 (шумный фон, см. выше):

| Метрика | EEVDF (текущий) | bpfland 1.1.2 | Вывод |
|---|---|---|---|
| wakeup p50 | 4 µs | 4 µs | = |
| wakeup p90 | 11 µs | 51 µs | EEVDF лучше |
| wakeup p99 | 685 µs | 555 µs | bpfland лучше |
| wakeup max | 3727 µs | 6199 µs | EEVDF лучше |
| request p99 | 16864 µs | 23008 µs | EEVDF лучше |
| request max | 38937 µs | 66135 µs | EEVDF лучше |
| RPS p50 | 1922 | 1810 | EEVDF лучше |

16T throughput: EEVDF 2791.7 MHz vs bpfland 2735.4 MHz (-2%, планировщик не влияет на насыщенную нагрузку).
4T: bpfland 3450 vs EEVDF 2455–2856 (зашумлено термальной инерцией — недостоверно).
**Решение: bpfland НЕ включать. sched-ext остаётся disabled (статус-кво подтверждён экспериментом).**
WARN: на чистом железе без фоновой нагрузки bpfland может показать иначе — но данных нет, оставляем EEVDF.

## Эксперимент 2: dynamic_epp (amd-pstate) — НЕ ВКЛЮЧАТЬ (конфликт с PPD!)
Новая фича ядра: amd-pstate сам ставит EPP при смене platform_profile.
Включение (`echo 1 > /sys/devices/system/cpu/amd_pstate/dynamic_epp`):
- governor стал powersave (был performance) — ПЛОХО
- platform_profile = custom (вместо performance)
- power-profiles-daemon перестал писать EPP: "Device or resource busy (26)"
- **Конфликт dynamic_epp ↔ power-profiles-daemon.**
Откат: `echo 0 > dynamic_epp` + restart power-profiles-daemon + set performance.
Восстановлено: governor=performance, EPP=performance, platform_profile=performance.
**Решение: dynamic_epp НЕ включать. Это WARN для runbook.**

## Эксперимент 3: amd-pstate prefcore — disabled, включить НЕЛЬЗЯ (readonly)
- `amd_pstate_prefcore = true` в ядре по умолчанию, но hw_prefcore=disabled.
- Причина: `CONFIG_AMD_HFI=y` + платформа amd_hfi есть → ядро выбирает HFI, а не prefcore
  (amd_pstate_init_prefcore: "should use amd-hfi instead").
- sysfs `prefcore` — readonly (write → EACCES). Параметра модуля нет.
- prefcore_ranking виден: P-ядра (Zen 5) 196–208, E-ядра (Zen 5c) 135; max freq 5.09 vs 3.5 GHz.
- **Решение: prefcore не наш рычаг на этом ядре/CPU. Зафиксировано как факт.**

## Эксперимент 4: источники I/O PSI — объяснено пользователем
- hermes-процессы (2 активные сессии) — основная I/O нагрузка (rchar 304 GB, 32 GB...).
- zram0 активен (12.4M reads / 16.6M writes, 3.6/30.5 GiB used) — штатно.
- НЕ дефект. Не «чинить».

## Итог
Включено улучшений: 0 новых (текущий стек: tctl 90 + performance + linux-zen + APST — максимум доказанного).
Получено отрицательных результатов: 2 ценных (bpfland, dynamic_epp) + 1 факт (prefcore readonly) —
это предотвращает будущие «оптимизации», которые ухудшили бы систему.
Добавлен PSI-gate в verify-install.sh (честные замеры).

## Evidence
- /tmp/sch-eevdf.json, /tmp/sch-bpfland.json (schbench JSON)
- Скрипты тестов: scripts/cpu-sustained-test.py, scripts/cpu-nthread-test.py
- Текущее состояние: EEVDF (sched_ext disabled), dynamic_epp disabled, EPP=performance, tctl=90
