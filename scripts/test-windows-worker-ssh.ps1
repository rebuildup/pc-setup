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
$errors=$null
Get-ChildItem "$root/ssh/*.ps1",$PSCommandPath|ForEach-Object{$null=[Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$null,[ref]$errors);if($errors){throw $errors}}
Write-Output 'Worker SSH/gateway contracts: PASS'
