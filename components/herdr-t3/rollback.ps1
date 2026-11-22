# Roll back the stable herdr-t3 app to the previously selected release.
# Pointer flip only — no rebuild. Quit and relaunch the app to apply.
$ErrorActionPreference = "Stop"
$StateDir = if ($env:HERDR_T3_STATE_DIR) { $env:HERDR_T3_STATE_DIR } else { Join-Path $env:LOCALAPPDATA "herdr-t3" }
$CurrentFile = Join-Path $StateDir "current"
$PrevFile = Join-Path $StateDir "previous"
$AppFile = Join-Path $StateDir "current_app"

if (-not (Test-Path $PrevFile)) { Write-Host "[herdr-t3] no previous release recorded" -ForegroundColor Red; exit 1 }
$prev = (Get-Content $PrevFile -Raw).Trim()
$prevExe = Join-Path $StateDir "releases\$prev\release\win-unpacked\herdr-t3.exe"
if (-not (Test-Path $prevExe)) { Write-Host "[herdr-t3] previous release $prev has no built app" -ForegroundColor Red; exit 1 }
Set-Content $CurrentFile $prev
Set-Content $AppFile $prevExe

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "shortcut.ps1")
Set-HerdrT3Shortcut -ExePath $prevExe
Write-Host "[herdr-t3] rolled back to $prev ($prevExe); relaunch the app to apply"
