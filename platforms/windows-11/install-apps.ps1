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

foreach ($app in $inventory.WingetApps) {
    & winget list --id $app.Id --exact --source winget --accept-source-agreements --disable-interactivity *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "ok      $($app.Name) already installed"
        continue
    }

    Write-Host "`n==> Installing Windows app: $($app.Name)"
    & winget install --id $app.Id --exact --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        Write-Warning "$($app.Name) could not be installed automatically (winget exit $exitCode). Continuing with remaining apps."
    }
}
