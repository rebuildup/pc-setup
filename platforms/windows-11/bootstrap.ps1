[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$rootBootstrap = Join-Path $repoRoot 'bootstrap.ps1'

if (-not (Test-Path -LiteralPath $rootBootstrap)) {
    throw "missing root bootstrap: $rootBootstrap"
}

& $rootBootstrap
exit $LASTEXITCODE
