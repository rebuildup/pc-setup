[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path (Get-Location) 'snapshots/windows-11')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) { throw 'This snapshot script targets Windows.' }

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$stamp = Get-Date -Format 'yyyy-MM-dd-HHmmss'
$target = Join-Path $OutputDirectory $stamp
New-Item -ItemType Directory -Force -Path $target | Out-Null

if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget export --output (Join-Path $target 'winget-export.json') --accept-source-agreements | Out-Null
    winget list --accept-source-agreements | Out-File -Encoding utf8 (Join-Path $target 'winget-list.txt')
}

Get-AppxPackage |
    Select-Object Name, PackageFullName, Version, Publisher |
    Sort-Object Name |
    ConvertTo-Json -Depth 3 |
    Out-File -Encoding utf8 (Join-Path $target 'appx-packages.json')

$uninstallPaths = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

$registryApps = foreach ($path in $uninstallPaths) {
    Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
        Where-Object DisplayName |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallLocation
}

$registryApps |
    Sort-Object DisplayName -Unique |
    ConvertTo-Json -Depth 3 |
    Out-File -Encoding utf8 (Join-Path $target 'uninstall-registry.json')

$commands = @(
    @('git','--version'),
    @('gh','--version'),
    @('pwsh','--version'),
    @('node','--version'),
    @('npm','--version'),
    @('bun','--version'),
    @('rustc','--version'),
    @('cargo','--version'),
    @('rg','--version'),
    @('fd','--version'),
    @('fzf','--version'),
    @('jq','--version'),
    @('bat','--version'),
    @('dotnet','--version')
)

$versionOutput = foreach ($entry in $commands) {
    $name = $entry[0]
    $args = if ($entry.Count -gt 1) { $entry[1..($entry.Count - 1)] } else { @() }
    if (Get-Command $name -ErrorAction SilentlyContinue) {
        try {
            $value = & $name @args 2>&1
            "$name $($args -join ' ')`n$value`n"
        } catch {
            "$name`nERROR: $($_.Exception.Message)`n"
        }
    } else {
        "$name`nMISSING`n"
    }
}

$versionOutput | Out-File -Encoding utf8 (Join-Path $target 'command-versions.txt')

Get-ComputerInfo |
    Select-Object WindowsProductName, WindowsVersion, OsBuildNumber, OsArchitecture, CsSystemType |
    ConvertTo-Json |
    Out-File -Encoding utf8 (Join-Path $target 'system.json')

Write-Host "Snapshot written to $target"
Write-Warning 'Review before committing: snapshots can reveal usernames, install paths, or software you do not intend to publish.'
