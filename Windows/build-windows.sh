#!/bin/bash
# Cross-builds Melon Tools for Windows (x86_64) on macOS.
#
# Prerequisites (installed once):
#   rustup target add x86_64-pc-windows-msvc
#   cargo install cargo-xwin --locked
#   brew install lld llvm
#
# Usage: ./build-windows.sh
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/bin:$PATH"
# Build cache off a slow volume by default.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/Library/Developer/melontools-win/target}"
CLI_SRC="${CLI_SRC:-$ROOT/../MacOS/_sources/CLIProxyAPI}"
VERSION="$(grep -m1 '"version"' app/src-tauri/Cargo.toml | sed -E 's/.*"([0-9.]+)".*/\1/')"
SIDECAR="$ROOT/app/src-tauri/binaries/cliproxyapi-x86_64-pc-windows-msvc.exe"
PACKED_ENGINE="$ROOT/app/resources/cliproxyapi.exe.z"

echo "==> 1/4 gateway sidecar (Go, windows/amd64)"
if [ -d "$CLI_SRC" ]; then
  mkdir -p app/src-tauri/binaries
  (cd "$CLI_SRC" && CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -ldflags "-s -w" \
    -o "$SIDECAR" ./cmd/server)
else
  echo "CLIProxyAPI sources not found at $CLI_SRC — using the embedded gateway engine"
fi

if [ -f "$SIDECAR" ]; then
  echo "==> 2/4 compress the engine into the app (single-file build)"
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
  echo "==> 2/4 using the checked-in compressed gateway engine"
else
  echo "No gateway engine found. Fetch CLIProxyAPI sources or provide the embedded engine." >&2
  exit 1
fi

echo "==> 3/4 cargo xwin build (x86_64-pc-windows-msvc)"
(
  cd app/src-tauri
  # cargo does not track ui/ changes (the assets are embedded by the
  # generate_context! macro), so a UI-only edit would ship a stale frontend.
  # Touching the crate entry point forces the recompile that re-embeds it.
  touch src/main.rs
  cargo xwin build --release --target x86_64-pc-windows-msvc
)

echo "==> 4/4 collecting artifacts (single executable)"
mkdir -p dist
cp "$CARGO_TARGET_DIR/x86_64-pc-windows-msvc/release/melontools.exe" "dist/MelonTools-${VERSION}-win-x64.exe"
cp "dist/MelonTools-${VERSION}-win-x64.exe" "MelonTools-${VERSION}.exe"
# Optional loose engine for development or manual installs — the app extracts
# its own embedded copy and does not need this file.
if [ -f "$SIDECAR" ]; then
  cp "$SIDECAR" "dist/cliproxyapi-x86_64-pc-windows-msvc.exe"
fi
echo "done: MelonTools-${VERSION}.exe (один файл, движок внутри)"
ls -lh dist
