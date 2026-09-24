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

function Prepare-MiseGitHubAuth {
    if ($env:MISE_GITHUB_TOKEN -or $env:GITHUB_API_TOKEN -or $env:GITHUB_TOKEN) {
        Write-Host 'ok      mise GitHub authentication provided by environment'
        return
    }

    Push-Location $HOME
    try {
        & mise install gh
        if ($LASTEXITCODE -ne 0) {
            throw "failed to install gh before GitHub-backed mise tools (exit $LASTEXITCODE)"
        }

        & mise exec gh -- gh auth status --hostname github.com *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'GitHub authentication is required before GitHub-backed tool installation.'
            & mise exec gh -- gh auth login --hostname github.com --git-protocol https --web
            if ($LASTEXITCODE -ne 0) {
                throw "GitHub authentication failed (exit $LASTEXITCODE)"
            }
        }

        $token = (& mise exec gh -- gh auth token --hostname github.com)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
            throw 'gh authentication succeeded but no GitHub token could be resolved for mise.'
        }

        $env:MISE_GITHUB_TOKEN = $token.Trim()
        Remove-Variable token
        Write-Host 'ok      mise GitHub authentication prepared from gh'
    }
    finally {
        Pop-Location
    }
}

Prepare-MiseGitHubAuth

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
