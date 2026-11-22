# Verify the stable herdr-t3 install (Windows 11).
#
# Checks: current release + built app exist, and with -Live the app process
# is running and the herdr endpoint (socket or named pipe) is reachable.
param([switch]$Live)

$ErrorActionPreference = "Stop"
$StateDir = if ($env:HERDR_T3_STATE_DIR) { $env:HERDR_T3_STATE_DIR } else { Join-Path $env:LOCALAPPDATA "herdr-t3" }
$CurrentFile = Join-Path $StateDir "current"
$AppFile = Join-Path $StateDir "current_app"

function Fail($msg) { Write-Host "[herdr-t3] FAIL: $msg" -ForegroundColor Red; exit 1 }

if (-not (Test-Path $CurrentFile)) { Fail "not installed ($CurrentFile missing)" }
$name = (Get-Content $CurrentFile -Raw).Trim()
$release = Join-Path $StateDir "releases\$name"
if (-not (Test-Path (Join-Path $release ".git"))) { Fail "release dir missing: $release" }
$exe = ""
if (Test-Path $AppFile) { $exe = (Get-Content $AppFile -Raw).Trim() }
if (-not $exe -or -not (Test-Path $exe)) { $exe = Join-Path $release "release\win-unpacked\herdr-t3.exe" }
if (-not (Test-Path $exe)) { Fail "no built app for $name ($exe)" }
$commit = (git -C $release rev-parse HEAD).Trim()
Write-Host "[herdr-t3] installed: $name @ $($commit.Substring(0,12)) -> $exe"

if ($Live) {
  if (-not (Get-Process -Name "herdr-t3" -ErrorAction SilentlyContinue)) { Fail "app is not running (run launch.ps1)" }
  $sock = if ($env:HERDR_SOCKET) { $env:HERDR_SOCKET } else { Join-Path $env:APPDATA "herdr\herdr.sock" }
  $pipe = "\\.\pipe\$sock"
  if (-not (Test-Path $sock) -and -not [System.IO.Directory]::Exists($pipe)) {
    Fail "herdr endpoint not found: $sock / $pipe (is herdr running?)"
  }
  Write-Host "[herdr-t3] live: app running, herdr endpoint present: $sock"
}
