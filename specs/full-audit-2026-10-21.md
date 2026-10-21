# Spec: Melon Tools full application audit — 2026-10-21

## SPEC

### Objective

Produce a prioritized, evidence-based audit of Melon Tools and its release
machinery. Identify defects, security/privacy risks, performance issues,
incomplete features, parity gaps, UX/accessibility issues, documentation drift
and missing tests. Do not modify production source.

### Scope

- macOS SwiftUI app, resources, tests, build settings.
- Windows Tauri app, Rust backend, WebView UI, composer script, installer.
- Gateway integration, model catalog/routing, OAuth, scheduler, dashboard,
  composer bridge, updater.
- CI, release workflows, packaging, manifests, docs and git hygiene.

### Out of scope

- Implementing fixes to production code.
- Publishing, committing, signing or deploying.
- Line-by-line audit of CLIProxyAPI internals; only its integration contract.

### Current state

- Worktree is Melon Tools 2.2.3. Local `HEAD` is `1cf6a8e` (2.2.0); the
  worktree is dirty relative to it. `origin/main` is `e803618` (2.2.3).
- CI and Security for 2.2.3 passed. All 17 Release workflow runs are failed or
  cancelled; 2.2.3 was published manually.
- No production file may be changed by this audit.

### Assumptions

- Live user data and services must not be modified by the audit.
- Findings need file:line evidence and, where practical, a local command or
  observed runtime value.
- Runtime-only Windows items are labelled “verify on Windows”.

### Acceptance criteria

- **AC1 Coverage:** macOS, Windows, release/CI/docs and parity covered.
- **AC2 Evidence:** every Critical/High finding has file:line evidence and an
  impact statement.
- **AC3 Prioritization:** findings grouped by severity with remediation and a
  top-10 action list.
- **AC4 Verification:** checks run on the current tree; limitations recorded.
- **AC5 Safety:** no production source, user data, release asset or GitHub
  state changed by the audit.
- **AC6 Review:** independent review of the report before PASS.

### Check plan

Required: `xcodebuild test`, `cargo test`, `node --check` for `app.js` and both
composer scripts, `docs_lint.py`, `bash -n` on build/sign scripts.

Advisory/recorded: `cargo clippy` (unavailable in this toolchain), GitHub run
history, runtime file permissions, release asset digests, read-only specialist
agents.

### Done criteria

AC1–AC6 satisfied; all checks recorded; non-PASS criteria repaired in the
report or explicitly BLOCKED.

### AUTHORIZED_MUTATIONS

`specs/full-audit-2026-10-21.md` only. No production source, assets, user data,
git refs or GitHub state.

## EVIDENCE

### Checks

| Check | Result |
|---|---|
| `xcodebuild ... test` | **149 passed, 0 failed** |
| `cargo test` | **137 passed, 0 failed** |
| `node --check Windows/app/ui/app.js` | OK |
| `node --check MacOS/app/Resources/composer-chips.js` | OK |
| `node --check Windows/app/resources/composer-chips.js` | OK |
| `docs_lint.py` | OK; 3 workflows, 3 winget manifests, version 2.2.3 |
| `bash -n` build/sign scripts | OK (macOS build, Windows build, sign-macos) |
| `git diff --check` | clean |
| `cargo clippy` | **not run**: `cargo-clippy` not installed |
| GitHub Release runs | **17 total: 9 failure, 8 cancelled; zero success** |
| Runtime gateway log | `-rw-r--r--` (0644), 235 KB at audit time |
| CI / Security for 2.2.3 | success / success |

Observed state commands (2026-10-21):

```text
$ git rev-parse --short HEAD
1cf6a8e
$ git status --short | wc -l
28          # 27 tracked modifications from the 2.2.3 worktree + this new spec
$ gh api repos/ivankuprin/MelonTools/git/ref/heads/main --jq .object.sha
e803618e8f2163308386f15024129b7ddb18f346
$ gh run list -R ivankuprin/MelonTools -w Release -L 30 --json status,conclusion \
    --jq 'group_by(.conclusion) | map({conclusion: .[0].conclusion, count: length})'
[{"conclusion":"cancelled","count":8},{"conclusion":"failure","count":9}]
```

No production files were changed by this audit. Existing 2.2.3 worktree changes
were present before the audit started.

### Independent inputs

Three read-only specialist passes covered macOS, Windows and
release/security/docs. Their findings were re-checked against source on this
machine for the Critical/High items below.

## FINDINGS

Severity: **Critical** = data loss/security or release integrity; **High** =
likely failure/security/privacy/regression; **Medium** = correctness,
performance or important UX; **Low** = polish/docs.

### Critical

#### C1 — Windows `instance_delete` can delete an arbitrary directory
**Evidence:** `Windows/app/src-tauri/src/instances.rs:34-48,94-103`;
command exposed at `Windows/app/src-tauri/src/main.rs:733-736`; renderer call
`Windows/app/ui/app.js:2916-2924`.
`home_for(id)` joins the raw id; `PathBuf::starts_with` does not normalize
`..`. `safe_id` exists but is only used by `launch`. An id of `../..` passes the
guard and `remove_dir_all` resolves to `%APPDATA%`/the profile. A crafted
`instances.json` or compromised renderer can wipe unrelated data.
**Fix:** reject `!safe_id(id)` in `delete`; canonicalize and require
`home.parent() == instances_root`; add traversal tests (`..`, `../..`,
absolute paths). **Highest priority.**

