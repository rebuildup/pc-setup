# Update the stable herdr-t3 install (Windows 11).
# Selects the newest v* tag (or -Ref), installs it, and records the
# superseded release for rollback. Failed updates keep the current release.
param([string]$Ref = "")

$ErrorActionPreference = "Stop"
$StateDir = if ($env:HERDR_T3_STATE_DIR) { $env:HERDR_T3_STATE_DIR } else { Join-Path $env:LOCALAPPDATA "herdr-t3" }
$CurrentFile = Join-Path $StateDir "current"
$PrevFile = Join-Path $StateDir "previous"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path

$prev = ""
if (Test-Path $CurrentFile) { $prev = (Get-Content $CurrentFile -Raw).Trim() }

& (Join-Path $Here "install.ps1") -Ref $Ref
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ($prev) {
  $cur = (Get-Content $CurrentFile -Raw).Trim()
  if ($cur -ne $prev) { Set-Content -Path $PrevFile -Value "$prev`n" -NoNewline }
}
