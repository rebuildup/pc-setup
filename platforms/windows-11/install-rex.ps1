[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Install the Rex Windows binary (https://www.superlogical.com/rex) for the
# current user. Rex has no WinGet package; the preview channel JSON at
# blob.superlogical.com is the official artifact index. The user-scope zip is
# extracted under %LOCALAPPDATA%\Programs\Rex (no admin), the directory is
# added to the user PATH, and `rex server install --user` registers the
# HKCU Run entry so the server starts at sign-in. The Windows Service variant
# needs an elevated shell and is a documented manual step instead.
# See docs/adr/ADR-0026.md.

$ReleasesUrl = 'https://blob.superlogical.com/api/releases/rex/preview'
$InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\Rex'

function Write-StepLocal {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "`n==> $Message"
}

function Find-RexExecutable {
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return $null }
    return Get-ChildItem -LiteralPath $Root -Filter 'rex.exe' -Recurse -File -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}

function Get-RexVersion {
    param([Parameter(Mandatory)][string]$RexExe)
    # `rex version` prints "rex <version>" on the first line; --version is not a flag.
    $line = (& $RexExe version 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -eq 0 -and $line -match 'rex\s+(\S+)') { return $Matches[1] }
    return $null
}

$architecture = switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { 'amd64' }
    'ARM64' { 'arm64' }
    default {
        Write-Warning "Rex Windows install is unsupported on architecture: $env:PROCESSOR_ARCHITECTURE"
        return
    }
}

Write-StepLocal "Resolving Rex preview artifacts ($architecture)"
$release = Invoke-RestMethod -Uri $ReleasesUrl -TimeoutSec 30
$artifact = @($release.artifacts | Where-Object {
    $_.os -eq 'windows' -and $_.arch -eq $architecture -and $_.filename -like '*.zip'
}) | Select-Object -First 1

if (-not $artifact) {
    throw "no windows/$architecture zip artifact in the Rex preview release"
}

$existingExe = Find-RexExecutable -Root $InstallRoot
$installedVersion = if ($existingExe) { Get-RexVersion -RexExe $existingExe } else { $null }
if ($installedVersion -and $installedVersion -eq $release.version) {
    Write-Host "ok      Rex $installedVersion already installed ($existingExe)"
}
else {
    Write-StepLocal "Installing Rex $($release.version) for $architecture"
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "rex-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        $zipPath = Join-Path $tempDir $artifact.filename
        Invoke-WebRequest -Uri $artifact.downloadUrl -OutFile $zipPath -TimeoutSec 300
        $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $artifact.sha256.ToLowerInvariant()) {
            throw "SHA-256 mismatch for $($artifact.filename): expected $($artifact.sha256), got $hash"
        }

        $extractDir = Join-Path $tempDir 'extract'
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

        if (Test-Path -LiteralPath $InstallRoot) {
            Remove-Item -LiteralPath $InstallRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
        Copy-Item -Path (Join-Path $extractDir '*') -Destination $InstallRoot -Recurse -Force

        $existingExe = Find-RexExecutable -Root $InstallRoot
        if (-not $existingExe) {
            throw "rex.exe was not found after extracting $($artifact.filename)"
        }

        $newVersion = Get-RexVersion -RexExe $existingExe
        Write-Host "ok      Rex $($newVersion ?? $release.version) installed -> $existingExe"
    }
    finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (-not $existingExe) {
    $existingExe = Find-RexExecutable -Root $InstallRoot
}
if (-not $existingExe) { throw 'rex.exe is missing after install' }
$rexDir = Split-Path -Parent $existingExe

# Keep the user PATH converged: the install dir must resolve rex.exe in new
# shells. Only append when absent; never reorder or remove existing entries.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$pathEntries = @($userPath -split ';' | Where-Object { $_ -ne '' })
if ($pathEntries -notcontains $rexDir) {
    [Environment]::SetEnvironmentVariable('Path', (@($pathEntries) + $rexDir) -join ';', 'User')
    Write-Host "ok      added $rexDir to the user PATH"
}
$env:Path = "$env:Path;$rexDir"

# HKCU Run registration needs no admin; the elevated Windows Service variant is
# a manual step documented in platforms/windows-11/README.md. During the beta
# the server may still require tester enrollment, so a failure here warns
# instead of failing the whole bootstrap.
try {
    & $existingExe server install --user
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "rex server install --user exited $LASTEXITCODE; the Rex server may require beta enrollment. Run it manually after signing in: rex server install --user"
    }
    else {
        Write-Host 'ok      rex server install --user completed'
    }
}
catch {
    Write-Warning "rex server install --user failed: $($_.Exception.Message). Run it manually after signing in: rex server install --user"
}
