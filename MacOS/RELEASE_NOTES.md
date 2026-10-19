# Melon Tools 1.6.0

- **Antigravity provider.** Connect a Google account via OAuth and use the
  Antigravity models (Gemini 4/3.x, GPT-OSS 120B and Antigravity-hosted Claude
  variants) through the local gateway and the Codex model picker.
- **Ownership-aware provider lists.** Models are attributed by the engine's
  `owned_by` field, so shared ids (for example `claude-sonnet-4-6`) no longer
  appear under the wrong provider.
- **Claude/Codex/OpenCode/OpenRouter unchanged.** Antigravity is an additional
  provider; no quota percentages are shown because the engine has no
  Antigravity quota API.

## Downloads

- [macOS universal DMG](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-1.6.0.dmg) — macOS 14 or later, Apple Silicon and Intel.
- [Windows x64 app](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-1.6.0-win-x64.exe) — WebView2 Runtime required.

Both files include SHA-256 checksum assets on the release page.

## Earlier fixes

- **1.5.0:** Claude provider (OAuth subscription + API-key fallback), Claude
  bento card with 5-hour/weekly quota, auth-sync fix on both platforms, fixed
  updater redirect allowlist, Windows engine rebuilt from the pinned commit.
- **1.4.8:** In-app updates on both platforms (verified SHA-256, HTTPS-only, daily
  auto-check); reduced idle work and hardened scheduler timing across both apps;
  quota refresh responds to gateway activity; remembered scroll positions and
  sidebar keyboard shortcuts on macOS; model-catalog privacy preserved from 1.4.6.
- **1.4.6:** Sanitized generated model catalogs and made quota reserve refresh respond to active gateway traffic.
- **1.4.5:** Fixed Codex account switching and live quota-routing updates.
