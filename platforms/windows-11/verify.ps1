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
        if ($channel) { Write-Ok "$($app.Name) installed ($channel)" }
        elseif (Test-OptionalApp -App $app) { Write-WarnLocal "$($app.Name) is not installed (optional, pending; does not block the development environment)" }
        else { Write-Fail "$($app.Name) missing" }
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

Write-Host "`nPowerShell (WinGet-managed Microsoft.PowerShell is canonical)"
$pwshCommand = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$pwshX64 = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
if (-not (Test-Path -LiteralPath $pwshX64)) {
    Write-Fail "PowerShell 7 x64 not found at $pwshX64"
}
elseif ($pwshCommand -and ($pwshCommand.Source -ne $pwshX64)) {
    Write-WarnLocal "pwsh resolves to $($pwshCommand.Source), not the x64 install. Nothing was removed; run platforms/windows-11/powershell-path.ps1 (plan) and -Apply from an elevated shell, or call $pwshX64 explicitly."
}
else {
    Write-Ok "pwsh -> $pwshX64"
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

    $tailscaleVerdict = 'manual'
    $statusOutput = @(& $tailscale status --json 2>$null)
    if ($LASTEXITCODE -ne 0 -or $statusOutput.Count -eq 0) {
        Write-Fail 'Tailscale status unavailable'
    }
    else {
        try {
            $status = ($statusOutput -join [Environment]::NewLine) | ConvertFrom-Json
            $tailscaleVerdict = Get-TailscaleBackendVerdict -BackendState $status.BackendState
            if ($tailscaleVerdict -eq 'ok') {
                Write-Ok 'Tailscale backend running'
            }
            else {
                # Login, node registration and Serve are manual/secret-backed
                # boundaries (setup-tailscale.ps1); verify only reports them.
                Write-WarnLocal "Tailscale backend state is $($status.BackendState) (pending manual step: authenticate and run setup-tailscale.ps1; the existing node identity is left as is)"
            }
        }
        catch {
            Write-Fail 'Tailscale status returned invalid JSON'
        }
    }

    $serveStatus = @(& $tailscale serve status 2>$null) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0) {
        if ($tailscaleVerdict -eq 'ok') { Write-Fail 'Tailscale Serve status unavailable' } else { Write-WarnLocal 'Tailscale Serve status unavailable (backend is not Running; pending manual step)' }
    }
    else {
        foreach ($mapping in $tailscaleConfig.Tailscale.Serve) {
            $targetPresent = $serveStatus.Contains([string]$mapping.Target)
            $portPresent = $serveStatus.Contains(":$($mapping.ListenPort)")
            if ($targetPresent -and $portPresent) {
                Write-Ok "Tailscale Serve $($mapping.ListenPort) -> $($mapping.Target)"
            }
            else {
                if ($tailscaleVerdict -eq 'ok') { Write-Fail "Tailscale Serve mapping missing for port $($mapping.ListenPort)" }
                else { Write-WarnLocal "Tailscale Serve mapping for port $($mapping.ListenPort) is pending (backend is not Running; configure after the manual authentication step)" }
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
Test-InstalledDisplayName -Pattern $script:CubaseDisplayNamePattern -Label 'Cubase'

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

Write-Host "`nTool ownership (which executable wins, who owns it, which version)"
# Answers three questions for each mise-managed tool, on two resolution paths:
#   1. activated shell (`mise activate pwsh`): the winner must be a mise install or
#      shim, and `mise which` must point at an installed binary.
#   2. non-activation path (`pwsh -NoProfile`, Scheduled Task, IDE, GUI launch):
#      the winner comes from the registry PATH only. A winner outside mise is a
#      known shadowing duplicate; it is reported as WARN with its path and is
#      never removed here (see platforms/windows-11/README.md, "PATH ownership").
# Read-only: nothing is installed, activated in this session, or changed.
$miseCommand = Get-Command mise -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $miseCommand) {
    Write-Fail 'mise not found; cannot verify tool ownership'
}
else {
    # Project mise.toml files in the repo are untrusted from here; ownership is a
    # machine-global question, so every mise call below runs from the home dir.
    Push-Location $env:USERPROFILE
    $miseData = if ($env:MISE_DATA_DIR) { $env:MISE_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'mise' }
    $miseOwnedPattern = '^' + [regex]::Escape($miseData.TrimEnd('\')) + '\\(shims|installs)\\'
    $ownershipTools = @('gh', 'node', 'python', 'nvim', 'rg', 'fd', 'jq', 'bat', 'claude', 'codex', 'opencode', 'pi')

    # Resolve every name in a child pwsh so the result does not depend on how
    # this script was started. The child prints `name|path|path|...` lines.
    $resolveScript = @'
param($Names, $Activate)
Set-Location $env:USERPROFILE
if ($Activate) { mise activate pwsh | Out-String | Invoke-Expression }
else {
    # Rebuild PATH from the registry only: what a Scheduled Task, an IDE or a
    # GUI launch sees. The parent session PATH may already carry mise entries.
    $env:Path = ((
        [Environment]::GetEnvironmentVariable('Path', 'Machine'),
        [Environment]::GetEnvironmentVariable('Path', 'User')
    ) -join ';')
    $env:Path = [Environment]::ExpandEnvironmentVariables($env:Path)
}
foreach ($n in $Names) {
    $all = @(Get-Command $n -All -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
    "$n|" + ($all -join '|')
}
'@
    $resolveFile = Join-Path ([System.IO.Path]::GetTempPath()) "pc-setup-resolve-$([guid]::NewGuid()).ps1"
    try {
        Set-Content -LiteralPath $resolveFile -Value $resolveScript -Encoding UTF8
        $pwshForChild = (Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if (-not $pwshForChild) { throw 'pwsh not found' }
        $resolved = @{}
        foreach ($mode in 'activated', 'registry') {
            $activate = if ($mode -eq 'activated') { '$true' } else { '$false' }
            $lines = & $pwshForChild -NoProfile -Command "& '$resolveFile' -Names @($(($ownershipTools | ForEach-Object { "'$_'" }) -join ',')) -Activate $activate" 2>$null
            $resolved[$mode] = @{}
            foreach ($line in $lines) {
                $parts = $line -split '\|'
                $resolved[$mode][$parts[0]] = @($parts | Select-Object -Skip 1 | Where-Object { $_ })
            }
        }

        $currentVersions = @{}
        try {
            $current = (& mise ls --current --json 2>$null) -join "`n" | ConvertFrom-Json
            foreach ($prop in $current.PSObject.Properties) {
                $entry = @($prop.Value) | Select-Object -First 1
                if ($entry -and $entry.PSObject.Properties['version']) { $currentVersions[$prop.Name] = [string]$entry.version }
            }
        }
        catch { Write-WarnLocal "mise ls --current --json could not be read: $($_.Exception.Message)" }

        $shadowing = New-Object System.Collections.Generic.List[string]
        foreach ($name in $ownershipTools) {
            $activatedWinner = $resolved['activated'][$name] | Select-Object -First 1
            $registryWinner = $resolved['registry'][$name] | Select-Object -First 1
            $whichOutput = (& mise which $name 2>$null | Select-Object -First 1)
            $whichPath = if ($whichOutput) { [string]$whichOutput } else { $null }

            if (-not $activatedWinner) { Write-Fail "$name does not resolve in an activated shell"; continue }
            if ($activatedWinner -notmatch $miseOwnedPattern) {
                Write-Fail "$name wins from $activatedWinner in an activated shell; expected a mise install or shim"
            }
            elseif (-not $whichPath -or -not (Test-Path -LiteralPath $whichPath)) {
                Write-Fail "$name resolves to mise ($activatedWinner) but `mise which $name` has no installed binary"
            }
            else {
                $versionText = ''
                $versionEntry = $currentVersions.Keys | Where-Object { $_ -eq $name -or $_ -match "[:/]$([regex]::Escape($name))$" -or $_ -match "[:/]$([regex]::Escape($name))-" } | Select-Object -First 1
                if ($versionEntry) { $versionText = " (mise $versionEntry $($currentVersions[$versionEntry]))" }
                Write-Ok "$name activated -> $activatedWinner [mise]$versionText"
            }

            if ($registryWinner -and $registryWinner -notmatch $miseOwnedPattern) {
                [void]$shadowing.Add("$name -> $registryWinner")
            }
            elseif (-not $registryWinner) {
                [void]$shadowing.Add("$name -> (unresolved without activation)")
            }
        }
        if ($shadowing.Count -gt 0) {
            Write-WarnLocal "without mise activation (pwsh -NoProfile, Scheduled Task, IDE) these tools resolve outside mise: $($shadowing -join '; '). Retained duplicates are listed in platforms/windows-11/README.md (PATH ownership)."
        }
        else {
            Write-Ok 'every checked tool resolves to mise even without activation'
        }
    }
    catch {
        Write-Fail "tool ownership check failed: $($_.Exception.Message)"
    }
    finally {
        Remove-Item -LiteralPath $resolveFile -ErrorAction SilentlyContinue
    }

    # Rust: report which manager owns the winning cargo/rustc. Only shape is
    # asserted here; the toolchain homes are checked in the Rust section.
    foreach ($rustTool in 'cargo', 'rustc') {
        $rustWinner = (Get-Command $rustTool -All -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if (-not $rustWinner) { continue }
        $owner = if ($rustWinner -match $miseOwnedPattern) { 'mise' } elseif ($rustWinner -match '\\\.cargo\\bin\\') { 'rustup proxy (.cargo\bin)' } else { 'other' }
        Write-Ok "$rustTool wins from $rustWinner (owner: $owner)"
    }

    # Orphan shims: a shim whose tool has no active version fails at run time
    # with "No version is set for shim". Every shim must resolve to an installed tool.
    $shimDir = Join-Path $miseData 'shims'
    if (Test-Path -LiteralPath $shimDir) {
        $declaredCargo = @($currentVersions.Keys | Where-Object { $_ -like 'cargo:*' })
        $orphans = New-Object System.Collections.Generic.List[string]
        foreach ($shim in Get-ChildItem -LiteralPath $shimDir -Filter '*.exe' -ErrorAction SilentlyContinue) {
            $shimName = [System.IO.Path]::GetFileNameWithoutExtension($shim.Name)
            # Capture the whole output before reading the exit code:
            # `Select-Object -First 1` stops the pipeline early and leaves
            # $LASTEXITCODE unreliable.
            $whichResult = @(& mise which $shimName 2>&1)
            $whichExit = $LASTEXITCODE
            if ($whichExit -ne 0 -or -not $whichResult) { [void]$orphans.Add($shimName) }
        }
        if ($orphans.Count -gt 0) {
            Write-WarnLocal "orphan mise shims (no active version; declare the tool in mise.global.toml or remove the shim): $($orphans -join ', ')"
        }
        else {
            Write-Ok "no orphan mise shims ($($declaredCargo.Count) cargo: tool(s) active)"
        }
    }
    Pop-Location
}

Write-Host "`nResult: $Failures failure(s), $Warnings warning(s)"
if ($Failures -ne 0) { exit 1 }