#### C2 — macOS tests launch the production app and mutate real state
**Evidence:** `TEST_HOST` at
`MacOS/app/MelonTools.xcodeproj/project.pbxproj:492,509`;
`AppDelegate.applicationDidFinishLaunching`
`MacOS/app/MelonTools/MelonToolsApp.swift:42-58`; unconditional catalog sync
`MacOS/app/MelonTools/Codex/ModelSources.swift:936-943` writes
`~/.codex/melon-model-catalog.json` and may edit `~/.codex/config.toml`;
`MainView.onAppear` checks GitHub
`MacOS/app/MelonTools/Views/MainView.swift:67-70`.
The test host reads the real vault, starts quota/scheduler/composer timers,
auto-starts the real gateway and can auto-relaunch Codex. This audit’s test run
regenerated the real catalog, proving the side effect.
**Fix:** under XCTest use an ephemeral support dir/UserDefaults suite, no-op
gateway/scheduler/composer, no update check, and no catalog/config writes. Add a
test asserting the real paths are untouched.

#### C3 — E2E script copies real OAuth tokens to a predictable `/tmp` path
**Evidence:** `MacOS/scripts/test-gateway-e2e.py:15-17,23-56`.
It reads `~/.codex/auth.json`, writes access/refresh/id tokens to
`/tmp/melon-gw-e2e/auths/...` with normal umask (typically 0644), and never
cleans up (even on failure). Any same-user process can read them.
`MacOS/scripts/test-quota.py` also reads the real token but keeps it in memory;
it is not part of the on-disk leak.
**Fix:** use `tempfile.mkdtemp()`, `umask(0o077)`, `chmod 0600`, `finally`
cleanup; preferably use redacted fixtures rather than real tokens.

#### C4 — Release workflow is non-functional; releases are manual and untested
**Evidence:** `.github/workflows/release.yml:34` (dispatch checkout has no
`ref`), `:249`/`:291` (publish; partial assets accepted), `.github/workflows/ci.yml:3`
(CI not triggered by tags); GitHub history: 17 Release runs, 9 failure, 8
cancelled, zero success. v2.2.3 assets were uploaded manually before the tag
workflow was cancelled.
`fail_on_unmatched_files: true` applies only to the wildcard
`release-assets/*`: it requires at least one matching file, not all eight
expected artifacts. No release job runs macOS/Windows tests, so a tag can
publish untested source. Manual dispatch can rebuild `main` instead of the
requested tag and overwrite live assets.
**Fix:** checkout `ref: ${{ env.RELEASE_TAG }}` for dispatch; add concurrency,
draft + environment approval, all-asset/checksum verification, tag CI gate, and
one successful end-to-end test tag before trusting automation.

### High — macOS

#### M-H1 — Instance names allow path traversal and token writes outside the instance root
**Evidence:** `MacOS/app/MelonTools/Views/Codex/CodexInstancesView.swift:185-190,218-263`.
The free-text name is appended directly to `instances/`; create/delete/write
auth then operate on the resolved path. `../../Documents/foo` can write Codex
tokens into a synced folder or delete an unrelated `codex-home`.
**Fix:** restrict names to `[A-Za-z0-9._-]`, reject `.`/`..`/separators/control
characters, standardize and require containment under the instances root, use
`SecureFile.write`, and delete only a validated directory.

#### M-H2 — OAuth loopback server can terminate the app on SIGPIPE
**Evidence:** `MacOS/app/MelonTools/Codex/LoopbackServer.swift:73-92,191-210`.
Accepted clients never set `SO_NOSIGPIPE`; `Darwin.write` can raise SIGPIPE when
the browser closes early. There is no `deinit`/guaranteed listener close.
**Fix:** set `SO_NOSIGPIPE` on accepted sockets or ignore SIGPIPE; add
`deinit`/scoped cleanup; install the continuation before opening the browser or
buffer an early callback.

#### M-H3 — CDP bridge trusts a remote WebSocket URL and exports account emails
**Evidence:** `MacOS/app/MelonTools/Codex/ComposerBridge.swift:628-641` accepts
any `ws://` target; `CDPSession.swift:23-29,44-53` connects; `ComposerBridge.swift:314-321,449-467`
pushes provider data including Claude/Antigravity emails.
A process squatting the debug port can redirect the bridge to a remote
WebSocket and receive account metadata.
**Fix:** require `127.0.0.1`/`localhost`, exact debug port, validate the final
`/json` URL and target, restrict to the main composer, and remove email
identities from the injected payload.

#### M-H4 — Quota refresh is reentrant and can lose account edits
**Evidence:** `MacOS/app/MelonTools/Codex/CodexStore.swift:837-843` only updates
`busyAccountIds`; no guard in `refreshAllQuotas` `:938-943`; timer/manual
callers can overlap; stale account snapshots overwrite the whole account
`:908-910`; token refresh `CodexService.swift:171-193` can rotate concurrently.
**Fix:** one coalescing refresh task + per-account guard; merge fetched fields
only; generation tokens for stale results; timeouts; no forced token refresh in
bulk refresh.

#### M-H5 — Account upsert loses routing fields; remove leaves credentials/history
**Evidence:** `MacOS/app/MelonTools/Codex/CodexStore.swift:613-627` preserves
only id/quota/note, dropping reserves/preferred/backup/subscription fields from
`CodexModels.swift:31-40`; import sets `currentAccountId` before/independent of
merged id `:563-583`; `remove` `:1070-1075` deletes only the vault entry.
**Fix:** merge all routing/subscription fields and return the merged record;
remove/rotate Codex auth and backups after confirmation; remove quota history
and notification records.

