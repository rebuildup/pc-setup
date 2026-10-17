[CmdletBinding()]
param(
    [string]$InventoryPath = (Join-Path $PSScriptRoot 'apps.psd1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget is required to install Windows desktop applications.'
}

$inventory = Import-PowerShellDataFile -LiteralPath $InventoryPath

. (Join-Path $PSScriptRoot 'app-detection.ps1')

$displayNames = @(Get-InstalledDisplayNames)
$appxPackages = @(Get-AppxPackage -ErrorAction SilentlyContinue)
$pendingApps = Get-PendingApps

foreach ($app in $inventory.WingetApps) {
    $channel = Get-AppInstallChannel -App $app -DisplayNames $displayNames -AppxPackages $appxPackages
    if ($channel) {
        Write-Host "ok      $($app.Name) already installed ($channel)"
        continue
    }

    $optional = Test-OptionalApp -App $app
    if ($optional -and $pendingApps.ContainsKey($app.Id)) {
        Write-Host "pending $($app.Name) (optional; previous install failed: $($pendingApps[$app.Id].Reason). Remove its entry from pending-apps.json to retry)"
        continue
    }

    Write-Host "`n==> Installing Windows app: $($app.Name)"
    & winget install --id $app.Id --exact --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        Write-Warning "$($app.Name) could not be installed automatically (winget exit $exitCode). Continuing with remaining apps."
        if ($optional) {
            Add-PendingApp -Id $app.Id -Reason "winget exit $exitCode"
            Write-Host "pending $($app.Name) recorded; it will not be retried automatically"
        }
    }
}
