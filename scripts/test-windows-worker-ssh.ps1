$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Join-Path $PSScriptRoot '../platforms/windows-11/worker'
. "$root/contract.ps1"
. "$root/ssh/contract.ps1"
. "$root/ssh/firewall-contract.ps1"
$key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABi+WLmtTWVkJ7Y1o67t1MrDFPuNajIscj0QhDv8KYL devnode-wsl-worker-1'
$plan=New-WorkerSshPlan '2a1084ec-5389-4b0b-a0f0-9a38fcfaece5' $key
if($plan.LinuxUser -cne 'worker' -or $plan.Port -ne 22224 -or $plan.ClientFingerprint -cne 'SHA256:5cj3QSTm+WQmCbM8nyzioyceOQxzEXLLnFgsXcQIEQM'){throw 'Invalid SSH plan'}
$holdArgs=@(Get-WorkerSshHoldArguments $plan)
if(($holdArgs -join ' ') -cne "--distribution $($plan.DistroName) --user worker --exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/sleep infinity"){throw 'Unsafe foreground hold argv'}
foreach($bad in @(($key+"`n"),('command="bad" '+$key),$key.Replace('AAAAC3','AAAAAA'))){$denied=$false;try{New-WorkerSshPlan $plan.InstanceId $bad|Out-Null}catch{$denied=$true};if(-not $denied){throw 'Invalid key accepted'}}
if(-not(Test-WorkerGatewaySubnet '172.30.1.2' '172.30.0.0/20')){throw 'Expected WSL subnet'}
foreach($ip in @('100.118.123.62','127.0.0.1','0.0.0.0','172.31.0.1')){if(Test-WorkerGatewaySubnet $ip '172.30.0.0/20'){throw 'Foreign gateway target accepted'}}
if((@(Get-WorkerGatewayBlockedRanges '100.83.203.34') -join ',') -cne '0.0.0.0-100.83.203.33,100.83.203.35-255.255.255.255'){throw 'Expected exact controller complement'}
function Refuses([scriptblock]$Body){$bad=$false;try{& $Body|Out-Null}catch{$bad=$true};if(-not $bad){throw 'Expected refusal'}}
$owned=@{Family='v4tov4';Name='100.118.123.62/22224';Target='172.30.1.2/22224'}
Assert-WorkerGatewayMapping @() '100.118.123.62' '172.30.1.2' -MustBeAbsent
Assert-WorkerGatewayMapping @($owned) '100.118.123.62' '172.30.1.2'
Refuses {Assert-WorkerGatewayMapping @($owned) '100.118.123.62' '172.30.1.2' -MustBeAbsent}
Refuses {Assert-WorkerGatewayMapping @($owned,$owned) '100.118.123.62' '172.30.1.2'}
Refuses {Assert-WorkerGatewayMapping @(@{Family='v4tov4';Name='0.0.0.0/22224';Target='172.30.1.2/22224'}) '100.118.123.62' '172.30.1.2'}
Refuses {Assert-WorkerGatewayMapping @(@{Family='v6tov4';Name='::/22224';Target='172.30.1.2/22224'}) '100.118.123.62' '172.30.1.2'}
Refuses {Assert-WorkerGatewayMapping @($owned) '100.118.123.62' '172.30.1.3'}
$text="action=Configure`nhost_fp=SHA256:5cj3QSTm+WQmCbM8nyzioyceOQxzEXLLnFgsXcQIEQM`nrestart_required=true`n"
$null=ConvertFrom-WorkerGuestReport $text Configure
Refuses {ConvertFrom-WorkerGuestReport ($text+"action=Configure`n") Configure}
Refuses {ConvertFrom-WorkerGuestReport ($text.Replace('restart_required=true','restart_required=false')) Configure}
Refuses {ConvertFrom-WorkerGuestReport ($text+"unexpected=field`n") Configure}
$profiles=@('Domain','Private','Public')|ForEach-Object{[pscustomobject]@{Name=$_;Enabled=$true;AllowLocalFirewallRules=$true;AllowInboundRules=$true;DisabledInterfaceAliases=@()}}
Assert-WorkerGatewayFirewallProfiles $profiles Tailscale
$profiles[0].DisabledInterfaceAliases=@('Tailscale')
Refuses {Assert-WorkerGatewayFirewallProfiles $profiles Tailscale}
$profiles[0].DisabledInterfaceAliases=@('*')
Refuses {Assert-WorkerGatewayFirewallProfiles $profiles Tailscale}
$profiles[0].DisabledInterfaceAliases=@();$profiles[1].AllowLocalFirewallRules=$false
Refuses {Assert-WorkerGatewayFirewallProfiles $profiles Tailscale}
$profiles[1].AllowLocalFirewallRules='NotConfigured'
Refuses {Assert-WorkerGatewayFirewallProfiles $profiles Tailscale}
$profiles[1].AllowLocalFirewallRules=$true;$profiles[2].Enabled=$false
Refuses {Assert-WorkerGatewayFirewallProfiles $profiles Tailscale}

