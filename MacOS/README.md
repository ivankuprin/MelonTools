# Melon Tools

A native macOS cockpit for the **Codex account pool**, model providers and **scheduled model tasks**.
Built with SwiftUI, macOS 14+, Apple Silicon (arm64).

```
┌─────────────────────────────────────────────────────────────┐
│  Melon Tools                                                │
│                                                             │
│  Codex            Scheduler            App                  │
│  ├─ Accounts      ├─ Tasks             └─ Settings          │
│  ├─ API Service   ├─ Run now                                │
│  ├─ Providers     ├─ History                                │
│  ├─ Composer      └─ Results                                │
│  └─ Instances                                               │
└─────────────────────────────────────────────────────────────┘
```

## What's new in 1.6.3 «Security and data safety»

- **Hardened updater and secrets.** The Windows updater applies only the release it checked, the URL opener avoids cmd.exe, the management secret stays in the backend, helper processes are stopped by PID with identity checks, the engine binary is SHA-256 verified after extraction, and a restrictive CSP is set.
- **Data safety.** Atomic permission-preserving writes for secrets, config and auth files, bounded log rotation, backups and updater logs locked to 0600 under ~/Library/Logs.
- **UX fixes.** Claude disconnect clears its picker models, instance deletion asks for confirmation, Windows keeps unsaved inputs on background refresh, and login polls time out.

## What's new in 1.6.2 «Antigravity settings»

- **Consistent provider card.** The Antigravity card always shows «Обновить» and «Настройки»; connecting, cancelling and disconnecting live on the Antigravity settings page.

## What's new in 1.6.1 «Installer fix»

- **In-app installer reliability.** The update sheet closes before termination, a watchdog exits the app if termination is vetoed, and the swap script escalates to TERM/KILL instead of waiting on a hung process.

## What's new in 1.6.0 «Antigravity»

- **Google Antigravity joins the Providers page.** Connect a Google account via
  OAuth (engine-native, same pattern as Claude); the account email and project
  id land on the card, and the Antigravity models appear in the Codex picker.
- **Ownership-aware models.** Antigravity serves Gemini, GPT-OSS and even
  Claude-family ids; the model lists now separate them by the engine's
  `owned_by` field, so Claude and Antigravity never claim each other's models.
- **No invented quota.** The engine exposes no Antigravity quota API, so the card
  shows connection state, account, project and model count only.

## What's new in 1.5.0 «Claude provider»

- **Claude joins the Providers page.** Connect a Claude Pro/Max subscription with
  OAuth (the same client flow the Claude Code app uses) or fall back to an
  Anthropic console API key. Credentials are written as engine-native
  `claude-*.json` auth files and hot-load into the gateway.
- **Claude models in the Codex picker.** Selected `claude-*` models ride the new
  priority band 300 and appear in a Claude group after Apply + relaunch.
- **Claude bento card.** The Providers page shows the connection state, account
  email, plan, 5-hour and weekly quota windows with reset times, and the
  selected-model count. Numbers come from the account usage endpoint; missing
  data renders as «—» instead of made-up values.
- **Account-sync safety (both platforms).** Codex account sync now cleans only
  `codex-*.json` auth files, so Claude logins survive pool refreshes and quota
  ticks. Disconnect asks for confirmation.

## What's new in 1.4.8 «Update from GitHub»

- **In-app updates.** A full-width control sits in the sidebar above the
  status footer: «Проверить обновление» while up to date, switching to a gold
  «Обновить» button automatically when a newer GitHub release is known. It
  opens a window with the release notes and «Отмена» / «Обновить»;
  auto-check runs at most once a day.
- Downloads are verified against the release SHA256 (native GitHub asset
  digest or the `.sha256` file) before anything is installed; only HTTPS
  GitHub hosts are accepted.
- macOS swaps the bundle from the DMG after the app quits and relaunches it;
  Windows replaces its single executable the same way.

## What's new in 1.4.7 «Hardening»

- **Quieter when idle.** The gateway log tail runs every 2 s, the quota and
  chips timers carry tolerances, and Fleet polling only runs while a fleet or
  dashboard page is on screen.
