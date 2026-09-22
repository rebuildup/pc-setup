[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WingetFile = Join-Path $ScriptDir 'winget-packages.txt'
$StoreFile = Join-Path $ScriptDir 'store-packages.txt'

$Failures = 0
$Warnings = 0

function Write-Ok { param([string]$Message) Write-Host "OK    $Message" }
function Write-Fail { param([string]$Message) Write-Host "FAIL  $Message" -ForegroundColor Red; $script:Failures++ }
function Write-WarnLocal { param([string]$Message) Write-Warning $Message; $script:Warnings++ }

function Get-ManifestLines {
    param([string]$Path)
    Get-Content -LiteralPath $Path | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
}

function Test-WingetId {
    param([string]$Id, [string]$Source = 'winget')
    $output = & winget list --id $Id --exact --source $Source --accept-source-agreements 2>&1
    if ($LASTEXITCODE -eq 0 -and ($output -join "`n") -notmatch 'No installed package found') {
        Write-Ok "$Id installed"
    } else {
        Write-Fail "$Id missing"
    }
}

function Test-CommandPresent {
    param([string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { Write-Ok "$Name -> $($command.Source)" } else { Write-Fail "$Name command missing" }
}

function Get-UninstallDisplayNames {
    $paths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($path in $paths) {
        Get-ItemProperty -Path $path -ErrorAction SilentlyContinue | Where-Object DisplayName | Select-Object -ExpandProperty DisplayName
    }
}

function Test-InstalledDisplayName {
    param([string]$Pattern, [string]$Label)
    if ($script:InstalledDisplayNames | Where-Object { $_ -match $Pattern }) { Write-Ok "$Label installed" } else { Write-Fail "$Label not found in uninstall inventory" }
}

if (-not $IsWindows) { throw 'This verification targets Windows.' }

Write-Host "pc-setup Windows 11 verification`n"

$os = Get-CimInstance Win32_OperatingSystem
if ($os.Caption -match 'Windows 11') { Write-Ok "$($os.Caption) $($os.Version)" } else { Write-Fail "expected Windows 11, found $($os.Caption)" }

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Fail 'winget command missing'
} else {
    foreach ($packageId in Get-ManifestLines -Path $WingetFile) { Test-WingetId -Id $packageId }
    foreach ($line in Get-ManifestLines -Path $StoreFile) {
        $parts = $line.Split('|', 2)
        $name = if ($parts.Count -gt 1) { $parts[1] } else { $parts[0] }
        $output = & winget list --name $name --accept-source-agreements 2>&1
        if ($LASTEXITCODE -eq 0 -and ($output -join "`n") -notmatch 'No installed package found') { Write-Ok "$name installed" } else { Write-Fail "$name missing" }
    }
}

Write-Host "`nCommand capabilities"
foreach ($commandName in @('git','gh','pwsh','code','node','npm','bun','rustup','rustc','cargo','rg','fd','fzf','jq','bat','dotnet')) { Test-CommandPresent -Name $commandName }

$script:InstalledDisplayNames = @(Get-UninstallDisplayNames)

Write-Host "`nVendor-managed child applications"
Test-InstalledDisplayName -Pattern 'After Effects' -Label 'Adobe After Effects'
Test-InstalledDisplayName -Pattern 'Illustrator' -Label 'Adobe Illustrator'
Test-InstalledDisplayName -Pattern '^Cubase' -Label 'Cubase'

if ($script:InstalledDisplayNames | Where-Object { $_ -match 'Steinberg Download Assistant' }) { Write-Ok 'Steinberg Download Assistant installed' } else { Write-WarnLocal 'Steinberg Download Assistant not found; verify manually if Cubase is managed another way' }

Write-WarnLocal 'ChgKey is portable/legacy and must be verified manually together with its active scan-code mapping.'
Write-WarnLocal 'kanata package presence does not prove the intended config/service/autostart state; verify those separately.'

gh auth status *> $null
if ($LASTEXITCODE -eq 0) {
    Write-Ok 'GitHub CLI authenticated'
}
else {
    Write-WarnLocal 'GitHub CLI is not authenticated'
}
if (-not (git config --global --get user.name)) { Write-WarnLocal 'global Git user.name is not configured' }
if (-not (git config --global --get user.email)) { Write-WarnLocal 'global Git user.email is not configured' }

Write-Host "`nResult: $Failures failure(s), $Warnings warning(s)"
if ($Failures -ne 0) { exit 1 }