#### M-H6 — Launch catalog sync silently edits another tool’s Codex config
**Evidence:** `MacOS/app/MelonTools/MelonToolsApp.swift:44` always calls
`syncCatalogIfNeeded`; `ModelSources.swift:936-943` always calls `sync`;
`CodexModelCatalog.swift:229-236` writes `model_catalog_json` without checking
`CodexGatewayService.codexRoute`.
**Fix:** write the reference only when Melon owns the route or the user applies
it; back up before editing; make catalog generation side-effect-free.

#### M-H7 — Automatic Codex restart can discard unsaved input
**Evidence:** `MacOS/app/MelonTools/Codex/ComposerBridge.swift:777-796` restarts
after two missed debug-port ticks; `:658-681` uses `terminate()` then
`forceTerminate()`; `CodexGatewayService.swift:749-762` always passes
`forceRestart: true`; disabling chips relaunches too `:43-52,126-158`.
**Fix:** restart only when route/debug state actually changes; confirm forced
restarts/chip disable; add a setting to disable auto-relaunch.

#### M-H8 — Gateway log is world-readable, unrotated and contains account identifiers
**Evidence:** `MacOS/app/MelonTools/Codex/CodexGatewayService.swift:539` creates
the log with default permissions; runtime observed `-rw-r--r--`; auth filenames
embed emails (`:78-85,160-164`); no rotation. `MacOS/README.md:22` claims 0600
and bounded rotation.
**Fix:** create 0600 under a 0700 directory; rotate by size; redact emails and
validation URLs; correct docs.

#### M-H9 — Gateway lifecycle can adopt/start the wrong service and hide failure
**Evidence:** `MacOS/app/MelonTools/Codex/CodexGatewayService.swift:296-308,605-641`.
Adoption trusts any HTTP 200 from `/v1/models`; spawned state stays `.starting`
until health succeeds; failed probes are ignored; termination sets `.failed`
without `lastError`.
**Fix:** require verified PID/identity; mark running after spawn/quick probe;
fail after repeated 401/unreachable; set `lastError`; cancel stale tasks.

#### M-H10 — Accessibility is systematically weak
**Evidence:** `MacOS/app/MelonTools/Design/MTTheme.swift:25,57-59,99-109`
(gold/tertiary contrast, fixed-point fonts); model rows use a static checkbox
image + row tap, not focusable (`ModelSourcesView.swift:1050-1085`); hidden
labels on account/scheduler toggles; icon-only buttons lack labels.
**Fix:** contrast tokens, semantic/relative fonts, focusable row buttons,
`.accessibilityLabel`/`Value`, VoiceOver grouping.

#### M-H11 — Composer refresh parses up to 128 MB every 5 seconds
**Evidence:** `MacOS/app/MelonTools/Codex/ComposerBridge.swift:98-106,341-345`
calls refresh every 5 s; `ProviderUsage.swift:610-619,651-695` reads up to
128 MB for an exact thread; mtime/size cache invalidates during active appends;
no tick reentrancy guard.
**Fix:** incremental byte-offset tail reader, slower cadence/background queue,
`isTicking` guard, skip heavy provider refresh while in flight.

#### M-H12 — API-key rotation leaves Codex’s bearer token stale
**Evidence:** `MacOS/app/MelonTools/Views/Codex/CodexAPIView.swift:52-57` writes
a new key and asks for a gateway restart; `CodexGatewayService.swift:466-504`
does not rewrite `~/.codex/config.toml` until route enable.
**Fix:** rotate key + config + Codex provider block atomically; tell the user
both changed.

#### M-H13 — Fresh route can point Codex at a missing catalog; apply+relaunch ignores start failure
**Evidence:** `MacOS/app/MelonTools/Codex/CodexModelCatalog.swift:65-76,229-236`
returns when config does not exist; `CodexGatewayService.swift:466-504` creates
the route without `model_catalog_json`; `ModelSources.swift:961-970` relaunches
Codex even if gateway start failed.
**Fix:** call `ensureConfigReference()` after creating the route; guard
`gateway.isRunning` before rewrite/relaunch.

#### M-H14 — No macOS single-instance protection
**Evidence:** `MacOS/app/MelonTools/Info.plist:4-35` has no
`LSMultipleInstancesProhibited`; `MelonToolsApp.swift:37-89` has no process
lock. Two copies share the PID file, config, auths, Codex config and port.
**Fix:** add the Info.plist key and a `flock`/`NSRunningApplication` guard;
activate the existing instance and exit.

#### M-H15 — Scheduler can lose tasks, replay an interrupted run, or run two tasks
**Evidence:** `MacOS/app/MelonTools/Scheduler/SchedulerStore.swift:232-237,240-250`
clears tasks on decode failure; `:211-225,363-371` leaves a stale `nextRunAt`
after an interrupted `.running`; `:324-329,376-379` clears `runningTaskID` while
the runner is in flight.
**Fix:** quarantine corrupt files, advance interrupted tasks one interval, and
cancel/await a running task before delete.

#### M-H16 — Updater does not verify code signature and targets a fixed bundle path
**Evidence:** `MacOS/app/MelonTools/Core/UpdaterStore.swift:179` checks only the
`/Applications/` prefix; `:236` always swaps `/Applications/Melon Tools.app`;
no Team ID/code-signature verification; terminates 0.6 s after starting the
installer without checking an active scheduler run.
**Fix:** Developer ID + notarization, signature/Team ID verification, derive
destination from `Bundle.main.bundleURL`, block/confirm during scheduler run.

