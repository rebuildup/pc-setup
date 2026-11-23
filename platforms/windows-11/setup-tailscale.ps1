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

# `tailscale status --json` emits UTF-8. Windows PowerShell 5.1 on a Japanese
# (or any non-UTF-8) console decodes native output with the OEM code page, so
# the Health strings arrive as mojibake and ConvertFrom-Json fails on
# 'Path 'Health[0]''. Decode as UTF-8 for the duration of the call and restore
# the previous encoding afterwards; a failure to set it must not stop the
# script, because the parse below still fails closed on bad output.
function Invoke-Utf8Native {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $previousEncoding = $null
    try {
        $previousEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    }
    catch { }

    try {
        $output = @(& $Command @Arguments 2>$null)
        $exitCode = $LASTEXITCODE
    }
    finally {
        if ($null -ne $previousEncoding) {
            try { [Console]::OutputEncoding = $previousEncoding } catch { }
        }
    }

    return [pscustomobject]@{ Output = $output; ExitCode = $exitCode }
}

# Returns the parsed `tailscale status --json` object, or $null when the state
# cannot be determined. Callers MUST treat $null as "unknown" and fail closed:
# an unparseable status once fell through to the `tailscale up --auth-key`
# path and re-registered a node that was already enrolled.
function Get-TailscaleStatus {
    param([Parameter(Mandatory)]$TailscaleCommand)

    $result = Invoke-Utf8Native -Command $TailscaleCommand -Arguments @('status', '--json')
    if ($result.ExitCode -ne 0 -or $result.Output.Count -eq 0) {
        return $null
    }

    try {
        return (($result.Output -join [Environment]::NewLine) | ConvertFrom-Json)
    }
    catch {
        return $null
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

$status = Get-TailscaleStatus -TailscaleCommand $tailscale

if ($null -eq $status -or $null -eq $status.BackendState) {
    # Fail closed: the backend state is unknown, so this script cannot tell a
    # fresh machine (NeedsLogin) from an already-enrolled node whose status
    # output failed to decode. Re-registering here once replaced a healthy
    # node identity; refuse instead and let the operator re-run once the
    # status command works.
    throw 'tailscale status --json is unavailable or unparseable; refusing to touch node registration (fail closed). Re-run after Tailscale is responsive.'
}

if ($status.BackendState -ne 'Running') {
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

$serveResult = Invoke-Utf8Native -Command $tailscale -Arguments @('serve', 'status')
$serveStatus = ($serveResult.Output -join [Environment]::NewLine)
if ($serveResult.ExitCode -ne 0) {
    throw "Tailscale Serve status failed with exit code $($serveResult.ExitCode)"
}

foreach ($mapping in $config.Tailscale.Serve) {
    if (-not $serveStatus.Contains([string]$mapping.Target) -or
        -not $serveStatus.Contains(":$($mapping.ListenPort)")) {
        throw "Tailscale Serve mapping was not observed for port $($mapping.ListenPort)"
    }
}

Write-Host 'Tailscale setup complete'