$repairPath=Join-Path $root 'ssh/repair-v1/runtime.ps1'
$repairTokens=$null;$repairErrors=$null
[System.Management.Automation.Language.Parser]::ParseFile($repairPath,[ref]$repairTokens,[ref]$repairErrors)|Out-Null
if($repairErrors){throw 'Worker gateway repair runtime has a PowerShell syntax error.'}
$repairSource=Get-Content -LiteralPath $repairPath -Raw
foreach($required in @('pc-setup/windows-worker-gateway-repair/v1','Read-WorkerGatewayRepairBaseV3','BaseGatewayManifestHash','HostFingerprint','Invoke-WorkerPortProxy set','Get-WorkerSshHoldArguments','Test-WorkerKeyStageGatewayRepairV1','instance.lock','[IO.FileShare]::None','Another gateway repair operation owns the instance lock.','*.intent.json','*.hold.json','Pending launch intent has no unique matching hold','latest journaled transition','PCSetupWorkerGatewayRepairStep','read-only-v3-verification','hold-process-resume-or-start','manifest-commit','Invoke-WorkerGatewayRepairV3ReadOnly','Assert-WorkerGatewayRepairV3Live','Assert-WorkerGatewayRepairHold','Replace-WorkerGatewayRepairManifest','PreviousManifestHash','404606904CFAD3D25C33F90AD31F2C47BEEAF8B5245B45BBEFC249E8A941C4B2','1DBB76DBE660317C2BC197DEE81ADA34CE8D2FEA4358D921818C81A01953822A','Repair manifest backup differs from its journaled before hash.')){if($repairSource -cnotmatch [regex]::Escape($required)){throw "Worker gateway repair contract missing: $required"}}
if($repairSource -match 'Assert-WorkerGatewayLive'){throw 'Repair stage must not pass a V3 report to the V1 live contract.'}
foreach($forbidden in @('Remove-NetFirewallRule','Stop-Service','Set-Service','ssh-agent')){if($repairSource -match [regex]::Escape($forbidden)){throw "Worker gateway repair contains forbidden operation: $forbidden"}}
# Security regression: an ineffective local rule must fail before port publication.
& {
    . "$root/ssh/gateway.ps1"
    $fixtureBase=Join-Path ([IO.Path]::GetTempPath()) ('pc-setup-gateway-test-'+[guid]::NewGuid().ToString('N'))
    $fixtureStage=Join-Path $fixtureBase 'stage';$fixtureGateway=Join-Path $fixtureBase 'gateway'
    $null=New-Item -ItemType Directory -Path $fixtureStage -Force
    [IO.File]::WriteAllText((Join-Path $fixtureStage 'manifest.json'),'{}')
    $effects=[Collections.Generic.List[string]]::new()
    function Assert-WorkerAdministrator {}
    function Read-WorkerSshStage { @{InstanceId=$plan.InstanceId;Sid='test-sid'} }
    function Assert-WorkerGatewayLive {}
    function Get-WorkerGatewayPath { $fixtureGateway }
    function Get-WorkerSshStagePath { $fixtureStage }
    function Get-WorkerGatewayMappings { @() }
    function Get-NetTCPConnection { @() }
    function Get-NetFirewallRule { @() }
    function Assert-WorkerPlainPath {}
    function Set-WorkerResourceAcl {}
    function Write-WorkerNewFile($Path,$Content) { [IO.File]::WriteAllText($Path,$Content) }
    function New-NetFirewallRule { $effects.Add('rule-created') }
    function Assert-WorkerGatewayRule { throw 'test-ineffective-rule' }
    function Invoke-WorkerPortProxy { $effects.Add('published') }
    function Read-WorkerGateway { @{Status='unexpected-success'} }
    $refused=$false
    try{
        $guest=[pscustomobject]@{Guest=[pscustomobject]@{address='172.30.1.2';host_fp='test'}}
        try{Initialize-WorkerGateway $plan.InstanceId $guest '100.118.123.62' '100.83.203.34'|Out-Null}catch{if($_.Exception.Message -cne 'test-ineffective-rule'){throw};$refused=$true}
        if(-not $refused -or $effects.Contains('published')){throw 'Gateway published before effective Firewall verification'}
        if(-not(Test-Path (Join-Path $fixtureGateway 'pending.json'))){throw 'Partial gateway state not preserved'}
    }finally{
        $resolved=[IO.Path]::GetFullPath($fixtureBase)
        $expectedParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]'\/')
        if([IO.Path]::GetDirectoryName($resolved) -cne $expectedParent -or [IO.Path]::GetFileName($resolved) -cnotmatch '^pc-setup-gateway-test-[a-f0-9]{32}$' -or (Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unsafe test cleanup path; preserve fixture'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
$repairRuntimePath=Join-Path $root 'ssh/repair-v1/runtime.ps1'
. $repairRuntimePath
$atomicRepairReplace=(Get-Command Replace-WorkerGatewayRepairManifest -CommandType Function).ScriptBlock
# Same-volume manifest commit must avoid File.Replace(null), and a failed commit
# must be resumable from the owned pending manifest without launching another WSL hold.
& {
    $fixtureBase=Join-Path ([IO.Path]::GetTempPath()) ('pc-setup-repair-test-'+[guid]::NewGuid().ToString('N'))
    $fixtureRoot=Join-Path $fixtureBase 'repair';$fixtureBaseV3=Join-Path $fixtureBase 'base';$fixtureSsh=Join-Path $fixtureBase 'ssh';$fixtureVerification=Join-Path $fixtureBase 'verification'
    foreach($directory in @($fixtureRoot,$fixtureBaseV3,$fixtureSsh,$fixtureVerification)){[void](New-Item -ItemType Directory -Path $directory -Force)}
    $script:repairFixture=[pscustomobject]@{Root=$fixtureRoot;Base=$fixtureBaseV3;Ssh=$fixtureSsh;Verification=$fixtureVerification;Sid='S-1-5-21-1-2-3-1001';Listen='100.118.123.62';Controller='100.83.203.34';OldGuest='172.30.1.2';CurrentGuest='172.30.1.3';HostFingerprint='SHA256:fixture-host-pin';CurrentTarget='172.30.1.3';Hold=$null;StartCalls=0;MappingCalls=0;ReplaceCalls=0;FailBeforeManifestReplace=$true;FailAfterBackupCreation=$false;FailAfterManifestReplace=$false}
    $journal=Join-Path $fixtureRoot 'journal';[void](New-Item -ItemType Directory -Path $journal -Force)
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'instance.lock'),'')
    [IO.File]::WriteAllText((Join-Path $fixtureBaseV3 'manifest.json'),'{}')
    [IO.File]::WriteAllText((Join-Path $fixtureSsh 'manifest.json'),'{}')
    $fixtureId=$plan.InstanceId;$currentSource=(Get-FileHash $repairRuntimePath).Hash
    $sshHash=(Get-FileHash (Join-Path $fixtureSsh 'manifest.json')).Hash;$baseHash=(Get-FileHash (Join-Path $fixtureBaseV3 'manifest.json')).Hash
    $intentId='159f5b48b4534c14bc701466d22eaf92';$changeId='eb92f556c9ed43f1b79c3807a5390af7'
    $holdArgs=@(Get-WorkerSshHoldArguments (New-WorkerSshPlan $fixtureId $key));$holdExe=Join-Path ([Environment]::GetFolderPath('System')) 'wsl.exe';$holdStart=[DateTime]::UtcNow.AddMinutes(-5).ToString('o')
    $hold=[ordered]@{PID=21964;Sid=$script:repairFixture.Sid;Executable=$holdExe;CommandLine="$holdExe $($holdArgs -join ' ')";StartTimeUtc=$holdStart}
    $script:repairFixture.Hold=$hold
    $gateway=[pscustomobject]@{InstanceId=$fixtureId;Sid=$script:repairFixture.Sid;ListenAddress=$script:repairFixture.Listen;ControllerAddress=$script:repairFixture.Controller;GuestAddress=$script:repairFixture.OldGuest;HostFingerprint=$script:repairFixture.HostFingerprint;Port=22224;VerifierManifestHash='fixture-verifier-hash';SafetyScope='controller-only'}
    $manifest=[ordered]@{Owner='pc-setup/windows-worker-gateway-repair/v1';InstanceId=$fixtureId;Sid=$gateway.Sid;SourceHash='1DBB76DBE660317C2BC197DEE81ADA34CE8D2FEA4358D921818C81A01953822A';SshManifestHash=$sshHash;VerifierManifestHash=$gateway.VerifierManifestHash;BaseGatewayManifestHash=$baseHash;HostFingerprint=$gateway.HostFingerprint;ListenAddress=$gateway.ListenAddress;ControllerAddress=$gateway.ControllerAddress;GuestAddress=$script:repairFixture.OldGuest;Port=22224;SafetyScope=$gateway.SafetyScope;Hold=$null;UpdatedAtUtc=[DateTime]::UtcNow.AddMinutes(-5).ToString('o')}
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'manifest.json'),($manifest|ConvertTo-Json -Depth 6))
    $intent=[ordered]@{Owner='pc-setup/windows-worker-gateway-repair/v1';InstanceId=$fixtureId;Sid=$gateway.Sid;Executable=$holdExe;Arguments=$holdArgs;CreatedAtUtc=[DateTime]::UtcNow.AddMinutes(-5).ToString('o')}
    [IO.File]::WriteAllText((Join-Path $journal "$intentId.intent.json"),($intent|ConvertTo-Json -Depth 5))
    $receipt=[ordered]@{Owner='pc-setup/windows-worker-gateway-repair/v1';InstanceId=$fixtureId;Sid=$gateway.Sid;Hold=$hold;IntentId=$intentId;RecordedAtUtc=[DateTime]::UtcNow.AddMinutes(-5).ToString('o')}
    [IO.File]::WriteAllText((Join-Path $journal "$intentId.hold.json"),($receipt|ConvertTo-Json -Depth 6))
    $before=[ordered]@{Owner='pc-setup/windows-worker-gateway-repair/v1';InstanceId=$fixtureId;Sid=$gateway.Sid;Previous=$script:repairFixture.OldGuest;Current=$script:repairFixture.CurrentGuest;PreviousHoldPID=$null;CurrentHoldPID=$hold.PID;CapturedAtUtc=[DateTime]::UtcNow.AddMinutes(-4).ToString('o')}
    [IO.File]::WriteAllText((Join-Path $journal "$changeId.before.json"),($before|ConvertTo-Json))
    $pending=[ordered]@{};foreach($name in $manifest.Keys){$pending[$name]=$manifest[$name]};$pending.GuestAddress=$script:repairFixture.CurrentGuest;$pending.Hold=$hold;$pending.SourceHash='404606904CFAD3D25C33F90AD31F2C47BEEAF8B5245B45BBEFC249E8A941C4B2';$pending.UpdatedAtUtc=[DateTime]::UtcNow.AddMinutes(-4).ToString('o')
    [IO.File]::WriteAllText((Join-Path $fixtureRoot "$changeId.pending.json"),($pending|ConvertTo-Json -Depth 6))
    $live=[pscustomobject]@{Guest=[pscustomobject]@{address=$script:repairFixture.CurrentGuest;host_fp=$script:repairFixture.HostFingerprint}}
    $script:repairFixture|Add-Member -NotePropertyName Live -NotePropertyValue $live

    function Assert-WorkerAdministrator {}
    function Assert-WorkerResourceAcl([string]$Path,[string]$Sid,[string]$Kind) {}
    function Set-WorkerResourceAcl([string]$Path,[string]$Sid,[string]$Kind) {}
    function Assert-WorkerVpnAddress([string]$Address) {}
    function Assert-WorkerGatewayRule([string]$Name,[string]$Kind,$Manifest) {}
    function Read-WorkerGatewayRepairBaseV3([string]$InstanceId) { $gateway }
    function Get-WorkerGatewayRepairV1Path([string]$InstanceId) { $script:repairFixture.Root }
    function Get-WorkerGatewayV3Path([string]$InstanceId) { $script:repairFixture.Base }
    function Get-WorkerSshStagePath([string]$InstanceId) { $script:repairFixture.Ssh }
    function Get-WorkerVerificationV3Path([string]$InstanceId) { $script:repairFixture.Verification }
    function Read-WorkerVerificationV3([string]$InstanceId) { $gateway }
    function Read-WorkerState([string]$InstanceId) { [pscustomobject]@{Sid=$script:repairFixture.Sid;UserName='fixture'} }
    function Read-WorkerSshStage([string]$InstanceId) { [pscustomobject]@{PublicKey=$key} }
    function Invoke-WorkerGatewayRepairV3ReadOnly([string]$InstanceId,[SecureString]$Password) { $script:repairFixture.Live }
    function Invoke-WorkerVerificationV3([string]$InstanceId,[SecureString]$Password,[switch]$ReadOnly) { $script:repairFixture.Live }
    function Assert-WorkerGatewayRepairV3Live($Stage,$Report,[string]$Listen,[string]$Controller) {}
    function Assert-WorkerGatewayRepairHold([string]$InstanceId,[string]$Sid,$Hold,[string]$PublicKey) {}
    function Get-WorkerGatewayMappings { @([pscustomobject]@{Family='v4tov4';Name="$($script:repairFixture.Listen)/22224";Target="$($script:repairFixture.CurrentTarget)/22224"}) }
    function Assert-WorkerGatewayMapping($Mappings,[string]$Listen,[string]$Guest,[switch]$MustBeAbsent) { if($MustBeAbsent -or $Listen -cne $script:repairFixture.Listen -or $Guest -cne $script:repairFixture.CurrentTarget -or $Mappings.Count -ne 1){throw 'fixture mapping mismatch'} }
    function Invoke-WorkerPortProxy([string]$Verb,[string]$Listen,[string]$Guest) { $script:repairFixture.MappingCalls++;$script:repairFixture.CurrentTarget=$Guest }
    function Get-WorkerGatewayBlockedRanges([string]$Controller) { @() }
    function Test-WorkerGatewaySubnet([string]$Ip,[string]$Prefix) { $true }
    function Get-NetRoute([string]$AddressFamily) { @([pscustomobject]@{InterfaceAlias='vEthernet (WSL)';NextHop='0.0.0.0';DestinationPrefix='172.30.0.0/20'}) }
    function Get-NetIPAddress([string]$AddressFamily,[string]$IPAddress) { @() }
    function Get-NetTCPConnection([string]$State,[int]$LocalPort,[string]$ErrorAction) { @([pscustomobject]@{LocalAddress=$script:repairFixture.Listen;OwningProcess=4}) }
    function Get-CimInstance([string]$ClassName,[string]$Filter,[string]$ErrorAction) { if($ClassName -eq 'Win32_Service'){[pscustomobject]@{State='Running';ProcessId=4}}else{[pscustomobject]@{ProcessId=$script:repairFixture.Hold.PID;ExecutablePath=$script:repairFixture.Hold.Executable;CommandLine=$script:repairFixture.Hold.CommandLine}} }
    function Invoke-CimMethod($InputObject,[string]$MethodName) { [pscustomobject]@{Sid=$script:repairFixture.Sid} }
    function Get-Process([int]$Id) { [pscustomobject]@{Id=$script:repairFixture.Hold.PID;StartTime=[DateTime]::UtcNow.AddMinutes(-5)} }
    function Test-WorkerHoldStartTime($Process,[string]$StartTimeUtc) { $true }
    function New-CleanWorkerStartInfo([string]$FileName,[string]$WorkingDirectory,[string]$SystemRoot) { $script:repairFixture.StartCalls++;throw 'fixture must resume recorded hold, not start another' }
    function Replace-WorkerGatewayRepairManifest([string]$Pending,[string]$Manifest,[string]$Backup,[string]$Sid,[string]$ExpectedBackupHash) {
        $script:repairFixture.ReplaceCalls++
        if($script:repairFixture.FailBeforeManifestReplace){$script:repairFixture.FailBeforeManifestReplace=$false;throw 'fixture interrupted before atomic manifest replace'}
        if($script:repairFixture.FailAfterBackupCreation){$script:repairFixture.FailAfterBackupCreation=$false;[IO.File]::Copy($Manifest,$Backup);Set-WorkerResourceAcl $Backup $Sid Metadata;throw 'fixture interrupted after backup creation'}
        & $atomicRepairReplace $Pending $Manifest $Backup $Sid $ExpectedBackupHash
        if($script:repairFixture.FailAfterManifestReplace){$script:repairFixture.FailAfterManifestReplace=$false;throw 'fixture interrupted after atomic manifest replace'}
    }
    $password=ConvertTo-SecureString 'fixture-only-not-a-secret' -AsPlainText -Force
    try {
        $firstFailed=$false
        try { Invoke-WorkerGatewayRepairV1 $fixtureId $password|Out-Null } catch { if($_.Exception.Message -cne 'fixture interrupted before atomic manifest replace'){throw};$firstFailed=$true }
        if(-not $firstFailed -or $global:PCSetupWorkerGatewayRepairStep -cne 'manifest-commit'){throw 'Fixture did not stop at the manifest commit boundary.'}
        $oldOnDisk=Get-Content (Join-Path $fixtureRoot 'manifest.json') -Raw|ConvertFrom-Json
        if($oldOnDisk.Hold -or $oldOnDisk.GuestAddress -cne $script:repairFixture.OldGuest -or -not(Test-Path (Join-Path $fixtureRoot "$changeId.pending.json")) -or $script:repairFixture.CurrentTarget -cne $script:repairFixture.CurrentGuest){throw 'Interrupted fixture state was not safely preserved.'}
        $result=Invoke-WorkerGatewayRepairV1 $fixtureId $password
        if($result.GuestAddress -cne $script:repairFixture.CurrentGuest -or $result.Hold.PID -ne $hold.PID -or $result.SourceHash -cne $currentSource){throw 'Fixture recovery manifest differs from live verified state.'}
        if((Test-Path (Join-Path $fixtureRoot "$changeId.pending.json")) -or (Test-Path (Join-Path $journal "$intentId.hold.json")) -or (Test-Path (Join-Path $journal "$intentId.intent.json"))){throw 'Fixture recovery left a committed pending/hold receipt.'}
        if($script:repairFixture.StartCalls -ne 0 -or $script:repairFixture.MappingCalls -ne 2 -or $script:repairFixture.CurrentTarget -cne $script:repairFixture.CurrentGuest){throw 'Fixture recovery restarted WSL or changed the wrong mapping.'}
        $script:repairFixture.FailAfterBackupCreation=$true;$noReceiptFailure=$false
        try { Invoke-WorkerGatewayRepairV1 $fixtureId $password|Out-Null } catch { if($_.Exception.Message -cne 'fixture interrupted after backup creation'){throw};$noReceiptFailure=$true }
        $noReceiptPending=@(Get-ChildItem -LiteralPath $fixtureRoot -Filter '*.pending.json' -Force)
        $partialBackup=@(Get-ChildItem -LiteralPath $journal -Filter '*.manifest-backup.json' -Force)
        if(-not $noReceiptFailure -or $noReceiptPending.Count -ne 1 -or $partialBackup.Count -ne 1 -or @(Get-ChildItem -LiteralPath $journal -Filter '*.hold.json' -Force).Count -ne 0){throw 'Fixture did not preserve a resumable no-change replace state without a hold receipt.'}
        $noReceiptId=[IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension($noReceiptPending[0].Name));$noReceiptTransition=Get-Content (Join-Path $journal "$noReceiptId.before.json") -Raw|ConvertFrom-Json
        if($noReceiptTransition.CurrentHoldPID -ne $hold.PID -or $noReceiptTransition.Current -cne $script:repairFixture.CurrentGuest){throw 'No-change pending manifest lacks its matching hold/mapping journal.'}
        $result=Invoke-WorkerGatewayRepairV1 $fixtureId $password
        if($result.Hold.PID -ne $hold.PID -or $result.SourceHash -cne $currentSource -or @(Get-ChildItem -LiteralPath $fixtureRoot -Filter '*.pending.json' -Force).Count -ne 0){throw 'Fixture could not resume a no-change manifest without a receipt.'}
        $script:repairFixture.FailAfterManifestReplace=$true;$afterReplaceFailed=$false
        try { Invoke-WorkerGatewayRepairV1 $fixtureId $password|Out-Null } catch { if($_.Exception.Message -cne 'fixture interrupted after atomic manifest replace'){throw};$afterReplaceFailed=$true }
        $backupFiles=@(Get-ChildItem -LiteralPath $journal -Filter '*.manifest-backup.json' -Force)
        if(-not $afterReplaceFailed -or $backupFiles.Count -ne 1 -or @(Get-ChildItem -LiteralPath $fixtureRoot -Filter '*.pending.json' -Force).Count -ne 0){throw 'Fixture did not preserve the ambiguous post-replace state.'}
        $result=Invoke-WorkerGatewayRepairV1 $fixtureId $password
        if($result.GuestAddress -cne $script:repairFixture.CurrentGuest -or $result.Hold.PID -ne $hold.PID -or $script:repairFixture.StartCalls -ne 0 -or @(Get-ChildItem -LiteralPath $journal -Filter '*.manifest-backup.json' -Force).Count -ne 0){throw 'Fixture did not resume and clean an already-committed manifest safely.'}
        $nullFailure=$false;$src=Join-Path $fixtureBase 'null-source';$dst=Join-Path $fixtureBase 'null-destination';[IO.File]::WriteAllText($src,'new');[IO.File]::WriteAllText($dst,'old')
        try{[IO.File]::Replace($src,$dst,$null)}catch{$nullFailure=$_.Exception.InnerException.Message -match 'path is empty'}
        if(-not $nullFailure -or [IO.File]::ReadAllText($dst) -cne 'old' -or -not[IO.File]::Exists($src)){throw 'File.Replace null binder regression was not reproduced.'}
        $backup=Join-Path $fixtureBase 'null-backup';$expectedBackupHash=(Get-FileHash $dst).Hash;& $atomicRepairReplace $src $dst $backup $script:repairFixture.Sid $expectedBackupHash
        if([IO.File]::ReadAllText($dst) -cne 'new' -or [IO.File]::Exists($src) -or [IO.File]::ReadAllText($backup) -cne 'old'){throw 'Explicit-backup atomic file replacement failed.'}
    } finally { $password.Dispose() }
    $resolved=[IO.Path]::GetFullPath($fixtureBase);$expectedParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]'\/')
    if([IO.Path]::GetDirectoryName($resolved) -cne $expectedParent -or [IO.Path]::GetFileName($resolved) -cnotmatch '^pc-setup-repair-test-[a-f0-9]{32}$' -or (Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unsafe repair fixture cleanup path; preserve fixture'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
    $script:repairFixture=$null
}
$errors=$null
Get-ChildItem "$root/ssh/*.ps1",$PSCommandPath|ForEach-Object{$null=[Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$null,[ref]$errors);if($errors){throw $errors}}
Write-Output 'Worker SSH/gateway contracts: PASS'
