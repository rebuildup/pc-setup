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
    # `mise bootstrap status` has to read this checkout's mise.toml, and mise
    # refuses an untrusted config. That is fatal here for a reason unrelated to
    # machine state: converge.ps1 runs this script from the deployment checkout,
    # which is a fresh clone that mise has never trusted, so the call failed with
    # "Config files ... are not trusted" on every tick and pcs-setup always
    # reported `verify: fail`. Trusting the path for this read keeps the probe
    # read-only (nothing is written to mise's trust list) and matches the
    # MISE_TRUSTED_CONFIG_PATHS technique the Windows CI job already uses.
    $previousTrusted = $env:MISE_TRUSTED_CONFIG_PATHS
    if ($previousTrusted) {
        if ($previousTrusted -notlike "*$RepoRoot*") { $env:MISE_TRUSTED_CONFIG_PATHS = "$RepoRoot;$previousTrusted" }
    }
    else {
        $env:MISE_TRUSTED_CONFIG_PATHS = [string]$RepoRoot
    }
    try {
        & mise bootstrap status --missing
        if ($LASTEXITCODE -eq 0) { Write-Ok 'mise bootstrap desired state' } else { Write-Fail 'mise bootstrap reports missing machine state' }
    }
    finally {
        if ($null -eq $previousTrusted) { Remove-Item Env:\MISE_TRUSTED_CONFIG_PATHS -ErrorAction SilentlyContinue }
        else { $env:MISE_TRUSTED_CONFIG_PATHS = $previousTrusted }
        Pop-Location
    }
}

# The machine-global config is a rendered copy of this repository's
# mise.global.toml (plus the Windows-only rewrites in
# scripts/windows-mise-config.ps1), and mise reads the copy, not the repository
# file. When the two drift apart, every `mise install` resolves a different tool
# set than the committed desired state while `mise bootstrap status` still only
# reports the tools the *copy* declares -- so a machine can look "converged"
# while installing a version the repository does not specify. Compare the copy
# with a fresh render and report the difference instead of trusting the copy.
function Get-GlobalMiseConfigTarget {
    if ($env:MISE_GLOBAL_CONFIG_FILE) { return $env:MISE_GLOBAL_CONFIG_FILE }
    return (Join-Path (Join-Path (Join-Path $env:USERPROFILE '.config') 'mise') 'config.toml')
}

# mise takes the lockfile name from the config file name: `mise.<env>.toml`
# becomes `mise.<env>.lock` and everything else (including `config.toml`)
# becomes `mise.lock`. Mirrors scripts/apply-global-mise.ps1.
function Get-GlobalMiseLockTarget {
    param([string]$ConfigTarget)
    $name = Split-Path -Leaf $ConfigTarget
    $lockName = if ($name -like 'mise.*.toml') {
        [System.IO.Path]::ChangeExtension($name, '.lock')
    }
    elseif ($name -like '*.local.toml') {
        'mise.local.lock'
    }
    else {
        'mise.lock'
    }
    return (Join-Path (Split-Path -Parent $ConfigTarget) $lockName)
}

