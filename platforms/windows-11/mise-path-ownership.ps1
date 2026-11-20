# Makes mise the single owner of the tools it declares, on Windows.
#
#   mise-path-ownership.ps1                 plan: report what would change, change nothing
#   mise-path-ownership.ps1 -Apply          remove the shadowing entries (needs elevation)
#   mise-path-ownership.ps1 -Restore <file> put a saved PATH back (needs elevation)
#
# The plan also enumerates every PATH entry that supplies a command mise declares.
# A shared directory (Node.js, Chocolatey) keeps a second copy of e.g. `node` or
# `rg` even when removing the whole entry would drop an unrelated tool, so the
# per-entry verdict alone cannot show that duplication.
#
# Why this exists
#   Windows evaluates the Machine PATH before the User PATH, and mise installs its
#   shims into the User PATH (%LOCALAPPDATA%\mise\shims). A Machine-PATH copy of a
#   tool mise declares therefore always wins, so `node`, `gh`, `nvim` and `rg`
#   resolve to the vendor install even though mise manages them. verify.ps1
#   reports that as a failure without offering a way to fix it; this script is
#   that fix.
#
# What it changes
#   Only the *Machine* PATH, and only entries that are proven redundant: an
#   entry is removed only when every executable name it would shadow is declared
#   in mise.global.toml and the same name resolves to a mise shim from the
#   registry PATH. An entry that also provides a tool mise does not manage (for
#   example a vendor directory with several binaries) is left alone and reported,
#   because removing it would silently drop something.
#
# What it does not do
#   It never uninstalls a program, never edits the User PATH, and never deletes a
#   directory. Removing the entry leaves the vendor install in place; re-adding
#   the entry restores the previous resolution order exactly.
#
# Safety
#   The unexpanded Machine PATH is saved to
#   %USERPROFILE%\.local\state\pc-setup\machine-path-<timestamp>.txt before any
#   write, and -Restore reads exactly that file back.
[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$Restore,
    [string]$RepoRoot = '',
    [string]$ConfigFile = '',
    [string]$StateDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$machineKeyPath = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$marker = 'managed-by: rebuildup/pc-setup platforms/windows-11/mise-path-ownership.ps1'

if (-not $StateDir) {
    $StateDir = Join-Path (Join-Path (Join-Path $HOME '.local') 'state') 'pc-setup'
}
if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
if (-not $ConfigFile) {
    $ConfigFile = Join-Path (Join-Path (Join-Path $HOME '.config') 'mise') 'config.toml'
}

function Get-MachinePathRaw {
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($machineKeyPath, $false)
    try {
        $value = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = $key.GetValueKind('Path')
    }
    finally { $key.Close() }
    return [pscustomobject]@{ Value = $value; Kind = $kind }
}

function Split-PathValue {
    param([string]$Value)
    # Keep empty entries out: they are not meaningful here and would make the
    # round-trip noisy. Windows treats an empty entry as the current directory,
    # so this script never introduces one either. The comma operator keeps an
    # empty result an empty array instead of $null.
    return , @($Value -split ';' | Where-Object { $_ -and $_.Trim() })
}

# Reads the tool keys mise declares, so "mise owns this name" is derived from the
# config rather than a hand-maintained list that silently drifts.
function Get-DeclaredNames {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "mise config not found: $Path. Run scripts/apply-global-mise.ps1 first."
    }
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -notmatch '^\s*"?([A-Za-z0-9_.:/\-@]+)"?\s*=') { continue }
        $key = $matches[1]
        if ($key -in 'settings', 'tools', 'bootstrap', 'tasks', 'env') { continue }
        # The command name mise exposes for a key: `ripgrep` -> rg, `neovim` -> nvim,
        # `npm:devin` -> devin, `cargo:just` -> just, `github:...` -> the last segment.
        $name = $null
        if ($key -match '^(npm|cargo|aqua|github|gitlab|vfox|core|pipx|go|gem):(.+)$') {
            $tail = $matches[2]
            $name = ($tail -split '/')[-1]
            if ($name -eq 'cli' -or $name -eq 'tauri-cli') { $name = $null }
        }
        elseif ($key -match '^[a-z0-9\-]+$') {
            $name = $key
        }
        if ($name) { [void]$names.Add($name) }
    }
    # Keys whose command name differs from the key. Kept small and explicit: this
    # is the same alias set verify.ps1 documents for its ownership check.
    $aliases = @{
        'ripgrep' = 'rg'
        'neovim'  = 'nvim'
        'fd'      = 'fd'
        'worktrunk' = 'wt'
        'oh-my-pi' = 'omp'
        'rust'    = 'rustc'
        'node'    = 'node'
    }
    foreach ($k in $aliases.Keys) { if ($names -contains $k) { [void]$names.Add($aliases[$k]) } }
    [void]$names.Add('mise')
    # The comma operator keeps a single-element result an array, so callers can
    # read .Count without StrictMode failing.
    return , @($names | Sort-Object -Unique)
}

