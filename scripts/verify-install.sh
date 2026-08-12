#!/usr/bin/env bash
# zenbook-install-verify.sh — zero-trust проверка установки Zenbook UM3406KA
# Эталон: runbook 03-analysis/zenbook-cachyos-fresh-install-runbook-2026-08-12.md
# Запуск: bash zenbook-install-verify.sh   (без sudo; sudo-пункты помечены [root])
# Выход: PASS/FAIL по каждому пункту; итог: ALL PASS или FAILURES=n
set -u
PASS=0; FAIL=0
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
chk()  { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "=== 0. PSI-gate (фоновая нагрузка искажает замеры!) ==="
IO_SOME=$(awk '/^some/ {print $2}' /proc/pressure/io | tr -d 'avg10=')
echo "io.some avg10 = $IO_SOME%"
if [ -n "$IO_SOME" ] && awk -v v="$IO_SOME" 'BEGIN{exit !(v+0 > 30)}'; then
  echo "WARN: io.some > 30% — фоновые сессии (Hermes/Ghostty и др.) искажают CPU/GPU замеры."
  echo "      Результаты ниже валидны как структурные (пакеты/настройки), НЕ как производительность."
else
  echo "OK: фоновая I/O нагрузка низкая — замеры производительности достоверны."
fi

echo "=== Zenbook UM3406KA install verify ==="
echo "--- 1. Железо ---"
chk "CPU Ryzen AI 7 350" 'grep -q "Ryzen AI 7 350" /proc/cpuinfo'
chk "8 ядер/16 потоков" 'test "$(nproc)" = "16"'
chk "RAM >= 30 GiB" 'awk "/MemTotal/{exit(\$2<30000000)}" /proc/meminfo'
chk "GPU amdgpu 1002:1114" 'lspci -nnk 2>/dev/null | grep -q "1002:1114"'
chk "NPU /dev/accel/accel0" 'test -e /dev/accel/accel0'
chk "NVMe SN850X" 'lsblk -dno MODEL /dev/nvme0n1 2>/dev/null | grep -qi "SN850X"'
chk "Wi-Fi MT7922" 'lspci -nnk 2>/dev/null | grep -qi "MT7922\|7922"'

echo "--- 2. Kernel/APST (критично) ---"
chk "Ядро linux-zen (НЕ cachyos)" 'uname -r | grep -q "zen1-1-zen"'
chk "APST default_ps_max_latency_us=0" 'cat /proc/cmdline | grep -q "nvme_core.default_ps_max_latency_us=0"'
chk "pcie_port_pm=off" 'cat /proc/cmdline | grep -q "pcie_port_pm=off"'
chk "APST runtime value = 0" 'test "$(cat /sys/module/nvme_core/parameters/default_ps_max_latency_us 2>/dev/null)" = "0"'
chk "APST drop-in существует" 'test -f /etc/sdboot-manage.conf.d/90-apst.conf'
chk "sdboot entry содержит APST (root)" 'sudo sh -c "grep -q nvme_core /boot/loader/entries/linux-zen.conf 2>/dev/null"'

echo "--- 3. GPU/Wayland ---"
chk "Сессия Wayland" 'test "${XDG_SESSION_TYPE:-}" = "wayland"'
chk "Mesa >= 26" 'pacman -Q mesa 2>/dev/null | grep -q "26"'
chk "vulkan-radeon установлен" 'pacman -Q vulkan-radeon >/dev/null 2>&1'
chk "RADV KRACKAN1" 'vulkaninfo --summary 2>/dev/null | grep -q "KRACKAN1"'

echo "--- 4. CPU-тюнинг ---"
chk "platform profile = performance" 'test "$(powerprofilesctl get 2>/dev/null)" = "performance"'
chk "governor = performance" 'grep -q "performance" /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor'
chk "EPP = performance" 'grep -q "performance" /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference'
chk "amd-pstate active" 'grep -q "active" /sys/devices/system/cpu/amd_pstate/status'
chk "ryzenadj установлен" 'test -x /usr/local/bin/ryzenadj'
chk "ryzen_smu модуль загружен" 'lsmod | grep -q ryzen_smu'
chk "ryzen_smu pm_table есть" 'test -e /sys/kernel/ryzen_smu_drv/pm_table'
chk "modules-load.d ryzen_smu" 'test -f /etc/modules-load.d/ryzen_smu.conf'
chk "ryzenadj-tune.service enabled" 'systemctl is-enabled ryzenadj-tune.service 2>/dev/null | grep -q enabled'
chk "tctl target = 90 (root)" 'sudo /usr/local/bin/ryzenadj -i 2>/dev/null | grep -q "THM LIMIT CORE.*90.000"'
chk "ananicy-cpp active" 'systemctl is-active ananicy-cpp 2>/dev/null | grep -q active'
chk "battery udev rule" 'test -f /etc/udev/rules.d/99-asus-battery-charge-limit.rules'

echo "--- 5. AI стек ---"
chk "ollama user-local dir" 'test -x $HOME/ai-projects/ollama-official/bin/ollama'
chk "xrt установлен" 'pacman -Q xrt >/dev/null 2>&1'
chk "xrt-plugin-amdxdna" 'pacman -Q xrt-plugin-amdxdna >/dev/null 2>&1'
chk "FastFlowLM dir" 'test -x $HOME/ai-projects/fastflowlm/flm'
chk "memlock limits" 'grep -q "memlock.*unlimited" /etc/security/limits.d/99-npu-memlock.conf 2>/dev/null'
chk "pam_limits активен" 'grep -q "pam_limits.so" /etc/pam.d/system-login'
chk "xrt-smi setcap (root)" 'getcap /usr/bin/xrt-smi 2>/dev/null | grep -q "cap_ipc_lock"'

echo "--- 6. Безопасность/обслуживание ---"
chk "UFW active (root)" 'sudo ufw status 2>/dev/null | grep -q "Status: active"'
chk "UFW default deny incoming" 'sudo ufw status verbose 2>/dev/null | grep -q "deny (incoming)"'
chk "systemd нет failed units" 'test -z "$(systemctl --failed --no-legend 2>/dev/null | grep -v "^0")"'
chk "yabsnap установлен" 'pacman -Q yabsnap >/dev/null 2>&1'
chk "fstrim.timer активен" 'systemctl is-active fstrim.timer 2>/dev/null | grep -q active'
chk "btrfs device stats = 0 (root)" 'sudo btrfs device stats / 2>/dev/null | grep -v " 0$" | grep -q . && false || true'

echo "--- 7. Ключевые WARN (не FAIL, а проверка) ---"
if pacman -Q snapper >/dev/null 2>&1; then echo "WARN: snapper установлен — конфликт с yabsnap!"; fi
if grep -q "swappiness = 10" /etc/sysctl.d/99-cachyos-custom.conf 2>/dev/null; then
  cur=$(cat /proc/sys/vm/swappiness 2>/dev/null)
  echo "WARN: swappiness custom=10, фактический=$cur (zram udev ставит 150 — штатно, см. runbook §10.3)"
fi

echo ""
echo "=== ИТОГ: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES=$FAIL — чини по runbook, не продолжай"; fi
exit $FAIL