#### M-H17 — Localization has missing keys, cached static strings and destructive language reset
**Evidence:** missing `Images`, `On`, cron field names
(`ModelSourcesView.swift:1033,1046-1047`;
`SchedulerModels.swift:283-291`); `MTSection.groups` static `L(...)`
(`MainView.swift:42-47`); `.id(l10n.code)` recreates `MainView`
(`MelonToolsApp.swift:12-15`) and resets selection/sheets; detached scheduler
window is not localized (`SettingsView.swift:342-360`).
**Fix:** add keys, pluralization, computed group titles, preserve UI state on
language change, update detached windows/CDP script.

#### M-H18 — Dashboard cards are hard-capped and “Run next” is enabled while the gateway is stopped
**Evidence:** `MacOS/app/MelonTools/Views/DashboardView.swift:187-190` uses
`minHeight/maxHeight: 250` without clipping/scroll; gateway error is one line
`:481-486`; Run next `:384-396` does not check `gateway.isRunning`.
**Fix:** use content-aware equal row heights or scrollable bodies; allow 2–3
error lines; disable Run next and show the existing wait text.

### High — Windows

#### W-H1 — Settings, reserves and provider-key saves read fields after re-render
**Evidence:** `Windows/app/ui/app.js:1072-1084` (`run` renders before `fn`);
`:2530-2541` reserves; `:2553-2569` keys; `:2662-2670` Claude key;
`:2754-2770` settings. Re-render restores old state, so language/port/interval,
reserves and keys silently don’t save. Scheduler code reads fields before
`run` (`:3038-3059`), confirming the intended pattern.
**Fix:** capture values before `run` or stop re-rendering in `run`; add DOM tests.

#### W-H2 — Polling re-renders wipe dirty forms and scroll
**Evidence:** `Windows/app/ui/app.js:3512-3535` timers call `render` without
`editsInProgress`; only status uses the guard `:2201-2222`; `:1122` replaces
`main.innerHTML` every 5 s.
**Fix:** respect dirty forms, preserve focus/scroll/state, or update only
status fragments.

#### W-H3 — Providers page can enter an infinite models reload loop
**Evidence:** `Windows/app/ui/app.js:1125` auto-calls `modelsLoad` when empty;
`:2840-2885` does not catch `gateway_models`; `run` finally renders, which calls
it again, producing repeated toasts.
**Fix:** catch the error, store `S.modelsError`, stop auto-retry until Refresh.

#### W-H4 — Composer popover throws `ReferenceError: status is not defined`
**Evidence:** `Windows/app/resources/composer-chips.js:580-581` uses
`status.requests`; no `status` variable; strict mode at `:23`. The same bug is
in `MacOS/app/Resources/composer-chips.js:627-628`.
**Fix:** add `const status = state.status || {};` at the top of `renderPopover`
and add a DOM test.

#### W-H5 — Windows composer contracts are broken
**Evidence:** `Windows/app/src-tauri/src/bridge.rs:407-440` sends ids as
`name`; `composer-chips.js:420-439,947-955` matches catalog display names;
shared-name suffixes make it worse. Refresh calls `__melonSend`
(`composer-chips.js:789-801`) but `bridge.rs:203-245` never registers
`Runtime.addBinding`. Provider keys sent by Rust (`bridge.rs:443-470`) differ
from the popover’s expected keys (`composer-chips.js:607-679`); session
`tokens` is never sent. OpenCode/Claude/Antigravity stats are absent.
**Fix:** send display name + slug, implement the binding or remove refresh,
align payload keys, add a contract test.

#### W-H6 — Recent calls parser uses the wrong log format
**Evidence:** `Windows/app/src-tauri/src/gateway.rs:631-661` requires five
`|` fields and reads status from `parts[1]`; the pinned engine emits four
fields (`MacOS/_sources/CLIProxyAPI/internal/logging/gin_logger.go:92`):
status, latency, IP, method/path. Normal calls are skipped.
**Fix:** parse status `parts[0]`, duration `parts[1]`, IP `parts[2]`,
method/path `parts[3]`; require `>=4`; add a sample-line test and refresh
`S.calls` on status poll.

#### W-H7 — Provider enable toggles are ignored; OpenCode routing is hardcoded
**Evidence:** `Windows/app/src-tauri/src/gateway.rs:162-199` reads keys but not
`opencode_enabled`/`openrouter_enabled`; `settings.rs:17-18`; UI toggles
`app.js:1664-1672,2559-2566`. All OpenCode models use the Go endpoint.
**Fix:** honor the flags; split Go/generic OpenCode models; add config tests.

#### W-H8 — Windows updater has no rollback/launch check and an encoding-unsafe swap
**Evidence:** `Windows/app/src-tauri/src/updater.rs:318-386` writes a `.cmd`
as UTF-8 without BOM (cmd.exe reads OEM code page), uses a fixed temp path
between hash and copy, and has no restore if the new exe fails.
**Fix:** use PowerShell `-EncodedCommand`/UTF-16LE or a Rust helper; unique
restricted temp dir; re-hash before copy; keep old exe and roll back; verify
launch.

#### W-H9 — Quit leaves the engine, chips script and CDP port alive
**Evidence:** `Windows/app/src-tauri/src/main.rs:1173` calls `app.exit(0)`;
`Gateway.child` is a plain `Child` (`gateway.rs:16,392-397`) and is not killed
on exit; no `__melonChipsDispose`; Codex keeps `--remote-debugging-port`.
**Fix:** handle exit, kill the child (or use a job object), dispose chips,
relaunch Codex without debug; add a “stop on quit”/“disable chips” setting.

