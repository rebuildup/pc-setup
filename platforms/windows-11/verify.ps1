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

. (Join-Path $PSScriptRoot 'app-detection.ps1')
. (Join-Path $PSScriptRoot 'visual-studio.ps1')

function Test-CommandPresent {
    param([string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { Write-Ok "$Name -> $($command.Source)" } else { Write-Fail "$Name command missing" }
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

function Resolve-TailscaleCommand {
    $command = Get-Command tailscale -CommandType Application -All -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) {
        return $command
    }

    if ($env:ProgramFiles) {
        $fallback = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
        if (Test-Path -LiteralPath $fallback) {
            return $fallback
        }
    }

    return $null
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
    $appDisplayNames = @(Get-InstalledDisplayNames)
    $appAppxPackages = @(Get-AppxPackage -ErrorAction SilentlyContinue)
    foreach ($app in $inventory.WingetApps) {
        $channel = Get-AppInstallChannel -App $app -DisplayNames $appDisplayNames -AppxPackages $appAppxPackages
        if ($channel) { Write-Ok "$($app.Name) installed ($channel)" } else { Write-Fail "$($app.Name) missing" }
    }

    # Store apps: winget --name can miss an installed MSIX (observed with
    # Microsoft PC Manager), so fall back to the Appx package name.
    foreach ($storeApp in @(
        @{ Name = 'ChatGPT'; AppxName = '' },
        @{ Name = 'Microsoft PC Manager'; AppxName = '^Microsoft\.MicrosoftPCManager$' }
    )) {
        $output = & winget list --name $storeApp.Name --accept-source-agreements 2>&1
        $viaWinget = $LASTEXITCODE -eq 0 -and ($output -join "`n") -notmatch 'No installed package found'
        $viaAppx = $storeApp.AppxName -and [bool]($appAppxPackages | Where-Object { $_.Name -match $storeApp.AppxName })
        if ($viaWinget -or $viaAppx) { Write-Ok "$($storeApp.Name) installed" } else { Write-Fail "$($storeApp.Name) missing" }
    }
}

if (Test-NotionInstalled) {
    Write-Ok 'Notion installed'
}
else {
    Write-Fail 'Notion missing'
}

Write-Host "`nVisual Studio (any edition/year; capabilities, not a product ID)"
$vswhere = Get-VswherePath
if (-not $vswhere) {
    Write-Fail 'vswhere.exe not found; install any Visual Studio edition with the MSVC and Windows SDK components'
}
else {
    $vsInstances = @(Get-VisualStudioStatus -VswherePath $vswhere)
    $vsComplete = @($vsInstances | Where-Object { $_.Missing.Count -eq 0 })
    if ($vsComplete.Count -gt 0) {
        foreach ($vs in $vsComplete) {
            Write-Ok "$($vs.Name) $($vs.Version): MSVC tools and Windows SDK present"
            foreach ($workload in $vs.MissingRecommendedWorkloads) {
                Write-WarnLocal "$($vs.Name): optional workload $workload not installed (not modified; enable it in Visual Studio Installer if a project needs it)"
            }
        }
    }
    else {
        $detail = if ($vsInstances.Count -eq 0) { 'no Visual Studio instance found' } else { ($vsInstances | ForEach-Object { "$($_.Name) lacks: $($_.Missing -join ', ')" }) -join '; ' }
        Write-Fail "no Visual Studio instance has the MSVC tools and Windows SDK ($detail). verify does not change Visual Studio; add the components in Visual Studio Installer."
    }
}

Write-Host "`nRust (rustup is canonical on Windows)"
$rustup = Get-Command rustup -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $rustup) {
    Write-WarnLocal 'rustup not found; install it from https://rustup.rs (mise does not manage Rust on Windows)'
}
else {
    # `rustup run` executes the real toolchain binaries, so a toolchain whose
    # rustc.exe/cargo.exe were removed fails here instead of passing on proxies.
    foreach ($tool in 'rustc', 'cargo') {
        $versionOutput = & $rustup.Source run stable $tool --version 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Ok "rustup stable $tool -> $($versionOutput | Select-Object -First 1)" } else { Write-Fail "rustup stable $tool is broken: $($versionOutput | Select-Object -First 1)" }
    }
    $disabled = (& mise settings get disable_tools 2>$null) -join ' '
    if ($disabled -match 'rust') { Write-Ok 'mise disable_tools includes rust' } else { Write-WarnLocal 'mise disable_tools does not include rust; re-run scripts/apply-global-mise.ps1' }
}

Write-Host "`nTailscale / WSL SSH"
$tailscaleConfig = Import-PowerShellDataFile -LiteralPath (Join-Path $ScriptDir 'tailscale.psd1')
$tailscale = Resolve-TailscaleCommand
if (-not $tailscale) {
    Write-Fail 'Tailscale command missing'
}
else {
    Write-Ok 'Tailscale command available'

    $statusOutput = @(& $tailscale status --json 2>$null)
    if ($LASTEXITCODE -ne 0 -or $statusOutput.Count -eq 0) {
        Write-Fail 'Tailscale status unavailable'
    }
    else {
        try {
            $status = ($statusOutput -join [Environment]::NewLine) | ConvertFrom-Json
            if ($status.BackendState -eq 'Running') {
                Write-Ok 'Tailscale backend running'
            }
            else {
                Write-Fail "Tailscale backend state is $($status.BackendState)"
            }
        }
        catch {
            Write-Fail 'Tailscale status returned invalid JSON'
        }
    }

    $serveStatus = @(& $tailscale serve status 2>$null) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0) {
        Write-Fail 'Tailscale Serve status unavailable'
    }
    else {
        foreach ($mapping in $tailscaleConfig.Tailscale.Serve) {
            $targetPresent = $serveStatus.Contains([string]$mapping.Target)
            $portPresent = $serveStatus.Contains(":$($mapping.ListenPort)")
            if ($targetPresent -and $portPresent) {
                Write-Ok "Tailscale Serve $($mapping.ListenPort) -> $($mapping.Target)"
            }
            else {
                Write-Fail "Tailscale Serve mapping missing for port $($mapping.ListenPort)"
            }
        }
    }
}

Write-Host "`nCommand capabilities"
foreach ($commandName in @(
    'git','gh','infisical','pwsh','code','node','python','pnpm','bun','rustc','cargo',
    'rg','fd','fzf','jq','bat','gdu','shellcheck','nvim',
    'claude','codex','opencode','wt','herdr',
    'gcloud','aws','supabase','vercel','npkill','ocr','cargo-clean-all','dotnet'
)) { Test-CommandPresent -Name $commandName }

$script:InstalledDisplayNames = @(Get-InstalledDisplayNames)

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
