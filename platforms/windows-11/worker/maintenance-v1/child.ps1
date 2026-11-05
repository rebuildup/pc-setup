[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Inspect','Apply')][string]$Action,
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$Nonce
)
$approvedModulePaths=[Collections.Generic.List[string]]::new()
$pwshModules=[IO.Path]::Combine($PSHOME,'Modules')
if([IO.Directory]::Exists($pwshModules)){$approvedModulePaths.Add($pwshModules)}
if($IsWindows){$windowsModules=[IO.Path]::Combine([Environment]::SystemDirectory,'WindowsPowerShell','v1.0','Modules');if([IO.Directory]::Exists($windowsModules)){$approvedModulePaths.Add($windowsModules)}}
[Environment]::SetEnvironmentVariable('PSModulePath',[string]::Join([IO.Path]::PathSeparator,$approvedModulePaths),'Process')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $IsWindows -or -not [Environment]::Is64BitProcess){throw 'Native x64 Windows only.'}
. (Join-Path $PSScriptRoot 'contract.ps1')
. (Join-Path $PSScriptRoot 'child-runtime.ps1')
Invoke-WorkerRootMaintenanceChildCore $Action $ManifestPath $Nonce