#### W-H10 — Codex route can point at a missing catalog
**Evidence:** `Windows/app/src-tauri/src/main.rs:150-156,651-659` calls
`codex_route::apply` before `sync_catalog`; `codex_route.rs:195-214` writes
`model_catalog_json` unconditionally. If `/v1/models` fails, Codex can refuse to
start.
**Fix:** generate catalog first; add only if it exists; drop dangling references;
`remove` should restore the backup.

#### W-H12 — Scheduler payload can be ~12.8 MB every 5 seconds
**Evidence:** `Windows/app/src-tauri/src/scheduler.rs:591-598` returns tasks
plus 200 history entries × 64 KiB; `app.js:2205-2211,3508` polls every 5 s.
**Fix:** dashboard summary without history/results; paginate history; fetch
results on demand.

#### W-H13 — Windows catalog entries inherit unsupported capabilities
**Evidence:** `Windows/app/src-tauri/src/codex_route.rs:575-596` clones the
GPT-6.1 Sol template and overrides only slug/display/priority/modalities;
description, 272k/872k context, speed tiers, search and `use_responses_lite`
stay from the template. macOS clears these
(`MacOS/app/MelonTools/Codex/CodexModelCatalog.swift:382-413`).
**Fix:** set real description/context and clear unsupported flags; add catalog
tests.

#### W-H14 — Catalog stays stale after provider login/disconnect
**Evidence:** `Windows/app/ui/app.js:2617-2622,2652-2658,2709-2714,2744-2750`
refreshes `S.models` but never calls `sync_catalog`; only startup/Apply does
(`main.rs:1254-1259,651-659`).
**Fix:** add a `catalog_sync` command and call after auth/key/source changes.

#### W-H15 — Engine cache key is manual and can keep an old engine
**Evidence:** `Windows/app/src-tauri/src/engine.rs:22,83-124`; build script
`Windows/build-windows.sh:63-89` rebuilds/recompresses but does not update
`ENGINE_VERSION`.
**Fix:** derive the cache key from payload SHA-256 at build time or fail the
build on mismatch; use a unique fallback name.

#### W-H16 — Store and gateway lifecycle have no locks
**Evidence:** scheduler `scheduler.rs:712-736,825-836,891-901`; vault
`vault.rs:304-315,403-409`; gateway start/stop
`gateway.rs:353-406`. Concurrent load-modify-save loses edits; two starts can
spawn two engines.
**Fix:** per-store mutexes, serialized gateway lifecycle, concurrency tests.

#### W-H17 — Corrupt JSON is silently replaced with defaults
**Evidence:** `vault.rs:209-216`, `settings.rs:83-110`,
`scheduler.rs:184-213`, `history.rs:68-77`. The next save overwrites the
original; no quarantine. A corrupt top-level array shape is also not validated.
**Fix:** rename to `.corrupt-<timestamp>`, surface an error, do not overwrite
until acknowledged; validate the top-level object shape.

#### W-H20 — CSP/inline handlers weaken the security boundary
**Evidence:** `Windows/app/src-tauri/tauri.conf.json:10,24` enables
`withGlobalTauri` and `script-src 'unsafe-inline'`; UI uses inline `onclick`;
`esc()` does not escape backslashes and HTML entities inside inline JS can
break out (`app.js:343-348,1319,1465`).
**Fix:** delegated handlers/data attributes, nonce/hash CSP,
`withGlobalTauri:false`, minimal typed bridge.

#### W-H21 — Roaming `%APPDATA%` holds the 68 MB engine/logs
**Evidence:** `Windows/app/src-tauri/src/paths.rs:9-20`; `engine.rs:26-32`.
Roaming profiles copy this at login/logout; AppLocker may block execution.
**Fix:** keep vault/settings in roaming, move engine/log/history to
`%LOCALAPPDATA%`; document allowlisting.

#### W-H22 — Vault display-name formatting can panic on short/non-ASCII ids
**Evidence:** `Windows/app/src-tauri/src/vault.rs:88-96` slices `self.id[..8]`
without checking UTF-8 boundaries.
**Fix:** use `chars().take(8).collect()` or `char_indices`; validate shape.

#### W-H23 — `run()` can leave busy state stuck on render failure
**Evidence:** `Windows/app/ui/app.js:1072-1084` calls `render()` outside
`try`; if render throws, `S.busy[action]` remains true and the action is dead.
**Fix:** move render inside try/finally or use a top-level error boundary.

#### W-H25 — Diagnostics performs a paid completion but is labelled read-only
**Evidence:** `Windows/app/ui/app.js:2301-2316`; `gateway.rs:682-734` sends a
real completion; label says read-only.
**Fix:** use `/v1/models` only or label it as a paid probe.

### High — release, CI and docs

#### R-H1 — Windows installer embeds an unsigned executable
**Evidence:** `.github/workflows/release.yml:169-219`: NSIS runs before
Authenticode signing of the portable. The installed `MelonTools.exe` stays
unsigned even if the installer is signed.
**Fix:** sign the portable first, then build the installer, or re-sign the
installed payload; verify all PE signatures.

#### R-H2 — Opaque 22 MB gateway binary is in the trust path
**Evidence:** `Windows/app/src-tauri/src/engine.rs:24` embeds
`cliproxyapi.exe.z`; CI does not rebuild it from the pinned commit; extraction
hash compares against a previous copy, not a published known-good digest.
**Fix:** build the payload in CI from the pinned commit, publish its hash/verify
it, or document it as an unaudited third-party artifact.

