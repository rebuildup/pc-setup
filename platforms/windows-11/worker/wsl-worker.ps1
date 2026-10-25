[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare','Inventory','Import','Verify')][string]$Action,
    [Parameter(Mandatory)][string]$InstanceId,
    [string]$ImagePath,
    [SecureString]$Password
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'wsl-runtime.ps1')
if ($Action -eq 'Prepare') { Initialize-WorkerWslStage $InstanceId $ImagePath }
else { Invoke-WorkerWslStage $InstanceId $Password $Action }
