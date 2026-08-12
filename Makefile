# Zenbook UM3406KA CachyOS pack — CI/CD make targets
# Methodology: every change → lint → emulate (VM) → verify → release.
# Usage:  make lint   (fast static gates)
#         make emulate-fast  (QEMU KVM, skips KDE/AI — ~10 min)
#         make emulate  (QEMU KVM, full install — ~30+ min)
#         make release  (tag + GitHub release with assets)

SHELL := /bin/bash
SCRIPTS := scripts/*.sh

.PHONY: lint emulate-fast emulate release check-patch

lint:
	@echo "=== LINT ==="
	@bash -n $(SCRIPTS) && echo "syntax OK"
	@for f in scripts/*.py; do python3 -m py_compile "$$f" || exit 1; done && echo "python OK"
	@if command -v shellcheck >/dev/null; then shellcheck -S error $(SCRIPTS) && echo "shellcheck OK (errors only)"; else echo "(shellcheck absent)"; fi
	@rm -rf /tmp/rs-lint && git clone --depth 1 -q https://github.com/amkillam/ryzen_smu /tmp/rs-lint \
	  && cd /tmp/rs-lint && git apply --check "$$OLDPWD/patches/ryzen_smu-krackan-full-adapted.patch" \
	  && echo "patch applies clean"
	@grep -rniE '(BEGIN (RSA|OPENSSH|EC|PRIVATE))' --include='*' --exclude-dir='.git' . \
	  && { echo "SECRET FOUND"; exit 1; } || echo "secret scan clean"

emulate-fast:
	@bash scripts/ci-emulate.sh --skip-desktop --skip-ai

emulate:
	@bash scripts/ci-emulate.sh

release:
	@test -n "$(TAG)" || (echo "usage: make release TAG=v1.0.0"; exit 1)
	@git tag "$(TAG)" && git push origin "$(TAG)"
	@gh release create "$(TAG)" --title "$(TAG)" \
	  --notes "Auto-generated release. See README for one-line install." \
	  scripts/autoinstall.sh scripts/verify-install.sh scripts/setup-ryzenadj.sh \
	  scripts/zenbook-watchdog.sh patches/ryzen_smu-krackan-full-adapted.patch \
	  docs/runbook.md README.md
	@echo "Release $(TAG) created."
