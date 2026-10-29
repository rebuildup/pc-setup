. (Join-Path $PSScriptRoot '../verification-v3/gateway.ps1')
. (Join-Path $PSScriptRoot 'contract.ps1')
function Get-WorkerKeyStagePath([string]$InstanceId,[string]$OperationId) {
    $null=New-WorkerPlan $InstanceId
    if($OperationId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'){throw 'Invalid key operation identity.'}
    Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "pc-setup-worker-ssh-keys-$InstanceId-$OperationId"
}
function Get-WorkerKeyStageSources {
    [ordered]@{'child.ps1'="$PSScriptRoot/child.ps1";'contract.ps1'="$PSScriptRoot/contract.ps1";'update-guest.sh'="$PSScriptRoot/update-guest.sh";'transaction.sh'="$PSScriptRoot/transaction.sh";'verify-guest.sh'="$PSScriptRoot/verify-guest.sh";'sshd-checks.sh'="$PSScriptRoot/../verification-v3/sshd-checks.sh"}
}
function Read-WorkerKeyStage([string]$InstanceId,[string]$OperationId,[int]$Depth=0) {
    if($Depth -gt 31){throw 'Key-stage history exceeds supported depth.'}
    $v=Read-WorkerVerificationV3 $InstanceId;$root=Get-WorkerKeyStagePath $InstanceId $OperationId
    Assert-WorkerResourceAcl $root $v.Sid Metadata
    $sources=Get-WorkerKeyStageSources;$allowed=@('manifest.json')+@($sources.Keys)
    foreach($a in @('VerifyBefore','Update','VerifyAfter')){$allowed+="attempt-$a.marker";$allowed+="result-$a.json"}
    foreach($file in @(Get-ChildItem -LiteralPath $root -Force)){if($file.Name -cnotin $allowed){throw 'Unknown key-stage state.'};Assert-WorkerResourceAcl $file.FullName $v.Sid Metadata}
    Assert-WorkerResourceAcl "$root/manifest.json" $v.Sid Metadata
    $m=Get-Content "$root/manifest.json" -Raw|ConvertFrom-Json
    if($m.Owner -cne 'pc-setup/windows-worker-ssh-keys/v1' -or $m.InstanceId -cne $InstanceId -or $m.OperationId -cne $OperationId -or $m.Sid -cne $v.Sid -or $m.SetupManifestHash -cne $v.SetupManifestHash -or $m.VerifierManifestHash -cne $v.ManifestHash -or $m.HostFingerprint -cne $v.HostFingerprint -or $m.RuntimeHash -cne (Get-FileHash "$PSScriptRoot/runtime.ps1").Hash -or @($m.SourceHashes.PSObject.Properties).Count -ne $sources.Count){throw 'Key-stage identity/source drift.'}
    foreach($name in $sources.Keys){Assert-WorkerResourceAcl "$root/$name" $v.Sid Metadata;if((Get-FileHash "$root/$name").Hash -cne $m.SourceHashes.$name -or (Get-FileHash $sources[$name]).Hash -cne $m.SourceHashes.$name){throw 'Key-stage source drift.'}}
    $plan=New-WorkerKeyTransition $InstanceId $OperationId $m.Current $m.Current.Generation $m.Action $m.Key $m.PreviousProofSha256 $m.HostFingerprint
    if($plan.BeforeSha256 -cne $m.BeforeSha256 -or $plan.AfterSha256 -cne $m.AfterSha256 -or $plan.BeforeRevokedSha256 -cne $m.BeforeRevokedSha256 -or $plan.AfterRevokedSha256 -cne $m.AfterRevokedSha256 -or $plan.Generation -ne $m.Generation){throw 'Key-stage plan drift.'}
    if($m.PreviousOperationId){
        if($m.PreviousOperationId -ceq $OperationId){throw 'Cyclic key-stage history.'}
        $previous=Read-WorkerKeyStage $InstanceId $m.PreviousOperationId ($Depth+1)
        $previousRoot=Get-WorkerKeyStagePath $InstanceId $m.PreviousOperationId
        $proofPath="$previousRoot/result-VerifyAfter.json";Assert-WorkerResourceAcl $proofPath $v.Sid Metadata
        if((Get-FileHash $proofPath).Hash.ToLowerInvariant() -cne $m.PreviousProofSha256 -or $previous.ManifestHash -cne $m.PreviousManifestHash){throw 'Previous key-stage proof changed.'}
        $proof=Get-Content $proofPath -Raw|ConvertFrom-Json;Assert-WorkerKeyStageReport $proof $previous 'VerifyAfter'
        if($m.Current.Generation -ne $previous.Generation -or $m.Current.Active.ContentSha256 -cne $previous.AfterSha256 -or $m.Current.RevokedSha256 -cne $previous.AfterRevokedSha256){throw 'Previous key-stage generation mismatch.'}
    }else{
        $setup=Read-WorkerSshStage $InstanceId
        $proofPath="$(Get-WorkerVerificationV3Path $InstanceId)/result-VerifyV3.json";Assert-WorkerResourceAcl $proofPath $v.Sid Metadata
        if((Get-FileHash $proofPath).Hash.ToLowerInvariant() -cne $m.PreviousProofSha256 -or $m.PreviousManifestHash -cne $v.ManifestHash -or $m.Current.Generation -ne 0 -or $m.Current.Active.Keys.Count -ne 1 -or $m.Current.Active.Keys[0] -cne $setup.PublicKey -or $m.Current.Revoked.Count -ne 0){throw 'Original key-stage baseline mismatch.'}
        Assert-WorkerV3Report (Get-Content $proofPath -Raw|ConvertFrom-Json) $v
    }
    $m|Add-Member -NotePropertyName ManifestHash -NotePropertyValue (Get-FileHash "$root/manifest.json").Hash
    $m
}
function Initialize-WorkerKeyStage([string]$InstanceId,[string]$OperationId,[SecureString]$Password,[ValidateSet('Add','Revoke')][string]$Action,[string]$Key,[string]$PreviousOperationId='') {
    Assert-WorkerAdministrator
    if(-not $Password -or $Password.Length -lt 1){throw 'Supply an in-memory credential.'}
    $v=Read-WorkerVerificationV3 $InstanceId;$root=Get-WorkerKeyStagePath $InstanceId $OperationId
    if(Test-Path -LiteralPath $root){throw 'Key-stage operation already exists; preserve state.'}
    if($PreviousOperationId){
        $previous=Read-WorkerKeyStage $InstanceId $PreviousOperationId
        $previousRoot=Get-WorkerKeyStagePath $InstanceId $PreviousOperationId
        $proofPath="$previousRoot/result-VerifyAfter.json"
        $proof=Get-Content $proofPath -Raw|ConvertFrom-Json;Assert-WorkerKeyStageReport $proof $previous 'VerifyAfter'
        $null=Invoke-WorkerKeyStage $InstanceId $PreviousOperationId $Password 'VerifyAfter' -ReadOnly
        $current=Update-WorkerKeyLedger $InstanceId $previous.Current $previous.Current.Generation $previous.Action $previous.Key
        $previousManifestHash=$previous.ManifestHash
    }else{
        $setup=Read-WorkerSshStage $InstanceId
        $proofPath="$(Get-WorkerVerificationV3Path $InstanceId)/result-VerifyV3.json"
        $proof=Get-Content $proofPath -Raw|ConvertFrom-Json;Assert-WorkerV3Report $proof $v
        $null=Invoke-WorkerVerificationV3 $InstanceId $Password -ReadOnly
        $current=New-WorkerKeyLedger $InstanceId 0 @($setup.PublicKey) @()
        $previousManifestHash=$v.ManifestHash
    }
    $proofHash=(Get-FileHash $proofPath).Hash.ToLowerInvariant()
    $plan=New-WorkerKeyTransition $InstanceId $OperationId $current $current.Generation $Action $Key $proofHash $v.HostFingerprint
    Assert-WorkerPlainPath $root;$null=New-Item -ItemType Directory -Path $root -ErrorAction Stop;Set-WorkerResourceAcl $root $v.Sid Metadata
    $sources=Get-WorkerKeyStageSources;$hashes=[ordered]@{}
    foreach($name in $sources.Keys){Write-WorkerNewFile "$root/$name" ([IO.File]::ReadAllText($sources[$name])) $v.Sid;$hashes[$name]=(Get-FileHash "$root/$name").Hash}
    $m=[ordered]@{Owner='pc-setup/windows-worker-ssh-keys/v1';InstanceId=$InstanceId;OperationId=$OperationId;Sid=$v.Sid;SetupManifestHash=$v.SetupManifestHash;VerifierManifestHash=$v.ManifestHash;HostFingerprint=$v.HostFingerprint;PreviousOperationId=$PreviousOperationId;PreviousManifestHash=$previousManifestHash;PreviousProofSha256=$proofHash;Current=$current;Action=$Action;Key=$Key;BeforeSha256=$plan.BeforeSha256;AfterSha256=$plan.AfterSha256;BeforeRevokedSha256=$plan.BeforeRevokedSha256;AfterRevokedSha256=$plan.AfterRevokedSha256;Generation=$plan.Generation;SourceHashes=$hashes;RuntimeHash=(Get-FileHash "$PSScriptRoot/runtime.ps1").Hash}
    Write-WorkerNewFile "$root/manifest.json" ($m|ConvertTo-Json -Depth 10) $v.Sid
    Read-WorkerKeyStage $InstanceId $OperationId
}
function Assert-WorkerKeyStageReport($Report,$Stage,[string]$Action) {
    if($Report.Owner -cne $Stage.Owner -or $Report.InstanceId -cne $Stage.InstanceId -or $Report.OperationId -cne $Stage.OperationId -or $Report.Sid -cne $Stage.Sid -or $Report.Action -cne $Action -or $Report.Administrator -isnot [bool] -or $Report.Administrator -or $Report.CanaryPresent -isnot [bool] -or $Report.CanaryPresent -or $Report.DiagnosticPresent -isnot [bool] -or $Report.DiagnosticPresent -or $Report.DistroName -cne "pcw-$($Stage.InstanceId)" -or $Report.KeyManifestHash -cne $Stage.ManifestHash -or $Report.VerifierManifestHash -cne $Stage.VerifierManifestHash){throw 'Key-stage report identity mismatch.'}
    $expected=if($Action -eq 'VerifyBefore'){$Stage.BeforeSha256}else{$Stage.AfterSha256}
    if($Action -eq 'Update'){
        if($Report.Guest.authorization_hash -cne $expected -or $Report.Guest.host_fp -cne $Stage.HostFingerprint){throw 'Update result mismatch.'}
    }else{
        $text=($Report.Guest.PSObject.Properties|ForEach-Object{"$($_.Name)=$($_.Value)"}) -join "`n"
        $guest=ConvertFrom-WorkerGuestKeyStage $text $expected
        if($guest.host_fp -cne $Stage.HostFingerprint){throw 'Host key changed.'}
    }
}
function Invoke-WorkerKeyStage([string]$InstanceId,[string]$OperationId,[SecureString]$Password,[ValidateSet('VerifyBefore','Update','VerifyAfter')][string]$Action,[switch]$ReadOnly) {
    Assert-WorkerAdministrator
    $m=Read-WorkerKeyStage $InstanceId $OperationId;$root=Get-WorkerKeyStagePath $InstanceId $OperationId;$state=Read-WorkerState $InstanceId
    if(-not $Password -or $Password.Length -lt 1){throw 'Supply an in-memory credential.'}
    if($ReadOnly -and $Action -ne 'VerifyAfter'){throw 'ReadOnly is limited to completed key-stage verification.'}
    if($Action -eq 'Update'){$prior=Get-Content "$root/result-VerifyBefore.json" -Raw|ConvertFrom-Json;Assert-WorkerKeyStageReport $prior $m 'VerifyBefore'}
    if($Action -eq 'VerifyAfter'){$prior=Get-Content "$root/result-Update.json" -Raw|ConvertFrom-Json;Assert-WorkerKeyStageReport $prior $m 'Update'}
    if(-not $ReadOnly){Write-WorkerNewFile "$root/attempt-$Action.marker" '' $m.Sid}
    $exe=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'PowerShell/7/pwsh.exe'
    $p=$null;$info=$null;$canary=[Environment]::GetEnvironmentVariable('PC_SETUP_CONTROLLER_CANARY')
    try{
        [Environment]::SetEnvironmentVariable('PC_SETUP_CONTROLLER_CANARY',[guid]::NewGuid().ToString('N'))
        $info=New-CleanWorkerStartInfo $exe (Get-WorkerPaths $InstanceId).Data ([Environment]::GetFolderPath('Windows'))
        Set-WorkerVerificationV3Environment $info ([Environment]::GetFolderPath('CommonApplicationData'))
        $info.UserName=$state.UserName;$info.Domain=[Environment]::MachineName;$info.Password=$Password;$info.LoadUserProfile=$true
        foreach($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',"$root/child.ps1",'-InstanceId',$InstanceId,'-OperationId',$OperationId,'-Action',$Action)){$info.ArgumentList.Add($arg)}
        $p=[Diagnostics.Process]::Start($info);$info.Password=$null;$p.StandardInput.Close()
        $out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit(120000) -or $p.ExitCode -ne 0){throw 'Key-stage operation failed; commit state may be unknown; preserve partial state and do not retry.'}
        $text=$out.GetAwaiter().GetResult();if($text.Length -gt 16384 -or $err.GetAwaiter().GetResult().Length){throw 'Unexpected key-stage child output.'}
        $report=$text|ConvertFrom-Json;Assert-WorkerKeyStageReport $report $m $Action
        if(-not $ReadOnly){Write-WorkerNewFile "$root/result-$Action.json" ($report|ConvertTo-Json -Depth 8) $m.Sid}
        $report
    }finally{[Environment]::SetEnvironmentVariable('PC_SETUP_CONTROLLER_CANARY',$canary);if($info){$info.Password=$null};if($p){$p.Dispose()}}
}
function Test-WorkerKeyStageGateway([string]$InstanceId,[string]$OperationId,[SecureString]$Password) {
    Assert-WorkerAdministrator
    $stage=Read-WorkerKeyStage $InstanceId $OperationId
    $v=Read-WorkerVerificationV3 $InstanceId
    $gateway=Read-WorkerGatewayV3 $InstanceId
    $proofPath="$(Get-WorkerKeyStagePath $InstanceId $OperationId)/result-VerifyAfter.json"
    Assert-WorkerResourceAcl $proofPath $stage.Sid Metadata
    $proof=Get-Content $proofPath -Raw|ConvertFrom-Json;Assert-WorkerKeyStageReport $proof $stage 'VerifyAfter'
    $fresh=Invoke-WorkerKeyStage $InstanceId $OperationId $Password 'VerifyAfter' -ReadOnly
    Assert-WorkerKeyGatewayBinding $InstanceId $gateway $fresh.Guest $stage.AfterSha256
    # The historical report supplies only the original hold/source binding;
    # fresh guest state is separately checked above against the same gateway.
    $historical=Get-Content "$(Get-WorkerVerificationV3Path $InstanceId)/result-VerifyV3.json" -Raw|ConvertFrom-Json
    Assert-WorkerGatewayV3Live $v $historical $gateway.ListenAddress $gateway.ControllerAddress
    $listeners=@(Get-NetTCPConnection -State Listen -LocalPort 22224 -ErrorAction SilentlyContinue)
    $helper=Get-CimInstance Win32_Service -Filter "Name='iphlpsvc'"
    if($listeners.Count -ne 1 -or $listeners[0].LocalAddress -cne $gateway.ListenAddress -or $listeners[0].OwningProcess -notin @(4,[int]$helper.ProcessId)){throw 'Gateway listener scope/process mismatch.'}
    [ordered]@{InstanceId=$InstanceId;OperationId=$OperationId;Generation=$stage.Generation;AuthorizationHash=$stage.AfterSha256;KeyProofHash=(Get-FileHash $proofPath).Hash;GatewayManifestHash=(Get-FileHash "$(Get-WorkerGatewayV3Path $InstanceId)/manifest.json").Hash;ListenAddress=$gateway.ListenAddress;ControllerAddress=$gateway.ControllerAddress;GuestAddress=$gateway.GuestAddress;Port=22224;HostFingerprint=$gateway.HostFingerprint;RemoteAuthenticationTested=$false;IdleReconnectTested=$false;RebootTested=$false}
}
