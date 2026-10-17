# Makes PowerShell 7 x64 win over a PowerShell 7 x86 copy in the machine PATH.
#
#   powershell-path.ps1            plan: show the resolution order, change nothing
#   powershell-path.ps1 -Apply     reorder the Machine PATH (needs an elevated shell)
#
# Windows resolves Machine PATH before User PATH, so a user-level fix cannot win.
# Only the order of two entries changes: no entry is removed and neither
# PowerShell installation is touched. The previous value is saved first.
[CmdletBinding()]
param([switch]$Apply)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'app-detection.ps1')

$x64 = Join-Path $env:ProgramFiles 'PowerShell\7'
$x86 = Join-Path ${env:ProgramFiles(x86)} 'PowerShell\7'

$key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $false)
$current = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
$kind = $key.GetValueKind('Path')
$key.Close()

Write-Host "pwsh currently resolves to: $((Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source)"
if (-not (Test-Path -LiteralPath (Join-Path $x64 'pwsh.exe'))) {
    Write-Warning "PowerShell 7 x64 not found at $x64; nothing to prefer."
    exit 0
}

$reordered = Get-ReorderedPath -Path $current -Preferred $x64 -Shadowed $x86
if ($reordered -eq $current) {
    Write-Host 'ok      x64 PowerShell already precedes the x86 copy (or no x86 entry exists)'
    exit 0
}

Write-Host "plan    move '$x64' before '$x86' in the Machine PATH (no entry removed)"
if (-not $Apply) {
    Write-Host 'plan only; re-run elevated with -Apply to change it.'
    exit 0
}

$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [Console]::Error.WriteLine('Machine PATH can only be changed from an elevated shell.')
    exit 1
}

$backupDir = Get-PcSetupStateDir
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$backup = Join-Path $backupDir "machine-path-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
Set-Content -LiteralPath $backup -Value $current -Encoding utf8
Write-Host "backup  $backup"

$write = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
$write.SetValue('Path', $reordered, $kind)
$write.Close()
# Broadcast the change so new processes pick it up.
[Environment]::SetEnvironmentVariable('PC_SETUP_PATH_TOUCH', '1', 'User')
[Environment]::SetEnvironmentVariable('PC_SETUP_PATH_TOUCH', $null, 'User')
Write-Host 'applied; open a new shell to use it.'
