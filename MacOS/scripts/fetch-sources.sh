#!/bin/bash
# Fetch pinned third-party sources needed by build.sh.
# melon-fleet (MIT) is embedded into the app bundle; CLIProxyAPI (MIT) is
# built into the gateway binary. Both are pinned to the commits this build used.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p _sources

if [ ! -d _sources/melon-fleet ]; then
  git clone https://github.com/adxd-og/melon-fleet.git _sources/melon-fleet
fi
git -C _sources/melon-fleet fetch --all --tags --quiet || true
git -C _sources/melon-fleet checkout --quiet 318529e7dff40a3996edcb4d39893b53fb273950

if [ ! -d _sources/CLIProxyAPI ]; then
  git clone https://github.com/router-for-me/CLIProxyAPI.git _sources/CLIProxyAPI
fi
git -C _sources/CLIProxyAPI fetch --all --tags --quiet || true
git -C _sources/CLIProxyAPI checkout --quiet e7003d2a3e2cee2d45f9950c067bf8e02a2ac0f8

echo "sources ready:"
git -C _sources/melon-fleet describe --tags 2>/dev/null || true
git -C _sources/CLIProxyAPI rev-parse --short HEAD
