[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$SourceConfig = Join-Path $RepoRoot 'mise.global.toml'
$TargetConfig = if ($env:MISE_GLOBAL_CONFIG_FILE) {
    $env:MISE_GLOBAL_CONFIG_FILE
}
else {
    Join-Path $HOME '.config\mise\config.toml'
}
$ManagedMarker = '# Managed by rebuildup/pc-setup.'

if (-not (Test-Path -LiteralPath $SourceConfig)) {
    throw "missing global mise source: $SourceConfig"
}

$targetDir = Split-Path -Parent $TargetConfig
New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

if (Test-Path -LiteralPath $TargetConfig) {
    $firstLine = Get-Content -LiteralPath $TargetConfig -TotalCount 1
    if ($firstLine -ne $ManagedMarker) {
        throw "refusing to overwrite unmanaged mise global config: $TargetConfig"
    }
}

Copy-Item -LiteralPath $SourceConfig -Destination $TargetConfig -Force
Write-Host "synced  $TargetConfig <- $SourceConfig"

Push-Location $HOME
try {
    & mise install
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
finally {
    Pop-Location
}

Write-Host 'Machine-global mise tools are installed.'
Write-Host 'Native Windows dotfiles linking is not canonical yet; apply dotfiles inside WSL until the Windows link adapter is enabled.'
