# Verify the stable herdr-t3 install (Windows 11).
# Checks the selected release has a built dist/, a real checkout and bun;
# -Live additionally checks the running bridge's /api/health.
param([switch]$Live)

$ErrorActionPreference = "Stop"
$StateDir = if ($env:HERDR_T3_STATE_DIR) { $env:HERDR_T3_STATE_DIR } else { Join-Path $env:LOCALAPPDATA "herdr-t3" }
$CurrentFile = Join-Path $StateDir "current"
$Port = if ($env:HERDR_T3_PORT) { $env:HERDR_T3_PORT } else { "4737" }

function Fail($msg) { Write-Host "[herdr-t3] FAIL: $msg" -ForegroundColor Red; exit 1 }

if (-not (Test-Path $CurrentFile)) { Fail "not installed" }
$name = (Get-Content $CurrentFile -Raw).Trim()
$release = Join-Path $StateDir "releases\$name"
if (-not (Test-Path (Join-Path $release ".git"))) { Fail "release dir missing: $release" }
if (-not (Test-Path (Join-Path $release "dist\index.html"))) { Fail "dist/ not built in $name" }
if (-not (Get-Command bun -ErrorAction SilentlyContinue)) { Fail "bun not on PATH" }
$commit = (git -C $release rev-parse HEAD).Trim()
Write-Host "[herdr-t3] installed: $name @ $($commit.Substring(0,12))"

if ($Live) {
  try {
    $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/health" -TimeoutSec 3
  } catch { Fail "bridge not healthy on 127.0.0.1:$Port (run launch.ps1)" }
  if (-not $health.ok) { Fail "health ok!=true" }
  if (-not $health.herdr.reachable) { Fail "herdr not reachable" }
  Write-Host "[herdr-t3] live: $($health | ConvertTo-Json -Compress)"
}
