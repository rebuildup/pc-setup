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

# ---------------------------------------------------------------------------
# Optional apps: record a failed install, never retry it automatically.
# ---------------------------------------------------------------------------

function Get-PcSetupStateDir {
    if ($env:PC_SETUP_STATE_DIR) { return $env:PC_SETUP_STATE_DIR }
    return Join-Path $env:LOCALAPPDATA 'pc-setup'
}

function Get-PendingApps {
    $path = Join-Path (Get-PcSetupStateDir) 'pending-apps.json'
    $pending = @{}
    if (Test-Path -LiteralPath $path) {
        try {
            $parsed = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            foreach ($property in $parsed.PSObject.Properties) { $pending[$property.Name] = $property.Value }
        }
        catch { Write-Warning "Ignoring unreadable $path : $($_.Exception.Message)" }
    }
    return $pending
}

function Add-PendingApp {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Reason)
    $dir = Get-PcSetupStateDir
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $pending = Get-PendingApps
    $pending[$Id] = [ordered]@{ Reason = $Reason; At = (Get-Date).ToString('s') }
    $pending | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $dir 'pending-apps.json') -Encoding utf8
}

function Test-OptionalApp {
    param([Parameter(Mandatory)][hashtable]$App)
    return ($App.ContainsKey('Optional') -and $App.Optional)
}

# ---------------------------------------------------------------------------
# Verification helpers with pure inputs (unit-tested in CI).
# ---------------------------------------------------------------------------

# Cubase may be a full edition or a bundled "Steinberg Cubase LE AI Elements 13".
$script:CubaseDisplayNamePattern = '^(Steinberg )?Cubase'

# Tailscale enrolment, login and Serve are manual/secret-backed boundaries. Any
# backend state other than Running is reported as pending, never as a failure
# that should be "fixed" by an automatic login or node registration.
function Get-TailscaleBackendVerdict {
    param([string]$BackendState)
    if ($BackendState -eq 'Running') { return 'ok' }
    return 'manual'
}

# Moves $Preferred to sit directly before $Shadowed in a PATH string. Entries are
# never removed or rewritten; only the order changes. Returns the input
# unchanged when the order is already right.
function Get-ReorderedPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Preferred,
        [Parameter(Mandatory)][string]$Shadowed
    )
    $normalize = { param($e) $e.Trim().TrimEnd('\').ToLowerInvariant() }
    $entries = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in ($Path -split ';')) { if ($entry) { $entries.Add($entry) } }

    $preferredIndex = -1; $shadowedIndex = -1
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $n = & $normalize $entries[$i]
        if ($preferredIndex -lt 0 -and $n -eq (& $normalize $Preferred)) { $preferredIndex = $i }
        if ($shadowedIndex -lt 0 -and $n -eq (& $normalize $Shadowed)) { $shadowedIndex = $i }
    }

    if ($shadowedIndex -lt 0) { return $Path }
    if ($preferredIndex -ge 0 -and $preferredIndex -lt $shadowedIndex) { return $Path }

    $value = if ($preferredIndex -ge 0) { $entries[$preferredIndex] } else { $Preferred }
    if ($preferredIndex -ge 0) {
        $entries.RemoveAt($preferredIndex)
        if ($preferredIndex -lt $shadowedIndex) { $shadowedIndex-- }
    }
    $entries.Insert($shadowedIndex, $value)
    return ($entries -join ';')
}
