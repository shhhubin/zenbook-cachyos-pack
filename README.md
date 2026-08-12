<div align="center">

# Zenbook UM3406KA — CachyOS Fresh-Install Pack

**Foolproof one-line installer + zero-trust verify kit** for ASUS Zenbook 14 UM3406KA
(Ryzen AI 7 350 · Krackan Point · Radeon 860M · XDNA 2 NPU).

**Status:** [CI passing](https://github.com/shhubin/zenbook-cachyos-pack/actions) · [Release v1.0.0](https://github.com/shhubin/zenbook-cachyos-pack/releases) · MIT License · *private repo (badges not rendered by shields.io)*

*Every number verified 2026-08-12 on the live machine; install logic verified in QEMU.*

</div>

---

## 🚀 One-line install (from CachyOS live ISO)

Boot the CachyOS ISO, open a terminal (Ctrl+Alt+F2), and paste **one line**:

```bash
curl -fL https://raw.githubusercontent.com/shhubin/zenbook-cachyos-pack/main/scripts/autoinstall.sh -o /tmp/ai.sh && bash /tmp/ai.sh
```

The script installs a **fully preconfigured system**: GPT + ESP 4G + Btrfs subvolumes,
optional LUKS2, KDE Plasma / Wayland, **linux-zen + APST NVMe fix (CRITICAL)**,
ryzenadj/ryzen_smu CPU tuning (tctl 90), NPU/AI stack, UFW default-deny — then verifies itself.

> ⚠️ **Foolproof by design**: 19 preflight gates refuse to run on the wrong machine,
> wrong disk, small disk (< 60 GB), low RAM (< 3 GB), without internet, or on a
> mounted/active disk. Double confirmation required unless `--yes`.

### Options

| Flag | Meaning |
|---|---|
| `--yes` | non-interactive (CI / unattended) |
| `--luks` | enable LUKS2 encryption (asks for passphrase) |
| `--skip-desktop` | CI fast mode: skip KDE/apps |
| `--skip-ai` | CI fast mode: skip ryzenadj/ryzen_smu build |
| `DISK=/dev/nvme0n1` | target disk (override) |
| `NEW_USER=totem` | username (default `totem`) |
| `NEW_HOSTNAME=zenbook` | hostname (default `zenbook`) |

---

## 📋 What you get

| Component | State | Verified |
|---|---|---|
| Kernel | `linux-zen` (NOT linux-cachyos — Bug B, CachyOS #913) | LIVE |
| NVMe | APST fix `nvme_core.default_ps_max_latency_us=0` (SN850X death prevention, Bugzilla #219852) | LIVE |
| CPU | performance profile + `ryzenadj -f 90` (tctl 90°C): 16T **2.76–2.83 GHz** vs stock 2.46 GHz | LIVE A/B |
| GPU | Mesa/RADV KRACKAN1 (gfx1152), Wayland | LIVE |
| AI GPU lane | ollama user-local, Vulkan (NO ROCm on gfx1152) | LIVE |
| AI NPU lane | FastFlowLM + Qwen3-4B-NPU2, ~23 t/s | LIVE |
| Security | UFW default-deny, no LAN listeners | LIVE |
| Battery | charge limit 80% (udev + sleep hook) | LIVE |

---

## 🧪 Verify after install

```bash
bash scripts/verify-install.sh    # 42 checks, expects ALL PASS
```

Every config has a rollback (runbook §16). The watchdog script checks APST/zen/tctl/PSI
daily and alerts (Telegram) only when something breaks:

```bash
bash scripts/zenbook-watchdog.sh  # silent when OK
```

---

## 📁 Repository layout

```
zenbook-cachyos-pack/
├── README.md                  # this file
├── Makefile                   # CI/CD: lint / emulate / release
├── docs/
│   ├── runbook.md             # full step-by-step install runbook (RU)
│   ├── emulation-github-pack-2026-08-12.md
│   ├── emulation-github-clone-2026-08-12.md
│   ├── x10-experiments-2026-08-12.md
│   └── autoinstall-cicd-emulation-2026-08-12.md
├── scripts/
│   ├── autoinstall.sh         # foolproof one-line installer
│   ├── verify-install.sh      # 42 automated PASS/FAIL checks
│   ├── setup-ryzenadj.sh      # ryzenadj + ryzen_smu DKMS build
│   ├── zenbook-watchdog.sh    # daily cron watchdog
│   ├── ci-emulate.sh          # QEMU acceptance test (KVM local / TCG CI)
│   ├── cpu-sustained-test.py  # 16-thread sustained CPU test
│   ├── cpu-nthread-test.py    # N-thread CPU test
│   └── asus-battery-charge-limit.sh  # battery 80% threshold
├── etc/
│   ├── sdboot-manage.conf.d/90-apst.conf   # APST fix (survives kernel updates)
│   ├── modules-load.d/ryzen_smu.conf       # load ryzen_smu at boot
│   ├── security/limits.d/99-npu-memlock.conf  # NPU BAR memlock
│   ├── systemd/system/ryzenadj-tune.service  # tctl 90 on AC
│   ├── 99-asus-battery-charge-limit.rules   # udev battery rule
│   ├── system-sleep-asus-battery-charge-limit # sleep hook
│   └── asus-battery-charge-limit            # config: 80
├── patches/
│   └── ryzen_smu-krackan-full-adapted.patch # Krackan PM table (SHA 32007196…)
├── reference/
│   └── pacman-explicit-reference.txt        # 277-package etalon
└── .github/workflows/ci.yml  # lint on push; emulate on dispatch/tag
```

---

## 🔄 CI/CD methodology

Every change follows **lint → emulate → verify → release**:

```bash
make lint          # fast gates: syntax, shellcheck, patch applies, secret scan
make emulate-fast  # QEMU KVM acceptance: one-line install (skips KDE/AI) — ~10 min
make emulate       # QEMU KVM full install — ~30+ min
make release TAG=v1.0.0   # tag + GitHub release with assets
```

- GitHub Actions `lint` runs on **every push** (syntax, shellcheck, patch, foolproof-gate,
  secret scan). The foolproof gate asserts `autoinstall.sh` REFUSES to run outside a live ISO.
- `emulate` job runs on `workflow_dispatch` or tag push (TCG mode; GitHub-hosted runners
  have **no KVM** — verified OSINT 2026-08-12).
- `ci-emulate.sh` is one script used both locally (KVM) and in CI (TCG).
- The one-line install was **emulated end-to-end in QEMU**: 14/14 steps PASS, and the
  emulation caught **12 real bugs** (documented in `docs/autoinstall-cicd-emulation-2026-08-12.md`).

---

## 🛡️ Zero-trust guarantees

- Every number in `docs/runbook.md` is tagged `LIVE` (measured) / `VENDOR` / `HOLD`.
- `verify-install.sh` is the acceptance gate: 42 checks, must end `ALL PASS`.
- Patches pinned by SHA-256; `git apply --check` verified on clean upstream.
- No credentials, tokens, or private identifiers in this repo (CI secret-scan enforced).
- `setup-ryzenadj.sh` refuses to run if the patch SHA mismatches.
- I/O PSI gate in verify: benchmarks are flagged invalid when background load is high.

---

## ⚠️ Known issues (do NOT "fix" blindly — all A/B tested)

- `scx_bpfland` (sched-ext): **worse** than EEVDF on mixed load → keep disabled.
- `amd_pstate/dynamic_epp`: conflicts with power-profiles-daemon → keep disabled.
- `prefcore`: read-only, CONFIG_AMD_HFI takes over → not a lever.
- PBI (`plasma-browser-integration-host`) crashes: xcb-in-Wayland bug, no X11 deps.
- KWin offscreen GL errors: correlation with driver defect **not established**.
- `swappiness=150` via udev zram rule: **normal**, don't fight it.

---

## 📚 Documentation

- [Full runbook (RU)](docs/runbook.md) — step-by-step with verify + rollback per step.
- [X10 experiments](docs/x10-experiments-2026-08-12.md) — OSINT + A/B evidence.
- [Autoinstall CI/CD emulation](docs/autoinstall-cicd-emulation-2026-08-12.md) — 12 bugs found.
- [GitHub clone emulation](docs/emulation-github-clone-2026-08-12.md) — clone == mirror SHA.
- [Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md) · [Code of Conduct](CODE_OF_CONDUCT.md) · [Security](SECURITY.md)

---

## 🗺️ Roadmap

- [ ] Full `make emulate` (KDE + AI lane) automated acceptance on tag
- [ ] Live ISO customization (CachyOS profile with this pack pre-baked)
- [ ] English runbook translation
- [ ] Release automation: auto-bump + changelog from conventional commits

---

## 📄 License

MIT — scripts/patches. Runbook prose and measurements: attribute to the source project
`zenbook-um3406ka-zero-trust-audit` in Obsidian.