function Get-ShimNames {
    param([string]$ShimDir)
    # Returning @() from a function yields $null, not an empty array, so callers
    # that read .Count would fail under StrictMode on a machine without shims.
    # Use the comma operator to emit an empty array as a single value.
    if (-not (Test-Path -LiteralPath $ShimDir)) { return , @() }
    return , @(Get-ChildItem -LiteralPath $ShimDir -Filter '*.exe' -ErrorAction SilentlyContinue |
        ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) } |
        Sort-Object -Unique)
}

# Classifies one PATH entry: does removing it lose anything mise does not own?
#
# The authority is `mise which <name>`, not a guess from the file name. A vendor
# directory often ships more than its headline binary (Neovim's bin also holds
# tee/xxd/win32yank, and those come from the same mise neovim install), so the
# only safe question is "does mise provide this exact command?".
function Get-EntryVerdict {
    param(
        [string]$Entry,
        [string[]]$DeclaredNames,
        [string[]]$ShimNames,
        [hashtable]$Cache
    )
    $expanded = [Environment]::ExpandEnvironmentVariables($Entry).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $expanded)) {
        return [pscustomobject]@{ Entry = $Entry; Kind = 'missing'; Owned = @(); Foreign = @() }
    }
    $owned = New-Object System.Collections.Generic.List[string]
    $foreign = New-Object System.Collections.Generic.List[string]
    foreach ($file in Get-ChildItem -LiteralPath $expanded -File -ErrorAction SilentlyContinue) {
        if ($file.Extension -notin '.exe', '.cmd', '.bat') { continue }
        $name = $file.BaseName
        if (-not $Cache.ContainsKey($name)) {
            $previous = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $resolved = @(& mise which $name 2>&1)
                $Cache[$name] = if ($LASTEXITCODE -ne 0 -or -not $resolved) { $false }
                                else { ([string]$resolved[0]).Trim() }
            }
            catch {
                # A failing probe must mean "mise does not own this name", never an
                # exception: the safe answer keeps the PATH entry.
                $Cache[$name] = $false
            }
            finally { $ErrorActionPreference = $previous }
        }
        $resolvedPath = $Cache[$name]
        if (-not $resolvedPath) { [void]$foreign.Add($name); continue }
        # `mise which tee` resolves through neovim, but coreutils' bin also has
        # `tee`. A command counts as replaceable only when mise resolves to a
        # file with the same name, not merely when mise happens to know the name.
        $resolvedName = [System.IO.Path]::GetFileNameWithoutExtension([string]$resolvedPath)
        if ($resolvedName -ieq $name) { [void]$owned.Add($name) } else { [void]$foreign.Add($name) }
    }
    $kind = if ($owned.Count -eq 0) { 'unrelated' }
            elseif ($foreign.Count -eq 0) { 'fully-redundant' }
            else { 'mixed' }
    return [pscustomobject]@{ Entry = $Entry; Kind = $kind; Owned = @($owned); Foreign = @($foreign) }
}