#### R-H3 — macOS signing secrets are exposed to build steps and notary password is on argv
**Evidence:** `.github/workflows/release.yml:23` job-level `APPLE_*`;
`packaging/sign-macos.sh:123` passes `--password` on the command line.
**Fix:** scope secrets to signing/notary steps, use `notarytool` keychain
profiles or stdin, set `persist-credentials:false`.

#### R-H4 — CI does not build release artifacts or gate tags
**Evidence:** `.github/workflows/ci.yml:31` Debug unit tests only; Release does
not run tests; v2.0.3 failed in the NSIS step. CI never runs `MacOS/build.sh`,
NSIS, engine embedding or signing.
**Fix:** build real artifacts on main/PR, require CI success on tags, and add an
NSIS installer smoke test.

#### R-H5 — Docs are stale or false
**Evidence:** `MacOS/README.md:4` says Apple Silicon only; `:19` opens
1.4.2; `:387` says Go 1.22 while `go.mod` requires 1.26; its first “What’s new”
section is 1.6.3; Windows README `:111` claims the same composer script (files
differ); `docs/FAQ.md:25,136` tells users to change a port that has no UI.
**Fix:** version/architecture/toolchain truth pass; link docs to code; add a
docs test for URLs and claims.

#### R-H6 — Version/manifest/checksum automation is incomplete
**Evidence:** `.github/workflows/release.yml:108` writes a path-prefixed
`.sha256` (`build/...`), while manual assets use bare filenames; bump list
omits `tauri.conf.json`/`Info.plist`/`Cargo.lock`/README links; `docs_lint.py`
checks format but not live hash equality.
**Fix:** generate flat checksums, derive versions from one source, verify
Cask/winget hashes against artifacts, fail on missing expected assets.

#### R-H7 — Live release body omits the signing warning; tags are unsigned
**Evidence:** GitHub release v2.2.3 body has no unsigned/notarized/SmartScreen
warning; tag is lightweight and the commit is unsigned.
**Fix:** include the warning in the release body; signed annotated tags/tag
protection/environment approval.

#### R-H8 — Security workflow coverage/pinning is inconsistent
**Evidence:** `.github/workflows/security.yml:51,70` uses floating
`codeql-action@v3`/`dependency-review-action@v4` while other actions are
SHA-pinned; CodeQL analyzes only JS; no Go audit/SBOM/`cargo-deny`.
**Fix:** SHA-pin, add `actionlint`/`shellcheck`, scope `security-events: write`,
add Go/Rust dependency and SBOM checks.

### Medium — macOS

- **M-M1 Capability flags:** `SourceModel` has no reasoning/tool flags
  (`ModelSources.swift:35-53`); catalog clones template capabilities
  (`CodexModelCatalog.swift:382-413`). Add provider metadata and tests.
- **M-M2 Priority collision:** `priorityBase + position` with 100-wide bands
  (`CodexModelCatalog.swift:99-100,262-269`); >100 models spill into the next
  provider. Use 10,000-wide bands.
- **M-M3 Language/script stale:** CDP script is registered once; language
  change only re-evaluates the current document
  (`CDPSession.swift:52`; `ComposerBridge.swift:264-268`).
- **M-M4 Composer email contract:** `statusPayload` says no emails
  (`ComposerBridge.swift:522`) but providersPayload sends them `:449-467`.
- **M-M5 Composer provider-spend keys:** session cost uses lowercase provider
  keys, while the catalog writes `Claude`/`Antigravity`; the spend lookup is
  case-mismatched (`ComposerBridge.swift:402`; `CodexModelCatalog.swift:272-279`).
  The separate `status.requests` bug is tracked as W-H4.
- **M-M6 Quota notification repeat/email:** `resetDate` derives from
  `reset_after_seconds` (`CodexService.swift:412-419`), so the dedupe key
  changes every poll (`CodexStore.swift:95-112`); bodies include email
  (`:1008-1011,1048-1051`); records save before authorization.
- **M-M7 Quota history cap:** 288 samples documented as 24 h at 5 min
  (`QuotaHistory.swift:33-35`), but urgent polling is 30 s; deleted accounts
  are not removed (`CodexStore.swift:1070-1075`).
- **M-M8 Scheduler errors:** full HTTP error bodies persisted
  (`SchedulerRunner.swift:89-97`; `SchedulerStore.swift:382-405`); template edit
  discards prompt edits (`SchedulerView.swift:596-604`); selected error falls
  back to latest (`:728-730`).
- **M-M11 Port docs/implementation:** no port field in UI, but
  `docs/FAQ.md:25,136` and `CodexGatewayService.swift:311` tell users to change
  it; `MacOS/README.md:238` says it was removed.
- **M-M12 Instance auth atomicity:** `.write(.atomic)` then chmod 0600
  (`CodexInstancesView.swift:260-262`); launch error overwritten `:266-278`;
  missing bound account silently writes no auth `:251-256`.
- **M-M13 Provider keys not persisted on edit:** `ModelSources.swift:95-98` and
  save only on model/apply (`:152-180`); empty model lists replace selections
  (`:453-534`); Apply enabled while busy (`ModelSourcesView.swift:1104-1113`).
- **M-M14 Launch-at-login:** `SMAppService.register()` without checking
  `.requiresApproval` or `/Applications` (`SettingsView.swift:134-137,170-182`).
- **M-M16 Test coverage:** no tests for config route, gateway lifecycle,
  quota parsing, session JSONL, loopback, instance store, refresh races, CDP,
  JS contract, localization, UI accessibility (`CodexModelCatalogTests` etc.
  cover catalog/pure code only).
- **M-M17 Build settings:** no signing/hardened runtime; minimal strict
  concurrency (`project.yml:13-19`); `--deep` ad-hoc sign (`build.sh:51-54`);
  no single-instance/localizations keys; version duplicated.
