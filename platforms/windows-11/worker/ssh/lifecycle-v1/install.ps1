param(
    [Parameter(Mandatory)][string]$InstanceId,
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][string]$ExpectedCommit,
    [Parameter(Mandatory)][string]$InfisicalSource,
    [Parameter(Mandatory)][string]$ExpectedInstallerSha256
)
$ErrorActionPreference = 'Stop'
if ((Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash -cne $ExpectedInstallerSha256) { throw 'Installer source hash differs from the reviewed value.' }
. (Join-Path $PSScriptRoot 'runtime.ps1')
Install-WorkerGatewayLifecycleV1 $InstanceId $RepositoryRoot $ExpectedCommit $InfisicalSource | ConvertTo-Json -Compress