- **Faster return from a tab.** Each section remembers its scroll offset —
  switching pages and coming back lands you where you left.
- **Cmd-1…9** jump straight to the first nine sidebar sections.
- The model catalog no longer bundles client-private prompt/policy fields.

## What's new in 1.4.6 «Fleet rebrand»

- **Full rebrand.** The fleet CLI, its env vars, and its home folder now use
  Melon Tools naming: the CLI is `melon-fleet` (bundled with the app), the
  env prefix is `MELON_FLEET_*`, and the workspace lives in
  `~/.melon-fleet`.
- **Quota reserve reacts fast now.** The quota refresh is adaptive: it keeps
  the configured interval when idle, but checks every ~30 seconds while the
  gateway is serving requests, so a 5% reserve pauses an account promptly
  instead of letting it burn to zero between five-minute checks. Same logic
  in the Windows build.

## What's new in 1.4.5 «Reliability fixes»

- **Codex no longer gets stuck after an account switch.** The auth file
  (`~/.codex/auth.json`) is now written in the full shape the Codex app
  expects: `auth_mode` and `tokens.account_id` are always present. Without
  them Codex logged “waiting for a ChatGPT account id” and blocked chatting
  with “failed to load workspace settings” — requests never reached the
  gateway.
- **Quota refresh now reaches the gateway live.** Account availability
  (paused / usable) is part of the routing signature, so both pause and
  unpause sync the gateway auth files on the refresh that landed them.
  Before, a window reset left the accounts disabled in the gateway until an
  unrelated sync happened.

## What's new in 1.4.4 «Smooth scrolling pass»

- **No shadowed scroll layers.** Card and sidebar shadows are gone: a layer
  with a shadow forces an offscreen render pass on every scroll frame and
  window animation on macOS. Hairline borders still separate the cards.
- **Pure-SwiftUI meters.** Quota and credit bars are capsule shapes scaled
  with a render transform — no hosted `ProgressView` per bar, and no
  `GeometryReader` inside scrolling content.
- **Light list rows.** The 300–470-row model lists use a static checkbox
  image with a whole-row tap instead of a hosted `Toggle` per row (re-hosting
  AppKit checkboxes while scrolling was a visible jank source).
- **Hover stays local.** Moving the pointer over the sidebar re-renders the
  row, not the whole layout including the active page behind it.
- **Quiet idle.** The 5s gateway health probe no longer publishes when
  nothing changed, and gateway/bridge log tails are internal state — no
  observer is invalidated by log traffic.
- **Universal build.** The embedded gateway engine now ships as a universal
  binary (arm64 + x86_64) — the DMG runs on both Apple Silicon and Intel
  Macs (macOS 14+).

## What's new in 1.4.3 «Donate & smooth GUI»

- **Donate page.** A new «Донат» sidebar item under Settings: USDT (TRC20)
  wallet with a QR generated on the fly by CoreImage (Vision-verified to
  decode back to the exact address) and a one-click copy button.
- **Smooth GUI.** Gateway log lines were published to every observer even
  though no view renders them — under agent load that invalidated the whole
  sidebar + active page dozens of times per second (the scroll/open/close
  lag). The log tail and the request journal are internal state now, the
  sidebar footer is its own tiny view, and status changes re-render only the
  footer.
- **Fleet without freezes.** CLI resolution is async (login-shell PATH probes
  no longer block the UI), streaming runs are cancellable with a Cancel
  button, console panes cap their buffer at 1000 lines and render lazily,
  result bodies read a bounded 512 KB prefix.
- **Account cards.** Horizontal quota bars instead of rings with
  two-component reset times — «через 1 ч 23 мин» for the hourly window and
  «через 6 дн 4 ч» for the weekly one. Deleting an account now asks for a
  confirmation.
- **Live pool load.** The pool popover shows «Запросы: N/мин» parsed from the
  gateway log — the actual load that burns the rolling windows.

## What's new in 1.4.2 «Providers, Go & hardening»

