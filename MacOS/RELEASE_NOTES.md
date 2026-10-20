# Melon Tools 2.2.0

- **Scheduler automation.** Tasks can now use five-field cron expressions
  (steps, ranges, lists, month/day names, Sunday 0 or 7) in addition to
  intervals, with a per-task time zone.
- **Task templates.** Five built-in templates cover a morning digest, PR
  review, weekly repository summary, log check and daily spend report.
  Variables such as `{{repo}}`, `{{branch}}` and `{{path}}` are filled in the
  editor and substituted when the task is created.
- **Background execution.** On macOS, keep Melon Tools in the menu bar and
  enable Launch at login; on Windows, closing the window now hides it to the
  tray. The scheduler keeps running while the app is in the background.
- Windows time zones support the system zone, UTC and fixed offsets; macOS
  supports the full IANA list.

## Downloads

- [macOS universal DMG](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-2.2.0.dmg) — macOS 14 or later, Apple Silicon and Intel.
- [Windows installer](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-2.2.0-setup.exe) — custom install path, WebView2 required.
- [Windows portable](https://github.com/ivankuprin/MelonTools/releases/latest/download/MelonTools-2.2.0-win-x64-portable.exe) — single file, no install.

## Earlier fixes

- **2.1.1:** Google Antigravity sign-in callback on port 51121.
- **2.1.0:** Dashboard 2.0, menu-bar/tray actions, task/reset notifications.
- **2.0.3:** Portable asset naming and legacy updater alias.
