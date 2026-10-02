[CmdletBinding()]
param(
    [switch]$Injected,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'tailscale.psd1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-Application {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$FallbackPath
    )

    $command = Get-Command $Name -CommandType Application -All -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($command) {
        return $command
    }

    if ($FallbackPath -and (Test-Path -LiteralPath $FallbackPath)) {
        return $FallbackPath
    }

    return $null
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)]$Command,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Description
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    throw 'This setup targets Windows.'
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Tailscale config not found: $ConfigPath"
}

$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
$tailscaleFallback = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
$tailscale = Resolve-Application -Name 'tailscale' -FallbackPath $tailscaleFallback
if (-not $tailscale) {
    throw 'Tailscale CLI is missing. Run the pc-setup Windows bootstrap first.'
}

if (-not $Injected) {
    $infisical = Resolve-Application -Name 'infisical'
    if (-not $infisical) {
        throw 'Infisical CLI is missing. Run the pc-setup Windows bootstrap first.'
    }

    $pwsh = Resolve-Application -Name 'pwsh'
    if (-not $pwsh) {
        throw 'PowerShell 7 is required to run the injected Tailscale setup.'
    }

    $previousApiUrl = $env:INFISICAL_API_URL
    $env:INFISICAL_API_URL = $config.Infisical.ApiUrl

    try {
        $arguments = @(
            'run',
            "--projectId=$($config.Infisical.ProjectId)",
            "--env=$($config.Infisical.Environment)",
            "--path=$($config.Infisical.Path)",
            '--',
            $pwsh.Source,
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            $PSCommandPath,
            '-Injected',
            '-ConfigPath',
            $ConfigPath
        )

        Invoke-Checked -Command $infisical -Arguments $arguments -Description 'Infisical-backed Tailscale setup'
    }
    finally {
        if ($null -eq $previousApiUrl) {
            Remove-Item Env:INFISICAL_API_URL -ErrorAction SilentlyContinue
        }
        else {
            $env:INFISICAL_API_URL = $previousApiUrl
        }
    }

    exit 0
}

$secretName = [string]$config.Infisical.RequiredSecrets[0]
$oauthSecret = [Environment]::GetEnvironmentVariable($secretName, 'Process')
if ([string]::IsNullOrWhiteSpace($oauthSecret)) {
    throw "Required Infisical secret is not injected: $secretName"
}

$status = $null
$statusOutput = @(& $tailscale status --json 2>$null)
if ($LASTEXITCODE -eq 0 -and $statusOutput.Count -gt 0) {
    try {
        $status = ($statusOutput -join [Environment]::NewLine) | ConvertFrom-Json
    }
    catch {
        $status = $null
    }
}

if (-not $status -or $status.BackendState -ne 'Running') {
    Write-Host 'Registering Windows host with Tailscale'
    $authKey = "${oauthSecret}?$($config.Tailscale.AuthKeyParameters)"
    try {
        Invoke-Checked -Command $tailscale -Arguments @(
            'up',
            "--auth-key=$authKey",
            "--advertise-tags=$($config.Tailscale.AdvertiseTag)"
        ) -Description 'Tailscale node registration'
    }
    finally {
        $authKey = $null
    }
}
else {
    Write-Host 'Tailscale is already connected; preserving the existing node identity'
}

foreach ($mapping in $config.Tailscale.Serve) {
    Write-Host "Configuring Tailscale Serve: $($mapping.Label)"
    Invoke-Checked -Command $tailscale -Arguments @(
        'serve',
        '--bg',
        '--yes',
        "--tcp=$($mapping.ListenPort)",
        [string]$mapping.Target
    ) -Description "Tailscale Serve $($mapping.ListenPort)"
}

$serveStatus = @(& $tailscale serve status 2>$null) -join [Environment]::NewLine
if ($LASTEXITCODE -ne 0) {
    throw "Tailscale Serve status failed with exit code $LASTEXITCODE"
}

foreach ($mapping in $config.Tailscale.Serve) {
    if (-not $serveStatus.Contains([string]$mapping.Target) -or
        -not $serveStatus.Contains(":$($mapping.ListenPort)")) {
        throw "Tailscale Serve mapping was not observed for port $($mapping.ListenPort)"
    }
}

Write-Host 'Tailscale setup complete'