function Test-ManagedGlobalMiseConfig {
    $renderer = Join-Path (Join-Path $RepoRoot 'scripts') 'windows-mise-config.ps1'
    $source = Join-Path $RepoRoot 'mise.global.toml'
    if (-not (Test-Path -LiteralPath $source)) {
        Write-WarnLocal "no mise.global.toml in $RepoRoot; machine-global config drift not checked"
        return
    }
    if (-not (Test-Path -LiteralPath $renderer)) {
        Write-WarnLocal "no scripts/windows-mise-config.ps1 in $RepoRoot; machine-global config drift not checked"
        return
    }

    # Only adopted state is authoritative. Run from a feature branch, or from a
    # checkout with uncommitted edits to the declared state, and the comparison
    # says nothing about the machine: the machine is converged to main, not to
    # whatever this checkout happens to contain. Report that case as a warning so
    # working on a branch does not turn the machine report red.
    $isAdopted = $true
    if (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) {
        $branch = (& git -C $RepoRoot symbolic-ref --quiet --short HEAD 2>$null)
        $dirty = @(& git -C $RepoRoot status --porcelain -- mise.global.toml mise.global.lock 2>$null)
        if ($LASTEXITCODE -eq 0 -and $branch -and $branch.Trim() -ne 'main') {
            $isAdopted = $false
            $why = "checkout is on '$($branch.Trim())', not main"
        }
        elseif ($dirty.Count -gt 0) {
            $isAdopted = $false
            $why = 'declared mise state has uncommitted changes'
        }
    }

    $target = Get-GlobalMiseConfigTarget
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Fail "machine-global mise config missing at $target; run scripts/apply-global-mise.ps1"
        return
    }

    # Dot-sourcing is safe: windows-mise-config.ps1 only defines functions.
    . $renderer
    $expected = ConvertTo-WindowsMiseConfig -Text ([System.IO.File]::ReadAllText($source))
    $actual = [System.IO.File]::ReadAllText($target)
    if ($actual -cne $expected) {
        $expectedLines = @($expected -split "`r?`n")
        $actualLines = @($actual -split "`r?`n")
        $drift = @(Compare-Object -ReferenceObject $expectedLines -DifferenceObject $actualLines)
        $sample = @($drift | Select-Object -First 6 | ForEach-Object {
            $side = if ($_.SideIndicator -eq '=>') { 'machine' } else { 'repo' }
            "$side $($_.InputObject)"
        })
        $detail = "machine-global mise config differs from the rendered repository config ($target). " +
            "First differences: " + ($sample -join ' | ')
        if ($isAdopted) {
            Write-Fail ($detail + ' Run scripts/apply-global-mise.ps1.')
        }
        else {
            Write-WarnLocal ($detail + " Not treated as a failure because $why.")
        }
    }
    else {
        Write-Ok 'machine-global mise config matches the rendered repository config'
    }

    # The lock is what `mise install --locked` resolves from. A stale copy pins
    # versions the repository no longer declares.
    $lockSource = Join-Path $RepoRoot 'mise.global.lock'
    $lockTarget = Get-GlobalMiseLockTarget -ConfigTarget $target
    if (-not (Test-Path -LiteralPath $lockSource)) { return }
    if (-not (Test-Path -LiteralPath $lockTarget)) {
        Write-Fail "machine-global mise lock missing at $lockTarget; run scripts/apply-global-mise.ps1"
        return
    }
    $lockExpected = [System.IO.File]::ReadAllText($lockSource)
    $lockActual = [System.IO.File]::ReadAllText($lockTarget)
    if ($lockActual -cne $lockExpected) {
        $detail = "machine-global mise lock differs from the repository lock ($lockTarget)."
        if ($isAdopted) {
            Write-Fail ($detail + ' Run scripts/apply-global-mise.ps1 so `mise install --locked` resolves the committed versions.')
        }
        else {
            Write-WarnLocal ($detail + " Not treated as a failure because $why.")
        }
    }
    else {
        Write-Ok 'machine-global mise lock matches the repository lock'
    }
}

Test-ManagedGlobalMiseConfig

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

Write-Host "`nRust (mise manages Rust on Windows; rustup runs underneath)"
$rustup = Get-Command rustup -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $rustup) {
    Write-Fail 'rustup not found; run scripts/apply-global-mise.ps1 (mise manages Rust on Windows)'
}
else {
    # `rustup run` executes the real toolchain binaries, so a toolchain whose
    # rustc.exe/cargo.exe were removed fails here instead of passing on proxies.
    foreach ($tool in 'rustc', 'cargo') {
        $versionOutput = & $rustup.Source run stable $tool --version 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Ok "rustup stable $tool -> $($versionOutput | Select-Object -First 1)" } else { Write-Fail "rustup stable $tool is broken: $($versionOutput | Select-Object -First 1)" }
    }
    $disabled = (& mise settings get disable_tools 2>$null) -join ' '
    if ($disabled -match 'rust') { Write-Fail 'mise disable_tools includes rust; run scripts/apply-global-mise.ps1 (Rust is mise-managed on Windows)' } else { Write-Ok 'mise does not disable the rust tool' }

    # `cargo:` backend tools are built by `cargo install`, which runs the rustup
    # proxy for rustup's *default* toolchain -- not the toolchain mise selected.
    # core:rust leaves that default unset (or stale), so the cargo: builds can
    # fail with "no default toolchain is configured" or "requires rustc N or
    # newer" while rust itself still looks installed. scripts/apply-global-mise.ps1
    # repairs this, so a mismatch here means the machine needs a re-apply.
    $declaredRust = $null
    foreach ($candidate in (Join-Path (Join-Path (Join-Path $env:USERPROFILE '.config') 'mise') 'config.toml'), (Join-Path $RepoRoot 'mise.global.toml')) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        foreach ($line in [System.IO.File]::ReadAllLines($candidate)) {
            $match = [regex]::Match($line, '^\s*rust\s*=\s*"([^"]+)"')
            if ($match.Success) { $declaredRust = $match.Groups[1].Value; break }
            $inline = [regex]::Match($line, '^\s*rust\s*=\s*\{[^}]*version\s*=\s*"([^"]+)"')
            if ($inline.Success) { $declaredRust = $inline.Groups[1].Value; break }
        }
        if ($declaredRust) { break }
    }
    if ($declaredRust) {
        $defaultOutput = (& mise exec rust -- rustup default 2>&1) -join ' '
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "rustup has no usable default toolchain (mise rust = $declaredRust); run scripts/apply-global-mise.ps1 so cargo: installs can build"
        }
        elseif ($defaultOutput -notmatch "(^|\s)$([regex]::Escape($declaredRust))(-\S+)?(\s|$)") {
            Write-Fail "rustup default toolchain is '$($defaultOutput.Trim())', not mise rust = $declaredRust; run scripts/apply-global-mise.ps1 (cargo: installs build with the default toolchain)"
        }
        else {
            Write-Ok "rustup default toolchain matches mise rust = $declaredRust"
        }
    }
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
    'claude','codex','opencode','devin','wt','herdr',
    'gcloud','aws','supabase','npkill','ocr','cargo-clean-all','dotnet'
)) { Test-CommandPresent -Name $commandName }

