# Spec: Full audit remediation — 2026-10-21

## SPEC

### Objective

Fix the code-controlled findings from
`specs/full-audit-2026-10-21.md`, starting with all Critical issues and then
the High/Medium items that can be changed and verified locally. Do not weaken
tests or acceptance criteria. Do not commit, push or publish without explicit
authorization.

### Safety and scope

- Authorized mutations: production source, tests, resources, workflows,
  packaging and docs under `/Volumes/Z Slim/MelonTools`; this spec and the audit
  report.
- No signing certificates, GitHub Environment approval, release publishing,
  commits or pushes were available/authorized.
- Windows-only runtime behavior is implemented and unit-tested on macOS, but
  is marked “verify on Windows”.

### Work items

P0: Windows instance delete traversal; macOS test isolation and token script;
Windows form saves; Windows composer; release workflow; macOS instance names.

P1: loopback SIGPIPE; CDP trust/email; quota single-flight/merge/delete; catalog
ownership/schema/order; log permissions/rotation; gateway lifecycle; automatic
Codex restart; API-key rotation; single instance; scheduler corruption/replay/
delete; updater path/encoding/rollback; release signing order/checksums;
Windows quit cleanup, engine key, updater encoding, toggles, recent-calls,
validation, installer uninstall, vault panic.

P2/P3: accessibility, full localization, incremental session parsing, Windows
background quota/CSP/locks/corrupt-store quarantine, provider-aware Windows
composer, full release supply chain, docs truth pass.

### Acceptance criteria

- **AC1** All Critical findings fixed with regression tests where directly
  testable.
- **AC2** Every claimed High fix has a test or observable verification;
  unverified/external items are labelled.
- **AC3** macOS and Windows test suites pass; JS/static checks pass.
- **AC4** No production behavior is weakened to obtain PASS.
- **AC5** No secrets, tokens or real user data are written by tests/scripts.
- **AC6** Independent review of the diff and evidence before final PASS; any
  unresolved item is `BLOCKED` with the exact external dependency.

## EVIDENCE

### Checks

| Check | Result |
|---|---|
| `xcodebuild ... test` | **153 passed, 0 failed** |
| `cargo test` | **139 passed, 0 failed** |
| `node --check` (app.js + both composer scripts) | OK |
| `docs_lint.py` | OK |
| `yaml.safe_load` on release workflow | OK |
| macOS `build.sh` | signature ok; DMG produced |
| Windows `build-windows.sh` | portable + setup produced (unsigned) |
| `git diff --check` | clean |
| `cargo clippy` | unavailable in this toolchain |

### Fixed

- **C1** Windows `instances.rs`: `safe_home` validates id and parent; delete and
  launch use it; traversal regression tests.
- **C2** macOS `AppRuntime.isTesting` guards AppDelegate and update check; test
  host no longer writes real catalog/config, starts gateway or scheduler.
- **C3** `test-gateway-e2e.py`: private temp dir, 0700 dirs, 0600 token/config,
  umask and atexit cleanup; no `/tmp` credential residue.
- **C4** release workflow: checkout `RELEASE_TAG` ref, concurrency, macOS/Windows
  tests in the release job, all eight assets checked, flat macOS checksum,
  signing order (portable → installer → setup), correct signing-secret guard.
- **macOS:** instance-name validation and containment; loopback `SO_NOSIGPIPE`
  and deinit; CDP loopback/port validation; masked emails; quota refresh
  single-flight and field merge; account-remove cleanup; catalog config
  ownership and fresh-route reference; log 0600/rotation and engine-log
  hardening; API-key rotation rewrites route; single-instance Info.plist;
  scheduler corrupt-file quarantine, interrupted-run advance, delete-while-
  running guard, error truncation; composer tick reentrancy guard; auto-Codex-
  relaunch opt-in (default off); updater destination from bundle path; Run-next
  gating; theme contrast; missing L10n keys; selection persists across language
  switch.
- **Windows:** form values read before `run`; render skips dirty forms; providers
  retry loop stopped; composer `status` ReferenceError fixed, refresh button
  hidden without binding, display names/providers sent; recent-calls parser
  matches engine log; engine cache key derives from payload; catalog schema and
  atomic write; catalog sync before route write and no dangling reference;
  provider toggles honored; quit stops engine; settings validation + port
  restart; vault panic fixed; updater PowerShell UTF-8/rollback/unique temp;
  NSIS uninstall pages, running-app kill, Run-key removal; device-login timeout;
  dashboard total/partition parity; diagnostics labelled paid; Windows README
  corrected; background quota refresh/notifications moved to Rust; corrupt
  settings/vault/scheduler/history files quarantined.
- **macOS:** model rows expose accessibility label/value/button trait and
  keyboard Space activation; theme tertiary contrast raised; exact-thread
  session read capped at 32 MB; automatic Codex relaunch is opt-in; debug-port
  relaunch on chip disable removed; selection survives language recreation.

### Remaining / BLOCKED

- **External:** Apple Developer ID/notarization and Authenticode certificate are
  not available. Code signing, notarization and signed tags cannot be completed
  locally.
- **Windows runtime-only:** tray/WebView2 timer throttling, toast AUMID,
  installer/uninstaller UI, and updater launch behavior need a Windows VM.
- **Still open (P1/P2):** full Windows CSP/inline-handler removal; full Windows
  Claude/Antigravity composer payload and `__melonSend` binding; cross-process
  store/gateway locks; scheduler summary/pagination; full engine trust path
  built from the pinned source; Windows installer route restoration; macOS
  full accessibility/Dynamic Type pass and truly incremental session reader;
  macOS updater signature/Team-ID verification; release CI artifact build,
  SBOM/action pinning and docs truth pass.
- No commit, push or release was made.

## REVIEW

Independent reviewer session was started but exhausted its step budget after
verifying the Windows instance fix and the form-save wrapper; it could not issue
a complete verdict. A later self-review confirmed every form handler captures
values before `run`, the composer typo is absent in both scripts, and macOS /
Windows tests plus builds pass. **AC6 is still not fully satisfied** because no
complete independent review exists for the full diff; no PASS is claimed.

## LOOP

- phase: BLOCKED
- baseline: worktree 2.2.3; HEAD `1cf6a8e`; origin/main `e803618`
- repair_count: 4
- reviewer_isolation: independent read-only session, partial; self-review
  completed; no source edits by reviewers
- required checks: macOS 153/153, Windows 139/139, JS/YAML/docs checks OK,
  macOS DMG and Windows portable/NSIS built
- next action: provide signing certificates and authorize the remaining P1/P2
  refactors; then complete an independent review and release.
