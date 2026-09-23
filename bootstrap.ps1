[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoUrl = if ($env:PC_SETUP_REPO_URL) { $env:PC_SETUP_REPO_URL } else { 'https://github.com/rebuildup/pc-setup.git' }
$RepoRef = if ($env:PC_SETUP_REF) { $env:PC_SETUP_REF } else { '1' }
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

$scriptRoot = $null
if ($MyInvocation.MyCommand.Path) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
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

Install-StoreApps
