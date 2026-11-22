# Launch the stable herdr-t3 bridge and open the GUI (Windows 11).
#
# Idempotent: if /api/health already answers the bridge is left alone.
# Otherwise the bridge is started detached from the `current` release; a
# port already owned by something else is reported, not hijacked.
$ErrorActionPreference = "Stop"

$StateDir = if ($env:HERDR_T3_STATE_DIR) { $env:HERDR_T3_STATE_DIR } else { Join-Path $env:LOCALAPPDATA "herdr-t3" }
$CurrentFile = Join-Path $StateDir "current"
$Port = if ($env:HERDR_T3_PORT) { $env:HERDR_T3_PORT } else { "4737" }
$Url = "http://127.0.0.1:$Port/"
$Health = "http://127.0.0.1:$Port/api/health"

function Log($msg) { Write-Host "[herdr-t3] $msg" }
function Die($msg) { Write-Host "[herdr-t3] ERROR: $msg" -ForegroundColor Red; exit 1 }
function Healthy { try { (Invoke-RestMethod -Uri $Health -TimeoutSec 2).ok -eq $true } catch { $false } }

if (-not (Healthy)) {
  if (-not (Test-Path $CurrentFile)) { Die "no install found; run install.ps1 first" }
  $name = (Get-Content $CurrentFile -Raw).Trim()
  $release = Join-Path $StateDir "releases\$name"
  if (-not (Test-Path (Join-Path $release "dist\index.html"))) { Die "release $name has no built dist/; reinstall" }
  if (-not (Get-Command bun -ErrorAction SilentlyContinue)) { Die "bun not on PATH" }

  $listener = Get-NetTCPConnection -LocalPort ([int]$Port) -State Listen -ErrorAction SilentlyContinue
  if ($listener) { Die "port $Port is already listening but /api/health did not answer; not hijacking it" }

  New-Item -ItemType Directory -Force -Path (Join-Path $StateDir "run"), (Join-Path $StateDir "logs") | Out-Null
  Log "starting bridge from $name on $Url"
  $env:PORT = $Port; $env:HOST = "127.0.0.1"
  $proc = Start-Process -FilePath "bun" -ArgumentList "run","server" -WorkingDirectory $release `
    -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $StateDir "logs\bridge.log") `
    -RedirectStandardError (Join-Path $StateDir "logs\bridge.err.log")
  Set-Content (Join-Path $StateDir "run\bridge.pid") $proc.Id

  $ok = $false
  foreach ($i in 1..50) { Start-Sleep -Milliseconds 200; if (Healthy) { $ok = $true; break } }
  if (-not $ok) { Die "bridge did not become healthy; see $StateDir\logs\bridge.log" }
}
Start-Process $Url
