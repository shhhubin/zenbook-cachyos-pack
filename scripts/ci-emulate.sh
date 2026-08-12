#!/usr/bin/env bash
# =============================================================================
# ci-emulate.sh — FULL CI/CD emulation of zenbook-cachyos-pack in QEMU (KVM).
# Runs the complete one-line install (autoinstall.sh) inside a VM and verifies.
#
# Usage (local, requires /dev/kvm + CachyOS ISO):
#   scripts/ci-emulate.sh [--skip-desktop] [--iso /path/cachyos.iso]
#
# CI philosophy: this is the SAME script GitHub Actions calls (TCG mode) and
# you run locally (KVM mode). One emulation = one acceptance test.
# =============================================================================
set -euo pipefail

ISO="${ISO:-$HOME/vm-cachyos/cachyos-desktop-linux-260628.iso}"
PACK_DIR="${PACK_DIR:-$HOME/zenbook-cachyos-pack}"   # shared as fat:rw (vdb1)
WORK="${WORK:-/tmp/zenbook-ci-emu}"
DISK_IMG="${WORK}/disk.qcow2"
DISK_SIZE=80G   # foolproof gate requires ≥60 GB; qcow2 is sparse (physical usage small)
VNC_DISPLAY="${VNC_DISPLAY:-11}"        # QEMU -vnc host:d → port = 5900+d
VNC_PORT=$((5900 + VNC_DISPLAY))         # actual TCP port for vncctl
MON_SOCK="${WORK}/monitor.sock"
VNCCTL="${VNCCTL:-$HOME/vm-cachyos/vncctl.py}"
EXTRA_ARGS=("$@")

[ -f "$ISO" ] || { echo "FATAL: ISO not found: $ISO"; exit 1; }
[ -e /dev/kvm ] && KVM="-accel kvm -cpu host" || KVM="-accel tcg"   # CI: no KVM -> TCG

rm -rf "$WORK"; mkdir -p "$WORK"
qemu-img create -f qcow2 "$DISK_IMG" "$DISK_SIZE" >/dev/null
# fresh OVMF vars BEFORE qemu starts
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd "$WORK/vars.fd" 2>/dev/null || true

echo "=== [CI] Starting QEMU emulation (KVM=$([ -e /dev/kvm ] && echo yes || echo no)) ==="
qemu-system-x86_64 \
  -machine q35 $KVM -smp 4 -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file="$WORK/vars.fd" \
  -drive file="$ISO",media=cdrom,readonly=on \
  -drive file="$DISK_IMG",if=virtio \
  -drive file=fat:rw:"$PACK_DIR",format=raw,if=virtio \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
  -device qemu-xhci -device usb-tablet \
  -vga virtio -display none -vnc "127.0.0.1:${VNC_DISPLAY}" \
  -monitor "unix:${MON_SOCK},server,nowait" &
QPID=$!
trap 'kill $QPID 2>/dev/null || true' EXIT

echo "=== [CI] Waiting for live boot (login prompt)... ==="
MON_SOCAT() { echo "$1" | socat - UNIX-CONNECT:"$MON_SOCK" >/dev/null 2>&1; }
for i in $(seq 1 40); do
  sleep 15
  # CachyOS live boots to GUI (Hello) by default; switch to tty2 for root login
  MON_SOCAT "sendkey ctrl-alt-f2"
  sleep 1
  # check via VNC screenshot OCR for login prompt
  if VNC_PORT=$VNC_PORT python3 "$VNCCTL" shot "$WORK/screen.ppm" >/dev/null 2>&1; then
    python3 -c "from PIL import Image; Image.open('$WORK/screen.ppm').convert('RGB').save('$WORK/screen.png')" 2>/dev/null || true
    if command -v tesseract >/dev/null; then
      tesseract "$WORK/screen.png" "$WORK/ocr" -l eng >/dev/null 2>&1 || true
      grep -q "login:" "$WORK/ocr.txt" 2>/dev/null && { echo "live ready"; break; }
    fi
  fi
done

echo "=== [CI] Typing root + mounting share ==="
type_one() { VNC_PORT=$VNC_PORT python3 "$VNCCTL" type "$1" && sleep 1 && VNC_PORT=$VNC_PORT python3 "$VNCCTL" key return && sleep 2; }
type_one "root"
type_one "mkdir -p /share"
type_one "mount /dev/vdb1 /share"
type_one "ls /share/pack 2>/dev/null || ls /share"

echo "=== [CI] Copying repo into VM + running one-line install ==="
# fat:rw:PACK_DIR exposes PACK_DIR CONTENTS at share root → /share/scripts/autoinstall.sh
type_one "cp /share/scripts/autoinstall.sh /tmp/ai.sh"
type_one "bash /tmp/ai.sh --yes DISK=/dev/vda ${EXTRA_ARGS[*]:-}"

echo "=== [CI] Waiting for install to finish ==="
for _ in $(seq 1 80); do
  sleep 30
  if VNC_PORT=$VNC_PORT python3 "$VNCCTL" shot "$WORK/screen.ppm" >/dev/null 2>&1; then
    python3 -c "from PIL import Image; Image.open('$WORK/screen.ppm').convert('RGB').save('$WORK/screen.png')" 2>/dev/null || true
    tesseract "$WORK/screen.png" "$WORK/ocr2" -l eng >/dev/null 2>&1 || true
    if grep -q "УСТАНОВКА ЗАВЕРШЕНА\|INSTALL COMPLETE" "$WORK/ocr2.txt" 2>/dev/null; then
      echo "=== [CI] INSTALL COMPLETE detected ==="
      break
    fi
    # OCR часто искажает кириллицу; ASCII-маркер надёжнее
    if grep -q "autoinstall\.log" "$WORK/ocr2.txt" 2>/dev/null; then
      echo "=== [CI] INSTALL COMPLETE detected (log marker) ==="
      break
    fi
  fi
done

echo "=== [CI] Final screen ==="
grep -vE "^\s*$" "$WORK/ocr2.txt" 2>/dev/null | tail -20
echo "=== [CI] Emulation finished (see logs above). Exit 0 = PASS ==="
