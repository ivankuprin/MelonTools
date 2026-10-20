# Frequently asked questions

Melon Tools is a desktop companion for Codex accounts, model providers, and
Fleet workflows on macOS and Windows. This page answers the common questions
about providers, quota, updates, account risk, and troubleshooting.

For data locations and the trust model, see
[SECURITY-MODEL.md](SECURITY-MODEL.md). For signing and distribution details,
see [packaging/README.md](../packaging/README.md).

## Providers

### Which providers can I connect?

| Provider | Connection | Notes |
|----------|------------|-------|
| Codex / ChatGPT | Account login or imported auth file | Account pool, quota, and local gateway. |
| Claude | Claude Pro/Max OAuth, or an Anthropic API key | OAuth uses the Claude Code client flow. |
| Google Antigravity | Google OAuth | Account email and project id appear on the card. |
| OpenRouter | API key | Key metrics and `openrouter/*` models. |
| OpenCode | API key | `opencode/*` models after a gateway restart. |

Selected models from every provider appear in the Codex model picker. The local
gateway exposes an OpenAI-compatible API on `127.0.0.1:18317` by default; the
port is configurable in Settings.

### Do I need an API key for Claude or Antigravity?

No. Claude Pro/Max and Google Antigravity use OAuth in a browser. An Anthropic
console API key is optional for Claude. OpenRouter and OpenCode always use an
API key.

### Where do provider keys go?

They are written to the local gateway configuration and the app's local store.
They are not sent to a Melon Tools server. See
[SECURITY-MODEL.md](SECURITY-MODEL.md).

## Quota

### Where do the quota numbers come from?

From the provider's own account or usage endpoint. Codex accounts show the
5-hour and weekly windows with reset times. Claude shows the same windows when
the usage endpoint returns them. OpenRouter shows key spend and limits.
Antigravity does not expose a quota API, so the card shows connection state,
account, project, and model count only.

### Why is a quota value blank or stale?

The provider may not return that window, the token may have expired, or the
refresh may be throttled. Use the refresh control on the page and check the
gateway log. Melon Tools does not invent numbers for missing windows; a dash
means "not reported".

### What is the quota reserve?

You can pause an account when its remaining quota drops below a threshold (for
example 5% or 10%). The pool then routes to another account. The pause state is
synced to the gateway auth files, so requests stop using that account on the
next refresh.

## Updates

### How does Melon Tools update itself?

The sidebar has a check/update control. Automatic checks run at most once a
day. When a newer GitHub release exists, the app downloads the matching asset,
verifies its SHA-256 against the release digest or the `.sha256` sibling, and
only then installs it.

On macOS the app must run from `/Applications` to self-update. It quits, swaps
the bundle from the DMG, and relaunches. On Windows the single executable is
replaced after the app exits.

### The download failed the checksum. What now?

Do not run the file. Delete it and retry from the release page. If the failure
repeats, the release asset or the network path is suspect; report it with the
release tag and the checksum you saw.

### Why does macOS or Windows warn about the app?

The 1.6.4 builds are ad-hoc signed (macOS) and not Authenticode-signed
(Windows). Signing is **BLOCKED until certificates are provided**; see
[packaging/README.md](../packaging/README.md). On macOS use right-click → Open
for the first launch, or clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine "/Applications/Melon Tools.app"
```

On Windows, SmartScreen may show "More info → Run anyway". Verify the SHA-256
before bypassing a warning.

## Terms of service and account risk

Melon Tools is an independent project and is not affiliated with or endorsed by
OpenAI, Anthropic, Google, OpenRouter, or OpenCode.

**Using a desktop automation or account-routing tool may violate a provider's
terms of service.** In particular, automating a consumer account, sharing one
subscription across users, reselling access, or routing traffic through an
account pool can lead to rate limits, suspension, or a permanent ban. This risk
is yours: review the current terms of each provider before connecting an
account, and do not use Melon Tools to provide access to other people.

The app stores credentials locally and calls provider APIs directly, but that
does not make the use permitted by the provider. Use a dedicated account when
you are unsure.

## Troubleshooting

### The gateway will not start

- Check whether another process uses the configured port:
  `lsof -nP -iTCP:18317 -sTCP:LISTEN` on macOS, or
  `Get-NetTCPConnection -LocalPort 18317` on Windows.
- Change the port in Settings and start the gateway again.
- Read the gateway log:
  `~/Library/Application Support/MelonTools/gateway/gateway.log` on macOS,
  `%APPDATA%\MelonTools\gateway\gateway.log` on Windows.

### Codex does not use the local gateway

The gateway writes `~/.codex/config.toml` (macOS) or
`%USERPROFILE%\.codex\config.toml` (Windows) with the `melon_local_access`
provider. Re-apply the route from the API page, then restart Codex. The original
file is backed up as `config.toml.melon-backup`.

### Composer chips do not appear

The chips bridge connects to the Codex desktop app through the DevTools
protocol on loopback. Restart Codex with the debug port using the
**Restart Codex with chips** button on the API page. If another Codex instance
is already running without the flag, quit it first.

### Login does not complete

The OAuth loopback server uses local ports 1455 and 1457. If both are busy,
close the other login attempt or the process holding the port and retry.

### The app will not open after an update

Reinstall from the release DMG or `.exe`. Your data stays under
`~/Library/Application Support/MelonTools` or `%APPDATA%\MelonTools`; the
installer does not delete it. If macOS reports a damaged app, remove the
quarantine flag as shown above and launch again.

### How do I remove all local data?

Quit the app, then delete the app and the data directory listed in
[SECURITY-MODEL.md](SECURITY-MODEL.md#data-at-rest). Removing
`~/.codex/auth.json` or `%USERPROFILE%\.codex\auth.json` also disconnects the
account from Codex itself; keep a backup first if you need it.