- **M-M18 Tests isolate bodies but not host:** see C2; add ephemeral support
  directories and launch guards.

### Medium — Windows

- **W-M1 Dashboard parity:** errors exclusive of paused, no Total, averages
  computed differently, no Codex pool card, variable tile heights
  (`app.js:674-702,884-896,1181-1189`; `mt.css:472-477`).
- **W-M2 Account list stale:** `accountsPage` iterates `routing.orderedIds`
  only (`app.js:1363-1374`); new accounts may disappear until routing reload.
- **W-M3 Device login:** no timeout/cancel/backoff (`app.js:2806-2831`;
  `device_login.rs:55-88`).
- **W-M4 Claude/Antigravity credentials:** `claude_credentials` returns all
  engine credentials, disconnect removes all Claude files, newest-file
  heuristic can switch accounts, usage errors hidden
  (`claude.rs:78-123,234-242`; `providers.rs:83-108`).
- **W-M5 Quota parity:** no `reset_after_seconds`; numeric expiry ignored;
  seconds/millis mismatch; unvalidated account id; no 401 refresh
  (`quota.rs:96-99,278-291,340-364`).
- **W-M6 CSP/escaping:** see W-H20; includes `connect-src 127.0.0.1:*`.
- **W-M7 Accessibility:** `--text3` 2.99:1 at 9–11 px; no live regions/dialog
  focus trap; `<html lang>` stays `ru`; `user-select:none` on diagnostics
  (`mt.css:13,40,157,210-216,324`; `index.html:2`; `app.js:1064-1070`).
- **W-M8 RU/EN:** backend errors Russian-only, tray labels Russian-only,
  composer EN label keys incomplete, mixed date formats
  (`main.rs:450,465,565,1194-1223`; `bridge.rs:250-295`; `app.js:982-992,2086`).
- **W-M9 Updater UX:** checks only at boot; no cancel/progress; digest can be
  invalid; stale cache not re-checked (`app.js:3199-3269,3498-3507`).
- **W-M10 Gateway health:** cannot distinguish down vs wrong key; busy port
  generic timeout; start kills child before resolving binary; stop doesn’t wait
  (`gateway.rs:334-437`).
- **W-M11 Windows rename:** tmp+rename can fail on open destination; sync deletes
  all auth first (`gateway.rs:261-330`; `vault.rs:483-513`).
- **W-M12 Models page:** ids only, silent 400-row truncation, loading until
  Refresh, no per-model controls/context/vision (`app.js:1684,1710-1727`).
- **W-M13 Diagnostics:** see W-H25.
- **W-M14 Build/release:** no `--locked`, no pinned commit check, no tests,
  no `.sha256`; Go not in prerequisites (`build-windows.sh:1-16,63-99`).
- **W-M15 Notifications:** no permission request/AUMID; portable toast may not
  appear; failures ignored (`main.rs:358-367,422-431`).
- **W-M16 Lifecycle:** second launch exits silently; tray show doesn’t
  unminimize; labels Russian-only (`main.rs:1084-1110,1194-1223`).
- **W-M18 Dead IPC:** `claude_refresh`/`antigravity_refresh` registered but
  never invoked (`main.rs:1355-1371`).
- **W-M19 Docs:** false claims about restart, port, checksum fallback, composer
  parity, config parity, bridge disable (`Windows/README.md:19,30,41,99,104-111`;
  `docs/FAQ.md:69-71,135,150-153`).
- **W-M22 Data conversion:** `historySamples` converts null to 0
  (`app.js:610-615`); partial reserve saves no rollback (`:2506-2528`).
- **W-M23 Scheduler UI:** raw ids; all Antigravity models grouped as “Gateway”;
  cached list; unknown timezone fallback (`app.js:2096-2136,2951-2960`).
- **W-M24 Catalog atomicity:** non-atomic write can expose a partial catalog
  (`codex_route.rs:741-748`).
- **W-M25 Backups:** plaintext `auth.json.melon-backup` and
  `config.toml.melon-backup` retained indefinitely (`vault.rs:500-513`;
  `codex_route.rs:198-203`).
- **W-M26 Quota timers (verify on Windows):** quota refresh and notifications
  depend on WebView `setInterval` (`app.js:3508-3536,2463-2481`;
  `main.rs:287-370`); WebView2 may throttle when hidden to tray. Move to Rust.
- **W-M27 Installer/uninstaller (verify on Windows):**
  `Windows/installer/MelonTools.nsi:54-67` lacks uninstall pages; `:137-155`
  does not close the app, remove the Run key, or restore the Codex route.
- **W-M28 Settings validation/watchdog:**
  `Windows/app/src-tauri/src/main.rs:102-127` accepts raw port/interval/
  reserves; `:1040-1078` watchdog uses `gateway::start`, not `start_gateway`.

### Medium — release/docs

- **R-M4 latest links:** README/Windows README/release notes use
  `/releases/latest/download/MelonTools-2.2.3.*`; these 404 after the next
  release.
- **R-M6 Signing guard:** release workflow tests `WINDOWS_CERT_PFX` path
  instead of `WINDOWS_CERT_PFX_BASE64`; password-only runs fail, cert-only
  skips.
- **R-M9 Repo hygiene:** 63/142 tracked files mode 100755, tracked generated
  project/Info.plist, 1,347 AppleDouble `._*`, no `.gitattributes`, no
  `*.p12`/`*.pfx`/`.env` ignore.
