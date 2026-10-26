# Effective profile gate. Never change global/GPO settings to make a local rule work.
function Assert-WorkerGatewayFirewallProfiles([object[]]$Profiles,[string]$InterfaceAlias) {
    if(-not $InterfaceAlias -or $Profiles.Count -ne 3){throw 'Expected one VPN interface and three effective Firewall profiles.'}
    foreach($name in @('Domain','Private','Public')){
        if(@($Profiles|Where-Object Name -CEQ $name).Count -ne 1){throw 'Unexpected effective Firewall profile set.'}
    }
    foreach($profile in $Profiles){
        if([string]$profile.Enabled -cne 'True' -or [string]$profile.AllowLocalFirewallRules -cne 'True' -or [string]$profile.AllowInboundRules -cne 'True'){throw 'Effective Firewall must enable the profile and local inbound rule merge; no global fallback.'}
        foreach($disabled in @($profile.DisabledInterfaceAliases)){
            if($disabled -and $InterfaceAlias -like $disabled){throw 'VPN interface is excluded from effective Firewall filtering.'}
        }
    }
}
