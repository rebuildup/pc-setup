# Converges the per-user PATH for the mise-managed Windows baseline.
#
#   user-path.ps1                 plan: report what would change, change nothing
#   user-path.ps1 -Apply          write the User PATH (no elevation needed)
#   user-path.ps1 -Restore <file> put a saved User PATH back
#
# Why this exists
#   ADR-0021 makes mise the single owner of Rust on Windows: rustup's home and
#   Cargo home live under the mise data dir, and the legacy
#   %USERPROFILE%\.cargo\bin entry must not stay on the registry User PATH —
#   on a real machine it sat at the head of User PATH and resolved rustc/cargo
#   to the legacy rustup proxies in shells that do not activate mise. mise's
#   own shims entry (%LOCALAPPDATA%\mise\shims) is the only mise-sourced entry
#   the registry PATH is supposed to carry.
#
# What it changes
#   Only the *User* PATH (HKCU), and only by exact expanded-path match:
#     - removes every entry that expands to <UserProfile>\.cargo\bin
#     - appends %LOCALAPPDATA%\mise\shims when it is absent
#   Nothing is reordered, no other entry is touched, and no file or
#   directory is deleted. Removing the PATH entry leaves the legacy
#   directory in place; the proxies simply stop winning resolution.
#
# Safety
#   The unexpanded User PATH is saved to
#   <state>\user-path-backup\user-path-<timestamp>.txt before any write,
#   and -Restore reads exactly that file back.
[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$Restore,
    [string]$StateDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'app-detection.ps1')

$userKeyPath = 'HKCU:\Environment'

# Legacy Rust proxy home. ADR-0021 keeps the directory itself (inert once
# RUSTUP_HOME/CARGO_HOME point into the mise data dir); only its PATH
# presence is the defect.
$legacyCargoBin = Join-Path $env:USERPROFILE '.cargo\bin'

$miseShimEntry = '%LOCALAPPDATA%\mise\shims'

function Split-PathValue {
    param([string]$Value)
    # Same rule as mise-path-ownership.ps1: empty entries are not meaningful
    # and are never introduced. The comma operator keeps an empty result an
    # empty array instead of $null.
    return , @($Value -split ';' | Where-Object { $_ -and $_.Trim() })
}

function Test-LegacyCargoEntry {
    param([Parameter(Mandatory)][string]$Entry)
    $expanded = [Environment]::ExpandEnvironmentVariables($Entry).Trim().TrimEnd('\')
    return ($expanded.Equals($legacyCargoBin.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase))
}

function Test-MiseShimEntry {
    param([Parameter(Mandatory)][string]$Entry)
    $expanded = [Environment]::ExpandEnvironmentVariables($Entry).Trim().TrimEnd('\')
    $expected = [Environment]::ExpandEnvironmentVariables($miseShimEntry).TrimEnd('\')
    return ($expanded.Equals($expected, [StringComparison]::OrdinalIgnoreCase))
}

if (-not $StateDir) {
    $StateDir = Join-Path (Get-PcSetupStateDir) 'user-path-backup'
}

function Get-UserPathRaw {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    try {
        if ($key.GetValueNames() -notcontains 'Path') {
            # PATH normally exists as REG_EXPAND_SZ; a missing value is
            # written back expandable.
            return [pscustomobject]@{ Value = ''; Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
        }
        $value = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = $key.GetValueKind('Path')
        if ($kind -eq [Microsoft.Win32.RegistryValueKind]::Unknown) {
            $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        }
    }
    finally { $key.Close() }
    return [pscustomobject]@{ Value = $value; Kind = $kind }
}

function Set-UserPathRaw {
    param([string]$Value, [Microsoft.Win32.RegistryValueKind]$Kind)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try { $key.SetValue('Path', $Value, $Kind) } finally { $key.Close() }
}

if ($Restore) {
    if (-not (Test-Path -LiteralPath $Restore)) { throw "restore file not found: $Restore" }
    $saved = (Get-Content -LiteralPath $Restore -Raw).TrimEnd("`r", "`n")
    $current = Get-UserPathRaw
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $pre = Join-Path $StateDir ("user-path-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Set-Content -LiteralPath $pre -Value $current.Value -Encoding utf8 -NoNewline
    Set-UserPathRaw -Value $saved -Kind $current.Kind
    Write-Host "restored User PATH from $Restore"
    Write-Host "previous value saved to $pre"
    exit 0
}

$current = Get-UserPathRaw
$entries = Split-PathValue -Value $current.Value
$removals = @($entries | Where-Object { Test-LegacyCargoEntry -Entry $_ })
$shimPresent = @($entries | Where-Object { Test-MiseShimEntry -Entry $_ }).Count -gt 0

Write-Host "User PATH entries: $($entries.Count)"
foreach ($entry in $removals) {
    Write-Host ("  remove  {0}  (expands to {1}; legacy rustup proxy home, ADR-0021)" -f $entry, $legacyCargoBin)
}
if ($removals.Count -eq 0) {
    Write-Host '  (no legacy .cargo\bin entry)'
}
if ($shimPresent) {
    Write-Host "  keep    $miseShimEntry (already present)"
}
else {
    Write-Host "  add     $miseShimEntry (mise shims; appended, order of existing entries unchanged)"
}

if (-not $Apply) {
    $changes = $removals.Count + $(if ($shimPresent) { 0 } else { 1 })
    if ($changes -eq 0) {
        Write-Host 'ok      User PATH already converged'
    }
    else {
        Write-Host "plan only; re-run with -Apply to change $changes entr$(if ($changes -eq 1) { 'y' } else { 'ies' })."
    }
    exit 0
}

$kept = @($entries | Where-Object { -not (Test-LegacyCargoEntry -Entry $_) })
if (-not $shimPresent) {
    # A REG_SZ User PATH is never environment-expanded at runtime, so the
    # shim entry must be stored pre-expanded there; REG_EXPAND_SZ keeps the
    # portable %LOCALAPPDATA% form.
    $shimEntry = if ($current.Kind -eq [Microsoft.Win32.RegistryValueKind]::String) {
        [Environment]::ExpandEnvironmentVariables($miseShimEntry)
    } else { $miseShimEntry }
    $kept += $shimEntry
}
$newValue = ($kept -join ';')

if ($newValue -eq $current.Value) {
    Write-Host 'ok      User PATH already converged'
    exit 0
}

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$backup = Join-Path $StateDir ("user-path-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Set-Content -LiteralPath $backup -Value $current.Value -Encoding utf8 -NoNewline
Write-Host "backup  $backup"
Write-Host "restore pwsh -NoProfile -File $PSCommandPath -Restore `"$backup`""

Set-UserPathRaw -Value $newValue -Kind $current.Kind
# Broadcast the change so new processes pick it up; existing shells keep
# their snapshot (same rule as mise-path-ownership.ps1).
[Environment]::SetEnvironmentVariable('PC_SETUP_PATH_TOUCH', '1', 'User')
[Environment]::SetEnvironmentVariable('PC_SETUP_PATH_TOUCH', $null, 'User')

Write-Host ('applied; removed {0} entr{1}, mise shims {2}. Open a new shell.' -f `
    $removals.Count, $(if ($removals.Count -eq 1) { 'y' } else { 'ies' }), `
    $(if ($shimPresent) { 'already present' } else { 'added' }))
