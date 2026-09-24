[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Resolve-Path (Join-Path $ScriptDir '..\..')

$Failures = 0
$Warnings = 0

function Write-Ok { param([string]$Message) Write-Host "OK    $Message" }
function Write-Fail { param([string]$Message) Write-Host "FAIL  $Message" -ForegroundColor Red; $script:Failures++ }
function Write-WarnLocal { param([string]$Message) Write-Warning $Message; $script:Warnings++ }

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

function Test-NotionInstalled {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $wingetOutput = & winget list --id Notion.Notion --exact --accept-source-agreements --disable-interactivity 2>$null
        if ($LASTEXITCODE -eq 0 -and ($wingetOutput -join "`n") -notmatch 'No installed package found') {
            return $true
        }
    }

    $appx = Get-AppxPackage -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'Notion' -or $_.PackageFullName -match 'Notion' } |
        Select-Object -First 1

    return [bool]$appx
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) { throw 'This verification targets Windows.' }

Write-Host "pc-setup Windows 11 verification`n"

$os = Get-CimInstance Win32_OperatingSystem
if ($os.Caption -match 'Windows 11') { Write-Ok "$($os.Caption) $($os.Version)" } else { Write-Fail "expected Windows 11, found $($os.Caption)" }

Test-CommandPresent -Name 'mise'

if (Get-Command mise -ErrorAction SilentlyContinue) {
    Push-Location $RepoRoot
    try {
        & mise bootstrap status --missing
        if ($LASTEXITCODE -eq 0) { Write-Ok 'mise bootstrap desired state' } else { Write-Fail 'mise bootstrap reports missing machine state' }
    }
    finally {
        Pop-Location
    }
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Fail 'winget command missing'
}
else {
    $inventory = Import-PowerShellDataFile -LiteralPath (Join-Path $ScriptDir 'apps.psd1')
    foreach ($app in $inventory.WingetApps) {
        & winget list --id $app.Id --exact --source winget --accept-source-agreements --disable-interactivity *> $null
        if ($LASTEXITCODE -eq 0) { Write-Ok "$($app.Name) installed" } else { Write-Fail "$($app.Name) missing" }
    }

    foreach ($name in @('ChatGPT', 'Microsoft PC Manager')) {
        $output = & winget list --name $name --accept-source-agreements 2>&1
        if ($LASTEXITCODE -eq 0 -and ($output -join "`n") -notmatch 'No installed package found') { Write-Ok "$name installed" } else { Write-Fail "$name missing" }
    }
}

if (Test-NotionInstalled) {
    Write-Ok 'Notion installed'
}
else {
    Write-Fail 'Notion missing'
}

Write-Host "`nCommand capabilities"
foreach ($commandName in @(
    'git','gh','infisical','pwsh','code','node','python','pnpm','bun','rustc','cargo',
    'rg','fd','fzf','jq','bat','shellcheck','nvim',
    'claude','codex','opencode','wt','herdr',
    'gcloud','aws','supabase','vercel','npkill','ocr','cargo-clean-all','dotnet'
)) { Test-CommandPresent -Name $commandName }

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
if (-not (git config --get user.name)) { Write-WarnLocal 'effective Git user.name is not configured' }
if (-not (git config --get user.email)) { Write-WarnLocal 'effective Git user.email is not configured' }

Write-Host "`nResult: $Failures failure(s), $Warnings warning(s)"
if ($Failures -ne 0) { exit 1 }
