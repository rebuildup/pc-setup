[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$SourceConfig = Join-Path $RepoRoot 'mise.global.toml'
$SourceLock = if ($env:PC_SETUP_MISE_SOURCE_LOCK_FILE) {
    $env:PC_SETUP_MISE_SOURCE_LOCK_FILE
}
else {
    Join-Path $RepoRoot 'mise.global.lock'
}
$TargetConfig = if ($env:MISE_GLOBAL_CONFIG_FILE) {
    $env:MISE_GLOBAL_CONFIG_FILE
}
else {
    Join-Path $HOME '.config\mise\config.toml'
}
$TargetLock = if ($env:MISE_GLOBAL_LOCK_FILE) {
    $env:MISE_GLOBAL_LOCK_FILE
}
else {
    # mise names a lockfile after the config file it belongs to:
    # `mise.<env>.toml` becomes `mise.<env>.lock`, and everything else,
    # including the default `config.toml`, becomes `mise.lock`.
    # `<config>.lock` is never read, so linking there would leave `--locked`
    # without a lockfile once the update train publishes mise.global.lock.
    $targetConfigName = Split-Path -Leaf $TargetConfig
    $lockName = if ($targetConfigName -like 'mise.*.toml') {
        [System.IO.Path]::ChangeExtension($targetConfigName, '.lock')
    }
    elseif ($targetConfigName -like '*.local.toml') {
        'mise.local.lock'
    }
    else {
        'mise.lock'
    }
    Join-Path (Split-Path -Parent $TargetConfig) $lockName
}
$ManagedMarker = '# Managed by rebuildup/pc-setup.'

if (-not (Test-Path -LiteralPath $SourceConfig)) {
    throw "missing global mise source: $SourceConfig"
}

$targetDir = Split-Path -Parent $TargetConfig
New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

if (Test-Path -LiteralPath $TargetConfig) {
    $firstLine = Get-Content -LiteralPath $TargetConfig -TotalCount 1
    if ($firstLine -ne $ManagedMarker) {
        throw "refusing to overwrite unmanaged mise global config: $TargetConfig"
    }
}

# Windows-only rewrites of the shared machine-global config live in
# scripts/windows-mise-config.ps1 so CI can exercise them directly.
. (Join-Path $PSScriptRoot 'windows-mise-config.ps1')

$targetContent = ConvertTo-WindowsMiseConfig -Text ([System.IO.File]::ReadAllText($SourceConfig))

# The managed marker only proves who wrote the file first. Local edits made
# after that (a tool pinned to another backend, an extra package) would be lost
# by the overwrite below, so keep a timestamped copy whenever content changes.
if (Test-Path -LiteralPath $TargetConfig) {
    $existingContent = [System.IO.File]::ReadAllText($TargetConfig)
    if ($existingContent -ne $targetContent) {
        $backup = "$TargetConfig.pc-setup-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $TargetConfig -Destination $backup
        Write-Host "backup  $backup"
    }
}

[System.IO.File]::WriteAllText($TargetConfig, $targetContent, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "synced  $TargetConfig <- $SourceConfig"

if (Test-Path -LiteralPath $SourceLock) {
    Copy-Item -LiteralPath $SourceLock -Destination $TargetLock -Force
    Write-Host "synced  $TargetLock <- $SourceLock"

    # The lock references its dependency sidecars by a path relative to the
    # lock file (`aube = { path = ".mise/locks/mise.global/<tool>/<version>" }`).
    # On POSIX the lock is a symlink into the repository, so mise resolves those
    # paths against the repository root and finds them. Windows copies the lock
    # instead, so mise resolves them against the copy's directory and every
    # locked install fails with "dependency sidecar ... path not found". Copy
    # the sidecar tree next to the lock to keep both platforms equivalent.
    $SourceSidecars = Join-Path $RepoRoot '.mise'
    $TargetSidecars = Join-Path (Split-Path -Parent $TargetLock) '.mise'
    if (Test-Path -LiteralPath $SourceSidecars) {
        if (Test-Path -LiteralPath $TargetSidecars) {
            Remove-Item -LiteralPath $TargetSidecars -Recurse -Force
        }
        Copy-Item -LiteralPath $SourceSidecars -Destination $TargetSidecars -Recurse -Force
        Write-Host "synced  $TargetSidecars <- $SourceSidecars"
    }
}
elseif (Test-Path -LiteralPath $TargetLock) {
    Remove-Item -LiteralPath $TargetLock -Force
}

# A plain `mise install` resolves every rolling selector (`latest`, `stable`)
# again and rewrites the lock it installs from. The GitHub-token bootstrap
# below and the main install both run `mise install`, so without this every
# apply would replace the committed lock with a freshly re-locked one before
# `--locked` is ever consulted, and the machine would end up installing a
# different tool set from the one this repository pins. MISE_LOCKED=1 makes
# mise treat the lock as read-only for the rest of the run; converge.ps1 sets
# it for the same reason. Only applied when a lock was actually synced, because
# a machine with no committed lock has to be allowed to create one.
$previousMiseLocked = $env:MISE_LOCKED
if (Test-Path -LiteralPath $TargetLock) {
    $env:MISE_LOCKED = '1'
}

function Prepare-MiseGitHubAuth {
    if ($env:MISE_GITHUB_TOKEN -or $env:GITHUB_API_TOKEN -or $env:GITHUB_TOKEN) {
        Write-Host 'ok      mise GitHub authentication provided by environment'
        return
    }

    Push-Location $HOME
    # Windows PowerShell 5.1 turns a native command's stderr into a
    # terminating NativeCommandError while $ErrorActionPreference is 'Stop'.
    # mise reports its progress on stderr, so every native call below has to
    # run with the preference relaxed and is judged by its exit code instead.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # `mise install gh` here is only a bootstrap step for the token lookup.
        # It must not re-lock: a plain `mise install` resolves every `latest`
        # again and rewrites the machine-global lock with all-platform entries,
        # so the `--locked` install below would then resolve from the rewritten
        # file instead of the committed one. MISE_LOCKED=1 makes this run, and
        # the install below, consume the committed lock unchanged.
        & mise install gh
        if ($LASTEXITCODE -ne 0) {
            throw "failed to install gh before GitHub-backed mise tools (exit $LASTEXITCODE)"
        }

        & mise exec gh -- gh auth status --hostname github.com *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'GitHub authentication is required before GitHub-backed tool installation.'
            & mise exec gh -- gh auth login --hostname github.com --git-protocol https --web
            if ($LASTEXITCODE -ne 0) {
                throw "GitHub authentication failed (exit $LASTEXITCODE)"
            }
        }

        $token = (& mise exec gh -- gh auth token --hostname github.com)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
            throw 'gh authentication succeeded but no GitHub token could be resolved for mise.'
        }

        $env:MISE_GITHUB_TOKEN = $token.Trim()
        Remove-Variable token
        Write-Host 'ok      mise GitHub authentication prepared from gh'
    }
    finally {
        $ErrorActionPreference = $previousPreference
        Pop-Location
    }
}

