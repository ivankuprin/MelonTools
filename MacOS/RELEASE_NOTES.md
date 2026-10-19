# Melon Tools 1.6.2

- **Antigravity card matches the Claude card.** The Providers card now always
  shows «Обновить» + «Настройки»; connecting, cancelling and disconnecting the
  Google account live on the Antigravity settings page.

## Downloads

- [macOS universal DMG](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-1.6.2.dmg) — macOS 14 or later, Apple Silicon and Intel.
- [Windows x64 app](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-1.6.2-win-x64.exe) — WebView2 Runtime required.

Both files include SHA-256 checksum assets on the release page.

## Earlier fixes

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
