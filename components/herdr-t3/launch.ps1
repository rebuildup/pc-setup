# Launch the stable herdr-t3 desktop app (Windows 11).
#
# Idempotent: if the app is already running it is simply activated. No
# bridge, port or browser is involved — the app embeds the bridge in its
# Main process and connects to herdr directly (native or WSL socket path
# resolved inside the app).
$ErrorActionPreference = "Stop"

$StateDir = if ($env:HERDR_T3_STATE_DIR) { $env:HERDR_T3_STATE_DIR } else { Join-Path $env:LOCALAPPDATA "herdr-t3" }
$CurrentFile = Join-Path $StateDir "current"
$AppFile = Join-Path $StateDir "current_app"

function Log($msg) { Write-Host "[herdr-t3] $msg" }
function Die($msg) { Write-Host "[herdr-t3] ERROR: $msg" -ForegroundColor Red; exit 1 }

if (-not (Test-Path $CurrentFile)) { Die "no install found; run install.ps1 first" }
$name = (Get-Content $CurrentFile -Raw).Trim()
$release = Join-Path $StateDir "releases\$name"
$exe = ""
if (Test-Path $AppFile) { $exe = (Get-Content $AppFile -Raw).Trim() }
if (-not $exe -or -not (Test-Path $exe)) {
  $exe = Join-Path $release "release\win-unpacked\herdr-t3.exe"
}
if (-not (Test-Path $exe)) { Die "release $name has no built app; reinstall ($exe)" }

$running = Get-Process -Name "herdr-t3" -ErrorAction SilentlyContinue
if ($running) {
  Log "already running; activating"
} else {
  Start-Process $exe
}
Log "launched $name ($exe)"