Prepare-MiseGitHubAuth

# `core:rust` installs toolchains through rustup but never sets rustup's
# *default* toolchain: rustup is initialized with `--default-toolchain none`.
# The cargo: backend tools are built by running `cargo install`, and the cargo
# that runs is the rustup proxy, which selects the *default* toolchain -- not the
# `rust = "stable"` toolchain mise selected and exported as RUSTUP_TOOLCHAIN.
# Two broken states follow from that, and both must be repaired:
#
#   * no default at all (a fresh machine): `cargo` fails with
#     "rustup could not choose a version of cargo to run" / "no default
#     toolchain is configured", so every cargo: install fails;
#   * a stale default (this machine had 1.89.0): cargo: installs that need a
#     newer compiler fail with "requires rustc 1.90 or newer".
#
# In both cases `mise ls rust` still reports rust as installed, so the failure
# looks unrelated to rust. Point rustup's default at the declared rust version so
# the cargo: builds and mise agree.
function Set-MiseRustDefault {
    if (-not (Get-Command mise -CommandType Application -ErrorAction SilentlyContinue)) { return }
    # Read the declared rust version from the rendered machine config first, then
    # from the repository source. Only the two shapes this repository uses are
    # understood: `rust = "stable"` and `rust = { version = "..." }`.
    $declared = $null
    $candidates = @($TargetConfig, (Join-Path $RepoRoot 'mise.global.toml'))
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        foreach ($line in [System.IO.File]::ReadAllLines($candidate)) {
            $match = [regex]::Match($line, '^\s*rust\s*=\s*(.+?)\s*$')
            if (-not $match.Success) { continue }
            $value = $match.Groups[1].Value
            $quoted = [regex]::Match($value, '^"([^"]+)"$')
            if ($quoted.Success) { $declared = $quoted.Groups[1].Value; break }
            $inline = [regex]::Match($value, 'version\s*=\s*"([^"]+)"')
            if ($inline.Success) { $declared = $inline.Groups[1].Value; break }
        }
        if ($declared) { break }
    }
    if (-not $declared) { return }

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $HOME
    try {
        # `mise exec rust --` supplies the RUSTUP_HOME/CARGO_HOME and
        # RUSTUP_TOOLCHAIN that core:rust manages, so this never touches a
        # standalone rustup home that mise does not own.
        #
        # A non-zero exit here is NOT a reason to skip the repair: on a fresh
        # machine `rustup default` exits 1 with "no default toolchain is
        # configured", which is exactly the state that has to be fixed. Only the
        # subsequent `rustup default <declared>` decides whether the repair
        # worked.
        $current = (& mise exec rust -- rustup default 2>&1) -join ' '
        if ($LASTEXITCODE -eq 0 -and $current -match "(^|\s)$([regex]::Escape($declared))(-\S+)?(\s|$)") {
            Write-Host "ok      rustup default toolchain is $declared"
            return
        }
        & mise exec rust -- rustup default $declared *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "aligned rustup default toolchain with mise rust = $declared"
        }
        else {
            Write-Host "warn    could not set the rustup default toolchain to $declared (exit $LASTEXITCODE)"
        }
    }
    finally {
        Pop-Location
        $ErrorActionPreference = $previousPreference
    }
}

