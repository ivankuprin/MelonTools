# Melon Tools 1.5.0

- **Claude provider.** Connect a Claude Pro/Max subscription via OAuth or an
  Anthropic console API key; selected Claude models appear in the Codex picker
  (priority band 300) and route through the local gateway engine (CLIProxyAPI v8).
- **Claude bento card.** Providers page shows connection state, account email,
  plan, 5-hour/weekly quota windows with reset times, and the model count;
  unavailable data renders as «—».
- **Auth-sync fix (both platforms).** Account sync no longer wipes non-Codex
  auth files, so Claude logins survive pool refreshes; disconnect is confirmed.
- **Windows engine rebuilt** from the pinned CLIProxyAPI commit, so the shipped
  engine binary provably contains the Claude and management-API code paths.

## Downloads

- [macOS universal DMG](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-1.5.0.dmg) — macOS 14 or later, Apple Silicon and Intel.
- [Windows x64 app](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-1.5.0-win-x64.exe) — WebView2 Runtime required.

Both files include SHA-256 checksum assets on the release page.

## Earlier fixes

- **1.4.8:** In-app updates on both platforms (verified SHA-256, HTTPS-only, daily
  auto-check); reduced idle work and hardened scheduler timing across both apps;
  quota refresh responds to gateway activity; remembered scroll positions and
  sidebar keyboard shortcuts on macOS; model-catalog privacy preserved from 1.4.6.
- **1.4.6:** Sanitized generated model catalogs and made quota reserve refresh respond to active gateway traffic.
- **1.4.5:** Fixed Codex account switching and live quota-routing updates.
