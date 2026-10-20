# Spec — P1–P3 hardening (audit fixes, both apps)

Status: approved-for-build (user instruction: «Исправь все P1, P2, P3 полностью», $specloop)
Baseline: delivery `f238f0f` · macOS 1.4.6 (15) · Windows 1.4.6 (single-file exe)
Scope owner: implementer (this session) · reviewer: independent `reviewer` subagent

## SPEC

### Objective
Close every P1–P3 finding from the stability/performance/UX audit. No behavior
change beyond the items below; no weakening of existing guarantees
(auth.json full shape, reserve pausing + live sync, chips contract).

### Requirements

**P1 — hot cost**
- R1 (W-4): the Windows chips bridge must not spawn PowerShell every 5 s.
  Discovery result (debug port) is cached; re-scan only when the cached port
  stops answering or the TTL expires.
- R2 (W-5): the Codex rollout lookup must not walk `~/.codex/sessions`
  every 5 s. The resolved path is cached per thread id; re-scan only when the
  thread changes or the file disappears.
- R3 (W-6): `requestsLastMinute` reads a bounded log tail (256–512 KB) instead
  of the whole gateway log.
- R4 (W-8): the bridge reuses a single reqwest client.
- R5 (M-3): `quotaTimer` and the ComposerBridge tick timer get tolerances.
- R6 (W-2): the embedded-engine extraction result is cached in memory; status
  polls never retry the 68 MB decompress.

**P2 — economy & UX**
- R7 (M-1): FleetStore polls and watches only while a Fleet/Dashboard section
  is visible (MainView drives it from the current selection).
- R8 (M-2): the macOS gateway log tail runs every 2 s (was 1 s).
- R9 (W-7): the bridge caches the gateway model list (short TTL).
- R10 (M-UX1): macOS restores the per-section scroll offset after switching
  sidebar sections (offset persisted per section key).
- R11 (M-UX2): macOS: Cmd+1…9 switch to the first nine sidebar sections.

**P3 — robustness & completeness**
- R12 (W-1): Windows single-instance lock; a second launch exits (lock held
  for the process lifetime, released by the OS on crash).
- R13 (W-3): Windows watchdog: if health fails twice while the app believes
  the gateway should run (and the user did not stop it), restart the engine —
  bounded attempts (3), surfaced in `gateway_status` (`watchdog`).
- R14 (X-1): Windows manual order buttons state explicitly that custom mode
  turns on (toast) and the README notes it.
- R15 (W-8/atomic): settings.json, config.yaml, instances.json and the Codex
  auth write on Windows go through tmp-file + rename.
- R16 (X-3): chips payload carries OpenRouter provider metrics (cached, 5 min).
  The session cost estimate stays hidden behind the built-in “no pricing”
  note on Windows (no price source ships with that build) — documented.

### Out of scope
Windows Fleet Call/Rules streaming pages; macOS engine watchdog; CLI changes;
new features.

### Assumptions
- The reviewer subagent is available for the independent REVIEW phase.
- Delivery commits/installs remain authorized by the project workflow.

## Acceptance criteria
- AC1 macOS: `xcodegen` + `xcodebuild test` → 16/16; `./build.sh` → signed
  app + DMG; installed app launches and the gateway answers.
- AC2 Windows: `cargo xwin build --release` succeeds; fresh single-file exe
  produced.
- AC3 Convergence: dev ↔ delivery diff = 0 (macOS tree); delivery git clean
  after commits.
- AC4 No regressions: unit tests unchanged/16 green; no new force-try/unwrap
  (audit greps stay clean).

## Check plan (required)
- CHK1 `xcodebuild ... test` (macOS) — required.
- CHK2 `./build.sh` (macOS release + DMG) — required.
- CHK3 `cargo xwin build --release --target x86_64-pc-windows-msvc` — required.
- CHK4 static greps: no PowerShell in the 5 s bridge path without cache;
  bounded log read; atomic writes present — required.
- CHK5 dev ↔ delivery convergence + `git status` clean — required.
- CHK6 install + process/gateway smoke, version readback — required.

## EVIDENCE

### Implemented changes (BUILD)

macOS (dev tree `/Users/ivankuprin/Projects/MelonTools/app`):
- R5: `CodexStore.startQuotaScheduler` → `quotaTimer?.tolerance = 3.0`;
  `ComposerBridge.start` → `tickTimer?.tolerance = 0.5`.
- R8: `CodexGatewayService` log tail interval 1.0 → 2.0 (tolerance kept).
- R7: `FleetStore.setActive(_:)` (start/stop); `MainView` drives it from the
  current section (`fleetSectionsActive`) on appear and on selection change.
- R10: new `Design/MTScrollMemory.swift` (NSScrollView offset memory) applied
  to all 14 pages via `.mtScrollMemory("scroll.<section>")`.
- R11: `MainView` overlay with Cmd-1…9 `keyboardShortcut` buttons mapping to
  `MTSection.allCases.prefix(9)`.
- Version: project.yml 1.4.7 (16); README «1.4.7 Hardening» section.

