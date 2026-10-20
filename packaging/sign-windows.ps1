<#
.SYNOPSIS
  Signs a Melon Tools Windows executable with Authenticode.

.DESCRIPTION
  Reads WINDOWS_CERT_PFX (path to a .pfx file) and WINDOWS_CERT_PASSWORD.
  When either is absent the script prints a clear SKIPPED block and exits 0,
  unless -Require is passed. See packaging/README.md for the secret list and
  the BLOCKED signing status.

.PARAMETER File
  Path to the .exe to sign.

.PARAMETER Require
  Fail instead of skipping when the certificate variables are absent.

.EXAMPLE
  ./packaging/sign-windows.ps1 -File Windows/dist/MelonTools-2.0.3-setup.exe
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$File,

  [switch]$Require
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
  throw "File not found: $File"
}

if (-not $env:WINDOWS_CERT_PFX -or
    -not (Test-Path -LiteralPath $env:WINDOWS_CERT_PFX -PathType Leaf) -or
    -not $env:WINDOWS_CERT_PASSWORD) {
  Write-Host "SIGNING SKIPPED - Windows"
  Write-Host "  Missing WINDOWS_CERT_PFX (path to a .pfx) or WINDOWS_CERT_PASSWORD."
  Write-Host "  The executable stays unsigned and may trigger SmartScreen."
  Write-Host "  Signing is BLOCKED until an Authenticode certificate is provided."
  Write-Host "  See packaging/README.md for the secret list."
  if ($Require) {
    throw "Signing credentials are missing and -Require was passed."
  }
  exit 0
}

$signtoolPath = $null
$command = Get-Command signtool.exe -ErrorAction SilentlyContinue
if ($command) {
  $signtoolPath = $command.Source
}

if (-not $signtoolPath) {
  $kitRoots = @(
    "${env:ProgramFiles(x86)}\Windows Kits\10\bin",
    "$env:ProgramFiles\Windows Kits\10\bin"
  ) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }

  foreach ($root in $kitRoots) {
    $found = Get-ChildItem -LiteralPath $root -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match '\\x64\\' } |
      Sort-Object FullName -Descending |
      Select-Object -First 1
    if ($found) {
      $signtoolPath = $found.FullName
      break
    }
  }
}

if (-not $signtoolPath) {
  throw "signtool.exe was not found. Install the Windows SDK signing tools."
}

Write-Host "==> signing $File"
Write-Host "    signtool: $signtoolPath"

& $signtoolPath sign /fd SHA256 /td SHA256 /tr http://timestamp.digicert.com `
  /f $env:WINDOWS_CERT_PFX /p $env:WINDOWS_CERT_PASSWORD $File
if ($LASTEXITCODE -ne 0) {
  throw "signtool sign failed with exit code $LASTEXITCODE."
}

& $signtoolPath verify /pa /v $File
if ($LASTEXITCODE -ne 0) {
  throw "signtool verify failed with exit code $LASTEXITCODE."
}

Write-Host "==> signed and verified: $File"
