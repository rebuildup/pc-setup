[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoUrl = if ($env:PC_SETUP_REPO_URL) { $env:PC_SETUP_REPO_URL } else { 'https://github.com/rebuildup/pc-setup.git' }
$RepoRef = if ($env:PC_SETUP_REF) { $env:PC_SETUP_REF } else { 'main' }
$TargetDir = if ($env:PC_SETUP_DIR) { $env:PC_SETUP_DIR } else { Join-Path $HOME 'src\pc-setup' }

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "`n==> $Message"
}

function Refresh-Path {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machinePath, $userPath) -join ';'
}

function Test-NotionInstalled {
    $wingetOutput = & winget list --id Notion.Notion --exact --accept-source-agreements --disable-interactivity 2>$null
    if ($LASTEXITCODE -eq 0 -and ($wingetOutput -join "`n") -notmatch 'No installed package found') {
        return $true
    }

    $appx = Get-AppxPackage -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'Notion' -or $_.PackageFullName -match 'Notion' } |
        Select-Object -First 1

    return [bool]$appx
}

function Install-NotionMsix {
    if (Test-NotionInstalled) {
        Write-Host 'ok      Notion already installed'
        return
    }

    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    $downloadUrl = switch ($architecture) {
        'X64' { 'https://www.notion.com/desktop/windows-msix/download' }
        'Arm64' { 'https://www.notion.com/desktop/windows-msix-arm/download' }
        default {
            Write-Warning "Notion MSIX auto-install is unsupported on architecture: $architecture"
            return
        }
    }

    Write-Step "Installing Notion from official MSIX ($architecture)"

    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) "notion-$([guid]::NewGuid()).msix"
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempPath -MaximumRedirection 10
        Add-AppxPackage -Path $tempPath -ErrorAction Stop

        if (-not (Test-NotionInstalled)) {
            throw 'Notion MSIX installation returned without a detectable installed package.'
        }

        Write-Host 'ok      Notion installed'
    }
    catch {
        Write-Warning "Notion could not be installed automatically from the official MSIX endpoint: $($_.Exception.Message)"
    }
    finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

function Install-StoreApps {
    $apps = @(
        @{ Id = '9PLM9XGG6VKS'; Name = 'ChatGPT' },
        @{ Id = '9PM860492SZD'; Name = 'Microsoft PC Manager' }
    )

    foreach ($app in $apps) {
        Write-Step "Installing Microsoft Store app: $($app.Name)"
        & winget install --id $app.Id --exact --source msstore --accept-package-agreements --accept-source-agreements --disable-interactivity
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "$($app.Name) could not be installed automatically. Store availability can depend on account/region."
        }
    }
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget is required. Install/update Microsoft App Installer, then rerun bootstrap.ps1.'
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Step 'Installing Git'
    & winget install --id Git.Git --exact --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) { throw "Git installation failed with exit code $LASTEXITCODE" }
    Refresh-Path
}

if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
    Write-Step 'Installing mise'
    & winget install --id jdx.mise --exact --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) { throw "mise installation failed with exit code $LASTEXITCODE" }
    Refresh-Path
}

$mise = Get-Command mise -ErrorAction SilentlyContinue
if (-not $mise) {
    throw 'mise was installed but is not visible on PATH. Open a new PowerShell and rerun bootstrap.ps1.'
}

$profileDir = Split-Path -Parent $PROFILE
if (-not (Test-Path -LiteralPath $profileDir)) {
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $PROFILE)) {
    New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}

$marker = '# >>> pc-setup mise >>>'
if (-not (Select-String -LiteralPath $PROFILE -SimpleMatch $marker -Quiet)) {
    Add-Content -LiteralPath $PROFILE -Value @'

# >>> pc-setup mise >>>
mise activate pwsh | Out-String | Invoke-Expression
# <<< pc-setup mise <<<
'@
}

$scriptPathProperty = $MyInvocation.MyCommand.PSObject.Properties['Path']
$scriptRoot = if ($scriptPathProperty -and $scriptPathProperty.Value) {
    Split-Path -Parent $scriptPathProperty.Value
}
else {
    $null
}

$useLocalCheckout = $false
if ($scriptRoot) {
    $localConfig = Join-Path $scriptRoot 'mise.toml'
    $localGit = Join-Path $scriptRoot '.git'
    $useLocalCheckout = (Test-Path -LiteralPath $localConfig) -and (Test-Path -LiteralPath $localGit)
}

if ($useLocalCheckout) {
    Write-Step 'Applying pc-setup from current checkout'
    $applyDir = $scriptRoot
}
else {
    Write-Step "Preparing pc-setup checkout ($RepoRef)"
    $parent = Split-Path -Parent $TargetDir
    New-Item -ItemType Directory -Path $parent -Force | Out-Null

    if (-not (Test-Path -LiteralPath $TargetDir)) {
        & git clone --branch $RepoRef --single-branch $RepoUrl $TargetDir
        if ($LASTEXITCODE -ne 0) {
            throw "pc-setup clone failed with exit code $LASTEXITCODE"
        }
    }
    elseif (-not (Test-Path -LiteralPath (Join-Path $TargetDir '.git'))) {
        throw "refusing to overwrite non-git path: $TargetDir"
    }
    else {
        $currentOrigin = (& git -C $TargetDir remote get-url origin 2>$null)
        if ($currentOrigin -ne $RepoUrl) {
            throw "existing checkout has unexpected origin: $currentOrigin"
        }

        Write-Step "Updating existing pc-setup checkout to $RepoRef"
        $remoteTrackingRef = "refs/remotes/origin/$RepoRef"
        $fetchRefSpec = "+refs/heads/${RepoRef}:$remoteTrackingRef"
        $configuredFetchSpecs = @(& git -C $TargetDir config --get-all remote.origin.fetch)

        if ($configuredFetchSpecs -notcontains $fetchRefSpec) {
            & git -C $TargetDir config --add remote.origin.fetch $fetchRefSpec
            if ($LASTEXITCODE -ne 0) { throw "git remote fetch configuration failed with exit code $LASTEXITCODE" }
        }

        & git -C $TargetDir fetch origin $fetchRefSpec
        if ($LASTEXITCODE -ne 0) { throw "git fetch failed with exit code $LASTEXITCODE" }

        & git -C $TargetDir show-ref --verify --quiet "refs/heads/$RepoRef"
        $localBranchExists = $LASTEXITCODE -eq 0

        if ($localBranchExists) {
            & git -C $TargetDir switch $RepoRef
        }
        else {
            & git -C $TargetDir switch --track -c $RepoRef "origin/$RepoRef"
        }
        if ($LASTEXITCODE -ne 0) { throw "git switch failed with exit code $LASTEXITCODE" }

        & git -C $TargetDir merge --ff-only "origin/$RepoRef"
        if ($LASTEXITCODE -ne 0) { throw "git fast-forward failed with exit code $LASTEXITCODE" }
    }

    $applyDir = $TargetDir
}

Push-Location $applyDir
try {
    & $mise.Source bootstrap --yes
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
finally {
    Pop-Location
}

Install-NotionMsix
Install-StoreApps
