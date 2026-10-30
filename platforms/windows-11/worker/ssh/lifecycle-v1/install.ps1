param(
    [Parameter(Mandatory)][string]$InstanceId,
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][string]$ExpectedCommit,
    [Parameter(Mandatory)][string]$InfisicalSource,
    [Parameter(Mandatory)][string]$ExpectedInstallerSha256,
    [switch]$NoExecute
)
$approvedModulePaths=[Collections.Generic.List[string]]::new()
$pwshModules=[IO.Path]::Combine($PSHOME,'Modules')
if([IO.Directory]::Exists($pwshModules)){$approvedModulePaths.Add($pwshModules)}
if($IsWindows){$windowsModules=[IO.Path]::Combine([Environment]::SystemDirectory,'WindowsPowerShell','v1.0','Modules');if([IO.Directory]::Exists($windowsModules)){$approvedModulePaths.Add($windowsModules)}}
[Environment]::SetEnvironmentVariable('PSModulePath',[string]::Join([IO.Path]::PathSeparator,$approvedModulePaths),'Process')
$ErrorActionPreference = 'Stop'
if ((Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash -cne $ExpectedInstallerSha256) { throw 'Installer source hash differs from the reviewed value.' }
. (Join-Path $PSScriptRoot 'runtime.ps1')
if(-not $NoExecute){Install-WorkerGatewayLifecycleV1 $InstanceId $RepositoryRoot $ExpectedCommit $InfisicalSource | ConvertTo-Json -Compress}
