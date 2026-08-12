# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [SemVer](https://semver.org/).

## [v1.0.0] — 2026-08-12

### Added
- `autoinstall.sh` — foolproof one-line installer for CachyOS live ISO
  (19 preflight gates, GPT+ESP 4G+Btrfs subvolumes, optional LUKS2, KDE, linux-zen+APST,
  ryzenadj/ryzen_smu tctl 90, NPU/AI stack, UFW).
- `verify-install.sh` — 42 automated PASS/FAIL acceptance checks (PSI-gate included).
- `setup-ryzenadj.sh` — builds ryzenadj (master) + ryzen_smu patched DKMS, SHA-verifies patch.
- `zenbook-watchdog.sh` — daily cron watchdog: APST/zen-kernel/tctl/PSI (silent when OK).
- `ci-emulate.sh` — QEMU acceptance test (KVM local / TCG in CI).
- `docs/runbook.md` — full step-by-step install runbook with verify + rollback per step.
- GitHub Actions CI: lint on push, emulate on workflow_dispatch/tag.
- Makefile targets: `lint`, `emulate-fast`, `emulate`, `release`.

### Fixed
- 12 bugs found by QEMU emulation (see `docs/autoinstall-cicd-emulation-2026-08-12.md`):
  live-ISO marker, VNC display semantics, fat:rw share layout, GUI→tty2 switch,
  disk-size and RAM gates, live-env USER/HOSTNAME collision, APST drop-in chroot path,
  memlock dir, UFW under --skip-desktop, fallback set -e, OCR marker detection.

### Security
- Repository history cleaned to a single commit; no credentials or personal data.
- CI secret-scan enforced; patch pinned by SHA-256 (`32007196…`).

## [Unreleased]

### Planned
- Full `make emulate` (KDE + AI lane) automated acceptance on tag.
- English runbook translation.
- Release automation with changelog from conventional commits.
