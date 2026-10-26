function New-WorkerSshPlan([string]$InstanceId,[string]$PublicKey) {
    $worker=New-WorkerPlan $InstanceId
    if($PublicKey -cnotmatch '\Assh-ed25519 ([A-Za-z0-9+/]{68}) ([A-Za-z0-9_.@-]{1,80})\z'){throw 'Single dedicated Ed25519 public key required.'}
    $blob=[Convert]::FromBase64String($Matches[1])
    if($blob.Length -ne 51 -or ($blob[0..3] -join ',') -cne '0,0,0,11' -or [Text.Encoding]::ASCII.GetString($blob,4,11) -cne 'ssh-ed25519' -or ($blob[15..18] -join ',') -cne '0,0,0,32'){throw 'Malformed Ed25519 key blob.'}
    $fp='SHA256:'+([Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData($blob))).TrimEnd('=')
    [ordered]@{Owner='pc-setup/windows-worker-ssh/v1';InstanceId=$worker.InstanceId;DistroName=$worker.DistroName;LinuxUser='worker';Port=22224;PublicKey=$PublicKey;ClientFingerprint=$fp}
}
function Test-WorkerGatewaySubnet([string]$Address,[string]$Subnet) {
    $ip=$null
    if(-not [Net.IPAddress]::TryParse($Address,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){return $false}
    $bytes=$ip.GetAddressBytes()
    if(-not($bytes[0] -eq 10 -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or ($bytes[0] -eq 192 -and $bytes[1] -eq 168))){return $false}
    if($Subnet -notmatch '^([0-9.]+)/([0-9]{1,2})$'){return $false}
    $network=$null;$prefix=[int]$Matches[2]
    if($prefix -lt 8 -or $prefix -gt 30 -or -not [Net.IPAddress]::TryParse($Matches[1],[ref]$network) -or $network.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){return $false}
    $netBytes=$network.GetAddressBytes()
    for($i=0;$i -lt 4;$i++){
        $bits=[Math]::Min(8,[Math]::Max(0,$prefix-8*$i))
        $mask=if($bits){(255 -shl (8-$bits)) -band 255}else{0}
        if(($bytes[$i] -band $mask) -ne ($netBytes[$i] -band $mask)){return $false}
    }
    $true
}
function Assert-WorkerVpnAddress([string]$Address) {
    $ip=$null
    if(-not [Net.IPAddress]::TryParse($Address,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $ip.ToString() -cne $Address){throw 'Canonical VPN IPv4 required.'}
    $bytes=$ip.GetAddressBytes()
    if($bytes[0] -ne 100 -or $bytes[1] -lt 64 -or $bytes[1] -gt 127){throw 'Tailscale IPv4 required.'}
}
function Get-WorkerGatewayBlockedRanges([string]$Controller) {
    Assert-WorkerVpnAddress $Controller
    $b=([Net.IPAddress]::Parse($Controller)).GetAddressBytes()
    $value=[uint64]$b[0]*16777216+[uint64]$b[1]*65536+[uint64]$b[2]*256+[uint64]$b[3]
    function Format-Address([uint64]$Number){@((($Number -shr 24) -band 255),(($Number -shr 16) -band 255),(($Number -shr 8) -band 255),($Number -band 255)) -join '.'}
    @(('0.0.0.0-'+(Format-Address ($value-1))),((Format-Address ($value+1))+'-255.255.255.255'))
}
function Assert-WorkerGatewayMapping([object[]]$Mappings,[string]$Listen,[string]$Guest,[switch]$MustBeAbsent) {
    $portMaps=@($Mappings|Where-Object Name -match '/22224$')
    if($MustBeAbsent){if($portMaps.Count){throw 'Foreign mapping on reserved port.'};return}
    if($portMaps.Count -ne 1 -or $portMaps[0].Family -cne 'v4tov4' -or $portMaps[0].Name -cne "$Listen/22224" -or $portMaps[0].Target -cne "$Guest/22224"){throw 'Portproxy ownership/target drift; no adoption.'}
}
function Get-WorkerSshHoldArguments($Plan) {
    $verified=New-WorkerSshPlan $Plan.InstanceId $Plan.PublicKey
    @('--distribution',$verified.DistroName,'--user','worker','--exec','/usr/bin/env','-i','PATH=/usr/sbin:/usr/bin:/sbin:/bin','/bin/sleep','infinity')
}
function ConvertFrom-WorkerGuestReport([string]$Text,[string]$Action) {
    if($Text.Length -gt 8192){throw 'Unexpected guest output size.'}
    $fields=[ordered]@{}
    foreach($line in ($Text -split "`r?`n")){
        if(-not $line){continue}
        if($line -cnotmatch '^([a-z_]+)=([A-Za-z0-9_:/+.-]+)$' -or $fields.Contains($Matches[1])){throw 'Unexpected guest report.'}
        $fields[$Matches[1]]=$Matches[2]
    }
    if($fields.action -cne $Action){throw 'Guest action mismatch.'}
    $expected=switch($Action){
        Inspect {@('action','wsl_conf_hash','server_installed','user_exists','policy_exists','stage_exists','home_exists','group_exists','auth_exists','unit_exists')}
        Configure {@('action','host_fp','restart_required')}
        Verify {@('action','address','port','linux_user','uid','host_fp','interop','windows_drive_mount','service_active')}
        default {throw 'Unexpected guest action.'}
    }
    if($fields.Count -ne $expected.Count -or @($expected|Where-Object{-not $fields.Contains($_)}).Count){throw 'Unexpected guest fields.'}
    if($Action -eq 'Inspect'){
        if($fields.wsl_conf_hash -cnotmatch '^(absent|[a-f0-9]{64})$'){throw 'Invalid baseline hash.'}
        foreach($name in @('server_installed','user_exists','policy_exists','stage_exists','home_exists','group_exists','auth_exists','unit_exists')){if($fields[$name] -cnotmatch '^(true|false)$'){throw 'Invalid baseline boolean.'}}
    }else{
        if($fields.host_fp -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}$'){throw 'Invalid guest host fingerprint.'}
        if($Action -eq 'Configure' -and $fields.restart_required -cne 'true'){throw 'Expected explicit restart stage.'}
        if($Action -eq 'Verify' -and ($fields.port -cne '22224' -or $fields.linux_user -cne 'worker' -or $fields.uid -cnotmatch '^[1-9][0-9]{3,4}$' -or $fields.interop -cne 'false' -or $fields.windows_drive_mount -cne 'false' -or $fields.service_active -cne 'true')){throw 'Guest SSH boundary incomplete.'}
    }
    $fields
}