Set-MiseRustDefault

Push-Location $HOME
$previousPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $installArgs = @('install')
    if (Test-Path -LiteralPath $TargetLock) {
        $installArgs += '--locked'
        Write-Host 'ok      using committed mise global lock'
    }

    & mise @installArgs
    $installExitCode = $LASTEXITCODE

    # On a fresh machine the call above runs while rust is still absent, so
    # `mise exec rust -- rustup default ...` cannot resolve the rust tool and the
    # first Set-MiseRustDefault call is a no-op. core:rust then installs the
    # toolchain but leaves rustup's default unset, so the cargo: builds fail with
    # "no default toolchain is configured" and the whole install exits non-zero
    # even though rust itself is now installed. Align the default now that the
    # toolchain exists and retry once, so a first bootstrap converges in this same
    # run instead of requiring a manual re-run.
    if ($installExitCode -ne 0) {
        Set-MiseRustDefault
        Write-Host 'retrying mise install after aligning the rustup default toolchain'
        & mise @installArgs
        $installExitCode = $LASTEXITCODE
    }
}
finally {
    $ErrorActionPreference = $previousPreference
    Pop-Location
}

# Keep the default aligned on the success path too: a machine whose cargo: tools
# were already built still has to report a rustup default matching the declared
# rust version, so `cargo install` from an ordinary shell behaves the same way.
Set-MiseRustDefault

if ($installExitCode -ne 0) {
    exit $installExitCode
}

Write-Host 'Machine-global mise tools are installed.'
Write-Host 'Native Windows dotfiles linking is not canonical yet; apply dotfiles inside WSL until the Windows link adapter is enabled.'

# Restore the caller's MISE_LOCKED only on a successful run; on failure the
# script exits above and the process ends, so nothing leaks into the caller.
if ($null -eq $previousMiseLocked) {
    Remove-Item Env:\MISE_LOCKED -ErrorAction SilentlyContinue
}
else {
    $env:MISE_LOCKED = $previousMiseLocked
}