# Enumerate every executable that supplies a declared command name, in the order
# a fresh process resolves them: Machine PATH first, then User PATH. The verdict
# above classifies whole entries; this finds the remaining copies of a name that
# mise also owns, including copies in entries that must be kept for other tools.
function Get-PathOwners {
    param(
        [string[]]$Names,
        [string[]]$MachineEntries,
        [string]$UserPathValue,
        [string]$ShimDirectory
    )
    $ordered = New-Object System.Collections.ArrayList
    foreach ($entry in $MachineEntries) {
        [void]$ordered.Add([pscustomobject]@{ Entry = $entry; Scope = 'Machine' })
    }
    foreach ($entry in (Split-PathValue -Value $UserPathValue)) {
        [void]$ordered.Add([pscustomobject]@{ Entry = $entry; Scope = 'User' })
    }

    $shimPrefix = $ShimDirectory.TrimEnd('\') + '\'
    # OS binaries (Windows PowerShell, WindowsApps aliases) cannot be uninstalled
    # as a vendor copy, and a PATH can legitimately list the same directory twice.
    # Neither belongs in a report of removable duplicates.
    $systemPrefix = $env:SystemRoot.TrimEnd('\') + '\'
    $found = New-Object System.Collections.ArrayList
    foreach ($name in $Names) {
        $owners = New-Object System.Collections.ArrayList
        $seen = @{}
        foreach ($slot in $ordered) {
            $dir = [Environment]::ExpandEnvironmentVariables($slot.Entry).TrimEnd('\')
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            foreach ($ext in @('.exe', '.cmd', '.bat')) {
                $candidate = Join-Path $dir ($name + $ext)
                if (-not (Test-Path -LiteralPath $candidate)) { continue }
                $key = $candidate.ToLowerInvariant()
                if ($seen.ContainsKey($key)) { break }
                $seen[$key] = $true
                if ($candidate.StartsWith($systemPrefix, [StringComparison]::OrdinalIgnoreCase)) { break }
                [void]$owners.Add([pscustomobject]@{
                    Name   = $name
                    Path   = $candidate
                    Scope  = $slot.Scope
                    Entry  = $slot.Entry
                    IsMise = $candidate.StartsWith($shimPrefix, [StringComparison]::OrdinalIgnoreCase)
                })
                break
            }
        }
        if ($owners.Count -gt 1) {
            [void]$found.Add([pscustomobject]@{ Name = $name; Owners = @($owners) })
        }
    }
    return , @($found)
}

# Best-effort installer lookup, so the report can name an uninstall command
# instead of just a path. A path with no owning registry entry (a stray binary
# in a shared directory) deliberately returns $null.
function Get-InstallSourceForPath {
    param([string]$Path)
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($root in $roots) {
        foreach ($item in (Get-ItemProperty -Path $root -ErrorAction SilentlyContinue)) {
            $locationProp = $item.PSObject.Properties['InstallLocation']
            if (-not $locationProp) { continue }
            $location = [string]$locationProp.Value
            if (-not $location) { continue }
            $expanded = [Environment]::ExpandEnvironmentVariables($location).TrimEnd('\')
            # Uninstall entries that point at the Windows directory are not
            # installers for the tool: matching them produces nonsense commands.
            if ($expanded.StartsWith($env:SystemRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (-not $Path.StartsWith($expanded + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
            $nameProp = $item.PSObject.Properties['DisplayName']
            $uninstallProp = $item.PSObject.Properties['UninstallString']
            return [pscustomobject]@{
                DisplayName = if ($nameProp) { [string]$nameProp.Value } else { '' }
                Uninstall   = if ($uninstallProp) { [string]$uninstallProp.Value } else { '' }
            }
        }
    }
    return $null
}

if ($Restore) {
    if (-not (Test-Path -LiteralPath $Restore)) { throw "restore file not found: $Restore" }
    $identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        [Console]::Error.WriteLine('The Machine PATH can only be changed from an elevated shell.')
        exit 1
    }
    $saved = (Get-Content -LiteralPath $Restore -Raw).TrimEnd("`r", "`n")
    $current = Get-MachinePathRaw
    $backupDir = Join-Path $StateDir 'machine-path-backup'
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $pre = Join-Path $backupDir ("machine-path-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Set-Content -LiteralPath $pre -Value $current.Value -Encoding utf8 -NoNewline
    $write = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($machineKeyPath, $true)
    try { $write.SetValue('Path', $saved, $current.Kind) } finally { $write.Close() }
    [Environment]::SetEnvironmentVariable('PC_SETUP_PATH_TOUCH', '1', 'User')
    [Environment]::SetEnvironmentVariable('PC_SETUP_PATH_TOUCH', $null, 'User')
    Write-Host "restored Machine PATH from $Restore"
    Write-Host "previous value saved to $pre"
    exit 0
}

$declared = Get-DeclaredNames -Path $ConfigFile
$machinePath = Get-MachinePathRaw
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$miseData = if ($env:MISE_DATA_DIR) { $env:MISE_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'mise' }
$shimDir = Join-Path $miseData 'shims'
$shimNames = Get-ShimNames -ShimDir $shimDir

Write-Host "mise declares $($declared.Count) command names; $($shimNames.Count) shims exist in $shimDir"
if ($shimNames.Count -eq 0) {
    Write-Host 'no mise shims found; run scripts/apply-global-mise.ps1 first.'
    exit 0
}
# The classification asks `mise which` per executable, so mise itself has to be
# runnable. A machine without mise is a documented no-op (the plan must stay safe
# to run anywhere), not a crash.
if (-not (Get-Command mise -CommandType Application -ErrorAction SilentlyContinue)) {
    Write-Host 'mise is not on PATH; cannot classify PATH entries. Run scripts/apply-global-mise.ps1 first.'
    exit 0
}

$entries = Split-PathValue -Value $machinePath.Value
$cache = @{}
$verdicts = @($entries | ForEach-Object { Get-EntryVerdict -Entry $_ -DeclaredNames $declared -ShimNames $shimNames -Cache $cache })
$remove = @($verdicts | Where-Object { $_.Kind -eq 'fully-redundant' })
$mixed = @($verdicts | Where-Object { $_.Kind -eq 'mixed' })

Write-Host ''
Write-Host 'Machine PATH entries that shadow mise'
foreach ($v in $verdicts) {
    if ($v.Kind -eq 'fully-redundant') {
        Write-Host ("  remove  {0}  (all of: {1})" -f $v.Entry, ($v.Owned -join ', '))
    }
    elseif ($v.Kind -eq 'mixed') {
        Write-Host ("  keep    {0}  (mise: {1}; not mise: {2})" -f $v.Entry, ($v.Owned -join ', '), ($v.Foreign -join ', '))
    }
}
if ($remove.Count -eq 0 -and $mixed.Count -eq 0) {
    Write-Host '  (none: mise already owns every declared command)'
}
if ($mixed.Count -gt 0) {
    Write-Host ''
    Write-Host 'Entries under "keep" also provide tools mise does not declare, so removing'
    Write-Host 'them would drop those tools. Uninstall the redundant package with its own'
    Write-Host 'installer (winget/choco) if mise should own the shared name.'
}

# Per-name view: a "keep" entry can still leave a second copy of a mise-owned
# executable behind. Report each such name with the owner that wins resolution,
# so the redundant copy can be removed through the package that installed it.
$duplicates = Get-PathOwners -Names $declared -MachineEntries $entries `
    -UserPathValue $userPath -ShimDirectory $shimDir
Write-Host ''
Write-Host 'Command names with more than one owner on PATH'
if ($duplicates.Count -eq 0) {
    Write-Host '  (none)'
}
else {
    foreach ($duplicate in $duplicates) {
        $winner = $duplicate.Owners[0]
        $winnerMark = if ($winner.IsMise) { ' [mise]' } else { '' }
        Write-Host ("  {0,-10} winner: {1}{2}" -f $duplicate.Name, $winner.Path, $winnerMark)
        foreach ($owner in $duplicate.Owners) {
            Write-Host ("      {0,-8} {1}" -f $(if ($owner.IsMise) { 'mise' } else { $owner.Scope }), $owner.Path)
        }
        foreach ($owner in $duplicate.Owners) {
            if ($owner.IsMise) { continue }
            $source = Get-InstallSourceForPath -Path $owner.Path
            if ($source -and $source.Uninstall) {
                Write-Host ("      uninstall {0}: {1}" -f $owner.Path, $source.Uninstall)
            }
        }
    }
    Write-Host ''
    Write-Host 'Several owners are not automatically a shadowing problem: the listed winner'
    Write-Host 'is what a fresh shell resolves. Remove the redundant copy with its own'
    Write-Host 'installer; deleting one binary from a shared vendor directory would leave'
    Write-Host 'that installer and its PATH entry inconsistent. An "uninstall" line is'
    Write-Host 'package-level and removes every command that package provides.'

}

if (-not $Apply) {
    Write-Host ''
    Write-Host ('plan only; re-run elevated with -Apply to remove {0} entr{1}.' -f $remove.Count, $(if ($remove.Count -eq 1) { 'y' } else { 'ies' }))
    exit 0
}

if ($remove.Count -eq 0) { exit 0 }

$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [Console]::Error.WriteLine('The Machine PATH can only be changed from an elevated shell. Re-run this script from an elevated PowerShell.')
    exit 1
}

$backupDir = Join-Path $StateDir 'machine-path-backup'
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$backup = Join-Path $backupDir ("machine-path-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Set-Content -LiteralPath $backup -Value $machinePath.Value -Encoding utf8 -NoNewline
Write-Host ''
Write-Host "backup  $backup"
Write-Host "        ($marker)"
Write-Host "restore pwsh -NoProfile -File $PSCommandPath -Restore `"$backup`""

$removeSet = @{}
foreach ($v in $remove) { $removeSet[$v.Entry] = $true }
$kept = @($entries | Where-Object { -not $removeSet.ContainsKey($_) })
$newValue = ($kept -join ';')

$write = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($machineKeyPath, $true)
try { $write.SetValue('Path', $newValue, $machinePath.Kind) } finally { $write.Close() }

# Broadcast so new processes see the change; existing shells keep their snapshot
# (which is why a stale terminal can keep resolving the removed copy).
[Environment]::SetEnvironmentVariable('PC_SETUP_PATH_TOUCH', '1', 'User')
[Environment]::SetEnvironmentVariable('PC_SETUP_PATH_TOUCH', $null, 'User')

Write-Host ('removed {0} Machine PATH entr{1}; open a new shell, then run platforms/windows-11/verify.ps1' -f $remove.Count, $(if ($remove.Count -eq 1) { 'y' } else { 'ies' }))
