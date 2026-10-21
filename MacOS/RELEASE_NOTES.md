# Melon Tools 2.2.4

- **Full audit remediation.** Hardened Windows instance deletion against path
  traversal, isolated macOS tests from the live vault/gateway/Codex config,
  removed real-token `/tmp` residue, and fixed the Windows settings/key/reserve
  saves.
- **Release and update safety.** Release workflow checks the requested tag,
  runs tests, verifies all assets, and signs the portable before building the
  installer. The Windows updater now uses a UTF-8 PowerShell swap with backup
  and rollback; the installer removes autostart and stops a running app.
- **Runtime fixes.** Windows quotas and notifications run in Rust while in the
  tray; corrupt stores are quarantined; the Chrome DevTools bridge validates
  loopback targets; quota refresh is single-flight; scheduler corruption and
  interrupted runs are handled; API-key rotation updates the Codex route;
  Antigravity emails are masked in the composer; the Codex catalog handles
  ownership, schema and shared model names correctly.
- **UI fixes.** Equal dashboard tiles, provider-aware composer chips, safer
  Codex relaunch behavior, accessibility labels/contrast, preserved section on
  language switch, and the Antigravity Google-verification warning.

## Downloads

- [macOS universal DMG](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-2.2.4.dmg) — macOS 14 or later, Apple Silicon and Intel.
- [Windows installer](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-2.2.4-setup.exe) — custom install path, WebView2 required.
- [Windows portable](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-2.2.4-win-x64-portable.exe) — single file, no install.

## Earlier fixes

- **2.2.3:** Equal dashboard tiles, provider-aware composer, Antigravity verification diagnostics.
- **2.2.2:** macOS refreshes the Codex model catalog on launch.
- **2.2.1:** Shared models stay visible under every provider.
- **2.2.0:** Cron schedules, task templates, menu-bar/tray background execution.
- **2.1.1:** Google Antigravity sign-in callback on port 51121.
- **2.1.0:** Dashboard 2.0, menu-bar/tray actions, task/reset notifications.
- **2.0.3:** Portable asset naming and legacy updater alias.
