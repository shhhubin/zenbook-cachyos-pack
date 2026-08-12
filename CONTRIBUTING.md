# Contributing

Thanks for considering a contribution to the Zenbook UM3406KA CachyOS install pack.

## How to contribute

1. **Open an issue first** for non-trivial changes — discuss before coding.
2. Fork the repo, create a feature branch (`feat/...`, `fix/...`).
3. Follow the CI/CD methodology (see README):

```bash
make lint          # syntax, shellcheck, patch applies, secret scan — MUST pass
make emulate-fast  # QEMU acceptance of the one-line install — MUST pass
```

4. Open a pull request. CI runs on every push; the `lint` job must be green.

## Standards

- **Zero-trust rule**: every claim about hardware behavior needs `LIVE`/`VENDOR`/`HOLD`
  status and ideally an A/B experiment (see `docs/x10-experiments-2026-08-12.md`).
- **No credentials**: never commit tokens, keys, passwords, or personal paths
  (`/home/<user>` → use `$HOME`). CI secret-scan fails the build otherwise.
- **SHA-pinned artifacts**: any patch or downloaded binary must be pinned by SHA-256
  and verified before use (see `setup-ryzenadj.sh`).
- **Rollback with every change**: if you add a setting, document how to revert it.
- Language: user-facing docs in Russian (per project convention); code/comments in English.

## Testing matrix

| Level | Command | What it verifies |
|---|---|---|
| Fast | `make lint` | syntax, shellcheck, patch applies clean, no secrets |
| Acceptance | `make emulate-fast` | one-line install in QEMU (skips KDE/AI) |
| Full | `make emulate` | complete install incl. KDE + AI lane |
| Live | `bash scripts/verify-install.sh` | 42 checks on the real machine |

## Good first issues

Check the [issue tracker](https://github.com/shhhubin/zenbook-cachyos-pack/issues)
for items tagged `good first issue`.
