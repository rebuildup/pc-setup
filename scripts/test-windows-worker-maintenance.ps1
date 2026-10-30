$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$workerRoot=Join-Path $PSScriptRoot '../platforms/windows-11/worker'
$maintenanceRoot=Join-Path $workerRoot 'maintenance-v1'
. (Join-Path $workerRoot 'contract.ps1')
. (Join-Path $maintenanceRoot 'contract.ps1')
. (Join-Path $maintenanceRoot 'runtime.ps1')

$mise=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../mise.toml') -Raw
$misePackages=@([regex]::Matches($mise,'(?m)^\s*"apt:([^"\r\n]+)"\s*=\s*\{\s*os\s*=\s*"linux"\s*\}')|ForEach-Object{$_.Groups[1].Value})
$scriptText=Get-Content -LiteralPath (Join-Path $maintenanceRoot 'root-maintenance.sh') -Raw
$pinnedHash=[regex]::Match((Get-Content -LiteralPath (Join-Path $maintenanceRoot 'runtime.ps1') -Raw),"WorkerRootMaintenanceScriptHash='([A-F0-9]{64})'")
if(-not $pinnedHash.Success -or (Get-FileHash (Join-Path $maintenanceRoot 'root-maintenance.sh') -Algorithm SHA256).Hash -cne $pinnedHash.Groups[1].Value){throw 'Root maintenance source does not match the reviewed SHA256 pin.'}
$packageBlock=[regex]::Match($scriptText,'(?s)packages=\(\s*(.*?)\s*\)')
if(-not $packageBlock.Success){throw 'Root maintenance package allowlist missing.'}
$scriptPackages=@($packageBlock.Groups[1].Value -split '\s+'|Where-Object{$_ -and $_ -notmatch '^#'})
$contractPackages=@(Get-WorkerRootMaintenancePackages)
if(($misePackages -join ',') -cne ($scriptPackages -join ',') -or ($misePackages -join ',') -cne ($contractPackages -join ',')){throw 'Root maintenance package list differs from mise.toml OS baseline.'}

$plan=New-WorkerPlan '2a1084ec-5389-4b0b-a0f0-9a38fcfaece5'
$nonce='0123456789abcdef0123456789abcdef'
$rootArgs=Get-WorkerRootMaintenanceArguments $plan Inspect $nonce
if(($rootArgs -join ' ') -cne "--distribution $($plan.DistroName) --user root --exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C /bin/bash -s -- Inspect $($plan.InstanceId) $nonce"){throw 'Root maintenance argv is not fixed to exact distro/root/env/script/action.'}
function Refuses([scriptblock]$Body){$denied=$false;try{& $Body|Out-Null}catch{$denied=$true};if(-not $denied){throw 'Expected root maintenance contract refusal.'}}
Refuses {Get-WorkerRootMaintenanceArguments $plan Inspect 'invalid'}
$csv=$contractPackages -join ','
$report=ConvertFrom-WorkerRootMaintenanceReport "action=Inspect`ninstance=$($plan.InstanceId)`nnonce=$nonce`nuid=0`npackages=$csv`nmissing=git`n" Inspect $plan.InstanceId $nonce
if($report.Complete -or $report.Missing.Count -ne 1 -or $report.Missing[0] -cne 'git'){throw 'Root maintenance inspect parser lost missing package state.'}
$complete=ConvertFrom-WorkerRootMaintenanceReport "action=Apply`ninstance=$($plan.InstanceId)`nnonce=$nonce`nuid=0`npackages=$csv`nmissing=`n" Apply $plan.InstanceId $nonce
if(-not $complete.Complete){throw 'Root maintenance apply report did not prove complete baseline.'}
Refuses {ConvertFrom-WorkerRootMaintenanceReport "action=Apply`ninstance=$($plan.InstanceId)`nnonce=$nonce`nuid=0`npackages=$csv`nmissing=git`n" Apply $plan.InstanceId $nonce}
Refuses {ConvertFrom-WorkerRootMaintenanceReport "action=Inspect`ninstance=$($plan.InstanceId)`nnonce=$nonce`nuid=0`npackages=$csv,unapproved`nmissing=`n" Inspect $plan.InstanceId $nonce}
Refuses {ConvertFrom-WorkerRootMaintenanceReport "action=Inspect`ninstance=$($plan.InstanceId)`nnonce=$nonce`nuid=0`npackages=$csv`nmissing=`nextra=x`n" Inspect $plan.InstanceId $nonce}
if($IsWindows){
    $registration=[pscustomobject]@{Name=$plan.DistroName;Version=2;BasePath='C:\ProgramData\pcw-wsl'}
    Assert-WorkerRootMaintenanceRegistration @($registration) $plan 'C:\ProgramData\pcw-wsl'|Out-Null
    Refuses {Assert-WorkerRootMaintenanceRegistration @($registration) $plan 'C:\ProgramData\different'}
}

