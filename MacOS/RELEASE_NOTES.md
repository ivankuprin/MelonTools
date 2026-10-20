# Melon Tools 1.7.1

- **Images work for provider models.** The generated Codex catalog now declares
  `input_modalities: ["text","image"]` for vision-capable models: Claude and
  Antigravity (Gemini/Claude families), OpenRouter models whose metadata lists
  image input, and common vision families on Windows. Existing saved models are
  backfilled on load, and the macOS model rows gained an «Images» toggle.
- Codex must be relaunched after Apply so it reloads
  `~/.codex/melon-model-catalog.json`.

## Downloads

- [macOS universal DMG](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-1.7.1.dmg) — macOS 14 or later, Apple Silicon and Intel.
- [Windows x64 app](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-1.7.1-win-x64.exe) — WebView2 Runtime required.

Both files include SHA-256 checksum assets on the release page.

## Earlier fixes

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
