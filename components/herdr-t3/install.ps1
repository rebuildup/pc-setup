# herdr-t3 stable install — native Electron app (Windows 11).
#
# Installs a verified release of rebuildup/herdr-t3 into the managed state
# dir as an independent per-ref checkout, builds the app once with
# electron-builder (win-unpacked + NSIS installer), and only then selects
# it. A failed install or update never disturbs the selected release.
#
# Usage: install.ps1 [-Ref <ref>]
param([string]$Ref = "")

$ErrorActionPreference = "Stop"
$RepoUrl = "https://github.com/rebuildup/herdr-t3.git"
$StateDir = if ($env:HERDR_T3_STATE_DIR) { $env:HERDR_T3_STATE_DIR } else { Join-Path $env:LOCALAPPDATA "herdr-t3" }
$ReleasesDir = Join-Path $StateDir "releases"
$CurrentFile = Join-Path $StateDir "current"
$AppFile = Join-Path $StateDir "current_app"
$LogDir = Join-Path $StateDir "logs"
New-Item -ItemType Directory -Force -Path $ReleasesDir, $LogDir | Out-Null

function Log($msg) { Write-Host "[herdr-t3] $msg" }
function Die($msg) { Write-Host "[herdr-t3] ERROR: $msg" -ForegroundColor Red; exit 1 }

if (-not $Ref) {
  $tags = git ls-remote --tags $RepoUrl "refs/tags/v*" |
    ForEach-Object { ($_ -split "/")[-1] } | Where-Object { $_ -notmatch '\^' }
  $Ref = $tags | Sort-Object { [version]($_.TrimStart('v')) } | Select-Object -Last 1
  if (-not $Ref) { Die "no v* tag found on $RepoUrl" }
}
if ($Ref -match '^v[0-9]') {
  git ls-remote --exit-code --tags $RepoUrl "refs/tags/$Ref" | Out-Null
  if ($LASTEXITCODE -ne 0) { Die "tag $Ref not found on $RepoUrl" }
} elseif ($Ref -notmatch '^[0-9a-f]{40}$') {
  Die "ref must be a v* tag or a full 40-char SHA (got: $Ref)"
}

$name = $Ref -replace '[/\\:]', '_'
$target = Join-Path $ReleasesDir $name

if (-not (Test-Path (Join-Path $target ".git"))) {
  Log "cloning $Ref into $target"
  git clone --quiet $RepoUrl $target
} else {
  git -C $target fetch --quiet --tags origin
}
git -C $target checkout --quiet $Ref
$commit = (git -C $target rev-parse HEAD).Trim()
Log "building $name ($commit)"

Push-Location $target
try {
  mise install --locked | Out-Null
  if ($LASTEXITCODE -ne 0) { Die "mise install failed" }
  bun install --frozen-lockfile | Out-Null
  if ($LASTEXITCODE -ne 0) { Die "bun install failed" }
  $env:CSC_IDENTITY_AUTO_DISCOVERY = "false"
  bun run desktop:pack | Out-Null
  if ($LASTEXITCODE -ne 0) { Die "electron-builder failed" }
} finally { Pop-Location }

$exe = Join-Path $target "release\win-unpacked\herdr-t3.exe"
if (-not (Test-Path $exe)) { Die "built app missing: $exe" }

Set-Content $CurrentFile $name
Set-Content $AppFile $exe

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "shortcut.ps1")
Set-HerdrT3Shortcut -ExePath $exe
Log "installed $name ($commit); current -> $name ($exe)"
