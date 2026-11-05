[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Plan','Capability','Provision','Verify','PrepareProfile','Probe')][string]$Action,
    [string]$InstanceId,
    [SecureString]$Password,
    [string]$ImagePath,
    [string]$SourceUri,
    [string]$Sha256,
    [int]$MemoryGB = 4,
    [int]$Processors = 2,
    [string]$ProtectedFile,
    [string]$PeerInstanceId
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'runtime.ps1')
switch ($Action) {
    Plan { New-WorkerPlan $InstanceId $MemoryGB $Processors }
    Capability { & (Join-Path $PSScriptRoot '../../../scripts/probe-windows-worker-host.ps1') }
    Provision { New-WindowsWorker $InstanceId $Password $ImagePath $SourceUri $Sha256 $MemoryGB $Processors }
    Verify {
        $state = Read-WorkerState $InstanceId
        $state.RegistryInventoryVerified = $false
        $state.DistroVerification = 'Credentialed worker Probe required; unloaded worker HKCU is not inspected here.'
        $state
    }
    PrepareProfile { Invoke-WorkerChild $InstanceId $Password PrepareProfile '' '' }
    Probe { Invoke-WorkerChild $InstanceId $Password Probe $ProtectedFile $PeerInstanceId }
}
