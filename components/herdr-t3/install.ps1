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
  # Stable release tags only: a prerelease tag like v1.1.0-rc.1 would fail
  # the [version] cast below and must never win auto-selection.
  $tags = git ls-remote --tags $RepoUrl "refs/tags/v*" |
    ForEach-Object { ($_ -split "/")[-1] } | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' }
  $Ref = $tags | Sort-Object { [version]($_.TrimStart('v')) } | Select-Object -Last 1
  if (-not $Ref) { Die "no stable v* tag found on $RepoUrl" }
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
if ($LASTEXITCODE -ne 0) { Die "git checkout $Ref failed in $target" }
$commit = (git -C $target rev-parse HEAD).Trim()
Log "building $name ($commit)"

# `mise install --locked` must see only the checkout's own mise.toml /
# mise.lock. On managed machines the user-global config pins
# machine-global tools that are absent from the repo lockfile and fails
# --locked installs (rebuildup/pc-setup#245). Point the global config at
# an empty file and ignore the user config locations; the data dir
# (installs, trust) is untouched.
$miseEmptyGlobal = Join-Path $StateDir "mise-empty-global.toml"
New-Item -ItemType File -Force -Path $miseEmptyGlobal | Out-Null
# MISE_IGNORED_CONFIG_PATHS uses the OS path separator (';' on Windows,
# ':' on Unix) since mise v2026.4.15.
$ignored = @(
  (Join-Path $env:USERPROFILE ".config\mise"),
  (Join-Path $env:APPDATA "mise"),
  (Join-Path $env:USERPROFILE ".tool-versions")
) -join ";"
if ($env:MISE_IGNORED_CONFIG_PATHS) { $ignored = "$ignored;$env:MISE_IGNORED_CONFIG_PATHS" }
$env:MISE_GLOBAL_CONFIG_FILE = $miseEmptyGlobal
$env:MISE_IGNORED_CONFIG_PATHS = $ignored

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

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "shortcut.ps1")

$prevCurrent = if (Test-Path $CurrentFile) { (Get-Content $CurrentFile -Raw).Trim() } else { $null }
$prevApp = if (Test-Path $AppFile) { (Get-Content $AppFile -Raw).Trim() } else { $null }
$prevShortcut = Get-HerdrT3ShortcutTarget

try {
  Set-Content $CurrentFile $name
  Set-Content $AppFile $exe
  Set-HerdrT3Shortcut -ExePath $exe
} catch {
  if ($null -ne $prevCurrent) { Set-Content $CurrentFile $prevCurrent } else { Remove-Item $CurrentFile -Force -ErrorAction SilentlyContinue }
  if ($null -ne $prevApp) { Set-Content $AppFile $prevApp } else { Remove-Item $AppFile -Force -ErrorAction SilentlyContinue }
  if ($prevShortcut) { try { Set-HerdrT3Shortcut -ExePath $prevShortcut } catch { } }
  Die "shortcut registration failed; previous selection restored"
}
Log "installed $name ($commit); current -> $name ($exe)"