- **OpenCode Go models work now.** Models the Go plan covers ride the
  `/inference/go` endpoints (with the required `x-opencode-session` header), so
  they bill against the Go subscription. The generic surface — which answered
  "Insufficient account funds" despite an active Go plan — is kept only for
  models the Go plan does not include.
- **The account pool fails over properly.** Reserve thresholds and exhausted
  windows (0% left) now *exclude* an account from gateway routing until the
  next quota refresh, instead of only reordering it; stale quota readings never
  pause an account. The gateway also retries through cooling credentials
  (`request-retry: 3`, 45 s max wait, 20 s transient cooldown).
- **Accounts show subscription and resets.** Every Codex account card now has
  the subscription end date (with a relative reminder like “31 дн.”, or
  «Подписка истекла»), the reset-credit count with an availability hint
  («Нет доступных сбросов») and the nearest expiry, plus a warning when a 0 %
  weekly window blocks the 5-hour one. The subscription date is re-read from
  the backend every 30 minutes and falls back to the id_token claim.
- **Accounts page: selection + bulk actions.** Checkboxes on every account
  card, select-all, bulk quota refresh and bulk delete.
- **The «Models» page is now «Providers».** Three bento cards — the Codex
  account pool, OpenCode and OpenRouter — show each provider's live numbers.
  The pool card leads to Accounts; **Настройки** on a source card opens its
  key + model picker right inside the page.
- **Hardening pass.** Gateway PID/kill hygiene (identity check before
  SIGTERM/SIGKILL — no more blind lsof/PID-file kills), rollout parsing cache
  (no more 128 MB re-reads every 5 s), `~/.codex/config.toml` written 0600
  (it carries the bearer token), thread-safe log buffers in `ShellService`,
  device-login retry cap, unique gateway auth-file names, YAML-escaped config
  values, and a session-cost attribution fix (pool turns are no longer billed
  to OpenCode when a model id collides).
- **OpenRouter numbers are split by meaning.** The card shows the remaining
  balance (`total_credits − total_usage`, e.g. **$3.03**), the credits spent of
  those purchased (**$26.97 of $30**) and the key limit usage
  (**$0.09 of $1000**) as three separate tiles — the key limit is no longer
  mixed up with the balance.
- **The composer chip is one compact pill.** Both modes fit one chip: the pool
  shows `[Аккаунты 3 · 5 ч 200% · Неделя 180%]` — the pool's total capacity,
  summed across accounts, a third-party model shows `[OpenRouter ≈$0.09]` with
  the session spend of that provider. The popover carries the full breakdown
  and the refresh button stays.
- **Session spend is an honest estimate.** Every rollout turn is priced with
  the model that ran it (OpenRouter list prices, cache reads priced separately)
  and the numbers are split per provider: spend, tokens, cache share, turns.
  Missing prices are filled from the public OpenRouter model list on demand.
  Pool models have no public price, so they show a dash instead of a made-up
  number.
- **OpenRouter routes to the cheapest provider.** The gateway config adds a
  `payload.default-raw` rule that sets `provider: {"sort": "price"}` on every
  `openrouter/*` request (price-verified end-to-end through CLIProxyAPI).
  OpenRouter aliases now carry the `openrouter/` prefix; older stores migrate
  on load.
- **The picker is grouped by provider.** The Codex model menu shows
  **OpenAI**, **OpenCode** and **OpenRouter** headers with the models of each
  provider underneath (and a small provider tag on every third-party row).
  The catalog builder assigns the order with priority bands — the pool keeps
  0…8, OpenCode starts at 100, OpenRouter at 200. A stale catalog (written by
  an older build) is regenerated automatically at app launch.
- **Sources load at launch.** The model-source store is now read when the app
  starts, so a gateway restart keeps the `api-keys.openai-compatibility`
  block instead of dropping it until the Providers page is opened.

## What's new in 1.4.0 «Model sources & Bento»

- **Models page with key-based sources.** A new **Codex → Models** page connects
  **OpenRouter** and **OpenCode** by API key: paste the key, load the account
  model list, tick the models you want. The pool models stay always available.
