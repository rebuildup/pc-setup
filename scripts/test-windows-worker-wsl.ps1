$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Join-Path $PSScriptRoot '../platforms/windows-11/worker'
if (-not (Test-Path "$root/wsl-contract.ps1")) { throw 'WSL worker contract not implemented' }
. "$root/contract.ps1"
. "$root/wsl-contract.ps1"
$parseErrors = $null
Get-ChildItem "$root/*.ps1", $PSCommandPath | ForEach-Object {
    $null = [Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$null,[ref]$parseErrors)
    if ($parseErrors) { throw $parseErrors }
}
function Check($Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Refuses([scriptblock]$Block) {
    $failed = $false
    try { & $Block | Out-Null } catch { $failed = $true }
    Check $failed 'Expected refusal'
}
$id = '2a1084ec-5389-4b0b-a0f0-9a38fcfaece5'
$plan = New-WorkerPlan $id
$location = 'C:\ProgramData\pc-setup-worker-data-' + $id + '\wsl'
$entry = @{ Name = $plan.DistroName; BasePath = $location; Version = 2 }
Assert-WorkerWslInventory @() $plan $location Inventory
Assert-WorkerWslInventory @() $plan $location Import
Assert-WorkerWslInventory @($entry) $plan $location Verify
Refuses { Assert-WorkerWslInventory @($entry) $plan $location Import }
Refuses { Assert-WorkerWslInventory @() $plan $location Verify }
Refuses { Assert-WorkerWslInventory @($entry, $entry) $plan $location Inventory }
Refuses { Assert-WorkerWslInventory @(@{Name='Ubuntu';BasePath=$location;Version=2}) $plan $location Inventory }
Refuses { Assert-WorkerWslInventory @(@{Name=$plan.DistroName;BasePath='C:\foreign';Version=2}) $plan $location Verify }
Refuses { Assert-WorkerWslInventory @(@{Name=$plan.DistroName;BasePath=$location;Version=1}) $plan $location Verify }
Refuses { Assert-WorkerWslInventory @(@{Name=$plan.DistroName;BasePath=$location}) $plan $location Verify }
Assert-WorkerWslInventory @(@{Name=$plan.DistroName;BasePath=('\\?\' + $location + '\');Version=2}) $plan $location Verify
Refuses { ConvertTo-WorkerWslComparablePath 'C:\owned\..\foreign' }
Refuses { ConvertTo-WorkerWslComparablePath '\\server\share' }
Refuses { ConvertTo-WorkerWslComparablePath 'C:\owned:stream' }
$args = @(Get-WorkerWslImportArguments $plan $location 'C:\owned\image.wsl')
Check (($args -join '|') -ceq "--import|$($plan.DistroName)|$location|C:\owned\image.wsl|--version|2") 'Import must target only the exact owned distro/location'
Check ($args -notcontains '--shutdown' -and $args -notcontains '--unregister') 'Destructive WSL operation'
Write-Output 'Windows worker WSL contract tests: PASS'
