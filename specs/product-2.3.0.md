# Spec: Melon Tools 2.3.0 — Reliable automation

Status: **IN_PROGRESS**
Baseline: `e1cc5d6` (2.2.4 release) + local 2.3.0 scheduler core.
Target: macOS and Windows **2.3.0**, unsigned.

## Objective

Finish the 2.3.0 reliability package from the product audit:

1. Workspace-aware scheduled tasks and guardrails.
2. Queue, cancellation and bounded retries.
3. Encrypted backup / export / import.
4. Onboarding health check with actionable repair links.
5. Release 2.3.0 on GitHub and install it on the Mac.

## Already implemented in the local worktree

- **S1** `workingDirectory`, `includeGitContext`, bounded `git status` / `log`
  / `diff --stat`, optional `max_tokens`.
- **S1** pool availability guard for Codex-pool models.
- **S1** `retryLimit` / `retryDelayMinutes` / `retryAttempt` with backoff and
  reset on success.
- **S1** editor fields and validation on macOS and Windows.
- Tests: macOS 156/156, Windows 140/140; both builds pass.

## Remaining scope

### S2 — queue and cancellation

- A manual `Run now` while another task is running must enter a visible queue
  instead of being silently ignored or blocking the UI.
- Queue is in memory only and must not survive app restart.
- `Cancel current` aborts the in-flight HTTP request and clears the queue.
- A cancelled task is recorded as `cancelled`, never retried, and keeps its
  normal schedule.
- A scheduled tick must not start while the queue is non-empty.
- Windows must expose the same behaviour through Tauri commands and UI.

### S3 — daily token guard

- Optional per-task `dailyTokenLimit`.
- Before a scheduled or manual run, sum today's history tokens for that task.
- If the limit is reached, do not send a request; record a clear skipped/error
  reason and keep the schedule.
- Editor field and validation on both platforms.
- `max_tokens` remains the per-request cap.

### B1 — encrypted backup / export / import

- One portable backup file with:
  - app version and format version;
  - scheduler tasks and history;
  - user settings needed by gateway, models and scheduler;
  - auth/vault entries.
- Exclude logs, caches, build artifacts and transient lock files.
- Encryption: AES-256-GCM with PBKDF2-HMAC-SHA256, random 16-byte salt,
  12-byte nonce, at least 210,000 iterations.
- Envelope is JSON and identical on macOS and Windows.
- Password is never persisted.
- Export uses mode `0600` where the OS supports it.
- Import validates format/version and decrypts before touching live files.
- Import writes account/settings/scheduler files atomically and restarts the
  gateway; a malformed backup must leave live data unchanged.
- UI on both platforms: password prompt, export path, import file, success and
  error messages. No plaintext secret preview.
- Round-trip tests on both platforms.

### O1 — onboarding 2.0 health check

- One check surface with PASS / WARN / FAIL rows:
  - gateway running and reachable;
  - at least one auth/vault entry;
  - model catalog reachable and a model selected;
  - scheduler state and next run;
  - backup recommendation (no backup yet / recent backup).
- Each failed row has a repair action or a deep link to the relevant screen.
- A demo task can be created from onboarding without sending a request.
- macOS and Windows parity.

### R1 — 2.3.0 release

- Version **2.3.0** in macOS and Windows metadata/build scripts.
- Release notes describe the 2.3.0 features and unsigned status.
- macOS DMG, Windows portable and NSIS installer.
- GitHub release `v2.3.0` with assets.
- Homebrew Cask and winget manifests updated to 2.3.0.
- CI and Security workflows green.
- Mac installed app updated and launched.

## Out of scope for 2.3.0

- Search/favorites/recents, command palette, analytics, webhook/Telegram,
  prompt library, update channels, Windows provider-aware composer parity.
- Plugin/CLI API, sync, team workspace, mobile companion, marketplace.
- Code signing, notarization and Authenticode.

## Acceptance criteria

- **AC-S1** Existing 2.3.0 core tests still pass.
- **AC-S2.1** A second manual run while busy is reported as queued.
- **AC-S2.2** Cancel aborts the request, marks `cancelled`, clears the queue,
  and does not schedule a retry.
- **AC-S3.1** A task at its daily token limit sends no request and records why.
- **AC-S3.2** Old scheduler files decode with `dailyTokenLimit = nil`.
- **AC-B1.1** Export/import round-trips scheduler, settings and auths.
- **AC-B1.2** Wrong password and malformed envelope fail without modifying live
  data.
- **AC-B1.3** Backup file contains no plaintext access/refresh tokens.
- **AC-O1.1** Health check reports gateway/auth/model/scheduler/backup state and
  offers repair actions.
- **AC-O1.2** Demo task creation works without a model request.
- **AC-R1.1** macOS and Windows tests and builds pass.
- **AC-R1.2** GitHub release, Cask, winget and local Mac install are verified.

## Check plan

Required:

- macOS `xcodebuild test` (all tests).
- Windows `cargo test`.
- `node --check Windows/app/ui/app.js`.
- macOS `build.sh`.
- Windows `build-windows.sh`.
- Version markers consistent at 2.3.0.
- Independent reviewer PASS on the complete diff.
- Release asset checks and installed-app version check.

Optional:

- Manual smoke test of backup/import with a disposable profile.
- Manual scheduler queue/cancel smoke test.

## Evidence

- S1 core: macOS 156/156, Windows 140/140, JS OK, both builds OK.
- S2/S3/B1/O1: pending.
- R1: pending.

## Review

Pending independent review after implementation.

## Loop

- phase: SPEC
- repair_count: 0
- next action: architect discovery, then implement S2/S3/B1/O1 on both platforms.
