#!/bin/sh
# asus-battery-charge-limit.sh — apply ASUS charge end threshold from config file.
# Runs on udev add of asus-nb-wmi (boot) and after suspend/hibernate (systemd-sleep).
# Config: /etc/asus-battery-charge-limit (allowed: 60|80|90|100)
set -eu

cfg=/etc/asus-battery-charge-limit
[ -r "$cfg" ] || exit 0
val=$(grep -vE '^[[:space:]]*(#|$)' "$cfg" | head -n 1 | tr -d '[:space:]')
[ -n "$val" ] || exit 0
case "$val" in
  60|80|90|100) ;;
  *) echo "asus-battery-charge-limit: invalid value '$val'" >&2; exit 1 ;;
esac

for b in /sys/class/power_supply/BAT?/charge_control_end_threshold; do
  [ -w "$b" ] || continue
  echo "$val" > "$b"
  echo "$(date -Iseconds) applied threshold=$val to $b" >> /var/log/asus-battery-charge-limit.log
done
exit 0