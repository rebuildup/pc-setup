$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Join-Path $PSScriptRoot '../platforms/windows-11/worker'
$parseErrors = $null
Get-ChildItem "$root/*.ps1", $PSCommandPath, (Join-Path $PSScriptRoot 'probe-windows-worker-host.ps1') | ForEach-Object {
    $null = [Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$null,[ref]$parseErrors)
    if ($parseErrors) { throw $parseErrors }
}
if (-not (Test-Path "$root/contract.ps1")) { throw 'Worker contract is not implemented' }
. "$root/contract.ps1"
function Check($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Refuses([scriptblock]$Block) {
    $failed = $false
    try { & $Block | Out-Null } catch { $failed = $true }
    Check $failed 'Expected refusal'
}
$id = 'd333ca8b-a218-488d-a27f-80edb9fe2eb4'
$plan = New-WorkerPlan $id 4 2
Check ($plan.InstanceId -ceq $id) 'Logical UUID changed'
Check ($plan.UserName -ceq 'pcw-d333ca8ba218') 'Account resource name'
Check ($plan.DistroName -ceq "pcw-$id") 'Distro resource name'
Refuses { New-WorkerPlan 'basic' 4 2 }
Refuses { New-WorkerPlan $id.ToUpperInvariant() 4 2 }
Refuses { New-WorkerPlan $id 25 2 }
Refuses { New-WorkerPlan $id 4 0 }
Assert-WorkerCapacity $plan 12 100
Refuses { Assert-WorkerCapacity $plan 5 100 }
Refuses { Assert-WorkerCapacity $plan 12 10 }
$hash = 'a' * 64
Assert-WorkerImage 'https://releases.ubuntu.com/resolute/image.wsl' $hash $hash
Refuses { Assert-WorkerImage 'https://evil.example/image.wsl' $hash $hash }
Refuses { Assert-WorkerImage 'https://releases.ubuntu.com.evil.example/image.wsl' $hash $hash }
Refuses { Assert-WorkerImage 'https://user@releases.ubuntu.com/image.wsl' $hash $hash }
Refuses { Assert-WorkerImage 'http://releases.ubuntu.com/image.wsl' $hash $hash }
Refuses { Assert-WorkerImage 'https://releases.ubuntu.com/image.wsl' $hash ('b' * 64) }
Assert-WorkerIdentity 'S-1-5-21-1-2-3-1002' 'S-1-5-21-1-2-3-1002' @('S-1-5-32-545') @() $plan.DistroName
Refuses { Assert-WorkerIdentity 'S-1-5-21-1-2-3-1002' 'S-1-5-21-1-2-3-1003' @('S-1-5-32-545') @() $plan.DistroName }
Refuses { Assert-WorkerIdentity 'S-1-5-21-1-2-3-1002' 'S-1-5-21-1-2-3-1002' @('S-1-5-32-545','S-1-5-32-544') @() $plan.DistroName }
Refuses { Assert-WorkerIdentity 'S-1-5-21-1-2-3-1002' 'S-1-5-21-1-2-3-1002' @('S-1-5-32-545','S-1-5-21-1-2-3-999') @() $plan.DistroName }
Refuses { Assert-WorkerIdentity 'S-1-5-21-1-2-3-1002' 'S-1-5-21-1-2-3-1002' @('S-1-5-32-545') @('foreign') $plan.DistroName }
$report = @{ Sid = 'S-1-5-21-1-2-3-1002'; Administrator = $false; CanaryPresent = $false; ProtectedReadable = $false; PeerReadable = $false }
Assert-WorkerReport $report 'S-1-5-21-1-2-3-1002'
foreach ($field in @('Administrator','CanaryPresent','ProtectedReadable','PeerReadable')) {
    $bad = $report.Clone(); $bad[$field] = $true
    Refuses { Assert-WorkerReport $bad 'S-1-5-21-1-2-3-1002' }
}
$bad = $report.Clone(); $bad.Sid = 'S-1-5-21-1-2-3-1003'
Refuses { Assert-WorkerReport $bad 'S-1-5-21-1-2-3-1002' }
$bad = $report.Clone(); $bad.Remove('PeerReadable')
Refuses { Assert-WorkerReport $bad 'S-1-5-21-1-2-3-1002' }
$bad = $report.Clone(); $bad.CanaryPresent = 'false'
Refuses { Assert-WorkerReport $bad 'S-1-5-21-1-2-3-1002' }
. "$root/runtime.ps1"
$env:PC_SETUP_CONTROLLER_CANARY = 'unit-test-canary'
try {
    $fakeWindows = [IO.Path]::GetTempPath()
    $fakeExe = Join-Path $fakeWindows 'trusted/pwsh.exe'
    $info = New-CleanWorkerStartInfo $fakeExe '.' $fakeWindows
    Check (-not $info.UseShellExecute) 'Shell launch is forbidden'
    Check (-not $info.Environment.ContainsKey('PC_SETUP_CONTROLLER_CANARY')) 'Canary inherited'
    Check (-not $info.Environment.ContainsKey('USERPROFILE')) 'Controller profile inherited'
    Check ($info.Environment.Count -eq 5) 'Environment must be allowlisted'
    Check ($info.Environment['PSModulePath'] -eq (Join-Path $fakeWindows 'trusted/Modules')) 'User modules inherited'
    Check ($info.Environment['PATH'] -eq (Join-Path $fakeWindows 'System32')) 'Controller PATH inherited'
} finally { Remove-Item Env:/PC_SETUP_CONTROLLER_CANARY }
$config = New-WorkerWslConfig $plan
Check ($config.Contains('memory=4GB') -and $config.Contains('processors=2') -and $config.Contains('localhostForwarding=false')) 'Profile budget differs'
$childAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'child-probe.ps1'),[ref]$null,[ref]$null)
$inventory = $childAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-WorkerRegistryDistroNames' },$true)
Check ($null -ne $inventory) 'Fail-closed registry inventory helper missing'
. ([scriptblock]::Create($inventory.Extent.Text))
Check (@(Get-WorkerRegistryDistroNames { $null }).Count -eq 0) 'Missing registry must mean no distro'
Refuses { Get-WorkerRegistryDistroNames { throw [UnauthorizedAccessException]::new('denied') } }
if ($IsWindows -and [Environment]::Is64BitProcess) {
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('worker-contract-' + [guid]::NewGuid())
    New-Item -ItemType Directory $scratch | Out-Null
    try {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        # ACL tests require elevation to assign Administrators ownership; no accounts are touched.
        if (([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Set-WorkerResourceAcl $scratch $sid Metadata
            Assert-WorkerResourceAcl $scratch $sid Metadata
            Refuses { Assert-WorkerResourceAcl $scratch 'S-1-5-21-1-2-3-1009' Metadata }
            Refuses { Assert-WorkerResourceAcl $scratch $sid Data }
            & {
                $testPaths = @{ Metadata = Join-Path $scratch 'meta'; Data = Join-Path $scratch 'data' }
                function Get-WorkerPaths { $testPaths }
                function Assert-WorkerAdministrator { }
                function Get-WorkerGroupSids { @('S-1-5-32-545') }
                function Get-LocalUser { [pscustomobject]@{ Enabled=$true; SID=[pscustomobject]@{Value=$sid}; Description="pc-setup/windows-worker/v1/$id" } }
                $script:workerTestCreationAttempted = $false
                function New-LocalUser { $script:workerTestCreationAttempted=$true; throw 'TEST ERROR: account creation must never be reached' }
                foreach ($path in $testPaths.Values) { New-Item -ItemType Directory $path | Out-Null }
                Set-WorkerResourceAcl $testPaths.Metadata $sid Metadata
                Set-WorkerResourceAcl $testPaths.Data $sid Data
                $probe = Join-Path $testPaths.Metadata 'child-probe.ps1'
                Write-WorkerNewFile $probe ([IO.File]::ReadAllText("$root/child-probe.ps1")) $sid
                $state = [ordered]@{}
                foreach ($property in $plan.PSObject.Properties) { $state[$property.Name]=$property.Value }
                $state.Sid=$sid; $state.SourceUri='https://releases.ubuntu.com/resolute/image.wsl'
                $image=Join-Path $scratch 'image.wsl'; [IO.File]::WriteAllText($image,'test fixture, not a deployable image')
                $state.Sha256=(Get-FileHash $image).Hash.ToLowerInvariant()
                $state.ProbeHash=(Get-FileHash $probe).Hash
                $manifest=Join-Path $testPaths.Metadata 'manifest.json'
                Write-WorkerNewFile $manifest ($state | ConvertTo-Json) $sid
                $valid=Read-WorkerState $id
                Check ($valid.Sid -ceq $sid) 'Valid owned state refused'
                $repeated=New-WindowsWorker $id (ConvertTo-SecureString 'unit-fixture-only' -AsPlainText -Force) $image $state.SourceUri $state.Sha256
                Check ($repeated.Sid -ceq $sid) 'Idempotent provision changed identity'
                # Same account name with a new SID is never adopted.
                function Get-LocalUser { [pscustomobject]@{ Enabled=$true; SID=[pscustomobject]@{Value='S-1-5-21-1-2-3-9999'}; Description="pc-setup/windows-worker/v1/$id" } }
                Refuses { Read-WorkerState $id }
                function Get-LocalUser { [pscustomobject]@{ Enabled=$true; SID=[pscustomobject]@{Value=$sid}; Description="pc-setup/windows-worker/v1/$id" } }
                [IO.File]::AppendAllText($probe,"`n# drift")
                Refuses { Read-WorkerState $id }
                [IO.File]::WriteAllText($probe,[IO.File]::ReadAllText("$root/child-probe.ps1"))
                $foreign=Join-Path $testPaths.Metadata 'foreign.txt'; [IO.File]::WriteAllText($foreign,'foreign')
                Refuses { Read-WorkerState $id }; Remove-Item -LiteralPath $foreign
                # A foreign/data-only partial attempt is not an invitation to create/reset a user.
                Remove-Item -LiteralPath $manifest,$probe
                Remove-Item -LiteralPath $testPaths.Metadata
                Refuses { New-WindowsWorker $id (ConvertTo-SecureString 'unit-fixture-only' -AsPlainText -Force) $image $state.SourceUri $state.Sha256 }
                Check (-not $script:workerTestCreationAttempted) 'Foreign state reached account creation'
                Remove-Item -LiteralPath $testPaths.Data,$image
                Write-Output 'Windows ACL/state adapter fixture checks passed (no accounts touched)'
            }
        } else {
            Write-Output 'SKIP Windows ACL/state adapter fixtures: elevation required'
        }
    } finally {
        if (@(Get-ChildItem -LiteralPath $scratch -Force).Count) { Write-Warning "Failed fixture preserved for inspection: $scratch" }
        else { Remove-Item -LiteralPath $scratch }
    }
}
Write-Output 'Worker contract checks passed'