Windows (delivery tree `/Volumes/Z Slim/MelonTools/Windows/app`):
- R1: `bridge::find_debug_port_cached` (TTL 45 s positive / 30 s negative) +
  `invalidate_discovery` on target/WS failures; tick uses it.
- R2: `find_rollout` + `read_session_usage` + `session_usage_cached`
  (path cached per thread id, TTL 20 s, existence check).
- R3: `gateway::requests_last_minute` reads `log_tail(256 KB)`.
- R4: `bridge::client()` static OnceLock client; tick/`picker_models` reuse it.
- R6: `engine::ensure_engine` caches `OnceLock<Result<PathBuf, String>>`.
- R9: `picker_models` cache TTL 45 s.
- R12: `ensure_single_instance()` with `fs2` exclusive lock on
  `%APPDATA%\MelonTools\app.lock`; second launch exits.
- R13: `Watchdog` state + `watchdog_check` (every 6th tick, 2 misses, ≤3
  restarts) wired to `gateway_start`/`gateway_stop`, surfaced in
  `gateway_status.watchdog`.
- R14: `movePriority` toast `orderCustom` (RU/EN) — manual order is explicit.
- R15: atomic tmp+rename writes in `settings::save`, `gateway::write_config`,
  `instances::save`, `vault::write_codex_auth_to`.
- R16: `providers_metrics` (OpenRouter, 5-min cache) in the chips payload
  (`providers.openrouter.{total,usage,remaining,keyUsage,keyLimit}`).
- Version: Cargo.toml / tauri.conf.json / app_info / UI mock → 1.4.7; README
  release links updated.

### Check results
- CHK1 (macOS tests): pending
- CHK2 (macOS build.sh): pending
- CHK3 (Windows cargo build): pending
- CHK4 (static greps): pending
- CHK5 (convergence + git): pending
- CHK6 (install + smoke): pending

### Prior live verification (context)
- Pause→resume cycle verified live 11:33: icloud window reset to 100 % and was
  re-enabled automatically; live POST through the gateway returned HTTP 200.

## REVIEW

Three independent reviewer passes (fresh subagent contexts, read-only):

**Pass 1 — macOS internals** (ses_ead1d228…): verified R5, R7, R8, R10
(MTScrollMemory: observer removal, weak refs, clamp+retry, no force-ops),
R11 (single keyboardShortcut, harmless buttons), FleetStore lifecycle
(idempotent start / full stop), 14 unique scroll keys, 5/14 anchors sampled.
No code defects. Verdict FAIL only as a process/evidence gap (Windows scope
not yet inspected).

**Pass 2 — Windows tree** (ses_ead16ec9…): R1, R2, R3, R4, R6, R9, R12,
R15, R16, version bumps, R14 toast → PASS with file:line evidence.
R13 → **FAIL**, findings:
- F1 (MEDIUM-HIGH): the auto-start path never armed the watchdog
  (`supervised` stayed false → no auto-restart after launch).
- F2 (MEDIUM): `restarts` counted only successes → a persistently failing
  start retried every 30 s forever; `misses` was not reset on failure.
- F3 (LOW): fixed tmp names (`.json.tmp`/`.yaml.tmp`) could collide between
  concurrent in-process writers.
- F6 (INFO): ENGINE_VERSION stays "1.4.6" — correct: the engine payload is
  unchanged this round; the constant tracks the engine build.
- F7 (INFO): verify `start()` kills a wedged child before respawning.

**Operator checks** (mechanical, after pass 2): the remaining 9 macOS
anchors are each inside their page's ScrollView with unique keys; AC4 greps
= 0 force operations.

**REPAIR** (4 findings, one attempt each, all successful):
- F1: setup-block arms `supervised/user_stopped/misses` after a successful
  auto-start (main.rs).
- F2: every watchdog attempt counts toward the ≤3 bound and resets `misses`;
  `gateway_start` resets the restart budget (main.rs).
- F3: `paths::tmp_path()` (`.<name>.<pid>.<counter>.tmp`) used by all five
  atomic writers.
- F7: `gateway::start` terminates any previous child after the adopt branch,
  before spawning.
- F6: documented, no change needed.
Post-repair Windows rebuild: clean (22 s).

**Pass 3 — repaired hunks only** (ses_ead099f1…): **PASS** for F1, F2, F3,
F7 — no new defects introduced.

## LOOP
- Spec fingerprint: p1p2p3-hardening-final · project state: macOS 1.4.7 (16),
  Windows 1.4.7 (single-file exe, MelonTools-1.4.7.exe)
- Baseline revision: delivery `c7b6734`
- Cumulative repairs: **4** (F1, F2, F3, F7) — attempts: 1/1 each, all closed
- Required checks: CHK1 16/16 · CHK2 build.sh 1.4.7 signed + DMG · CHK3
  cargo xwin clean (27 s pre-repair, 22 s post-repair) · CHK4 static greps
  green · CHK5 convergence OK, tree clean · CHK6 installed 1.4.7 (16),
  running, gateway HTTP 401
- Reviewer isolation: three fresh read-only reviewer contexts; repairs verified
  by the independent pass 3 (self-review only for the mechanical greps)
