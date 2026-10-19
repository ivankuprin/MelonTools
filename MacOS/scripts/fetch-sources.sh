#!/bin/bash
# Fetch the pinned third-party source required to build the gateway engine.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p _sources

if [ ! -d _sources/CLIProxyAPI ]; then
  git clone https://github.com/router-for-me/CLIProxyAPI.git _sources/CLIProxyAPI
fi
git -C _sources/CLIProxyAPI fetch --all --tags --quiet || true
git -C _sources/CLIProxyAPI checkout --quiet e7003d2a3e2cee2d45f9950c067bf8e02a2ac0f8

echo "gateway source ready:"
git -C _sources/CLIProxyAPI rev-parse --short HEAD