- **The Codex picker is generated.** Applying writes
  `~/.codex/melon-model-catalog.json` — the pool catalog plus one entry per
  selected model (slug, display name, context window, auto-compact limit) — and
  points `model_catalog_json` in `~/.codex/config.toml` at it. Selected models
  appear in the Codex composer after a relaunch.
- **One gateway config for everything.** Selected models ride in the same
  gateway service (`api-keys.openai-compatibility`), hot-reloaded — no restart:
  OpenRouter models keep their raw ids (`z-ai/glm-5.3-flash`), OpenCode models
  are aliased as `opencode/<model>`.
- **Bento layout.** The sidebar is one solid card on the app canvas; the content
  area is a stack of cards. Timers were reworked: batched log ingestion, change
  detection on fleet polling, cached process discovery, wider probe intervals.

## What's new in 1.3.3 «Glass & brand»

- **Frosted chips popover.** The «Account status» popover in the Codex composer
  now sits on a frosted-glass surface: 30 px blur with saturation over a
  72–78% opaque tint (dark/light), readable in both themes. The popover had no
  background at all — its palette custom properties were bound to
  `.melon-chips` while the popover is attached to `document.body`.
- **Technical text out of the UI.** The API Service page drops the port field,
  the raw endpoint lines, and the requests/log cards; Settings drops the
  «Paths» and «Diagnostics» cards; the composer page drops the debug-port line
  and the event log. What stays in «Client setup» is everything needed to
  connect other tools: Base URL and API key, each with a copy button.
- **Cleaner Fleet pages.** Fleet pages use `fleet …` kickers, the Call and
  Rules consoles print human status lines instead of shell commands, and
  exit pills read **Done / Tool error / Failed (n)**.
- **Brand refresh.** The new melon-and-wrench logo appears in the sidebar, the
  menu bar extra, and About; the app icon and the DMG volume icon are drawn
  from the new artwork.

## What's new in 1.3.2 «Pool routing»

- **The API control card moved to API Service.** The full «API control»
  block — gateway state, launch, and pool routing — now lives on the
  **Codex → API Service** page. **Codex → Accounts** gets a compact twin as
  the first card in the grid: state, address, routing mode, queue preview,
  and **Launch Codex** / **Manage** buttons.
- **Per-account limits with automatic switching.** Each account can set
  “pause” thresholds for the 5-hour and weekly quota — for example, switch
  away when the 5-hour quota left drops to 10%. When a threshold is hit, the
  planner demotes the account and the next one takes over live (the gateway
  hot-reloads auth files, no restart); the account returns automatically
  when its quota recovers.
- **Account priority and roles.** Mark an account **Always first** (it leads
  the queue while usable) or **Backup** (used only when the regular accounts
  are unavailable).
- **Seven routing modes**, mirroring Cockpit Tools: **Auto (recommended)**,
  **Most quota left first**, **Least quota left first**, **Top plan first**,
  **Lower plan first**, **Expiring soon first**, and **Manual order** with
  reorder arrows. The gateway runs fill-first over the computed priorities:
  the top account serves until it is exhausted, then the next takes over.
- **No technical paths in the UI** — raw file paths in normal screens are
  replaced with plain wording (import, route status, instances, diagnostics).
- **Consistent naming.** The brand is simply **Fleet** everywhere in the UI.

## What's new in 1.3.1 «Launch the app»

- **Every “Launch Codex” button opens the app.** The buttons in the API
  Service page, Settings, and the account rows no longer open Terminal with
  the CLI — they start the gateway when needed, write the route, and restart
  the Codex app, exactly like the card in **Accounts**.
- **Fresh settings on every launch.** Each launch restarts the app (like
  Cockpit Tools does for its default instance), so it always rereads
  `~/.codex/config.toml` and comes up with the current routing.
- **Chips always come back.** While the Melon route is active, a Codex app
  that is running without the debug port (for example, started from the Dock)
  is relaunched automatically so the composer chips attach. An app that
  ignores the quit request is force closed after a graceful wait.

