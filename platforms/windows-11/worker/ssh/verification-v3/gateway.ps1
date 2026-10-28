# V1 helpers are read-only definitions; its manifest/source and entry points remain unchanged.
. (Join-Path $PSScriptRoot '../gateway.ps1')
. (Join-Path $PSScriptRoot 'runtime.ps1')
function Test-WorkerHoldStartTime([datetime]$Actual,$Recorded) {
    $expected=[datetime]::MinValue
    if($Recorded -is [datetime]){$expected=$Recorded}
    elseif($Recorded -is [string]){
        if(-not [datetime]::TryParseExact($Recorded,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$expected)){return $false}
    }else{return $false}
    if($expected.Kind -ne [DateTimeKind]::Utc){return $false}
    $Actual.ToUniversalTime().Ticks -eq $expected.Ticks
}
function Get-WorkerGatewayV3Path([string]$InstanceId) {
    $null=New-WorkerPlan $InstanceId
    Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "pc-setup-wsl-gateway-v3-$InstanceId"
}
function Get-WorkerGatewayLegacyV2Path([string]$InstanceId) {
    $null=New-WorkerPlan $InstanceId
    Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "pc-setup-wsl-gateway-v2-$InstanceId"
}
function Assert-WorkerGatewayV3Live($Stage,$Report,[string]$Listen,[string]$Controller) {
    Assert-WorkerV3Report $Report $Stage
    Assert-WorkerVpnAddress $Listen;Assert-WorkerVpnAddress $Controller
    if($Listen -ceq $Controller){throw 'Controller and gateway must differ.'}
    $routes=@(Get-NetRoute -AddressFamily IPv4|Where-Object{$_.InterfaceAlias -like 'vEthernet (WSL*' -and $_.NextHop -eq '0.0.0.0'})
    if(-not @($routes|Where-Object{Test-WorkerGatewaySubnet $Report.Guest.address $_.DestinationPrefix}).Count -or @(Get-NetIPAddress -AddressFamily IPv4|Where-Object IPAddress -eq $Report.Guest.address).Count){throw 'Guest must be on the connected WSL subnet, not a Windows address.'}
    $vpn=& 'C:/Program Files/Tailscale/tailscale.exe' status --json|ConvertFrom-Json
    if($LASTEXITCODE -ne 0 -or $vpn.BackendState -cne 'Running' -or $vpn.TailscaleIPs -notcontains $Listen -or @($vpn.Peer.PSObject.Properties.Value|Where-Object{$_.TailscaleIPs -contains $Controller -and $_.Online}).Count -ne 1){throw 'Current VPN attributes mismatch.'}
    if((Get-CimInstance Win32_Service -Filter "Name='iphlpsvc'").State -cne 'Running'){throw 'Existing IP Helper must already be running.'}
    $interfaces=@(Get-NetIPAddress -AddressFamily IPv4 -IPAddress $Listen)
    if($interfaces.Count -ne 1){throw 'Ambiguous VPN interface.'}
    Assert-WorkerGatewayFirewallProfiles @(Get-NetFirewallProfile -PolicyStore ActiveStore) $interfaces[0].InterfaceAlias
    $root=Get-WorkerVerificationV3Path $Stage.InstanceId
    $hold=Get-Content "$root/result-HoldV3.json" -Raw|ConvertFrom-Json
    $setup=Read-WorkerSshStage $Stage.InstanceId
    $exe=Join-Path ([Environment]::SystemDirectory) 'wsl.exe'
    $args=@(Get-WorkerSshHoldArguments (New-WorkerSshPlan $Stage.InstanceId $setup.PublicKey))
    $native=Get-CimInstance Win32_Process -Filter "ProcessId=$($hold.PID)"
    $owner=Invoke-CimMethod $native -MethodName GetOwnerSid
    $process=Get-Process -Id $hold.PID
    if($hold.InstanceId -cne $Stage.InstanceId -or $hold.Sid -cne $Stage.Sid -or $hold.VerifierManifestHash -cne $Stage.ManifestHash -or $hold.ProofHash -cne (Get-FileHash "$root/result-VerifyV3.json").Hash -or $hold.Executable -ine $exe -or $owner.Sid -cne $Stage.Sid -or $native.ExecutablePath -ine $exe -or $native.CommandLine -cne $hold.CommandLine -or -not $native.CommandLine.EndsWith(($args -join ' '),[StringComparison]::Ordinal) -or -not(Test-WorkerHoldStartTime $process.StartTime $hold.StartTimeUtc)){throw 'Owned foreground hold is absent or changed.'}
}
function Read-WorkerGatewayV3([string]$InstanceId) {
    $v=Read-WorkerVerificationV3 $InstanceId;$root=Get-WorkerGatewayV3Path $InstanceId
    Assert-WorkerResourceAcl $root $v.Sid Metadata
    $files=@(Get-ChildItem $root -Force)
    if($files.Count -ne 1 -or $files[0].Name -cne 'manifest.json'){throw 'Partial or unknown v3 gateway state.'}
    Assert-WorkerResourceAcl "$root/manifest.json" $v.Sid Metadata
    $m=Get-Content "$root/manifest.json" -Raw|ConvertFrom-Json
    if($m.Owner -cne 'pc-setup/windows-worker-gateway/v3' -or $m.InstanceId -cne $InstanceId -or $m.Sid -cne $v.Sid -or $m.VerifierManifestHash -cne $v.ManifestHash -or $m.ProofHash -cne (Get-FileHash "$(Get-WorkerVerificationV3Path $InstanceId)/result-VerifyV3.json").Hash -or $m.SourceHash -cne (Get-FileHash "$PSScriptRoot/gateway.ps1").Hash -or $m.HelperHash -cne (Get-FileHash "$PSScriptRoot/../gateway.ps1").Hash -or $m.FirewallContractHash -cne (Get-FileHash "$PSScriptRoot/../firewall-contract.ps1").Hash -or $m.HostFingerprint -cne $v.HostFingerprint -or $m.Port -ne 22224){throw 'V3 gateway ownership/source drift.'}
    Assert-WorkerVpnAddress $m.ListenAddress;Assert-WorkerVpnAddress $m.ControllerAddress
    Assert-WorkerGatewayMapping @(Get-WorkerGatewayMappings) $m.ListenAddress $m.GuestAddress
    foreach($kind in @('Allow','Block')){Assert-WorkerGatewayRule "pc-setup-wsl-$InstanceId-22224-$kind" $kind $m}
    $m
}
function Initialize-WorkerGatewayV3([string]$InstanceId,[SecureString]$Password,[string]$ListenAddress,[string]$ControllerAddress) {
    Assert-WorkerAdministrator
    if(-not $Password -or $Password.Length -lt 1){throw 'Supply an in-memory credential for fresh verification.'}
    $v=Read-WorkerVerificationV3 $InstanceId
    $proof=Get-Content "$(Get-WorkerVerificationV3Path $InstanceId)/result-VerifyV3.json" -Raw|ConvertFrom-Json
    Assert-WorkerV3Report $proof $v
    $live=Invoke-WorkerVerificationV3 $InstanceId $Password -ReadOnly
    Assert-WorkerGatewayV3Live $v $live $ListenAddress $ControllerAddress
    $root=Get-WorkerGatewayV3Path $InstanceId
    if(Test-Path -LiteralPath $root){$m=Read-WorkerGatewayV3 $InstanceId;if($m.ListenAddress -cne $ListenAddress -or $m.ControllerAddress -cne $ControllerAddress -or $m.GuestAddress -cne $live.Guest.address){throw 'V3 gateway attributes changed; explicit reconciliation required.'};return $m}
    if(Test-Path -LiteralPath (Get-WorkerGatewayPath $InstanceId)){throw 'V1 gateway exists; do not migrate or adopt.'}
    if(Test-Path -LiteralPath (Get-WorkerGatewayLegacyV2Path $InstanceId)){throw 'V2 gateway exists; do not migrate or adopt.'}
    Assert-WorkerGatewayMapping @(Get-WorkerGatewayMappings) $ListenAddress $live.Guest.address -MustBeAbsent
    if(@(Get-NetTCPConnection -State Listen -LocalPort 22224 -ErrorAction SilentlyContinue).Count){throw 'Foreign listener on reserved port.'}
    foreach($kind in @('Allow','Block')){if(@(Get-NetFirewallRule -Name "pc-setup-wsl-$InstanceId-22224-$kind" -ErrorAction SilentlyContinue).Count){throw 'Foreign Firewall rule name.'}}
    Assert-WorkerPlainPath $root;$null=New-Item -ItemType Directory -Path $root -ErrorAction Stop;Set-WorkerResourceAcl $root $v.Sid Metadata
    $m=[ordered]@{Owner='pc-setup/windows-worker-gateway/v3';InstanceId=$InstanceId;Sid=$v.Sid;VerifierManifestHash=$v.ManifestHash;ProofHash=(Get-FileHash "$(Get-WorkerVerificationV3Path $InstanceId)/result-VerifyV3.json").Hash;SourceHash=(Get-FileHash "$PSScriptRoot/gateway.ps1").Hash;HelperHash=(Get-FileHash "$PSScriptRoot/../gateway.ps1").Hash;FirewallContractHash=(Get-FileHash "$PSScriptRoot/../firewall-contract.ps1").Hash;ListenAddress=$ListenAddress;ControllerAddress=$ControllerAddress;GuestAddress=$live.Guest.address;HostFingerprint=$v.HostFingerprint;Port=22224;SafetyScope='authenticated-single-controller-poc'}
    Write-WorkerNewFile "$root/pending.json" ($m|ConvertTo-Json) $v.Sid
    foreach($kind in @('Block','Allow')){
        $remote=if($kind -eq 'Allow'){@($ControllerAddress)}else{@(Get-WorkerGatewayBlockedRanges $ControllerAddress)}
        $null=New-NetFirewallRule -Name "pc-setup-wsl-$InstanceId-22224-$kind" -DisplayName "Owned WSL SSH $InstanceId $kind" -Description "$($m.Owner)/$InstanceId/$kind" -Direction Inbound -Action $kind -Enabled True -Profile Any -Protocol TCP -LocalAddress $ListenAddress -LocalPort 22224 -RemoteAddress $remote -EdgeTraversalPolicy Block
    }
    # Re-read both the guest and effective host policy immediately before publication.
    $fresh=Invoke-WorkerVerificationV3 $InstanceId $Password -ReadOnly
    Assert-WorkerGatewayV3Live (Read-WorkerVerificationV3 $InstanceId) $fresh $ListenAddress $ControllerAddress
    if($fresh.Guest.address -cne $m.GuestAddress){throw 'Guest address changed before publication; preserve partial rules.'}
    foreach($kind in @('Block','Allow')){Assert-WorkerGatewayRule "pc-setup-wsl-$InstanceId-22224-$kind" $kind $m}
    Assert-WorkerGatewayMapping @(Get-WorkerGatewayMappings) $ListenAddress $m.GuestAddress -MustBeAbsent
    if(@(Get-NetTCPConnection -State Listen -LocalPort 22224 -ErrorAction SilentlyContinue).Count){throw 'Listener appeared before publication.'}
    Invoke-WorkerPortProxy add $ListenAddress $m.GuestAddress
    $pending=[IO.Path]::GetFullPath("$root/pending.json");$target=[IO.Path]::GetFullPath("$root/manifest.json")
    if([IO.Path]::GetDirectoryName($pending) -cne [IO.Path]::GetFullPath($root) -or [IO.Path]::GetDirectoryName($target) -cne [IO.Path]::GetFullPath($root)){throw 'Gateway manifest path escaped its owned root.'}
    Move-Item -LiteralPath $pending -Destination $target -ErrorAction Stop
    Read-WorkerGatewayV3 $InstanceId
}
function Test-WorkerGatewayV3([string]$InstanceId,[SecureString]$Password) {
    Assert-WorkerAdministrator
    $m=Read-WorkerGatewayV3 $InstanceId
    $live=Invoke-WorkerVerificationV3 $InstanceId $Password -ReadOnly
    Assert-WorkerGatewayV3Live (Read-WorkerVerificationV3 $InstanceId) $live $m.ListenAddress $m.ControllerAddress
    if($live.Guest.address -cne $m.GuestAddress){throw 'Guest address changed; explicit reconciliation required.'}
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    do{$listeners=@(Get-NetTCPConnection -State Listen -LocalPort 22224 -ErrorAction SilentlyContinue);if($listeners.Count){break};Start-Sleep -Seconds 1}while([DateTime]::UtcNow -lt $deadline)
    $helper=Get-CimInstance Win32_Service -Filter "Name='iphlpsvc'"
    if($listeners.Count -ne 1 -or $listeners[0].LocalAddress -cne $m.ListenAddress -or $listeners[0].OwningProcess -notin @(4,[int]$helper.ProcessId)){throw 'Gateway listener scope/process mismatch.'}
    [ordered]@{InstanceId=$InstanceId;User='worker';ListenAddress=$m.ListenAddress;Port=22224;ControllerAddress=$m.ControllerAddress;GuestAddress=$m.GuestAddress;HostFingerprint=$m.HostFingerprint;ListenerPid=$listeners[0].OwningProcess;SafetyScope=$m.SafetyScope;RemoteAuthenticationTested=$false;IdleReconnectTested=$false;RebootTested=$false}
}
