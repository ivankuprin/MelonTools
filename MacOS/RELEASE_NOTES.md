# Melon Tools 2.1.0

- **Dashboard 2.0.** Pool health (usable/paused/errors, average 5h/week),
  quota trends over 24 h and 7 days, session spend and the top three providers,
  and a scheduler summary with Run next. Four cards can be hidden in Settings.
- **Menu bar / tray quick actions.** Pool quotas at a glance, open the app,
  jump to the scheduler, run the next due task, pause/resume the API service and
  quit. The Windows tray exposes the same actions.
- **Notifications.** Scheduled runs report success or failure; a quota window
  reset is announced once per account/window; low-quota alerts honor the master
  toggle.

## Downloads

- [macOS universal DMG](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-2.1.0.dmg) — macOS 14 or later, Apple Silicon and Intel.
- [Windows installer](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-2.1.0-setup.exe) — custom install path, WebView2 required.
- [Windows portable](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-2.1.0-win-x64-portable.exe) — single file, no install.

## Earlier fixes

- **2.0.3:** Portable asset renamed to `-win-x64-portable.exe`; legacy updater alias.
- **2.0.2:** Pool-pause banner with nearest reset and «Снять паузу».
- **2.0.1:** Windows NSIS installer; fixed welcome modal.
- **2.0.2:** Pool-pause banner with nearest reset and «Снять паузу».
- **2.0.1:** Windows NSIS installer with path selection; fixed welcome modal.
- **2.0.0:** Fleet removed; task scheduler added.
- **2.0.1:** Windows installer with path selection; fixed welcome modal; scheduler polish.
- **2.0.0:** Fleet removed; task scheduler with model selection added.
- **1.7.4:** Codex catalog schema fix (instructions + experimental tools from
  the local cache), 1.7.1 route behavior restored, images supported.
- **1.7.3:** Preserved `experimental_supported_tools` in generated catalogs.
- **1.7.2:** (superseded) automatic catalog apply and capability metadata.
- **1.7.1:** Images work for provider models.
- **1.7.2:** Automatic catalog apply + relaunch banner; per-model reasoning/tool
  capabilities; hourly model-list refresh on macOS.
- **1.7.1:** Images work for provider models (catalog declares text+image for
  vision models, Images toggle, backfill for saved models).
- **1.7.0:** Security (DPAPI v2, CDP gating, CSP extras, SHA-pinned CI),
  reliability (6h update checks, macOS rollback), UX (onboarding, diagnostics,
  quota sparklines, low-quota notifications), packaging/docs.
- **1.6.4:** Clean distribution (measurement/testing docs removed, naming
  unified, rebuilt artifacts).
- **1.6.3:** Security and data-safety hardening (updater trust, URL opener,
  secret redaction, PID-based process control, engine SHA256 provenance, atomic
  writes, CSP) plus UX fixes (Claude disconnect cleanup, instance confirmation,
  Windows input preservation, i18n).
- **1.6.2:** Antigravity card aligned with the Claude card (Refresh + Settings;
  connect/disconnect in Settings).
- **1.6.1:** Fixed the in-app installer hang (sheet dismissal, hard-exit
  watchdog, script TERM/KILL fallback).
- **1.6.0:** Antigravity provider (Google account OAuth) with ownership-aware
  model lists and band-400 catalog entries; no fabricated quota.
- **1.5.0:** Claude provider (OAuth subscription + API-key fallback), Claude
  bento card with 5-hour/weekly quota, auth-sync fix on both platforms, fixed
  updater redirect allowlist, Windows engine rebuilt from the pinned commit.
- **1.4.8:** In-app updates on both platforms (verified SHA-256, HTTPS-only, daily
  auto-check); reduced idle work and hardened scheduler timing across both apps;
  quota refresh responds to gateway activity; remembered scroll positions and
  sidebar keyboard shortcuts on macOS; model-catalog privacy preserved from 1.4.6.
- **1.4.6:** Sanitized generated model catalogs and made quota reserve refresh respond to active gateway traffic.
- **1.4.5:** Fixed Codex account switching and live quota-routing updates.
