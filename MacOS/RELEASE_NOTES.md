# Melon Tools 1.4.8

- Added in-app updates on both platforms: the sidebar shows «Проверить обновление» and switches to «Обновить» when a newer GitHub release is available. The update window opens only if you confirm it, verifies the asset SHA-256 before installing, and relaunches the new build: Windows swaps the single executable, macOS swaps the bundle from the DMG.
- Update downloads are restricted to HTTPS GitHub hosts and verified against the release digest; auto-check runs at most once a day, and partial or failed downloads are skipped.

- Reduced idle work and hardened scheduler timing across both apps; quota refresh responds to gateway activity.
- Hardened account, gateway, and Fleet process handling; fixed reliability issues found in the cross-platform audit.
- Added remembered scroll positions and sidebar keyboard shortcuts on macOS.
- Preserved the model catalog privacy protections introduced in 1.4.6.

## Downloads

- [macOS universal DMG](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-1.4.8.dmg) — macOS 14 or later, Apple Silicon and Intel.
- [Windows x64 app](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-1.4.8-win-x64.exe) — WebView2 Runtime required.

Both files include SHA-256 checksum assets on the release page.

## Earlier fixes

- **1.4.6:** Sanitized generated model catalogs and made quota reserve refresh respond to active gateway traffic.
- **1.4.5:** Fixed Codex account switching and live quota-routing updates.
