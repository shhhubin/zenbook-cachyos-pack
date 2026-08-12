#!/usr/bin/env bash
# setup-ryzenadj.sh — build & install ryzenadj (master) + ryzen_smu (patched DKMS)
# For AMD Krackan Point (Ryzen AI 7 350) — tctl-temp control.
# Zero-trust: prints every artifact SHA; rollback at the bottom.
set -euo pipefail

echo "=== [1/5] Check deps ==="
command -v cmake >/dev/null || { echo "FATAL: cmake missing (sudo pacman -S cmake)"; exit 1; }
command -v dkms >/dev/null || { echo "FATAL: dkms missing (sudo pacman -S dkms)"; exit 1; }
command -v git >/dev/null || { echo "FATAL: git missing"; exit 1; }

PATCH="$(dirname "$0")/../patches/ryzen_smu-krackan-full-adapted.patch"
PATCH_SHA_EXPECT="32007196a9aa9c7c0f42aef3b0e9716b027778e798695f7aa435800cc7f67e68"
[ -f "$PATCH" ] || { echo "FATAL: patch not found: $PATCH"; exit 1; }
PATCH_SHA_ACTUAL="$(sha256sum "$PATCH" | cut -d' ' -f1)"
echo "patch sha256: $PATCH_SHA_ACTUAL"
if [ "$PATCH_SHA_ACTUAL" != "$PATCH_SHA_EXPECT" ]; then
  echo "FATAL: patch SHA mismatch! expected=$PATCH_SHA_EXPECT actual=$PATCH_SHA_ACTUAL"
  exit 1
fi
echo "OK: patch SHA verified"

echo "=== [2/5] Build ryzenadj from master (tag v0.19.0 does NOT know Krackan) ==="
rm -rf /tmp/ryzenadj-build
git clone --depth 1 https://github.com/FlyGoat/RyzenAdj /tmp/ryzenadj-build
cd /tmp/ryzenadj-build
cmake -B build -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build build -j"$(nproc)" >/dev/null
sudo cp build/ryzenadj /usr/local/bin/ryzenadj
sudo ldconfig 2>/dev/null || true
echo "ryzenadj installed: $(sha256sum /usr/local/bin/ryzenadj | cut -c1-16)"

echo "=== [3/5] Build ryzen_smu + apply Krackan patch ==="
rm -rf /tmp/ryzen_smu-build
git clone --depth 1 https://github.com/amkillam/ryzen_smu /tmp/ryzen_smu-build
cd /tmp/ryzen_smu-build
git apply --check "$PATCH"
git apply "$PATCH"
sudo make dkms-install
echo "=== [4/5] Load module + autoload ==="
sudo modprobe ryzen_smu
sudo tee /etc/modules-load.d/ryzen_smu.conf > /dev/null << 'EOF'
# Load ryzen_smu kernel module at boot (SMU access for ryzenadj on Krackan Point)
ryzen_smu
EOF

echo "=== [5/5] Verify ==="
ls /sys/kernel/ryzen_smu_drv/pm_table >/dev/null 2>&1 \
  || { echo "FAIL: pm_table missing (patch did not apply?)"; exit 1; }
sudo /usr/local/bin/ryzenadj -i | head -8
echo "OK: ryzenadj + ryzen_smu ready. Next: sudo ryzenadj -f 90"
echo ""
echo "=== Rollback ==="
echo "sudo rm /etc/modules-load.d/ryzen_smu.conf"
echo "sudo dkms remove ryzen_smu/0.1.7 --all"
echo "sudo rm /usr/local/bin/ryzenadj"
echo "sudo reboot   # tctl returns to BIOS default 85"
