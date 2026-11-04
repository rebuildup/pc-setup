# Converge this Windows machine to the adopted state committed on origin/main (ADR-0016).
#
# Thin PowerShell counterpart of scripts/converge.sh. It is not the bash script
# run through Git Bash on purpose: on Windows the machine-global mise config is a
# rendered copy (scripts/apply-global-mise.ps1 + windows-mise-config.ps1), not a
# symlink, and the bash path would create symlinks there. The steps and the rules
# are the same:
#   - consume committed adopted state only: `mise install --locked` via
#     apply-global-mise.ps1, with MISE_LOCKED=1 so mise writes nothing into the lock;
#   - never run `mise upgrade`, `mise lock`, or resolve `latest`;
#   - dirty checkouts are reported and skipped, never reset or stashed;
#   - one run at a time (named mutex), status written to state\status.json.
#
# Runs as the current user (Scheduled Task, see install-converge.ps1). Windows
# PowerShell 5.1 compatible.
#
# Exit codes: 0 converged, 1 a step failed, 3 skipped or pending steps, 75 lock held.
[CmdletBinding()]
param(
    [string]$DeployDir = $(if ($env:PC_SETUP_DEPLOY_DIR) { $env:PC_SETUP_DEPLOY_DIR } else { Join-Path (Join-Path $env:LOCALAPPDATA 'pc-setup') 'deploy' }),
    [string]$RepoUrl = $(if ($env:PC_SETUP_REPO_URL) { $env:PC_SETUP_REPO_URL } else { 'https://github.com/rebuildup/pc-setup.git' }),
    [string]$DotfilesDir = $(if ($env:DOTFILES_DIR) { $env:DOTFILES_DIR } else { Join-Path $env:USERPROFILE '.dotfiles' }),
    [string]$StateDir = $(if ($env:PC_SETUP_STATE_DIR) { $env:PC_SETUP_STATE_DIR } else { Join-Path (Join-Path $env:LOCALAPPDATA 'pc-setup') 'state' })
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 2.0

$script:Steps = New-Object System.Collections.ArrayList
$script:DeployOk = $false
$script:RunStarted = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$script:LogDir = Join-Path $StateDir 'logs'
$script:LogFile = Join-Path $script:LogDir ('converge-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + $PID + '.log')
$script:ConvergeDir = Join-Path $StateDir 'converge'
$script:StatusFile = Join-Path $StateDir 'status.json'
$script:ExitCode = 0

function Get-IsoNow {
    (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Write-Log {
    param([string]$Message)
    Add-Content -LiteralPath $script:LogFile -Value $Message -Encoding UTF8
}

function Add-Step {
    # Detail strings are authored here. Raw tool output goes to the log file.
    param([string]$Step, [string]$Status, [string]$Detail)
    $clean = $Detail -replace "[`t`r`n]", ' '
    [void]$script:Steps.Add([pscustomobject]@{ at = (Get-IsoNow); step = $Step; status = $Status; detail = $clean })
    Write-Host ('{0,-16} {1,-8} {2}' -f $Step, $Status, $clean)
}

# Runs git in a directory and returns the output and exit code. Native stderr is
# captured, not thrown, because the script runs with ErrorActionPreference=Continue.
function Invoke-Git {
    param([string]$Dir, [string[]]$GitArgs)
    $output = & git -C $Dir @GitArgs 2>&1
    $code = $LASTEXITCODE
    foreach ($line in @($output)) { Write-Log ([string]$line) }
    return [pscustomobject]@{ Code = $code; Output = (@($output) | ForEach-Object { [string]$_ }) }
}

function Get-GitValue {
    param([string]$Dir, [string[]]$GitArgs)
    $result = Invoke-Git -Dir $Dir -GitArgs $GitArgs
    if ($result.Code -ne 0) { return '' }
    return (($result.Output | Select-Object -First 1) -as [string]).Trim()
}

function Test-GitDirty {
    param([string]$Dir)
    $result = Invoke-Git -Dir $Dir -GitArgs @('status', '--porcelain')
    return @($result.Output | Where-Object { $_ -ne '' }).Count -gt 0
}

function Sync-Deploy {
    if (-not (Test-Path -LiteralPath $DeployDir)) {
        $parent = Split-Path -Parent $DeployDir
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        $clone = & git clone --quiet --branch main --single-branch $RepoUrl $DeployDir 2>&1
        if ($LASTEXITCODE -eq 0) {
            $script:DeployOk = $true
            Add-Step 'deploy-sync' 'ok' ('cloned main at ' + (Get-GitValue $DeployDir @('rev-parse', '--short', 'HEAD')))
        } else {
            foreach ($line in @($clone)) { Write-Log ([string]$line) }
            Add-Step 'deploy-sync' 'error' ('clone of ' + $RepoUrl + ' failed')
        }
        return
    }
    if (-not (Test-Path -LiteralPath (Join-Path $DeployDir '.git'))) {
        Add-Step 'deploy-sync' 'error' ($DeployDir + ' exists and is not a git checkout')
        return
    }
    $origin = Get-GitValue $DeployDir @('remote', 'get-url', 'origin')
    if ($origin -ne $RepoUrl) {
        Add-Step 'deploy-sync' 'error' ("origin is '" + $origin + "', expected " + $RepoUrl)
        return
    }
    $branch = Get-GitValue $DeployDir @('symbolic-ref', '--quiet', '--short', 'HEAD')
    if ($branch -ne 'main') {
        Add-Step 'deploy-sync' 'error' ("deploy checkout is on '" + $branch + "', expected main")
        return
    }
    # Refuse rather than reset or stash: local edits are someone's work.
    if (Test-GitDirty $DeployDir) {
        Add-Step 'deploy-sync' 'skipped' 'deploy checkout has local changes; not updated and dependent steps skipped'
        return
    }
    $fetch = Invoke-Git -Dir $DeployDir -GitArgs @('fetch', '--quiet', 'origin', 'main')
    if ($fetch.Code -ne 0) {
        Add-Step 'deploy-sync' 'error' 'fetch of origin/main failed'
        return
    }
    $before = Get-GitValue $DeployDir @('rev-parse', 'HEAD')
    $merge = Invoke-Git -Dir $DeployDir -GitArgs @('merge', '--quiet', '--ff-only', 'origin/main')
    if ($merge.Code -ne 0) {
        Add-Step 'deploy-sync' 'error' 'main cannot fast-forward to origin/main'
        return
    }
    $after = Get-GitValue $DeployDir @('rev-parse', 'HEAD')
    $script:DeployOk = $true
    if ($before -eq $after) {
        Add-Step 'deploy-sync' 'ok' ('main at ' + $after.Substring(0, 12) + ', no change')
    } else {
        Add-Step 'deploy-sync' 'ok' ('main ' + $before.Substring(0, 12) + ' -> ' + $after.Substring(0, 12))
    }
}

function Get-LockHash {
    $lock = Join-Path $DeployDir 'mise.global.lock'
    if (-not (Test-Path -LiteralPath $lock)) { return '' }
    return (Get-FileHash -LiteralPath $lock -Algorithm SHA256).Hash
}

function Invoke-MiseApply {
    if (-not $script:DeployOk) {
        Add-Step 'mise-apply' 'skipped' 'deploy checkout not converged in this run'
        return
    }
    $apply = Join-Path (Join-Path $DeployDir 'scripts') 'apply-global-mise.ps1'
    $before = Get-LockHash
    # MISE_LOCKED=1 keeps mise from writing lock-time provenance into the adopted
    # lock (see ADR-0016 and the bash converge). The hash check below is a safety net.
    $env:MISE_LOCKED = '1'
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $apply *>&1 | ForEach-Object { Write-Log ([string]$_) }
        $code = $LASTEXITCODE
    } finally {
        Remove-Item Env:\MISE_LOCKED -ErrorAction SilentlyContinue
    }
    $after = Get-LockHash
    if ($before -ne $after) {
        Add-Step 'adopted-lock' 'error' 'apply changed the adopted mise.global.lock in the deploy checkout; not restored automatically'
    }
    if ($code -eq 0) {
        Add-Step 'mise-apply' 'ok' 'config rendered from deploy checkout; locked install ok'
    } else {
        Add-Step 'mise-apply' 'error' ('apply-global-mise.ps1 exited ' + $code + '; see ' + $script:LogFile)
    }
}

function Invoke-DotfilesSync {
    if ((Test-Path -LiteralPath (Join-Path $DotfilesDir '.git')) -and (Test-GitDirty $DotfilesDir)) {
        Add-Step 'dotfiles-sync' 'skipped' ($DotfilesDir + ' has local changes; sync and link skipped')
        return
    }
    if (-not $script:DeployOk) {
        Add-Step 'dotfiles-sync' 'skipped' 'deploy checkout not converged in this run; sync and link skipped'
        return
    }
    if (Test-Path -LiteralPath (Join-Path $DotfilesDir '.git')) {
        $fetch = Invoke-Git -Dir $DotfilesDir -GitArgs @('fetch', '--quiet', 'origin', 'main')
        $merge = Invoke-Git -Dir $DotfilesDir -GitArgs @('merge', '--quiet', '--ff-only', 'origin/main')
        if ($fetch.Code -ne 0 -or $merge.Code -ne 0) {
            Add-Step 'dotfiles-sync' 'error' 'fetch or fast-forward of dotfiles origin/main failed'
            return
        }
        Add-Step 'dotfiles-sync' 'ok' ('fast-forwarded ' + $DotfilesDir)
    } else {
        Add-Step 'dotfiles-sync' 'error' ($DotfilesDir + ' is not a git checkout; run bootstrap once to clone it')
        return
    }
    $link = Join-Path (Join-Path $DotfilesDir 'script') 'link.ps1'
    if (-not (Test-Path -LiteralPath $link)) {
        Add-Step 'dotfiles-link' 'error' ($link + ' is missing')
        return
    }
    # -Apply is adoption-first in link.ps1: it creates absent links and never
    # replaces an existing file or directory.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $link -Apply *>&1 | ForEach-Object { Write-Log ([string]$_) }
    if ($LASTEXITCODE -eq 0) {
        Add-Step 'dotfiles-link' 'ok' 'link.ps1 -Apply reported success'
    } else {
        Add-Step 'dotfiles-link' 'error' ('link.ps1 exited ' + $LASTEXITCODE + '; see ' + $script:LogFile)
    }
}

function Invoke-Verify {
    if (-not $script:DeployOk) {
        Add-Step 'verify' 'skipped' 'deploy checkout not converged in this run'
        return
    }
    $verify = Join-Path (Join-Path (Join-Path $DeployDir 'platforms') 'windows-11') 'verify.ps1'
    if (-not (Test-Path -LiteralPath $verify)) {
        Add-Step 'verify' 'skipped' 'no verify.ps1 in the deploy checkout'
        return
    }
    # verify checks tools by name (rustc, cargo, ...). The Scheduled Task has no
    # mise activation, so verify runs inside `mise exec`. A missing mise is a
    # documented skip, not a failure. MISE_EXEC_AUTO_INSTALL=0: verify never installs.
    $mise = Get-Command mise -ErrorAction SilentlyContinue
    if (-not $mise) {
        Add-Step 'verify' 'skipped' 'mise not found on PATH; verify not run'
        return
    }
    $env:MISE_EXEC_AUTO_INSTALL = '0'
    try {
        & mise -C $env:USERPROFILE exec -- powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verify *>&1 | ForEach-Object { Write-Log ([string]$_) }
        $code = $LASTEXITCODE
    } finally {
        Remove-Item Env:\MISE_EXEC_AUTO_INSTALL -ErrorAction SilentlyContinue
    }
    if ($code -eq 0) {
        Add-Step 'verify' 'ok' 'verify passed (inside mise exec)'
    } else {
        Add-Step 'verify' 'fail' ('verify exited ' + $code + ' under mise exec; see ' + $script:LogFile)
    }
}

# Reads a property that may be absent (Set-StrictMode 2.0 throws on missing ones).
function Get-JsonField {
    param($Object, [string]$Name)
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

# Every installed mise version with its tool id and install path, from
# `mise ls --json`. Returns $null when mise cannot list. Tool ids come from the
# JSON keys, so install directory names are never translated back into tool ids.
function Get-MiseInstalls {
    $raw = & mise -C $env:USERPROFILE ls --json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
    $tools = (@($raw) -join "`n") | ConvertFrom-Json
    $installs = New-Object System.Collections.ArrayList
    foreach ($prop in $tools.PSObject.Properties) {
        foreach ($entry in @($prop.Value)) {
            $path = [string](Get-JsonField $entry 'install_path')
            if (-not $path) { continue }
            [void]$installs.Add([pscustomobject]@{
                tool   = $prop.Name
                path   = $path.Replace('/', '\').TrimEnd('\')
                active = [bool](Get-JsonField $entry 'active')
            })
        }
    }
    return ,$installs
}

# Stale processes: executables under the mise install tree that belong to a known
# install which is not the active version of its tool. Each executable is matched
# against the install paths longest-prefix-first. An executable under the tree that
# matches no install is unresolved. Detect only; nothing is signalled.
function Get-StaleProcesses {
    $installRoot = (Join-Path (Join-Path $env:LOCALAPPDATA 'mise') 'installs').TrimEnd('\') + '\'
    $installs = Get-MiseInstalls
    if ($null -eq $installs) { throw 'mise ls --json failed; process scan not run' }
    $activeByTool = @{}
    foreach ($i in $installs) { if ($i.active) { $activeByTool[$i.tool] = $i.path } }
    $sorted = @($installs | Sort-Object { $_.path.Length } -Descending)

    $results = New-Object System.Collections.ArrayList
    $procs = Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        $exe = ([string]$p.ExecutablePath).Replace('/', '\')
        if (-not $exe -or -not $exe.StartsWith($installRoot, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $found = $null
        foreach ($i in $sorted) {
            if ($exe.StartsWith($i.path + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $found = $i; break }
        }
        if ($null -eq $found) {
            [void]$results.Add([pscustomobject]@{ kind = 'unresolved'; pid = [int]$p.ProcessId; tool = ''; binary = $exe; detail = 'no mise install matches this path' })
            continue
        }
        $current = $activeByTool[$found.tool]
        if ($null -eq $current) {
            [void]$results.Add([pscustomobject]@{ kind = 'stale'; pid = [int]$p.ProcessId; tool = $found.tool; binary = $exe; detail = ('no active version of ' + $found.tool) })
        } elseif ($found.path -ine $current) {
            [void]$results.Add([pscustomobject]@{ kind = 'stale'; pid = [int]$p.ProcessId; tool = $found.tool; binary = $exe; detail = $current })
        }
    }
    return ,$results
}

function Write-StatusReport {
    param([int]$Exit)
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $drift = & mise outdated 2>$null
    if ($LASTEXITCODE -eq 0) {
        $drift = @($drift | Where-Object { $_ -and $_.ToString().Trim() -ne '' })
        $outdatedCount = $drift.Count
    } else {
        $outdatedCount = -1
    }

    $deployHead = Get-GitValue $DeployDir @('rev-parse', 'HEAD')
    $dotHead = Get-GitValue $DotfilesDir @('rev-parse', 'HEAD')
    $errors = New-Object System.Collections.ArrayList
    # The process scan must never block the report: a failure is recorded as an error.
    $stale = @()
    try {
        $stale = @(Get-StaleProcesses)
    } catch {
        [void]$errors.Add('stale-process-scan: ' + $_.Exception.Message)
    }
    foreach ($s in $script:Steps) {
        if ($s.status -in @('error', 'fail', 'pending', 'skipped')) { [void]$errors.Add($s.step + ': ' + $s.detail) }
    }
    if ($outdatedCount -lt 0) { [void]$errors.Add('mise-outdated: mise outdated failed; drift count unknown') }

    $verifyStep = $script:Steps | Where-Object { $_.step -eq 'verify' } | Select-Object -Last 1
    $verifyObj = $null
    if ($verifyStep) { $verifyObj = [pscustomobject]@{ status = $verifyStep.status; detail = $verifyStep.detail; at = $verifyStep.at } }

    $report = [pscustomobject]@{
        schema          = 1
        platform        = 'windows-11'
        generated_at    = (Get-IsoNow)
        deploy          = [pscustomobject]@{ present = (Test-Path -LiteralPath (Join-Path $DeployDir '.git')); path = $DeployDir; branch = (Get-GitValue $DeployDir @('symbolic-ref', '--quiet', '--short', 'HEAD')); head = $deployHead; dirty = (Test-GitDirty $DeployDir) }
        dotfiles        = [pscustomobject]@{ present = (Test-Path -LiteralPath (Join-Path $DotfilesDir '.git')); path = $DotfilesDir; branch = (Get-GitValue $DotfilesDir @('symbolic-ref', '--quiet', '--short', 'HEAD')); head = $dotHead; dirty = ((Test-Path -LiteralPath (Join-Path $DotfilesDir '.git')) -and (Test-GitDirty $DotfilesDir)) }
        mise            = [pscustomobject]@{ outdated_count = $outdatedCount }
        verify          = $verifyObj
        last_converge   = [pscustomobject]@{ started = $script:RunStarted; finished = (Get-IsoNow); exit = $Exit; log = $script:LogFile; script = $PSCommandPath }
        steps           = @($script:Steps)
        stale_processes = @($stale | Where-Object { $_.kind -eq 'stale' } | ForEach-Object { [pscustomobject]@{ pid = $_.pid; tool = $_.tool; binary = $_.binary; expected_current = $_.detail } })
        unresolved_processes = @($stale | Where-Object { $_.kind -eq 'unresolved' } | ForEach-Object { [pscustomobject]@{ pid = $_.pid; binary = $_.binary; reason = $_.detail } })
        errors          = @($errors)
    }

    $tmp = $script:StatusFile + '.tmp'
    $json = $report | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($tmp, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $script:StatusFile -Force
}

function Invoke-Main {
    New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
    New-Item -ItemType Directory -Force -Path $script:ConvergeDir | Out-Null
    Set-Content -LiteralPath $script:LogFile -Value ('converge started ' + $script:RunStarted) -Encoding UTF8

    Sync-Deploy
    Invoke-MiseApply
    Invoke-DotfilesSync
    Invoke-Verify

    $hasError = @($script:Steps | Where-Object { $_.status -in @('error', 'fail') }).Count -gt 0
    $hasSkip = @($script:Steps | Where-Object { $_.status -in @('skipped', 'pending') }).Count -gt 0
    if ($hasError) { $script:ExitCode = 1 } elseif ($hasSkip) { $script:ExitCode = 3 } else { $script:ExitCode = 0 }
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\pc-setup-converge')
$owned = $false
try {
    $owned = $mutex.WaitOne(0)
    if (-not $owned) {
        Write-Host 'another converge run holds the lock'
        $script:ExitCode = 75
    } else {
        Invoke-Main
        Write-StatusReport -Exit $script:ExitCode
    }
} finally {
    if ($owned) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
exit $script:ExitCode
