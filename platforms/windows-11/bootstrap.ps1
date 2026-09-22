[CmdletBinding()]
param(
    [switch]$SkipStore,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WingetFile = Join-Path $ScriptDir 'winget-packages.txt'
$StoreFile = Join-Path $ScriptDir 'store-packages.txt'

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "`n==> $Message"
}

function Get-ManifestLines {
    param([Parameter(Mandatory)][string]$Path)

    Get-Content -LiteralPath $Path |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') }
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Source,
        [string]$DisplayName = $Id
    )

    $args = @(
        'install',
        '--id', $Id,
        '--exact',
        '--source', $Source,
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )

    if ($WhatIf) {
        Write-Host "WHATIF winget $($args -join ' ') # $DisplayName"
        return
    }

    Write-Host "Installing/confirming: $DisplayName [$Id] from $Source"
    & winget @args

    if ($LASTEXITCODE -ne 0) {
        throw "winget failed for $DisplayName [$Id] with exit code $LASTEXITCODE"
    }
}

if (-not $IsWindows) {
    throw 'This bootstrap targets Windows 11.'
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget is required. Update/install Microsoft App Installer first.'
}

Write-Step 'Installing WinGet desired-state packages'
foreach ($packageId in Get-ManifestLines -Path $WingetFile) {
    Install-WingetPackage -Id $packageId -Source 'winget'
}

if (-not $SkipStore) {
    Write-Step 'Installing Microsoft Store desired-state packages'

    foreach ($line in Get-ManifestLines -Path $StoreFile) {
        $parts = $line.Split('|', 2)
        $id = $parts[0]
        $name = if ($parts.Count -gt 1) { $parts[1] } else { $id }

        try {
            Install-WingetPackage -Id $id -Source 'msstore' -DisplayName $name
        }
        catch {
            Write-Warning "$name could not be installed automatically: $($_.Exception.Message)"
            Write-Warning 'Store package availability can depend on account/region. Keep it as a manual gate rather than changing region silently.'
        }
    }
}

Write-Step 'Manual/vendor-managed steps still required'
Write-Host @'
1. Adobe Creative Cloud:
   - sign in
   - install After Effects
   - install Illustrator

2. Steinberg:
   - install current Steinberg Download Assistant from https://www.steinberg.net/sda
   - sign in / activate licensing
   - install Cubase

3. ChgKey:
   - obtain the legacy portable utility from a trusted source
   - run as Administrator and restore the intended scan-code mapping
   - restart Windows

4. Visual Studio Installer:
   - confirm C++ desktop and .NET desktop workloads required by active projects

5. Authentication:
   - GitHub / ChatGPT / Discord / Linear / Slack / Teams / Adobe / Steinberg
   - do not put credentials into this repository
'@

Write-Step 'Post-install toolchain notes'
Write-Host @'
Open a fresh PowerShell after installation so PATH updates are visible.

Then initialize/update Rust if needed:
  rustup default stable
  rustup update stable

Run verification:
  .\platforms\windows-11\verify.ps1
'@