$scriptPath=Join-Path $maintenanceRoot 'root-maintenance.sh'
$bash=if($IsWindows){Join-Path $env:ProgramW6432 'Git/bin/bash.exe'}else{(Get-Command bash -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source}
if(-not(Test-Path -LiteralPath $bash)){throw 'Git Bash/Bash executable is required for the root maintenance syntax test.'}
& $bash -n $scriptPath
if($LASTEXITCODE -ne 0){throw 'Root maintenance Bash syntax check failed.'}
$operationalScript=($scriptText -split "`r?`n"|Where-Object{$_ -notmatch '^\s*#'}) -join "`n"
if($operationalScript -match '(?i)\bsudo\b|apt(-get)?\s+(full-upgrade|upgrade|remove|purge|autoremove)|\b(mise|npm|pip|cargo)\b|curl\s+https?://|/home/worker|~\/') {throw 'Root maintenance includes an unapproved runtime/user-scope operation.'}
foreach($required in @('apt-get update','apt-get -s --no-install-recommends --no-upgrade install','grep -Eq ''^(Inst [^[:space:]]+ \[[^]]+\] \(|Remv )''','apt-get install -y --no-install-recommends --no-upgrade')){if($scriptText -cnotmatch [regex]::Escape($required)){throw "Root maintenance fixed boundary missing: $required"}}

foreach($path in @((Join-Path $maintenanceRoot 'runtime.ps1'),(Join-Path $maintenanceRoot 'child.ps1'),(Join-Path $maintenanceRoot 'child-runtime.ps1'),(Join-Path $maintenanceRoot 'contract.ps1'))){
    $tokens=$null;$errors=$null
    [Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)|Out-Null
    if($errors){throw "Root maintenance PowerShell syntax error: $path"}
}
$runtimeText=Get-Content (Join-Path $maintenanceRoot 'runtime.ps1') -Raw
$childText=Get-Content (Join-Path $maintenanceRoot 'child.ps1') -Raw
$childRuntimeText=Get-Content (Join-Path $maintenanceRoot 'child-runtime.ps1') -Raw
$contractText=Get-Content (Join-Path $maintenanceRoot 'contract.ps1') -Raw
foreach($required in @('Initialize-WorkerRootMaintenanceStage','Invoke-WorkerRootMaintenanceV1','SourceCommit','RootScriptHash','Read-WorkerWslStage')){if($runtimeText -notmatch [regex]::Escape($required) -and $childText -notmatch [regex]::Escape($required)){throw "Root maintenance implementation missing: $required"}}
if($contractText -notmatch 'Assert-WorkerRootMaintenanceRegistration' -or $contractText -notmatch 'Get-WorkerRootMaintenanceWslConfig' -or $childRuntimeText -notmatch 'Assert-WorkerRootMaintenanceRegistration'){throw 'Root maintenance must validate the exact enrolled WSL registry path and worker profile.'}
if(-not $contractText.Contains('$process.StandardInput.Write($ScriptText)') -or -not $childRuntimeText.Contains('Invoke-WorkerRootMaintenanceWslScript (Get-WorkerRootMaintenanceWslExecutable) $plan $Action $Nonce $scriptText') -or -not $contractText.Contains("'--user','root'") -or -not $contractText.Contains("'/bin/bash','-s'")){throw 'Root maintenance must pipe only the fixed staged script through stdin to the exact WSL distro.'}

# Exercise real initialization/readback and child launch preparation from a clean
# PowerShell process. Only Windows identity/ACL/WSL boundaries are replaced.
$fixtureBase=Join-Path ([IO.Path]::GetTempPath()) ('pc-setup-root-maintenance-call-'+[guid]::NewGuid().ToString('N'))
$fixtureMetadata=Join-Path $fixtureBase 'worker-metadata';$fixtureData=Join-Path $fixtureBase 'worker-data'
foreach($directory in @($fixtureBase,$fixtureMetadata,$fixtureData)){[void](New-Item -ItemType Directory -Path $directory -Force)}
$harness=Join-Path $fixtureBase 'fresh-call-path.ps1';$mockWsl=Join-Path $fixtureBase 'mock-wsl.ps1'
$fixtureWorkerManifest=[ordered]@{InstanceId='2a1084ec-5389-4b0b-a0f0-9a38fcfaece5';Sid='S-1-5-21-1-2-3-1000';MemoryGB=4;Processors=2}|ConvertTo-Json -Compress
[IO.File]::WriteAllText((Join-Path $fixtureMetadata 'manifest.json'),$fixtureWorkerManifest,[Text.UTF8Encoding]::new($false))
[void](New-Item -ItemType Directory -Path (Join-Path $fixtureBase 'worker-profile') -Force)
[IO.File]::WriteAllText((Join-Path $fixtureBase 'worker-profile/.wslconfig'),"[wsl2]`nmemory=4GB`nprocessors=2`nswap=1GB`nlocalhostForwarding=false`n",[Text.UTF8Encoding]::new($false))
@'
param([string]$Action,[string]$InstanceId,[string]$Nonce,[string]$Packages)
$stdin=[Console]::In.ReadToEnd()
if($stdin -notmatch '(?m)^#!/usr/bin/env bash$' -or $stdin -notmatch 'apt-get -s --no-install-recommends --no-upgrade install'){exit 71}
Write-Output "action=$Action`ninstance=$InstanceId`nnonce=$Nonce`nuid=0`npackages=$Packages`nmissing="
'@|Set-Content -LiteralPath $mockWsl -Encoding utf8
@'
param([string]$RepositoryRoot,[string]$FixtureBase,[string]$MockWsl)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $RepositoryRoot 'platforms/windows-11/worker/maintenance-v1/runtime.ps1')
$script:fixtureStage=Join-Path $FixtureBase 'stage'
$fixtureMetadata=Join-Path $FixtureBase 'worker-metadata';$fixtureData=Join-Path $FixtureBase 'worker-data';$script:fixtureProfile=Join-Path $FixtureBase 'worker-profile'
$instance='2a1084ec-5389-4b0b-a0f0-9a38fcfaece5';$expectedCommit='0123456789abcdef0123456789abcdef01234567';$script:mockWsl=$MockWsl
function Assert-WorkerAdministrator {}
function Assert-WorkerRootMaintenanceCheckout([string]$RepositoryRoot,[string]$ExpectedCommit){if($ExpectedCommit -cne $expectedCommit){throw 'fixture commit mismatch'}}
function Read-WorkerState([string]$InstanceId){if($InstanceId -cne $instance){throw 'fixture identity mismatch'};[pscustomobject]@{Sid='S-1-5-21-1-2-3-1000';UserName='worker'}}
function Read-WorkerWslStage([string]$InstanceId){[pscustomobject]@{InstallLocation='C:\ProgramData\pcw-wsl\distro'}}
function Get-WorkerRootMaintenanceStagePath([string]$InstanceId){$script:fixtureStage}
function Get-WorkerPaths([string]$InstanceId){[pscustomobject]@{Metadata=$script:fixtureMetadata;Data=$script:fixtureData}}
function Get-WorkerRootMaintenanceIdentity {[pscustomobject]@{User=[pscustomobject]@{Value='S-1-5-21-1-2-3-1000'};Groups=[pscustomobject]@{Value=@()}}}
function Get-WorkerRootMaintenanceCurrentProfile {$script:fixtureProfile}
function Get-WorkerRootMaintenanceRegisteredProfile([string]$Sid){$script:fixtureProfile}
function Get-WorkerRootMaintenanceRegistrations {@([pscustomobject]@{Name="pcw-$instance";BasePath='C:\ProgramData\pcw-wsl\distro';Version=2})}
function Get-WorkerRootMaintenanceWslExecutable {$script:mockWsl}
function Assert-WorkerPlainPath([string]$Path){}
function Assert-WorkerResourceAcl([string]$Path,[string]$Sid,[string]$Kind){}
function Set-WorkerResourceAcl([string]$Path,[string]$Sid,[string]$Kind){}
function Write-WorkerNewFile([string]$Path,[string]$Content,[string]$Sid){[IO.File]::WriteAllText($Path,$Content,[Text.UTF8Encoding]::new($false))}
$script:launchCaptured=$false
function Start-WorkerRootMaintenanceCredentialedChild([Diagnostics.ProcessStartInfo]$StartInfo){
    $arguments=@($StartInfo.ArgumentList)
    if($StartInfo.FileName -notlike '*pwsh.exe' -or $StartInfo.UserName -cne 'worker' -or $StartInfo.Domain -cne [Environment]::MachineName -or $StartInfo.Password -isnot [Security.SecureString] -or -not $StartInfo.LoadUserProfile -or ($arguments -join ' ') -notmatch '-NoProfile.*-File.*child.ps1.*-Action Inspect'){throw 'credentialed child launch contract mismatch'}
    $script:launchCaptured=$true
    throw 'fixture launch captured'
}
function Start-WorkerRootMaintenanceWslProcess([Diagnostics.ProcessStartInfo]$StartInfo){
    $args=@($StartInfo.ArgumentList)
    $expected=@('--distribution',"pcw-$instance",'--user','root','--exec','/usr/bin/env','-i','PATH=/usr/sbin:/usr/bin:/sbin:/bin','LC_ALL=C','/bin/bash','-s','--','Inspect',$instance,'0123456789abcdef0123456789abcdef')
    if(($args -join "`n") -cne ($expected -join "`n")){throw 'WSL argv boundary mismatch'}
    $StartInfo.FileName=(Get-Process -Id $PID).Path
    $StartInfo.ArgumentList.Clear()
    foreach($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',$MockWsl,'-Action','Inspect','-InstanceId',$instance,'-Nonce','0123456789abcdef0123456789abcdef','-Packages',((Get-WorkerRootMaintenancePackages)-join ','))){$StartInfo.ArgumentList.Add($arg)}
    [Diagnostics.Process]::Start($StartInfo)
}
$stage=Initialize-WorkerRootMaintenanceStage $instance $RepositoryRoot $expectedCommit
. (Join-Path $fixtureStage 'child-runtime.ps1')
function Get-WorkerRootMaintenanceIdentity {[pscustomobject]@{User=[pscustomobject]@{Value='S-1-5-21-1-2-3-1000'};Groups=[pscustomobject]@{Value=@()}}}
function Get-WorkerRootMaintenanceCurrentProfile {$script:fixtureProfile}
function Get-WorkerRootMaintenanceRegisteredProfile([string]$Sid){$script:fixtureProfile}
function Get-WorkerRootMaintenanceRegistrations {@([pscustomobject]@{Name="pcw-$instance";BasePath='C:\ProgramData\pcw-wsl\distro';Version=2})}
function Get-WorkerRootMaintenanceWslExecutable {$script:mockWsl}
$copied=@(Get-ChildItem -LiteralPath $fixtureStage -File|ForEach-Object Name|Sort-Object)
if(($copied -join ',') -cne 'child-runtime.ps1,child.ps1,contract.ps1,manifest.json,root-maintenance.sh' -or $stage.SourceCommit -cne $expectedCommit){throw 'actual stage copy/readback failed'}
$password=ConvertTo-SecureString 'fixture-only' -AsPlainText -Force
try{Invoke-WorkerRootMaintenanceChild $instance $password Inspect $RepositoryRoot $expectedCommit|Out-Null;throw 'expected launch capture'}catch{if($_.Exception.Message -ne 'fixture launch captured' -or -not $script:launchCaptured){throw}}
$previousCanary=[Environment]::GetEnvironmentVariable('PC_SETUP_CONTROLLER_CANARY');[Environment]::SetEnvironmentVariable('PC_SETUP_CONTROLLER_CANARY',$null,'Process');Remove-Item Env:/PC_SETUP_CONTROLLER_CANARY -ErrorAction SilentlyContinue
$fixtureStageInfo=Get-Content (Join-Path $fixtureStage 'manifest.json') -Raw|ConvertFrom-Json;$fixtureIdentity=Get-WorkerRootMaintenanceIdentity
if($fixtureStageInfo.Owner -cne 'pc-setup/windows-worker-root-maintenance/v1' -or $fixtureIdentity.User.Value -cne $fixtureStageInfo.Sid -or $fixtureIdentity.Groups.Value -contains 'S-1-5-32-544' -or (Test-Path Env:/PC_SETUP_CONTROLLER_CANARY)){throw "Fresh fixture precondition mismatch: owner=$($fixtureStageInfo.Owner -ceq 'pc-setup/windows-worker-root-maintenance/v1') sid=$($fixtureIdentity.User.Value -ceq $fixtureStageInfo.Sid) admin=$($fixtureIdentity.Groups.Value -contains 'S-1-5-32-544') canary=$(Test-Path Env:/PC_SETUP_CONTROLLER_CANARY)."}
$childOutput=Invoke-WorkerRootMaintenanceChildCore Inspect (Join-Path $fixtureStage 'manifest.json') '0123456789abcdef0123456789abcdef'|ConvertFrom-Json
 [Environment]::SetEnvironmentVariable('PC_SETUP_CONTROLLER_CANARY',$previousCanary,'Process')
if($childOutput.Sid -cne 'S-1-5-21-1-2-3-1000' -or $childOutput.RootUid -ne 0 -or -not $childOutput.Complete -or $childOutput.Nonce -cne '0123456789abcdef0123456789abcdef'){throw 'fresh child WSL stdin roundtrip/report validation failed'}
'@|Set-Content -LiteralPath $harness -Encoding utf8
$pwshPath=Join-Path $env:ProgramW6432 'PowerShell/7/pwsh.exe';if(-not(Test-Path -LiteralPath $pwshPath)){ $pwshPath=(Get-Process -Id $PID).Path };$previousModulePath=$env:PSModulePath
try{
    $env:PSModulePath=(Join-Path $fixtureBase 'untrusted-modules')+[IO.Path]::PathSeparator+[IO.Path]::PathSeparator
    & $pwshPath -NoLogo -NoProfile -NonInteractive -File $harness $PSScriptRoot/.. $fixtureBase $mockWsl
    if($LASTEXITCODE -ne 0){throw 'Fresh maintenance call-path fixture failed.'}
}finally{$env:PSModulePath=$previousModulePath}
$resolvedFixture=[IO.Path]::GetFullPath($fixtureBase);$expectedParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
if([IO.Path]::GetDirectoryName($resolvedFixture).TrimEnd('\') -cne $expectedParent -or [IO.Path]::GetFileName($resolvedFixture) -cnotmatch '^pc-setup-root-maintenance-call-[a-f0-9]{32}$' -or (Get-Item -LiteralPath $resolvedFixture -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unsafe call-path fixture cleanup target; preserve it for inspection.'}
Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
Write-Output 'Worker root maintenance contracts: PASS'
