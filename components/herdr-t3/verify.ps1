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

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "shortcut.ps1")
$lnk = Get-HerdrT3ShortcutTarget
if (-not $lnk) { Fail "Start Menu shortcut missing ($script:HerdrT3ShortcutPath)" }
if ($lnk -ne $exe) { Fail "Start Menu shortcut points to $lnk, expected $exe" }
Write-Host "[herdr-t3] start menu: $lnk"

if ($Live) {
  if (-not (Get-Process -Name "herdr-t3" -ErrorAction SilentlyContinue)) { Fail "app is not running (run launch.ps1)" }
  $sock = if ($env:HERDR_SOCKET) { $env:HERDR_SOCKET } else { Join-Path $env:APPDATA "herdr\herdr.sock" }
  # Windows herdr endpoints are named pipes; Directory.Exists cannot see
  # them, so probe the pipe with a short connect instead.
  $pipeName = [System.IO.Path]::GetFileName($sock)
  $pipeUp = $false
  try {
    $pipeClient = New-Object System.IO.Pipes.NamedPipeClientPipe('.', $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
    try { $pipeClient.Connect(1500); $pipeUp = $true } catch { }
    finally { $pipeClient.Dispose() }
  } catch { }
  if (-not (Test-Path $sock) -and -not $pipeUp) {
    Fail "herdr endpoint not found: $sock / \\.\pipe\$pipeName (is herdr running?)"
  }
  Write-Host "[herdr-t3] live: app running, herdr endpoint present: $sock"
}
