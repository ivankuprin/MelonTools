# Melon Tools 2.2.3

- **Dashboard tiles are equal height.** Every overview card now uses the same
  fixed tile height, so the grid is aligned instead of a staircase.
- **The composer follows the selected provider.** Choosing an Antigravity or
  Claude model now replaces the Codex account-pool chips with that provider's
  account, project, model count and, for Claude, the 5-hour/weekly windows.
- **Antigravity verification diagnostics.** When Google blocks model calls with
  `VALIDATION_REQUIRED`, the Providers card shows the warning and a link to
  Google Account. Antigravity models stay unavailable until Google verifies
  the account.
- **Shared model names stay distinct in the composer index**, matching the
  provider-qualified Codex catalog names.
- No other changes.

## Downloads

- [macOS universal DMG](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-2.2.3.dmg) — macOS 14 or later, Apple Silicon and Intel.
- [Windows installer](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-2.2.3-setup.exe) — custom install path, WebView2 required.
- [Windows portable](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-2.2.3-win-x64-portable.exe) — single file, no install.

## Earlier fixes

- **2.2.2:** macOS refreshes the Codex model catalog on launch.
- **2.2.1:** Shared models stay visible under every provider.
- **2.2.0:** Cron schedules, task templates, menu-bar/tray background execution.
- **2.1.1:** Google Antigravity sign-in callback on port 51121.
- **2.1.0:** Dashboard 2.0, menu-bar/tray actions, task/reset notifications.
- **2.0.3:** Portable asset naming and legacy updater alias.
