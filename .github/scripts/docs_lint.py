#!/usr/bin/env python3
"""Basic repository lint for docs and distribution manifests.

Checks run in CI (`.github/workflows/ci.yml`) and can be run locally:

    python3 .github/scripts/docs_lint.py

The lint intentionally avoids third-party tooling beyond PyYAML. It verifies
that workflow/manifest YAML and JSON parse, that release versions agree across
the macOS project, the Windows crate and the distribution manifests, and that
the documented files exist and are linked from the root README.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
ERRORS: list[str] = []


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def check_yaml(path: Path) -> object | None:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return yaml.safe_load(handle)
    except Exception as exc:  # noqa: BLE001 - report every parse failure
        ERRORS.append(f"{rel(path)}: invalid YAML: {exc}")
        return None


def check_json(path: Path) -> None:
    try:
        with path.open("r", encoding="utf-8") as handle:
            json.load(handle)
    except Exception as exc:  # noqa: BLE001
        ERRORS.append(f"{rel(path)}: invalid JSON: {exc}")


def find_files(pattern: str) -> list[Path]:
    return sorted(
        path
        for path in ROOT.glob(pattern)
        if path.is_file() and not path.name.startswith("._")
    )


# --- YAML and JSON syntax -------------------------------------------------

workflow_files = find_files(".github/workflows/*.yml")
if not workflow_files:
    ERRORS.append(".github/workflows: no workflow files found")

for path in workflow_files:
    document = check_yaml(path)
    if isinstance(document, dict) and "jobs" not in document:
        ERRORS.append(f"{rel(path)}: workflow has no jobs section")

for path in find_files(".github/ISSUE_TEMPLATE/*.yml"):
    check_yaml(path)

dependabot = ROOT / ".github/dependabot.yml"
if dependabot.is_file():
    document = check_yaml(dependabot)
    if isinstance(document, dict) and "updates" not in document:
        ERRORS.append(f"{rel(dependabot)}: no updates entries")
else:
    ERRORS.append(".github/dependabot.yml: missing")

winget_files = find_files("packaging/winget/*.yaml")
if len(winget_files) != 3:
    ERRORS.append(
        "packaging/winget: expected version, installer, and locale manifests; "
        f"found {len(winget_files)}"
    )
for path in winget_files:
    check_yaml(path)

for path in [
    ROOT / "Windows/app/src-tauri/tauri.conf.json",
    *find_files("Windows/app/src-tauri/capabilities/*.json"),
]:
    if path.is_file():
        check_json(path)

# --- Version consistency --------------------------------------------------

project_yaml = ROOT / "MacOS/app/project.yml"
project_version = None
if project_yaml.is_file():
    project = check_yaml(project_yaml)
    try:
        project_version = project["targets"]["MelonTools"]["info"]["properties"][
            "CFBundleShortVersionString"
        ]
    except (KeyError, TypeError):
        ERRORS.append("MacOS/app/project.yml: could not read the bundle version")
else:
    ERRORS.append("MacOS/app/project.yml: missing")

cargo_version = None
cargo_toml = ROOT / "Windows/app/src-tauri/Cargo.toml"
if cargo_toml.is_file():
    match = re.search(
        r'^version\s*=\s*"([^"]+)"', cargo_toml.read_text(encoding="utf-8"), re.MULTILINE
    )
    cargo_version = match.group(1) if match else None
else:
    ERRORS.append("Windows/app/src-tauri/Cargo.toml: missing")

cask_path = ROOT / "packaging/homebrew/Casks/melon-tools.rb"
cask_text = cask_path.read_text(encoding="utf-8") if cask_path.is_file() else ""
cask_version_match = re.search(r'^\s*version\s+"([^"]+)"', cask_text, re.MULTILINE)
cask_sha_match = re.search(r'^\s*sha256\s+"([0-9a-fA-F]{64})"', cask_text, re.MULTILINE)
if not cask_path.is_file():
    ERRORS.append("packaging/homebrew/Casks/melon-tools.rb: missing")
if not cask_version_match:
    ERRORS.append("Homebrew Cask: version is missing")
if not cask_sha_match:
    ERRORS.append("Homebrew Cask: sha256 is missing or not 64 hex characters")

winget_versions: dict[str, object] = {}
winget_sha = None
for path in winget_files:
    document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    winget_versions[path.name] = document.get("PackageVersion")
    if "InstallerSha256" in document:
        winget_sha = str(document["InstallerSha256"]).lower()
        if not re.fullmatch(r"[0-9a-f]{64}", winget_sha):
            ERRORS.append(f"{rel(path)}: InstallerSha256 is not 64 hex characters")

versions = {
    "MacOS/app/project.yml": project_version,
    "Windows/app/src-tauri/Cargo.toml": cargo_version,
    "Homebrew Cask": cask_version_match.group(1) if cask_version_match else None,
}
for name, version in winget_versions.items():
    versions[f"winget {name}"] = version

known = {version for version in versions.values() if version}
if len(known) != 1:
    ERRORS.append(f"version mismatch across release files: {versions}")

for name, version in versions.items():
    if not version:
        ERRORS.append(f"{name}: version is missing")

# --- Distribution URLs ----------------------------------------------------

version = next(iter(known), None)
if version:
    cask_url_ok = (
        f"releases/download/v#{{version}}/MelonTools-#{{version}}.dmg" in cask_text
    )
    if not cask_url_ok:
        ERRORS.append("Homebrew Cask: DMG URL does not use the cask version")

    installer_path = ROOT / "packaging/winget/ivankuprin.MelonTools.installer.yaml"
    installer_text = installer_path.read_text(encoding="utf-8") if installer_path.is_file() else ""
    if not installer_text:
        ERRORS.append("winget installer manifest: missing")
    else:
        if f"MelonTools-{version}-win-x64.exe" not in installer_text:
            ERRORS.append("winget installer manifest: exe URL does not use the package version")
        if "https://github.com/ivankuprin/MelonTools/releases/download/" not in installer_text:
            ERRORS.append("winget installer manifest: InstallerUrl is not a GitHub release URL")

# --- Documentation --------------------------------------------------------

required_docs = {
    "docs/FAQ.md": 1500,
    "docs/SECURITY-MODEL.md": 1500,
    "packaging/README.md": 800,
}
for name, minimum in required_docs.items():
    path = ROOT / name
    if not path.is_file():
        ERRORS.append(f"{name}: missing")
    elif len(path.read_text(encoding="utf-8")) < minimum:
        ERRORS.append(f"{name}: shorter than {minimum} characters")

readme = ROOT / "README.md"
if readme.is_file():
    readme_text = readme.read_text(encoding="utf-8")
    for link in ["docs/FAQ.md", "docs/SECURITY-MODEL.md"]:
        if link not in readme_text:
            ERRORS.append(f"README.md: missing documentation link to {link}")
else:
    ERRORS.append("README.md: missing")

# --- Result ---------------------------------------------------------------

if ERRORS:
    print("docs-lint: FAILED")
    for error in ERRORS:
        print(f"  - {error}")
    sys.exit(1)

print("docs-lint: OK")
print(f"  workflows: {len(workflow_files)}")
print(f"  winget manifests: {len(winget_files)}")
print(f"  version: {version}")
