# Shared detection for apps that may already be installed through a channel
# other than the one apps.psd1 names (Microsoft Store/MSIX, vendor installers).
# Dot-source this file; it defines functions only and has no side effects.
#
# Detection order, first hit wins:
#   1. WinGet exact ID (any source)
#   2. Appx/MSIX package name regex   (inventory key: AppxName)
#   3. Uninstall registry DisplayName regex (inventory key: DisplayName)
#
# An app found by 2 or 3 is adopted as-is: install-apps.ps1 must not install a
# second copy through WinGet, and verify.ps1 must not report it missing.

function Get-InstalledDisplayNames {
    $paths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($path in $paths) {
        # Not every uninstall key has DisplayName; under Set-StrictMode, filtering
        # on the bare property name throws on those, so test the property.
        Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName } |
            ForEach-Object { $_.DisplayName }
    }
}

function Test-WingetPackageInstalled {
    param([Parameter(Mandatory)][string]$Id)
    & winget list --id $Id --exact --accept-source-agreements --disable-interactivity *> $null
    return ($LASTEXITCODE -eq 0)
}

# Returns the channel that satisfied the app ('winget', 'appx', 'registry'),
# or $null when it is not installed by any known route.
function Get-AppInstallChannel {
    param(
        [Parameter(Mandatory)][hashtable]$App,
        [string[]]$DisplayNames,
        [object[]]$AppxPackages
    )

    if (Test-WingetPackageInstalled -Id $App.Id) { return 'winget' }

    if ($App.ContainsKey('AppxName')) {
        if ($null -eq $AppxPackages) { $AppxPackages = @(Get-AppxPackage -ErrorAction SilentlyContinue) }
        if ($AppxPackages | Where-Object { $_.Name -match $App.AppxName }) { return 'appx' }
    }

    if ($App.ContainsKey('DisplayName')) {
        if ($null -eq $DisplayNames) { $DisplayNames = @(Get-InstalledDisplayNames) }
        if ($DisplayNames | Where-Object { $_ -match $App.DisplayName }) { return 'registry' }
    }

    return $null
}
