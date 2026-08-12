# Security Policy

## Reporting a Vulnerability

This repository contains install/verify tooling for a specific laptop (ASUS Zenbook UM3406KA).
Because the scripts run with elevated privileges during install, treat security reports seriously.

**Please do NOT open a public issue for security problems.**

- Report privately via GitHub Security Advisories:
  https://github.com/shhubin/zenbook-cachyos-pack/security/advisories/new
- Or open a private discussion: https://github.com/shhubin/zenbook-cachyos-pack/discussions

## What is in scope

- `autoinstall.sh` — anything that could cause data loss, wrong-disk formatting,
  or bypass of the foolproof preflight gates.
- `verify-install.sh` — checks that could falsely report PASS.
- Patch authenticity (`patches/ryzen_smu-krackan-full-adapted.patch` SHA pinning).
- Secret handling: this repo must never contain credentials; report any accidental commit.

## Supported versions

| Version | Supported |
|---|---|
| v1.0.x | ✅ |
| main (development) | ⚠️ best-effort |

## Response times

- Acknowledgement: within 48h
- Triage: within 5 business days
- Fix: depends on severity, but critical issues get priority

## Disclosure

We follow responsible disclosure: report first, fix, then coordinate public announcement.
