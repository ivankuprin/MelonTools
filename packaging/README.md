# Packaging, signing, and distribution

This directory holds the release-signing scaffolding and the distribution
manifests for Melon Tools. The application source and version files are not
touched by the packaging scripts.

## Current status

**Signing and notarization are BLOCKED until real certificates are provided.**

| Platform | State | Consequence |
|----------|-------|-------------|
| macOS | Ad-hoc signed, not notarized | Gatekeeper may require right-click → Open on first launch. |
| Windows | Not Authenticode-signed | SmartScreen may warn on first launch. |

The CI release workflow builds and publishes unsigned artifacts when the
secrets below are absent. It never fails because a signing secret is missing.
When the secrets exist, the signing steps run and a genuine signing failure
does fail the release.

## Release artifacts for 1.7.1

| Artifact | File name | SHA-256 |
|----------|-----------|---------|
| macOS DMG | `MelonTools-1.7.1.dmg` | `cd34bd4dd6e45c3d6458fd19e12858ccdcada72bb8db487fdcc2ecfe6618fc99` |
| Windows x64 | `MelonTools-1.7.1-win-x64.exe` | `4cdcf9ad431bbe39445c5eef0d67df1f4b363e8d781432878dfa00ae69e99884` |

Both files and their `.sha256` siblings are attached to the GitHub release for
tag `v1.7.1`. The in-app updater accepts only HTTPS GitHub hosts and verifies
the downloaded file against the release digest or the `.sha256` sibling.

## Required secrets

Configure these in **Settings → Secrets and variables → Actions**.

### macOS

| Secret | Required | Purpose |
|--------|----------|---------|
| `APPLE_CERT_P12` | yes | Base64 of a `.p12` containing a **Developer ID Application** certificate and its private key. |
| `APPLE_CERT_PASSWORD` | yes | Password that protects the `.p12`. |
| `APPLE_ID` | yes | Apple developer account email used by `notarytool`. |
| `APPLE_TEAM_ID` | yes | Apple Developer team identifier. |
| `APPLE_APP_PASSWORD` | yes | App-specific password for `notarytool`. |
| `APPLE_SIGN_IDENTITY` | no | Exact codesign identity. Defaults to the first `Developer ID Application` identity in the keychain. |

### Windows

| Secret | Required | Purpose |
|--------|----------|---------|
| `WINDOWS_CERT_PFX` | yes | Base64 of an Authenticode `.pfx` (OV or EV code-signing certificate). |
| `WINDOWS_CERT_PASSWORD` | yes | Password that protects the `.pfx`. |

Create the base64 values locally:

```bash
# macOS / Linux
base64 -i certificate.p12 | pbcopy          # macOS
base64 -w 0 certificate.p12 > certificate.b64   # Linux
```

```powershell
# Windows PowerShell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("certificate.pfx")) |
  Set-Clipboard
```

Never commit a certificate, password, or `.p12`/`.pfx` file. The repository
ignores build outputs, but it cannot protect a secret that was committed once.

## macOS signing and notarization

`.github/workflows/release.yml` imports `APPLE_CERT_P12` into a temporary
keychain, then calls:

```bash
./packaging/sign-macos.sh \
  "$HOME/Library/Developer/MelonTools/Build/Products/Release/Melon Tools.app" \
  "MacOS/build/MelonTools-1.7.1.dmg"
```

The script:

1. Requires `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_PASSWORD`; otherwise it
   prints a `SIGNING SKIPPED — macOS` block and exits 0.
2. Finds the `Developer ID Application` identity in the keychain.
3. Signs the gateway sidecar and the app with hardened runtime and a trusted
   timestamp.
4. Re-creates the DMG from the signed app.
5. Submits the DMG with `notarytool --wait` and staples the ticket.

Set `REQUIRE_SIGNING=1` to turn a missing-secret skip into an error (useful in
a strict local release script). The workflow itself uses the secret condition
on the step, so a missing secret simply skips the step.

## Windows signing

`.github/workflows/release.yml` decodes `WINDOWS_CERT_PFX` to a temporary file
and calls:

```powershell
./packaging/sign-windows.ps1 `
  -File Windows/dist/MelonTools-1.7.1-win-x64.exe -Require
```

The script locates `signtool.exe` from the Windows SDK, signs with SHA-256 and
an RFC 3161 timestamp, and verifies the result. Without the two certificate
variables it prints `SIGNING SKIPPED - Windows` and exits 0; `-Require` turns
that skip into an error.

## Homebrew Cask

The manifest lives at
[`homebrew/Casks/melon-tools.rb`](homebrew/Casks/melon-tools.rb). It points at
the DMG for the matching GitHub release and carries the 1.7.1 SHA-256.

Local validation and installation:

```bash
ruby -c packaging/homebrew/Casks/melon-tools.rb
brew audit --cask --strict packaging/homebrew/Casks/melon-tools.rb
brew install --cask packaging/homebrew/Casks/melon-tools.rb
```

The cask is not yet submitted to the upstream `homebrew-cask` repository. A
future submission requires a notarized DMG; the Cask cannot pass upstream audit
while the build is ad-hoc signed. This is part of the signing blocker.

## winget manifests

The three manifests live in [`winget/`](winget/):

- `ivankuprin.MelonTools.yaml` — version manifest
- `ivankuprin.MelonTools.installer.yaml` — portable x64 exe, URL, SHA-256
- `ivankuprin.MelonTools.locale.en-US.yaml` — display metadata

Local validation on Windows:

```powershell
winget validate packaging/winget
```

The manifests target a future `winget-pkgs` submission but are not submitted
yet. Upstream validation expects a stable, signed release; the unsigned exe can
still be installed manually from the GitHub release.

## Version bumps

When a new release is prepared, update all of these together:

1. `MacOS/app/project.yml` (macOS version — only the release owner changes it).
2. `Windows/app/src-tauri/Cargo.toml` (Windows version).
3. The Cask `version`, `url`, and `sha256`.
4. `PackageVersion` in all three winget manifests, plus `InstallerUrl` and
   `InstallerSha256` in the installer manifest.

`python3 .github/scripts/docs_lint.py` fails when these versions disagree or a
manifest loses its 64-character SHA-256.

## Checksums

```bash
shasum -a 256 MacOS/build/MelonTools-1.7.1.dmg
```

```powershell
Get-FileHash .\MelonTools-1.7.1-win-x64.exe -Algorithm SHA256
```

The `.sha256` files published next to each artifact use the standard
`<hex>  <file name>` format. The in-app updater reads the first 64-character
hex token, so both formats are accepted.