- **R-M11 Data docs:** security model/FAQ omit `gateway.log`, gateway auth
  logs, `model-sources.json`, backup files, preferences.
- **R-M12 CSP docs:** MacOS README calls Windows CSP restrictive although
  inline scripts are allowed.

### Low / polish

- Double escaping in `subscriptionText` (`app.js:1287-1294,1330`).
- Date formats mix `DD.MM`, OS locale, and language (`app.js:982-992,2086`).
- Dead `S.schedulerAt` (`app.js:320,2208,2259,3128,3140`).
- Ghost disabled buttons have no visual style (`mt.css:181-183`).
- Icon-only buttons often lack `aria-label` (`app.js:1319-1320`;
  composer `:687-695`).
- `schedulerSystemZone` hardcodes “System” (`app.js:1983-1988`).
- `gateway_start` toast says “adopted” (`app.js:2272`).
- Autostart check only verifies the value exists, not the current exe
  (`main.rs:751-766`).
- `gateway::health` builds a new reqwest client per poll (`gateway.rs:334-341`).
- `rust-version = 1.77` is untested; CI uses a newer toolchain.
- No SBOM/license notice for CLIProxyAPI.
- QR canvas has no accessible alternative (`app.js:1739-1747`).
- Bug template still says 1.4.6; SECURITY.md lacks supported-version/SLA.
- Node 20 is EOL; XcodeGen/PyYAML/NSIS unpinned; NSIS English-only while
  tauri.conf declares RU/EN; signing timestamp URL is HTTP.

## WHAT IS SOLID

- DPAPI v2 vault, v1 migration, entropy, reserved-prefix escaping and
  zeroization are well designed (`Windows/app/src-tauri/src/dpapi.rs`).
- Updater **selection** is careful: portable before legacy, setup never,
  HTTPS host allowlist, redirect checks, mandatory SHA-256
  (`Windows/app/src-tauri/src/updater.rs`).
- Cron parser/policy covers ranges, lists, steps, names, Vixie day OR and DST
  gaps; 137 Rust tests and 149 macOS tests pass.
- Atomic writes, YAML escaping, bounded log tails and unique temp paths are
  generally good on POSIX.
- Process launches avoid shells; `open_url` restricts schemes; no obvious
  command/SQL injection in the Rust command layer.
- The gateway is loopback-only (`host: 127.0.0.1`, `allow-remote: false`), auth
  files/config are 0600, and no telemetry endpoints exist.
- CI/Security pass; docs_lint, node syntax checks and bash syntax checks pass.

## PRIORITIZED ROADMAP

### P0 — before the next release

1. Fix Windows `instance_delete` traversal and add tests.
2. Isolate macOS tests from production; remove real-token `/tmp` scripts.
3. Repair the Windows form-save architecture (`run` re-render) and dirty-form
   polling; this currently breaks settings, reserves and provider keys.
4. Fix Windows composer `status` ReferenceError and align name/payload/binding
   contracts.
5. Repair and gate the Release workflow: tag ref, CI gate, all assets/checksums,
   signing order, no manual publish.

### P1 — next patch

6. Add store/gateway locks; stop engine/chips/debug port on Windows quit.
7. Harden filesystem/security: instance names, CDP host/port, loopback
   SIGPIPE, log 0600/rotation, single-instance, secret scoping.
8. Fix catalog ownership/schema/staleness on both platforms.
9. Add Windows updater rollback/encoding-safe swap; macOS signature/path checks.
10. Fix scheduler corruption/replay/payload and quota background timers.

### P2 — quality

11. Accessibility/contrast/fonts/labels/keyboard.
12. Localization/pluralization, docs truth pass, ARIA/live regions.
13. Performance: incremental session reader, dashboard summary, history
    pagination, fewer full renders.
14. Test expansion: JS DOM, config route, gateway lifecycle, quota parsing,
    CDP, updater, localization.
15. Release supply chain: SBOM, CodeQL Swift/Rust/Go, signed tags, notarization.

## REVIEW

Independent reviewer (fresh read-only session, no edits) verified the ten
highest-risk findings against source. All were accurate (TEST_HOST side effects,
Windows instance deletion, Windows form saves, composer ReferenceError,
release dispatch/ref, recent-calls parser, macOS instance traversal, log
permissions, CDP trust, updater path). It returned **REPAIR NEEDED** for
report-level issues, not technical false positives:

- seven duplicate finding pairs (merged);
- unmapped `/tmp` token claim included `test-quota.py` (restricted to
  `test-gateway-e2e.py`);
- run-history/git claims lacked a recorded command (added);
- four Windows items were over-severe (moved to Medium);
- `fail_on_unmatched_files` nuance missing (added).

Repairs applied to this report only. A second independent read-only review
confirmed C3/C4 evidence, AC1–AC6, and all Critical/High claims; it found only
remaining duplicate Medium entries (W-M20, W-M29, R-M2/R-M3/R-M5/R-M7/R-M8/
R-M10) and one duplicated scheduler-window phrase. Those were removed/merged.
No technical false positives were found. Final self-check: no duplicate finding
labels remain; C3 is scoped to `test-gateway-e2e.py`; C4 includes the
wildcard-only asset nuance; run-history/git commands are recorded.

## LOOP

- phase: REVIEW → PASS (audit deliverable)
- baseline: worktree 2.2.3; HEAD `1cf6a8e`; origin/main `e803618`
- repair_count: 2
- reviewer_isolation: two independent read-only reviewer sessions; no source
  edits, no builds, no user-data changes
- gate: AC1–AC6 satisfied for the audit deliverable; production findings remain
  open by design (this task is an audit, not a fix release)

