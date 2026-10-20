#!/bin/bash
# Sign and notarize a Melon Tools macOS build.
#
# Usage:
#   packaging/sign-macos.sh <path/to/Melon Tools.app> [output.dmg]
#
# With an output DMG path the script re-creates the disk image from the signed
# app, submits it to Apple's notary service, and staples the ticket. Without a
# DMG path it signs the app and notarizes it through a temporary zip.
#
# Required environment for notarization:
#   APPLE_ID            Apple developer account email
#   APPLE_TEAM_ID       Apple Developer team id
#   APPLE_APP_PASSWORD  App-specific password for notarytool
#
# Optional:
#   APPLE_SIGN_IDENTITY "Developer ID Application: ..." identity. When unset,
#                       the first Developer ID Application identity in the
#                       keychain is used.
#   REQUIRE_SIGNING     1 = fail when the notarization secrets are absent.
#
# The signing certificate itself (APPLE_CERT_P12 + APPLE_CERT_PASSWORD in CI)
# must already be imported into the keychain; .github/workflows/release.yml
# does that in the step before this script.
#
# When the secrets are absent the script prints a clear SKIPPED block and exits
# 0 so that unsigned releases keep working. See packaging/README.md.
set -euo pipefail

usage() {
  echo "usage: $0 <path/to/Melon Tools.app> [output.dmg]" >&2
}

APP="${1:-}"
OUT_DMG="${2:-}"

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "error: app bundle not found: ${APP:-<empty>}" >&2
  usage
  exit 64
fi

if [ -n "$OUT_DMG" ] && [ "${OUT_DMG##*.}" != "dmg" ]; then
  echo "error: the output path must end in .dmg: $OUT_DMG" >&2
  exit 64
fi

missing=()
[ -n "${APPLE_ID:-}" ] || missing+=("APPLE_ID")
[ -n "${APPLE_TEAM_ID:-}" ] || missing+=("APPLE_TEAM_ID")
[ -n "${APPLE_APP_PASSWORD:-}" ] || missing+=("APPLE_APP_PASSWORD")

if [ "${#missing[@]}" -gt 0 ]; then
  cat <<EOF
SIGNING SKIPPED — macOS
  Missing environment variables: ${missing[*]}
  The build stays ad-hoc signed and is NOT notarized.
  Signing is BLOCKED until an Apple Developer certificate and app-specific
  password are provided. See packaging/README.md for the secret list.
EOF
  if [ "${REQUIRE_SIGNING:-0}" = "1" ]; then
    echo "error: REQUIRE_SIGNING=1 but the signing secrets are missing." >&2
    exit 1
  fi
  exit 0
fi

IDENTITY="${APPLE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' \
    | head -1)"
fi
if [ -z "$IDENTITY" ]; then
  cat >&2 <<EOF
error: no "Developer ID Application" identity found in the keychain.
  Import the .p12 certificate first (APPLE_CERT_P12 / APPLE_CERT_PASSWORD in CI)
  or pass APPLE_SIGN_IDENTITY explicitly. See packaging/README.md.
EOF
  exit 1
fi

echo "==> signing $APP"
echo "    identity: $IDENTITY"

sign_path() {
  /usr/bin/codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" "$1"
}

# Sign nested executable code first (gateway sidecar and app entry point), then
# the bundle itself. The fleet CLI is JavaScript and ships as data.
for dir in \
  "$APP/Contents/MacOS" \
  "$APP/Contents/Resources/bin" \
  "$APP/Contents/Frameworks" \
  "$APP/Contents/PlugIns"; do
  [ -d "$dir" ] || continue
  while IFS= read -r -d '' candidate; do
    sign_path "$candidate"
  done < <(find "$dir" -type f -perm -111 -print0)
done

sign_path "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
echo "==> signature verified"

if [ -n "$OUT_DMG" ]; then
  echo "==> re-creating the DMG from the signed app"
  STAGE="$(mktemp -d "${TMPDIR:-/tmp}/melontools-sign.XXXXXX")"
  trap 'rm -rf "$STAGE"' EXIT
  # Stage the bundle under its user-facing name, matching build.sh and the
  # Homebrew Cask ("Melon Tools.app"), not the product file name.
  ditto "$APP" "$STAGE/Melon Tools.app"
  /usr/bin/codesign --verify --deep --strict "$STAGE/Melon Tools.app"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$OUT_DMG"
  mkdir -p "$(dirname "$OUT_DMG")"
  hdiutil create -volname "Melon Tools" -srcfolder "$STAGE" \
    -ov -format UDZO "$OUT_DMG" >/dev/null
  NOTARY_TARGET="$OUT_DMG"
  echo "==> submitting $NOTARY_TARGET to Apple"
  xcrun notarytool submit "$NOTARY_TARGET" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
  xcrun stapler staple "$NOTARY_TARGET"
  xcrun stapler validate "$NOTARY_TARGET"
  echo "==> signed and notarized: $NOTARY_TARGET"
else
  ZIP="$(mktemp "${TMPDIR:-/tmp}/melontools-notary.XXXXXX.zip")"
  trap 'rm -f "$ZIP"' EXIT
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "==> submitting a temporary zip to Apple"
  xcrun notarytool submit "$ZIP" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  echo "==> signed and notarized: $APP"
fi
