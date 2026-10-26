. (Join-Path $PSScriptRoot 'runtime.ps1')
function Get-WorkerGatewayPath([string]$InstanceId) {
    $null=New-WorkerPlan $InstanceId
    Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "pc-setup-wsl-gateway-$InstanceId"
}
function Get-WorkerGatewayMappings {
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
    try{
        foreach($family in @('v4tov4','v4tov6','v6tov4','v6tov6')){
            $key=$base.OpenSubKey("SYSTEM\CurrentControlSet\Services\PortProxy\$family\tcp")
            if($null -eq $key){continue}
            try{foreach($name in $key.GetValueNames()){[pscustomobject]@{Family=$family;Name=$name;Target=$key.GetValue($name)}}}finally{$key.Dispose()}
        }
    }finally{$base.Dispose()}
}
function Invoke-WorkerPortProxy([string]$Verb,[string]$Listen,[string]$Guest) {
    if($Verb -cnotin @('add','set')){throw 'Unsupported portproxy mutation.'}
    Assert-WorkerVpnAddress $Listen
    $ip=$null
    if(-not [Net.IPAddress]::TryParse($Guest,[ref]$ip) -or $ip.ToString() -cne $Guest -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'Canonical guest IPv4 required.'}
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=Join-Path ([Environment]::SystemDirectory) 'netsh.exe'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($arg in @('interface','portproxy',$Verb,'v4tov4',"listenaddress=$Listen",'listenport=22224',"connectaddress=$Guest",'connectport=22224','protocol=tcp')){$info.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::Start($info)
    try{$p.StandardInput.Close();$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();if(-not $p.WaitForExit(15000) -or $p.ExitCode -ne 0){throw 'Owned portproxy change failed; preserve partial state.'};$null=$out.GetAwaiter().GetResult();$null=$err.GetAwaiter().GetResult()}finally{$p.Dispose()}
}
function Assert-WorkerGatewayLive($Stage,$Report,[string]$Listen,[string]$Controller) {
    Assert-WorkerVpnAddress $Listen;Assert-WorkerVpnAddress $Controller
    if($Listen -ceq $Controller){throw 'Controller and gateway must differ.'}
    if($Report.Sid -cne $Stage.Sid -or $Report.Action -cne 'Verify' -or $Report.Administrator -isnot [bool] -or $Report.Administrator -or $Report.CanaryPresent -isnot [bool] -or $Report.CanaryPresent -or $Report.DistroName -cne (New-WorkerPlan $Stage.InstanceId).DistroName){throw 'Expected fresh credentialed guest verification.'}
    $configured=Get-Content (Join-Path (Get-WorkerSshStagePath $Stage.InstanceId) 'result-Configure.json') -Raw|ConvertFrom-Json
    if($Report.Guest.host_fp -cne $configured.Guest.host_fp -or $Report.Guest.port -cne '22224' -or $Report.Guest.service_active -cne 'true' -or $Report.Guest.interop -cne 'false' -or $Report.Guest.windows_drive_mount -cne 'false'){throw 'Guest SSH boundary/identity drift.'}
    $routes=@(Get-NetRoute -AddressFamily IPv4|Where-Object{$_.InterfaceAlias -like 'vEthernet (WSL*' -and $_.NextHop -eq '0.0.0.0'})
    if(-not @($routes|Where-Object{Test-WorkerGatewaySubnet $Report.Guest.address $_.DestinationPrefix}).Count){throw 'Guest IPv4 must be on the connected WSL virtual subnet.'}
    if(@(Get-NetIPAddress -AddressFamily IPv4|Where-Object IPAddress -eq $Report.Guest.address).Count){throw 'Guest target is a Windows interface.'}
    $vpn=& 'C:/Program Files/Tailscale/tailscale.exe' status --json|ConvertFrom-Json
    if($LASTEXITCODE -ne 0 -or $vpn.BackendState -cne 'Running' -or $vpn.TailscaleIPs -notcontains $Listen -or @($vpn.Peer.PSObject.Properties.Value|Where-Object{$_.TailscaleIPs -contains $Controller -and $_.Online}).Count -ne 1){throw 'Current VPN attributes mismatch.'}
    if((Get-CimInstance Win32_Service -Filter "Name='iphlpsvc'").State -cne 'Running'){throw 'Existing IP Helper must already be running; no service reconfiguration.'}
    $profiles=@(Get-NetFirewallProfile -PolicyStore ActiveStore)
    if($profiles.Count -ne 3 -or @($profiles|Where-Object Enabled -ne $true).Count){throw 'All existing Firewall profiles must be enabled; no global policy change.'}
}
function Assert-WorkerGatewayRule([string]$Name,[string]$Kind,$Manifest) {
    $rules=@(Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue)
    if($rules.Count -ne 1){throw 'Owned gateway Firewall rule missing/duplicate.'}
    $r=$rules[0]
    if($r.Description -cne "$($Manifest.Owner)/$($Manifest.InstanceId)/$Kind" -or $r.Enabled -ne 'True' -or $r.Direction -ne 'Inbound' -or $r.Action -cne $Kind -or $r.Profile -ne 'Any' -or $r.EdgeTraversalPolicy -ne 'Block'){throw 'Firewall identity/policy drift.'}
    $port=$r|Get-NetFirewallPortFilter;$address=$r|Get-NetFirewallAddressFilter
    $expected=if($Kind -eq 'Allow'){@($Manifest.ControllerAddress)}else{@(Get-WorkerGatewayBlockedRanges $Manifest.ControllerAddress)}
    if($port.Protocol -ne 'TCP' -or "$($port.LocalPort)" -cne '22224' -or "$($port.RemotePort)" -cne 'Any' -or "$($address.LocalAddress)" -cne $Manifest.ListenAddress -or ((@($address.RemoteAddress)|Sort-Object)-join ',') -cne (($expected|Sort-Object)-join ',')){throw 'Firewall scope drift.'}
    if(($r|Get-NetFirewallApplicationFilter).Program -ne 'Any' -or ($r|Get-NetFirewallServiceFilter).Service -ne 'Any'){throw 'Firewall application/service drift.'}
}
function Read-WorkerGateway([string]$InstanceId) {
    $stage=Read-WorkerSshStage $InstanceId
    $root=Get-WorkerGatewayPath $InstanceId
    Assert-WorkerResourceAcl $root $stage.Sid Metadata
    if(@(Get-ChildItem $root -Force).Count -ne 2){throw 'Unknown/partial gateway state.'}
    foreach($path in @("$root/manifest.json","$root/journal")){Assert-WorkerResourceAcl $path $stage.Sid Metadata}
    foreach($file in @(Get-ChildItem "$root/journal" -Force)){
        if($file.Name -cnotmatch '^[a-f0-9]{32}\.before\.json$'){throw 'Partial/unknown gateway repair; inspect journal.'}
        Assert-WorkerResourceAcl $file.FullName $stage.Sid Metadata
    }
    $m=Get-Content "$root/manifest.json" -Raw|ConvertFrom-Json
    if($m.Owner -cne 'pc-setup/windows-worker-gateway/v1' -or $m.InstanceId -cne $InstanceId -or $m.Sid -cne $stage.Sid -or $m.SshManifestHash -cne (Get-FileHash (Join-Path (Get-WorkerSshStagePath $InstanceId) 'manifest.json')).Hash -or $m.SourceHash -cne (Get-FileHash (Join-Path $PSScriptRoot 'gateway.ps1')).Hash){throw 'Gateway ownership/source drift.'}
    Assert-WorkerVpnAddress $m.ListenAddress;Assert-WorkerVpnAddress $m.ControllerAddress
    Assert-WorkerGatewayMapping @(Get-WorkerGatewayMappings) $m.ListenAddress $m.GuestAddress
    foreach($kind in @('Allow','Block')){Assert-WorkerGatewayRule "pc-setup-wsl-$InstanceId-22224-$kind" $kind $m}
    $m
}
function Initialize-WorkerGateway([string]$InstanceId,$GuestReport,[string]$ListenAddress,[string]$ControllerAddress) {
    Assert-WorkerAdministrator
    $stage=Read-WorkerSshStage $InstanceId
    Assert-WorkerGatewayLive $stage $GuestReport $ListenAddress $ControllerAddress
    $root=Get-WorkerGatewayPath $InstanceId
    if(Test-Path -LiteralPath $root){$m=Read-WorkerGateway $InstanceId;if($m.ListenAddress -cne $ListenAddress -or $m.ControllerAddress -cne $ControllerAddress -or $m.GuestAddress -cne $GuestReport.Guest.address -or $m.HostFingerprint -cne $GuestReport.Guest.host_fp){throw 'Gateway attributes changed; explicit repair required.'};return $m}
    Assert-WorkerGatewayMapping @(Get-WorkerGatewayMappings) $ListenAddress $GuestReport.Guest.address -MustBeAbsent
    if(@(Get-NetTCPConnection -State Listen -LocalPort 22224 -ErrorAction SilentlyContinue).Count){throw 'Foreign listener on reserved port.'}
    foreach($kind in @('Allow','Block')){if(@(Get-NetFirewallRule -Name "pc-setup-wsl-$InstanceId-22224-$kind" -ErrorAction SilentlyContinue).Count){throw 'Foreign Firewall name.'}}
    Assert-WorkerPlainPath $root
    $null=New-Item -ItemType Directory -Path $root -ErrorAction Stop;Set-WorkerResourceAcl $root $stage.Sid Metadata
    $null=New-Item -ItemType Directory -Path "$root/journal" -ErrorAction Stop;Set-WorkerResourceAcl "$root/journal" $stage.Sid Metadata
    $m=[ordered]@{Owner='pc-setup/windows-worker-gateway/v1';InstanceId=$InstanceId;Sid=$stage.Sid;SshManifestHash=(Get-FileHash (Join-Path (Get-WorkerSshStagePath $InstanceId) 'manifest.json')).Hash;SourceHash=(Get-FileHash (Join-Path $PSScriptRoot 'gateway.ps1')).Hash;ListenAddress=$ListenAddress;ControllerAddress=$ControllerAddress;GuestAddress=$GuestReport.Guest.address;HostFingerprint=$GuestReport.Guest.host_fp;Port=22224}
    Write-WorkerNewFile "$root/pending.json" ($m|ConvertTo-Json) $stage.Sid
    # The explicit complement block prevents an unrelated broad allow from exposing this port.
    foreach($kind in @('Block','Allow')){
        $remote=if($kind -eq 'Allow'){@($ControllerAddress)}else{@(Get-WorkerGatewayBlockedRanges $ControllerAddress)}
        $null=New-NetFirewallRule -Name "pc-setup-wsl-$InstanceId-22224-$kind" -DisplayName "Owned WSL SSH $InstanceId $kind" -Description "$($m.Owner)/$InstanceId/$kind" -Direction Inbound -Action $kind -Enabled True -Profile Any -Protocol TCP -LocalAddress $ListenAddress -LocalPort 22224 -RemoteAddress $remote -EdgeTraversalPolicy Block
    }
    Invoke-WorkerPortProxy add $ListenAddress $m.GuestAddress
    Move-Item -LiteralPath "$root/pending.json" -Destination "$root/manifest.json" -ErrorAction Stop
    Read-WorkerGateway $InstanceId
}
function Repair-WorkerGateway([string]$InstanceId,$GuestReport) {
    Assert-WorkerAdministrator
    $m=Read-WorkerGateway $InstanceId
    $stage=Read-WorkerSshStage $InstanceId
    Assert-WorkerGatewayLive $stage $GuestReport $m.ListenAddress $m.ControllerAddress
    if($GuestReport.Guest.host_fp -cne $m.HostFingerprint){throw 'Host identity changed; no reuse.'}
    if($GuestReport.Guest.address -ceq $m.GuestAddress){return $m}
    $root=Get-WorkerGatewayPath $InstanceId;$change=[guid]::NewGuid().ToString('N')
    Write-WorkerNewFile "$root/journal/$change.before.json" ([IO.File]::ReadAllText("$root/manifest.json")) $stage.Sid
    $m.GuestAddress=$GuestReport.Guest.address
    Write-WorkerNewFile "$root/journal/$change.pending.json" ($m|ConvertTo-Json) $stage.Sid
    Invoke-WorkerPortProxy set $m.ListenAddress $m.GuestAddress
    [IO.File]::Replace("$root/journal/$change.pending.json","$root/manifest.json",$null)
    Set-WorkerResourceAcl "$root/manifest.json" $stage.Sid Metadata
    Read-WorkerGateway $InstanceId
}
function Test-WorkerGateway([string]$InstanceId,$GuestReport) {
    Assert-WorkerAdministrator
    $m=Read-WorkerGateway $InstanceId
    Assert-WorkerGatewayLive (Read-WorkerSshStage $InstanceId) $GuestReport $m.ListenAddress $m.ControllerAddress
    if($GuestReport.Guest.address -cne $m.GuestAddress -or $GuestReport.Guest.host_fp -cne $m.HostFingerprint){throw 'Fresh guest attributes differ; explicit owned repair required.'}
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    do{
        $listeners=@(Get-NetTCPConnection -State Listen -LocalPort 22224 -ErrorAction SilentlyContinue)
        if($listeners.Count){break}
        Start-Sleep -Seconds 1
    }while([DateTime]::UtcNow -lt $deadline)
    $helper=Get-CimInstance Win32_Service -Filter "Name='iphlpsvc'"
    if($listeners.Count -ne 1 -or $listeners[0].LocalAddress -cne $m.ListenAddress -or $listeners[0].OwningProcess -notin @(4,[int]$helper.ProcessId)){throw 'Gateway listener scope/process mismatch.'}
    [ordered]@{InstanceId=$InstanceId;User='worker';ListenAddress=$m.ListenAddress;Port=22224;ControllerAddress=$m.ControllerAddress;GuestAddress=$m.GuestAddress;HostFingerprint=$m.HostFingerprint;ListenerPid=$listeners[0].OwningProcess;IpHelperState=$helper.State;VpnSharedGateway=$true;IndependentVpnIdentity=$false;RemoteAuthenticationTested=$false;IdleReconnectTested=$false}
}
