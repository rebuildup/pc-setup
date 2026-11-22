# Roll back the stable herdr-t3 install to the previously selected release.
# Pointer flip only — the old release dir is kept by update.ps1, so no
# rebuild is needed; restart the bridge to apply.
$ErrorActionPreference = "Stop"

$StateDir = if ($env:HERDR_T3_STATE_DIR) { $env:HERDR_T3_STATE_DIR } else { Join-Path $env:LOCALAPPDATA "herdr-t3" }
$CurrentFile = Join-Path $StateDir "current"
$PrevFile = Join-Path $StateDir "previous"

if (-not (Test-Path $PrevFile)) { Write-Host "[herdr-t3] no previous release recorded" -ForegroundColor Red; exit 1 }
$prev = (Get-Content $PrevFile -Raw).Trim()
if (-not (Test-Path (Join-Path $StateDir "releases\$prev\dist\index.html"))) {
  Write-Host "[herdr-t3] previous release $prev is missing its build" -ForegroundColor Red; exit 1
}
Set-Content -Path $CurrentFile -Value "$prev`n" -NoNewline
Write-Host "[herdr-t3] rolled back to $prev (restart the bridge to apply)"