Write-Host "`nmise-managed commands resolve to mise (no shadowing copy earlier in PATH)"
$miseRoot = Join-Path $env:LOCALAPPDATA 'mise'
foreach ($commandName in @('node','python','pnpm','bun','cargo','rustc','gh','rg','fd','fzf','jq','nvim','claude','codex','herdr','infisical')) {
    $resolved = Get-Command $commandName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $resolved) { continue }
    if ($resolved.Source.StartsWith($miseRoot, [StringComparison]::OrdinalIgnoreCase)) { Write-Ok "$commandName -> mise" }
    else { Write-Fail "$commandName resolves to $($resolved.Source), not mise; remove that copy (Machine PATH wins over User PATH)" }
}

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
    # The location is restored in `finally`, so no later exception can leak it.
    Push-Location $env:USERPROFILE
    try {
        $miseData = if ($env:MISE_DATA_DIR) { $env:MISE_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'mise' }
        $miseOwnedPattern = '^' + [regex]::Escape($miseData.TrimEnd('\')) + '\\(shims|installs)\\'
        # Command names, not mise keys. platforms/windows-11 CI asserts each name
        # maps to a mise.global.toml [tools] key (with an alias for names such as
        # ripgrep -> rg), so this list cannot silently drift from the config.
        $ownershipTools = @('gh', 'node', 'python', 'nvim', 'rg', 'fd', 'jq', 'bat', 'claude', 'codex', 'opencode', 'devin', 'pi')

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
        $resolveErrFile = Join-Path ([System.IO.Path]::GetTempPath()) "pc-setup-resolve-$([guid]::NewGuid()).err"
        # Assigned before the try blocks so every later read is defined even when
        # resolution or the version read fails (StrictMode would otherwise throw).
        $currentVersions = @{}
        $resolved = @{ activated = @{}; registry = @{} }
        $modeOk = @{ activated = $false; registry = $false }

        try {
            Set-Content -LiteralPath $resolveFile -Value $resolveScript -Encoding UTF8
            $pwshCommand = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $pwshCommand) { throw 'pwsh not found' }
            $pwshForChild = $pwshCommand.Source

            foreach ($mode in 'activated', 'registry') {
                $activate = if ($mode -eq 'activated') { '$true' } else { '$false' }
                # stderr goes to a file: a crashed child must be reported with its
                # exit code, not misread as "every tool is unresolved".
                $lines = @(& $pwshForChild -NoProfile -Command "& '$resolveFile' -Names @($(($ownershipTools | ForEach-Object { "'$_'" }) -join ',')) -Activate $activate" 2>$resolveErrFile)
                $childExit = $LASTEXITCODE
                if ($childExit -ne 0) {
                    $childErr = @(Get-Content -LiteralPath $resolveErrFile -ErrorAction SilentlyContinue | Select-Object -First 3) -join ' | '
                    Write-Fail "tool ownership: the $mode resolution child exited $childExit; no results for this mode. stderr: $childErr"
                    continue
                }
                foreach ($line in $lines) {
                    $parts = ([string]$line) -split '\|'
                    $resolved[$mode][$parts[0]] = @($parts | Select-Object -Skip 1 | Where-Object { $_ })
                }
                $modeOk[$mode] = $true
            }

            try {
                $current = (& mise ls --current --json 2>$null) -join "`n" | ConvertFrom-Json
                foreach ($prop in $current.PSObject.Properties) {
                    $entry = @($prop.Value) | Select-Object -First 1
                    if ($entry -and $entry.PSObject.Properties['version']) { $currentVersions[$prop.Name] = [string]$entry.version }
                }
            }
            catch { Write-WarnLocal "mise ls --current --json could not be read: $($_.Exception.Message)" }

            # Registry (non-activation) resolution is evaluated first and for every
            # name, so a failed activated check can never hide it.
            $shadowing = New-Object System.Collections.Generic.List[string]
            if ($modeOk['registry']) {
                foreach ($name in $ownershipTools) {
                    $registryWinner = $resolved['registry'][$name] | Select-Object -First 1
                    if ($registryWinner -and $registryWinner -notmatch $miseOwnedPattern) {
                        [void]$shadowing.Add("$name -> $registryWinner")
                    }
                    elseif (-not $registryWinner) {
                        [void]$shadowing.Add("$name -> (unresolved without activation)")
                    }
                }
            }

            if ($modeOk['activated']) {
                foreach ($name in $ownershipTools) {
                    $activatedWinner = $resolved['activated'][$name] | Select-Object -First 1
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
                }
            }

            if (-not $modeOk['registry']) {
                # The FAIL above already says why; do not print an OK for unknowns.
            }
            elseif ($shadowing.Count -gt 0) {
                # mise is the single owner (ADR-0025): a non-mise winner is a real
                # defect, not an accepted duplicate, because scheduled tasks, IDEs
                # and GUI launches all take this path. Point at the fix instead of
                # asking the reader to uninstall by hand.
                Write-Fail ("without mise activation (pwsh -NoProfile, Scheduled Task, IDE) these tools resolve outside mise: $($shadowing -join '; '). " +
                    'Removing the redundant Machine PATH entry is what fixes this: pwsh -NoProfile -File platforms/windows-11/mise-path-ownership.ps1 (plan), then -Apply from an elevated shell. Entries that also serve a command mise does not provide are reported as keep and need their own installer removed.')
            }
            else {
                Write-Ok 'every checked tool resolves to mise even without activation'
            }
        }
        catch {
            Write-Fail "tool ownership check failed: $($_.Exception.Message)"
        }
        finally {
            Remove-Item -LiteralPath $resolveFile, $resolveErrFile -ErrorAction SilentlyContinue
        }

        # Rust: report which manager owns the winning cargo/rustc. Only shape is
        # asserted here; the toolchain homes are checked in the Rust section. A
        # machine without cargo/rustc is a tolerated state, so a missing command is
        # skipped (CommandInfo is null-checked before .Source is read).
        foreach ($rustTool in 'cargo', 'rustc') {
            $rustCommand = Get-Command $rustTool -All -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $rustCommand) { continue }
            $rustWinner = $rustCommand.Source
            $owner = if ($rustWinner -match $miseOwnedPattern) { 'mise' } elseif ($rustWinner -match '\\\.cargo\\bin\\') { 'rustup proxy (.cargo\bin)' } else { 'other' }
            Write-Ok "$rustTool wins from $rustWinner (owner: $owner)"
        }

        # Legacy Rust homes are orphaned but inert once RUSTUP_HOME/CARGO_HOME live
        # under the mise data dir; they are retained until a reviewed removal
        # (platforms/windows-11/README.md), so this is informational only.
        foreach ($legacy in (Join-Path $env:USERPROFILE '.rustup'), (Join-Path $env:USERPROFILE '.cargo')) {
            if (Test-Path -LiteralPath $legacy) { Write-WarnLocal "legacy Rust home $legacy is present (informational): retained on purpose; removal procedure in platforms/windows-11/README.md" }
        }

        # Executability, not mere presence. A mise npm install can resolve on PATH
        # and still fail at run time when its internal dependency tree under
        # `node_modules/.mise/<pkg>@<ver>` is incomplete: `Get-Command devin`
        # succeeded while `devin --version` exited with "the devin-win32-x64
        # package is not installed". `mise install` reports such an install as
        # already installed and does not repair it, so this class of breakage goes
        # unnoticed unless the tool is actually executed. Each entry names the
        # mise key so a failure points at the repair (`mise install <key> --force`).
        $executableTools = @(
            @{ key = 'node';        command = 'node';     args = @('--version') },
            @{ key = 'python';      command = 'python';   args = @('--version') },
            @{ key = 'bun';         command = 'bun';      args = @('--version') },
            @{ key = 'pnpm';        command = 'pnpm';     args = @('--version') },
            @{ key = 'gh';          command = 'gh';       args = @('--version') },
            @{ key = 'infisical';   command = 'infisical'; args = @('--version') },
            @{ key = 'claude';      command = 'claude';   args = @('--version') },
            @{ key = 'codex';       command = 'codex';    args = @('--version') },
            @{ key = 'npm:@opencode/cli'; command = 'opencode'; args = @('--version') },
            @{ key = 'npm:devin';   command = 'devin';    args = @('--version') },
            @{ key = 'npm:@earendil-works/pi-coding-agent'; command = 'pi'; args = @('--version') },
            @{ key = 'npm:@deepseek-ai/dsh'; command = 'dsh'; args = @('--version') },
            @{ key = 'npm:playwright'; command = 'playwright'; args = @('--version') },
            @{ key = 'npm:npkill';  command = 'npkill';   args = @('--version') },
            @{ key = 'worktrunk';   command = 'wt';       args = @('--version') },
            @{ key = 'oh-my-pi';    command = 'omp';      args = @('--version') },
            @{ key = 'rust';        command = 'rustc';    args = @('--version') },
            @{ key = 'ripgrep';     command = 'rg';       args = @('--version') },
            @{ key = 'fd';          command = 'fd';       args = @('--version') },
            @{ key = 'jq';          command = 'jq';       args = @('--version') },
            @{ key = 'bat';         command = 'bat';      args = @('--version') },
            @{ key = 'fzf';         command = 'fzf';      args = @('--version') },
            @{ key = 'gdu';         command = 'gdu';      args = @('--version') },
            @{ key = 'shellcheck';  command = 'shellcheck'; args = @('--version') },
            @{ key = 'neovim';      command = 'nvim';     args = @('--version') },
            @{ key = 'github:herdrdev/herdr'; command = 'herdr'; args = @('--version') },
            @{ key = 'github:alibaba/open-code-review'; command = 'ocr'; args = @('--version') },
            @{ key = 'cargo:just';  command = 'just';     args = @('--version') },
            @{ key = 'cargo:tauri-cli'; command = 'cargo-tauri'; args = @('--version') }
        )
        $execBroken = New-Object System.Collections.Generic.List[string]
        foreach ($tool in $executableTools) {
            if (-not (Get-Command $tool.command -CommandType Application -ErrorAction SilentlyContinue)) {
                # A tool this machine does not have is covered by the ownership
                # section above; only an unresolved command is reported here when
                # it should have resolved, so record it and continue.
                [void]$execBroken.Add("$($tool.key): '$($tool.command)' does not resolve")
                continue
            }
            # Run with stderr captured: a launcher that fails prints its reason
            # there, and that reason is the actionable part of the report.
            $previous = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $output = @(& $tool.command @($tool.args) 2>&1)
                $code = $LASTEXITCODE
            }
            finally { $ErrorActionPreference = $previous }
            if ($code -ne 0) {
                $reason = (@($output | Select-Object -First 2) -join ' ') -replace '\s+', ' '
                if ($reason.Length -gt 200) { $reason = $reason.Substring(0, 200) + '...' }
                [void]$execBroken.Add("$($tool.key): '$($tool.command) $($tool.args -join ' ')' exited $code ($reason.Trim())")
            }
        }
        if ($execBroken.Count -eq 0) {
            Write-Ok "every declared tool starts (checked $($executableTools.Count) commands, not just resolution)"
        }
        else {
            foreach ($broken in $execBroken) {
                Write-Fail "declared tool does not run: $broken. A mise npm/cargo install whose internal dependency tree is incomplete still reports as installed and is not repaired by a plain 'mise install'; reinstall that tool with 'mise install <key> --force'."
            }
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
                # Windows PowerShell 5.1 turns native stderr into a terminating
                # error while ErrorActionPreference is Stop, so relax it for this call.
                $previousPreference = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    $whichResult = @(& mise which $shimName 2>&1)
                    $whichExit = $LASTEXITCODE
                }
                finally { $ErrorActionPreference = $previousPreference }
                if ($whichExit -ne 0 -or -not $whichResult) { [void]$orphans.Add($shimName) }
            }
            if ($orphans.Count -gt 0) {
                Write-WarnLocal "orphan mise shims (no active version; declare the tool in mise.global.toml or remove the shim): $($orphans -join ', ')"
            }
            else {
                Write-Ok "no orphan mise shims ($($declaredCargo.Count) cargo: tool(s) active)"
            }
        }
    }
    finally {
        Pop-Location
    }
}

Write-Host "`nResult: $Failures failure(s), $Warnings warning(s)"
if ($Failures -ne 0) { exit 1 }