## What's new in 1.3.0 «API Control»

- **Main API control card** — a permanent first card in **Codex → Accounts**.
  It manages the local API service end to end (status, copy URL, check API,
  restart, stop) and adds **Launch Codex**: one click points the Codex app at
  the gateway — the previous `~/.codex/config.toml` is backed up, the route is
  written, and the app relaunches with the debug port so the chips reconnect.
  **Remove routing** restores the backed-up config and relaunches the app.
- **Account routing strategies** — «Even» spreads requests across the pool
  (round-robin); «By priority» is fill-first: the top account serves until it
  is exhausted, then the next one. Reorder with the arrows and press
  **Apply routing** — the gateway restarts with the new strategy and the
  priorities land in the account auth files.
- **Solid surfaces everywhere** — Liquid Glass styling is gone from the app
  and from the injected composer chips: flat cards, buttons, and popovers
  with higher contrast in both themes.
- **Startup safety** — a `model_catalog_json` reference to a missing file
  (left behind when another route tool removes its catalog) stops the Codex
  app from starting. Melon Tools now drops the dangling key while its route
  is active; the backup restores the line on «Remove routing».

## What's new in 1.2.1 «Chips»

- **Compact traffic panel** — the «Recent requests» list in **Codex → API
  Service** is now a fixed-height card with its own scroll, so it stays
  compact no matter how much traffic flows through the gateway.

## What's new in 1.2.0 «Chips»

- **Composer Chips for the Codex app** — Liquid Glass chips right in the Codex
  composer: account count, 5-hour and weekly quota, one-click refresh, and an
  «Account status» popover with per-plan quotas and pool health
  (working / failed / paused). Russian by default — the chips follow the app
  language.
- **Zero-footprint injection** — the chips live over a local DevTools
  connection to the Codex app. Nothing on disk is patched, no ports are opened,
  no tokens are shared: Melon Tools pushes the pool snapshot, the chips push
  back refresh requests. The Codex app is relaunched with a loopback debug port
  automatically.
- **Graceful lifecycle** — when Melon Tools quits, the chips dim and keep the
  last values; they reconnect on the next launch. Turning the feature off in
  **Codex → Composer Chips** removes them instantly. The chips adapt to the
  composer width: full → accounts + refresh → hidden.

## What it does

### Scheduler
A small, local task scheduler that runs while Melon Tools is open:

- **Tasks** — name, prompt, model (from the local gateway: pool, OpenCode,
  OpenRouter, Claude, Antigravity), optional reasoning effort and interval.
- **Run now / enable toggle** — manual runs always work; enabled tasks run on
  their interval through the local gateway (`/v1/chat/completions`).
- **Results and history** — the last result, duration and tokens per task, with
  bounded history (20 entries per task, 200 in total) in
  `~/Library/Application Support/MelonTools/scheduler.json` (0600).
- **No background agent** — tasks run only while the app process is alive; a
  missed run fires once after wake/relaunch, never as a burst.

### Codex
Re-implemented from scratch on top of the official OAuth/API endpoints:

- **Accounts** — a local vault of ChatGPT subscription accounts. Import the
  current `~/.codex/auth.json`, paste an auth payload, or sign in with the
  device flow. Per-account hourly/weekly quota rings from
  `chatgpt.com/backend-api/wham/usage`, reset-credit count, one-click switch
  (writes `~/.codex/auth.json`, keeps a backup), proactive token refresh.
- **API Service** — a local OpenAI-compatible gateway (CLIProxyAPI engine,
  MIT, embedded) that serves your account pool on `http://127.0.0.1:18317`
  with a generated API key. Start/stop, health check, client setup snippets.
  Any OpenAI-compatible tool can point at it. The control card in
  **Accounts** keeps it at hand: launch the Codex app on the gateway in one
  click, switch the routing strategy, reorder account priorities.
- **Composer Chips** — solid status chips inside the Codex app composer:
  accounts count, 5-hour and weekly quota, one-click refresh, and an
  «Account status» popover. Injected over a local DevTools connection — no
  files patched, no ports opened; chips dim when Melon Tools is off and are
  removed when the feature is disabled.
