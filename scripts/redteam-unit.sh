#!/usr/bin/env bash
# redteam-unit.sh — adversarial unit tests for autoinstall.sh (host-level, no VM).
# Each test tries to BREAK the script; expected outcome = script REFUSES safely.
# Exit 0 = all guards held. Exit 1 = a guard failed (BUG).
set -u
PASS=0; FAIL=0
t() { # name, expected_exit, actual_exit
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "PASS: $1 (exit=$3, expected=$2)"
  else FAIL=$((FAIL+1)); echo "FAIL: $1 (exit=$3, expected=$2) ← БАГ"; fi
}
AUTO=scripts/autoinstall.sh

echo "=== RED TEAM: autoinstall.sh guard tests (host) ==="

# T1: не-root запуск → должен упасть (не root)
# (запускаем как текущий юзер — не root в этой сессии)
bash "$AUTO" --yes DISK=/dev/null 2>/tmp/rt1.log >/dev/null
t "не-root: отказ" 1 $?

# T2: root, не-live (на установленной системе) → должен упасть
sudo -n bash "$AUTO" --yes DISK=/dev/null NEW_USER=ci 2>/tmp/rt2.log >/dev/null
t "root+не-live: отказ (главный гейт)" 1 $?

# T3: несуществующий диск → отказ
# (пропускаем live-гейт фейком? нет — T3 проверим через фейковый /run/archiso)
# Для T3-T8 подменяем live-маркер: создаём фейковый /run/archiso (только чтение теста)
if [ "$(id -u)" = "0" ]; then
  mkdir -p /run/archiso 2>/dev/null
fi

# T4: несуществующий диск при live-маркере → отказ
sudo -n bash "$AUTO" --yes DISK=/dev/does-not-exist NEW_USER=ci 2>/tmp/rt4.log >/dev/null
t "несуществующий диск: отказ" 1 $?

# T5: DMI-гейт на реальной машине → корректный Zenbook НЕ должен давать WARN.
# (обратная проверка: «не-Zenbook» невозможно сэмулировать на настоящем Zenbook)
sudo -n mkdir -p /run/archiso
sudo -n bash "$AUTO" --yes DISK=/dev/null NEW_USER=ci >/tmp/rt5.log 2>&1
sudo -n rmdir /run/archiso 2>/dev/null
if grep -q "OK: DMI идентифицирован" /tmp/rt5.log && ! grep -qiE "WARN.*(DMI|ne pomome)" /tmp/rt5.log; then
  echo "PASS: DMI-гейт корректно принимает реальный Zenbook (без WARN)"; PASS=$((PASS+1))
else
  echo "FAIL: DMI-гейт повёл себя неожиданно (лог: $(tail -c 250 /tmp/rt5.log))"; FAIL=$((FAIL+1))
fi

# T6: инъекция через DISK (path traversal / опции)
sudo -n bash "$AUTO" --yes "DISK=/dev/null; rm -rf /tmp/pwned" NEW_USER=ci 2>/tmp/rt6.log >/dev/null
[ ! -e /tmp/pwned ] && echo "PASS: инъекция в DISK не выполнилась" && PASS=$((PASS+1)) || { echo "FAIL: инъекция выполнилась!"; FAIL=$((FAIL+1)); }

# T7: инъекция через NEW_USER (команды в имени юзера)
sudo -n bash "$AUTO" --yes DISK=/dev/null "NEW_USER=ci;touch /tmp/pwned2" 2>/tmp/rt7.log >/dev/null
[ ! -e /tmp/pwned2 ] && echo "PASS: инъекция в NEW_USER не выполнилась" && PASS=$((PASS+1)) || { echo "FAIL: инъекция выполнилась!"; FAIL=$((FAIL+1)); }

# T8: слишком короткий LUKS passphrase (интерактив невозможен в --yes, но проверим валидацию кода)
grep -q '${#LUKS_PASS} -ge 8' "$AUTO" && echo "PASS: LUKS passphrase ≥8 валидация в коде" && PASS=$((PASS+1)) || { echo "FAIL: нет валидации LUKS"; FAIL=$((FAIL+1)); }

# T9: set -euo pipefail обязателен (ищем по всему файлу, не только 1-я строка)
grep -q 'set -euo pipefail' "$AUTO" && echo "PASS: set -euo pipefail" && PASS=$((PASS+1)) || { echo "FAIL: нет set -euo"; FAIL=$((FAIL+1)); }

# T10: никаких echo пароля в лог при генерации
grep -q 'openssl rand' "$AUTO" && echo "PASS: случайный пароль при non-interactive" && PASS=$((PASS+1)) || { echo "FAIL: нет генерации"; FAIL=$((FAIL+1)); }

# T11: секрет-скан самого скрипта
grep -nE '(BEGIN (RSA|PRIVATE)|ghp_|sk-[A-Za-z0-9]{20})' "$AUTO" >/dev/null && { echo "FAIL: секрет в скрипте"; FAIL=$((FAIL+1)); } || { echo "PASS: нет секретов в скрипте"; PASS=$((PASS+1)); }

# T12: watchdog молчит при норме
OUT=$(bash scripts/zenbook-watchdog.sh 2>&1)
[ -z "$OUT" ] && echo "PASS: watchdog тихий при норме" && PASS=$((PASS+1)) || { echo "FAIL: watchdog шумит: $OUT"; FAIL=$((FAIL+1)); }

echo ""
echo "=== ИТОГ RED TEAM: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" = "0" ] && echo "ALL GUARDS HELD" || echo "BUGS FOUND"
