#!/usr/bin/env bash
# zenbook-watchdog.sh — kernel-APST + PSI + tctl watchdog for Zenbook UM3406KA.
# Runs from cron; STAYS SILENT unless something is wrong (watchdog pattern).
# Checks:
#  1. /proc/cmdline contains nvme_core.default_ps_max_latency_us=0 (APST fix alive)
#  2. running kernel is linux-zen (not linux-cachyos)
#  3. tctl target is 90 (ryzenadj tune alive)
#  4. io.some PSI not pathologically high (excluding our own known Hermes sessions)
#  5. power profile still performance
set -u

OUT=""
warn() { OUT="${OUT}⚠️ $1
"; }

KVER=$(uname -r)
case "$KVER" in
  *zen*) ;;
  *) warn "Ядро НЕ linux-zen: $KVER (Bug B CachyOS #913 — риск падений)" ;;
esac

if ! grep -q "nvme_core.default_ps_max_latency_us=0" /proc/cmdline 2>/dev/null; then
  warn "APST-параметр ПРОПАЛ из /proc/cmdline — sdboot-kernel-update hook сбросил options! Проверь /etc/sdboot-manage.conf.d/90-apst.conf и запусти: sudo sdboot-manage gen"
fi

if command -v /usr/local/bin/ryzenadj >/dev/null 2>&1; then
  TCTL=$(sudo -n /usr/local/bin/ryzenadj -i 2>/dev/null | grep -o "THM LIMIT CORE.*" | grep -oE "[0-9]+\.[0-9]+" | head -1)
  if [ -n "$TCTL" ] && [ "$TCTL" != "90.000" ] && [ "$TCTL" != "90" ]; then
    warn "tctl target = $TCTL (ожидается 90.000) — ryzenadj-tune.service не отработал"
  fi
fi

PROF=$(powerprofilesctl get 2>/dev/null)
if [ "$PROF" != "performance" ]; then
  warn "power profile = $PROF (ожидается performance) — PPD сброшен? sudo powerprofilesctl set performance"
fi

IO_SOME=$(awk '/^some/ {print $2}' /proc/pressure/io | tr -d 'avg10=')
if [ -n "$IO_SOME" ] && awk -v v="$IO_SOME" 'BEGIN{exit !(v+0 > 95)}'; then
  warn "io.some avg10 = ${IO_SOME}% (>95%) — подозрительная I/O нагрузка; проверь top"
fi

if [ -n "$OUT" ]; then
  echo "Zenbook UM3406KA — предупреждение стражника:"
  echo ""
  echo -n "$OUT"
  echo "Пакет/runbook: https://github.com/shhhubin/zenbook-cachyos-pack"
else
  # silence = OK
  :
fi
