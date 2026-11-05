# Install, refresh, or remove the per-user Scheduled Task that runs converge.ps1
# from the deployment checkout (ADR-0016). Same interface as
# platforms/macos/install-converge.sh and platforms/ubuntu-wsl/install-converge.sh.
#
#   install-converge.ps1                       install or refresh
#   install-converge.ps1 -Uninstall            remove the task
#   install-converge.ps1 -ConvergeScript P     run P instead of the deployment copy
#   install-converge.ps1 -Interval SECONDS     repeat interval (default 3600)
#
# The task runs as the current user with RunLevel Limited, so no elevation is
# needed. It only runs while the user is logged on (LogonType Interactive), which
# is what the mise tools and the GitHub credential store need.
#
# Windows PowerShell 5.1 compatible.
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [string]$ConvergeScript,
    [ValidateRange(60, 86400)]
    [int]$Interval = 3600
)

$ErrorActionPreference = 'Stop'

$taskName = 'pc-setup-converge'
$marker = 'managed-by: rebuildup/pc-setup platforms/windows-11/install-converge.ps1'
# Write-Error is terminating under $ErrorActionPreference = 'Stop', which made the
# `exit 1` after it unreachable and left callers reading a stale $LASTEXITCODE. Errors
# are written to stderr directly (same pattern as powershell-path.ps1).
function Stop-WithError {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 1
}

if (-not $env:LOCALAPPDATA) { Stop-WithError 'LOCALAPPDATA is not set; cannot place the pc-setup state directory.' }
$localRoot = Join-Path $env:LOCALAPPDATA 'pc-setup'
# Absolute path: the task starts in System32, so a relative path would be baked in
# and fail on every scheduled run without any visible error (the window is hidden).
$deployDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($(if ($env:PC_SETUP_DEPLOY_DIR) { $env:PC_SETUP_DEPLOY_DIR } else { Join-Path $localRoot "deploy" }))
$repoUrl = if ($env:PC_SETUP_REPO_URL) { $env:PC_SETUP_REPO_URL } else { 'https://github.com/rebuildup/pc-setup.git' }
# DOMAIN\USER from the environment is unreliable on Microsoft/Entra accounts. The
# identity name is what Task Scheduler resolves, for the principal and the logon trigger.
$userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
if (-not $userId) { Stop-WithError 'could not determine the current Windows identity.' }

function Get-ManagedTask {
    Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
}

function Test-ManagedTask {
    param($Task)
    return ($null -ne $Task) -and ([string]$Task.Description).Contains($marker)
}

$existing = Get-ManagedTask

if ($Uninstall) {
    if ($null -eq $existing) {
        Write-Host "not installed: $taskName"
        exit 0
    }
    if (-not (Test-ManagedTask $existing)) {
        Stop-WithError "refusing to remove unmanaged scheduled task: $taskName"
    }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "removed scheduled task $taskName"
    exit 0
}

if ($null -ne $existing -and -not (Test-ManagedTask $existing)) {
    Stop-WithError "refusing to overwrite unmanaged scheduled task: $taskName"
}

if (-not $ConvergeScript) {
    if (-not (Test-Path -LiteralPath (Join-Path $deployDir '.git'))) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $deployDir) | Out-Null
        & git clone --quiet --branch main --single-branch $repoUrl $deployDir
        if ($LASTEXITCODE -ne 0) { Stop-WithError "clone of $repoUrl failed" }
        Write-Host "cloned main into $deployDir"
    }
    $ConvergeScript = Join-Path (Join-Path (Join-Path $deployDir 'platforms') 'windows-11') 'converge.ps1'
}

if (-not (Test-Path -LiteralPath $ConvergeScript)) {
    Stop-WithError "converge script not found: $ConvergeScript. Until the deployment checkout contains platforms/windows-11/converge.ps1, pass -ConvergeScript."
}
$ConvergeScript = (Resolve-Path -LiteralPath $ConvergeScript).Path

$logDir = Join-Path (Join-Path $localRoot 'state') 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$argument = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ConvergeScript + '"'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument

# AtLogOn gives a run per logon; the repetition trigger gives the periodic runs.
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$repeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
    -RepetitionInterval (New-TimeSpan -Seconds $Interval) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $taskName -Action $action `
    -Trigger @($logonTrigger, $repeatTrigger) -Settings $settings -Principal $principal `
    -Description $marker -Force | Out-Null

if ($null -eq $existing) {
    Write-Host "installed scheduled task $taskName (interval ${Interval}s, script $ConvergeScript)"
} else {
    Write-Host "refreshed scheduled task $taskName (interval ${Interval}s, script $ConvergeScript)"
}
Write-Host 'Not started now. To run once: Start-ScheduledTask -TaskName pc-setup-converge'
