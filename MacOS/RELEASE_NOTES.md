# Melon Tools 2.3.0

- **Workspace-aware scheduler.** Tasks can use a working directory and append
  bounded `git status`, recent log and diff stat to the prompt. Optional
  `max_tokens` caps each completion.
- **Guardrails.** Scheduled runs pause when the Codex pool has no usable
  account, and an optional daily token limit skips a task before any request
  when today's budget is spent. Provider-namespaced models stay independent.
- **Queue, cancel and retries.** `Run now` while busy is queued visibly; the
  active request can be cancelled; failures retry with a bounded delay and
  resume the normal schedule afterwards.
- **Encrypted backup / export / import.** One portable AES-256-GCM backup
  (PBKDF2-HMAC-SHA256, 210,000 rounds) covers scheduler tasks and history,
  settings, accounts and auth files, and model sources. Logs and gateway keys
  are excluded. Restore validates and decrypts before replacing live data.
- **Onboarding 2.0.** A live health check covers the gateway, accounts, model
  catalog, scheduler and last backup. Each failed row links to the relevant
  screen, and a disabled demo task can be created without sending a request.
- **Release hygiene.** Version metadata is aligned at 2.3.0 on macOS and
  Windows. Builds remain ad-hoc signed on macOS and unsigned on Windows.

## Downloads

- [macOS universal DMG](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-2.3.0.dmg) — macOS 14 or later, Apple Silicon and Intel.
- [Windows installer](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-2.3.0-setup.exe) — custom install path, WebView2 required.
- [Windows portable](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-2.3.0-win-x64-portable.exe) — single file, no install.

## Earlier fixes

- **2.2.4:** Full audit remediation: security and data handling, updater
  hardening, scheduler corruption handling, logs/CDP/quota protections, Windows
  Rust quota loop, equal dashboard tiles, provider-aware composer, Antigravity
  verification diagnostics.
- **2.2.3:** Equal dashboard tiles, provider-aware composer, Antigravity
  verification diagnostics.
- **2.2.2:** macOS refreshes the Codex model catalog on launch.
- **2.2.1:** Shared models stay visible under every provider.
- **2.2.0:** Cron schedules, task templates, menu-bar/tray background execution.
- **2.1.1:** Google Antigravity sign-in callback on port 51121.
- **2.1.0:** Dashboard 2.0, menu-bar/tray actions, task/reset notifications.
- **2.0.3:** Portable asset naming and legacy updater alias.