- **Instances** — parallel Codex CLI sessions, each with its own `CODEX_HOME`
  and bound account; launch opens Terminal with the isolated environment.

## Requirements (runtime)

| Component    | Why                                   | How to get              |
|--------------|---------------------------------------|-------------------------|
| macOS 14+    | App baseline                          | —                       |
| Apple Silicon| arm64 build                           | —                       |
| Codex CLI    | Instances (optional)                  | `npm i -g @openai/codex`|
| Codex app    | Composer Chips (optional)             | openai.com/codex        |

## Build from source

Prerequisites: Xcode (27+), XcodeGen (`brew install xcodegen`), Go 1.22+
(`brew install go`). `create-dmg` (`brew install create-dmg`)
is optional — the script falls back to a plain `hdiutil` image.

```bash
./build.sh            # full pipeline: gateway → icon → xcode → dmg
open build/MelonTools-1.4.2.dmg
```

The app is ad-hoc signed (personal build, not notarized). On first launch use
**right-click → Open**, or clear the quarantine flag:
`xattr -dr com.apple.quarantine "/Applications/Melon Tools.app"`.

Individual steps:

```bash
# 1. Gateway engine (Go, arm64, stripped)
cd _sources/CLIProxyAPI
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags "-s -w" \
  -o ../../build/cliproxyapi ./cmd/server

# 2. Icon
#    scripts/assets/source-appicon.png → sips + iconutil (see build.sh)

# 3. App (build products stay in ~/Library — they never appear in Launchpad)
cd app && xcodegen generate
xcodebuild -project MelonTools.xcodeproj -scheme MelonTools \
  -configuration Release -derivedDataPath "$HOME/Library/Developer/MelonTools" build

# 4. Ad-hoc sign + DMG
codesign --force --deep --sign - "$HOME/Library/Developer/MelonTools/Build/Products/Release/MelonTools.app"
create-dmg --volname "Melon Tools" "build/MelonTools-1.4.2.dmg" "Melon Tools.app"
```

## Layout

```
app/                          XcodeGen project + Swift sources
  project.yml                 target definition (embed scripts live here)
  MelonTools/
    Core/                     AppState, ShellService (Process wrapper)
    Design/                   MTTheme tokens, MTComponents
    Scheduler/                Task models, store, gateway runner
    Codex/                    Accounts, OAuth/quota service, gateway service
    Views/                    Dashboard, Scheduler, Codex views, Settings
  Resources/                  AppIcon.icns, Logo.png (bundled artwork)
scripts/
  assets/                     icon + logo sources used by build.sh
  trim-logo.swift             crops transparent margins from the logo source
  make-icon.swift             legacy icon generator (unused)
  test-gateway.py             smoke-test for the gateway config shape
_sources/
  CLIProxyAPI/                gateway engine (MIT)
build/                        artifacts (gateway binary, icon, dmg)
```

## Data locations

| What                  | Where                                              |
|-----------------------|----------------------------------------------------|
| Account vault         | `~/Library/Application Support/MelonTools/codex/accounts.json` (0600) |
| Gateway config        | `~/Library/Application Support/MelonTools/gateway/config.yaml` |
| Gateway account files | `…/gateway/auths/codex-*.json`                    |
| Instances             | `…/MelonTools/instances/<name>/codex-home/`       |
| Scheduler tasks       | `…/MelonTools/scheduler.json` (0600)              |

## Licensing notes

- The gateway engine is **CLIProxyAPI** (MIT), built from source.
- The Codex flows are a clean-room re-implementation of visible behavior
  against public endpoints; no cockpit-tools code was copied.
- This is a personal tool. You are responsible for how you use your accounts.

### Provenance (this build)

| Component      | Version | Commit                                    |
|----------------|---------|-------------------------------------------|
| CLIProxyAPI    | v8 tree | `e7003d2a3e2cee2d45f9950c067bf8e02a2ac0f8` |
