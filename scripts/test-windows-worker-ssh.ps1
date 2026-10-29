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
foreach($required in @('pc-setup/windows-worker-gateway-repair/v1','Read-WorkerGatewayRepairBaseV3','BaseGatewayManifestHash','HostFingerprint','Invoke-WorkerPortProxy set','Get-WorkerSshHoldArguments','Test-WorkerKeyStageGatewayRepairV1','instance.lock','[IO.FileShare]::None','Another gateway repair operation owns the instance lock.')){if($repairSource -cnotmatch [regex]::Escape($required)){throw "Worker gateway repair contract missing: $required"}}
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
$errors=$null
Get-ChildItem "$root/ssh/*.ps1",$PSCommandPath|ForEach-Object{$null=[Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$null,[ref]$errors);if($errors){throw $errors}}
Write-Output 'Worker SSH/gateway contracts: PASS'
