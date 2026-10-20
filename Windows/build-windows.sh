#!/bin/bash
# Cross-builds Melon Tools for Windows (x86_64) on macOS.
#
# Prerequisites (installed once):
#   rustup target add x86_64-pc-windows-msvc
#   cargo install cargo-xwin --locked
#   brew install lld llvm
#   brew install makensis          # optional, builds the NSIS installer
#
# Usage: ./build-windows.sh
#
# Optional Authenticode signing:
#   WINDOWS_CERT_PFX=/path/to/cert.pfx WINDOWS_CERT_PASSWORD=... \
#     ./build-windows.sh
# Requires osslsigncode. Without the variables (or without osslsigncode) the
# portable exe and the installer stay unsigned and the build still succeeds.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/bin:$PATH"
# Build cache off a slow volume by default.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/Library/Developer/melontools-win/target}"
CLI_SRC="${CLI_SRC:-$ROOT/../MacOS/_sources/CLIProxyAPI}"
VERSION="$(grep -m1 '^version' app/src-tauri/Cargo.toml | sed -E 's/.*"([0-9.]+)".*/\1/')"
if [ -z "$VERSION" ]; then
  echo "Cannot read version from app/src-tauri/Cargo.toml" >&2
  exit 1
fi
PORTABLE_EXE="dist/MelonTools-${VERSION}-win-x64-portable.exe"
LEGACY_EXE="dist/MelonTools-${VERSION}-win-x64.exe"
INSTALLER="dist/MelonTools-${VERSION}-setup.exe"
SIDECAR="$ROOT/app/src-tauri/binaries/cliproxyapi-x86_64-pc-windows-msvc.exe"
PACKED_ENGINE="$ROOT/app/resources/cliproxyapi.exe.z"

# Sign one PE file when a certificate and osslsigncode are available.
# A missing certificate/tool is a skip; a genuine signing error is fatal.
sign_windows_file() {
  local file="$1"
  if [ -z "${WINDOWS_CERT_PFX:-}" ] || [ -z "${WINDOWS_CERT_PASSWORD:-}" ]; then
    echo "    note: WINDOWS_CERT_PFX/WINDOWS_CERT_PASSWORD not set — $(basename "$file") stays unsigned"
    return 0
  fi
  if ! command -v osslsigncode >/dev/null 2>&1; then
    echo "    note: osslsigncode not installed — $(basename "$file") stays unsigned"
    return 0
  fi
  local signed="${file}.signed"
  echo "    signing $(basename "$file")"
  osslsigncode sign \
    -pkcs12 "$WINDOWS_CERT_PFX" \
    -pass "$WINDOWS_CERT_PASSWORD" \
    -n "Melon Tools" \
    -i "https://github.com/ivankuprin/MelonTools" \
    -ts "http://timestamp.digicert.com" \
    -h sha256 \
    -in "$file" \
    -out "$signed"
  mv "$signed" "$file"
  echo "    signed: $(basename "$file")"
}

echo "==> 1/6 gateway sidecar (Go, windows/amd64)"
if [ -d "$CLI_SRC" ]; then
  mkdir -p app/src-tauri/binaries
  (cd "$CLI_SRC" && CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -ldflags "-s -w" \
    -o "$SIDECAR" ./cmd/server)
else
  echo "CLIProxyAPI sources not found at $CLI_SRC — using the embedded gateway engine"
fi

if [ -f "$SIDECAR" ]; then
  echo "==> 2/6 compress the engine into the app (single-file build)"
  python3 - "$SIDECAR" "$PACKED_ENGINE" <<'PY'
import sys
import zlib

src, dst = sys.argv[1:]
data = open(src, "rb").read()
packed = zlib.compress(data, 9)
open(dst, "wb").write(packed)
print(f"engine: {len(data)/1e6:.1f} MB -> {len(packed)/1e6:.1f} MB embedded")
PY
elif [ -f "$PACKED_ENGINE" ]; then
  echo "==> 2/6 using the checked-in compressed gateway engine"
else
  echo "No gateway engine found. Fetch CLIProxyAPI sources or provide the embedded engine." >&2
  exit 1
fi

echo "==> 3/6 cargo xwin build (x86_64-pc-windows-msvc)"
(
  cd app/src-tauri
  # cargo does not track ui/ changes (the assets are embedded by the
  # generate_context! macro), so a UI-only edit would ship a stale frontend.
  # Touching the crate entry point forces the recompile that re-embeds it.
  touch src/main.rs
  cargo xwin build --release --target x86_64-pc-windows-msvc
)

echo "==> 4/6 collecting artifacts (single executable)"
mkdir -p dist
cp "$CARGO_TARGET_DIR/x86_64-pc-windows-msvc/release/melontools.exe" "$PORTABLE_EXE"
sign_windows_file "$PORTABLE_EXE"
# Legacy updater alias: apps on 2.0.2 only accept this name.
cp "$PORTABLE_EXE" "$LEGACY_EXE"
cp "$PORTABLE_EXE" "MelonTools-${VERSION}-portable.exe"
# Optional loose engine for development or manual installs — the app extracts
# its own embedded copy and does not need this file.
if [ -f "$SIDECAR" ]; then
  cp "$SIDECAR" "dist/cliproxyapi-x86_64-pc-windows-msvc.exe"
fi

echo "==> 5/6 Windows installer (NSIS)"
if command -v makensis >/dev/null 2>&1; then
  rm -f "$INSTALLER"
  makensis -V2 \
    -DVERSION="$VERSION" \
    -DSOURCE_EXE="../$PORTABLE_EXE" \
    installer/MelonTools.nsi
  if [ ! -f "$INSTALLER" ]; then
    echo "makensis did not produce $INSTALLER" >&2
    exit 1
  fi
  echo "installer: $INSTALLER ($(du -h "$INSTALLER" | cut -f1))"
else
  echo "note: makensis not found — skipping the Windows installer."
  echo "      Install NSIS to build it: brew install makensis (macOS) or https://nsis.sourceforge.io (Windows)."
fi

echo "==> 6/6 Authenticode signing"
if [ -f "$INSTALLER" ]; then
  sign_windows_file "$INSTALLER"
else
  echo "    note: no installer artifact to sign"
fi

echo "done: MelonTools-${VERSION}.exe (один файл, движок внутри)"
if [ -f "$INSTALLER" ]; then
  echo "      $INSTALLER"
fi
ls -lh dist
