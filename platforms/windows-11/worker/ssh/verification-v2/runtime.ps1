. (Join-Path $PSScriptRoot '../runtime.ps1')
. (Join-Path $PSScriptRoot 'contract.ps1')
function Get-WorkerVerificationV2Path([string]$InstanceId) {
    $null=New-WorkerPlan $InstanceId
    Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "pc-setup-worker-ssh-verification-v2-$InstanceId"
}
function Read-WorkerVerificationV2([string]$InstanceId) {
    $setup=Read-WorkerSshStage $InstanceId
    $root=Get-WorkerVerificationV2Path $InstanceId
    Assert-WorkerResourceAcl $root $setup.Sid Metadata
    $allowed=@('manifest.json','child.ps1','contract.ps1','guest.sh','attempt-VerifyV2.marker','result-VerifyV2.json','attempt-HoldV2.marker','result-HoldV2.json')
    foreach($file in @(Get-ChildItem $root -Force)){if($file.Name -cnotin $allowed){throw 'Unknown v2 verification state.'};Assert-WorkerResourceAcl $file.FullName $setup.Sid Metadata}
    Assert-WorkerResourceAcl "$root/manifest.json" $setup.Sid Metadata
    $m=Get-Content "$root/manifest.json" -Raw|ConvertFrom-Json
    if($m.Owner -cne 'pc-setup/windows-worker-ssh-verification/v2' -or $m.InstanceId -cne $InstanceId -or $m.Sid -cne $setup.Sid -or $m.SetupManifestHash -cne (Get-FileHash "$(Get-WorkerSshStagePath $InstanceId)/manifest.json").Hash -or $m.SetupGuestScriptSha256 -cne $setup.GuestScriptSha256 -or $m.RuntimeHash -cne (Get-FileHash "$PSScriptRoot/runtime.ps1").Hash -or @($m.SourceHashes.PSObject.Properties).Count -ne 3){throw 'V2 verification source/identity drift.'}
    foreach($name in @('child.ps1','contract.ps1','guest.sh')){
        Assert-WorkerResourceAcl "$root/$name" $setup.Sid Metadata
        if((Get-FileHash "$root/$name").Hash -cne $m.SourceHashes.$name -or (Get-FileHash "$PSScriptRoot/$name").Hash -cne $m.SourceHashes.$name){throw 'V2 verifier source drift.'}
    }
    $configured=Get-Content "$(Get-WorkerSshStagePath $InstanceId)/result-Configure.json" -Raw|ConvertFrom-Json
    if($configured.Sid -cne $setup.Sid -or $configured.Action -cne 'Configure' -or $configured.Guest.host_fp -cne $m.HostFingerprint -or $m.HostFingerprint -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}$'){throw 'Original host identity mismatch.'}
    $m|Add-Member -NotePropertyName ManifestHash -NotePropertyValue (Get-FileHash "$root/manifest.json").Hash
    $m
}
function Initialize-WorkerVerificationV2([string]$InstanceId) {
    Assert-WorkerAdministrator
    $setup=Read-WorkerSshStage $InstanceId
    $root=Get-WorkerVerificationV2Path $InstanceId
    if(Test-Path -LiteralPath $root){return Read-WorkerVerificationV2 $InstanceId}
    $old=Get-WorkerSshStagePath $InstanceId
    $configured=Get-Content "$old/result-Configure.json" -Raw|ConvertFrom-Json
    $restarted=Get-Content "$old/result-Restart.json" -Raw|ConvertFrom-Json
    if($configured.Sid -cne $setup.Sid -or $configured.Action -cne 'Configure' -or $configured.Guest.host_fp -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}$' -or $restarted.Sid -cne $setup.Sid -or $restarted.Action -cne 'Restart' -or $restarted.Guest.distro_stopped -isnot [bool] -or -not $restarted.Guest.distro_stopped){throw 'Original configure/restart evidence missing.'}
    # Separate metadata; never rewrite the original setup or failed Verify marker.
    Assert-WorkerPlainPath $root;$null=New-Item -ItemType Directory -Path $root -ErrorAction Stop
    Set-WorkerResourceAcl $root $setup.Sid Metadata
    $hashes=[ordered]@{}
    foreach($name in @('child.ps1','contract.ps1','guest.sh')){Write-WorkerNewFile "$root/$name" ([IO.File]::ReadAllText("$PSScriptRoot/$name")) $setup.Sid;$hashes[$name]=(Get-FileHash "$root/$name").Hash}
    $m=[ordered]@{Owner='pc-setup/windows-worker-ssh-verification/v2';InstanceId=$InstanceId;Sid=$setup.Sid;SetupManifestHash=(Get-FileHash "$old/manifest.json").Hash;SetupGuestScriptSha256=$setup.GuestScriptSha256;HostFingerprint=$configured.Guest.host_fp;SourceHashes=$hashes;RuntimeHash=(Get-FileHash "$PSScriptRoot/runtime.ps1").Hash}
    Write-WorkerNewFile "$root/manifest.json" ($m|ConvertTo-Json -Depth 5) $setup.Sid
    Read-WorkerVerificationV2 $InstanceId
}
function Invoke-WorkerVerificationV2([string]$InstanceId,[SecureString]$Password,[switch]$ReadOnly) {
    Assert-WorkerAdministrator
    $m=Read-WorkerVerificationV2 $InstanceId;$state=Read-WorkerState $InstanceId;$root=Get-WorkerVerificationV2Path $InstanceId
    if(-not $Password -or $Password.Length -lt 1){throw 'Supply an in-memory credential.'}
    if(-not $ReadOnly){Write-WorkerNewFile "$root/attempt-VerifyV2.marker" '' $m.Sid}
    $exe=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'PowerShell/7/pwsh.exe'
    $info=New-CleanWorkerStartInfo $exe (Get-WorkerPaths $InstanceId).Data ([Environment]::GetFolderPath('Windows'))
    $info.UserName=$state.UserName;$info.Domain=[Environment]::MachineName;$info.Password=$Password;$info.LoadUserProfile=$true
    foreach($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',"$root/child.ps1",'-InstanceId',$InstanceId)){$info.ArgumentList.Add($arg)}
    $p=$null
    try{
        $p=[Diagnostics.Process]::Start($info);$info.Password=$null;$p.StandardInput.Close()
        $out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit(120000) -or $p.ExitCode -ne 0){throw 'V2 verification failed; preserve partial state, no retry.'}
        $text=$out.GetAwaiter().GetResult();if($text.Length -gt 16384 -or $err.GetAwaiter().GetResult().Length){throw 'Unexpected v2 child output.'}
        $report=$text|ConvertFrom-Json
        Assert-WorkerV2Report $report $m
        if(-not $ReadOnly){Write-WorkerNewFile "$root/result-VerifyV2.json" ($report|ConvertTo-Json -Depth 6) $m.Sid}
        $report
    }finally{$info.Password=$null;if($p){$p.Dispose()}}
}
function Start-WorkerSshHoldV2([string]$InstanceId,[SecureString]$Password) {
    Assert-WorkerAdministrator
    $m=Read-WorkerVerificationV2 $InstanceId;$state=Read-WorkerState $InstanceId;$root=Get-WorkerVerificationV2Path $InstanceId
    if(-not $Password -or $Password.Length -lt 1){throw 'Supply an in-memory credential.'}
    $proof=Get-Content "$root/result-VerifyV2.json" -Raw|ConvertFrom-Json
    Assert-WorkerV2Report $proof $m
    Write-WorkerNewFile "$root/attempt-HoldV2.marker" '' $m.Sid
    $exe=Join-Path ([Environment]::SystemDirectory) 'wsl.exe'
    $info=New-CleanWorkerStartInfo $exe (Get-WorkerPaths $InstanceId).Data ([Environment]::GetFolderPath('Windows'))
    $info.UserName=$state.UserName;$info.Domain=[Environment]::MachineName;$info.Password=$Password;$info.LoadUserProfile=$true
    $info.RedirectStandardOutput=$false;$info.RedirectStandardError=$false
    $setup=Read-WorkerSshStage $InstanceId
    $args=@(Get-WorkerSshHoldArguments (New-WorkerSshPlan $InstanceId $setup.PublicKey))
    foreach($arg in $args){$info.ArgumentList.Add($arg)}
    try{
        $p=[Diagnostics.Process]::Start($info);$info.Password=$null;$p.StandardInput.Close()
        Start-Sleep -Seconds 2;$p.Refresh()
        if($p.HasExited){throw 'Foreground WSL hold exited; preserve state, no retry.'}
        $native=Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)";$owner=Invoke-CimMethod $native -MethodName GetOwnerSid
        if($owner.Sid -cne $m.Sid -or $native.ExecutablePath -ine $exe -or -not $native.CommandLine.EndsWith(($args -join ' '),[StringComparison]::Ordinal)){throw 'Hold identity/command mismatch; preserve process.'}
        $report=[ordered]@{InstanceId=$InstanceId;Sid=$owner.Sid;PID=$p.Id;StartTimeUtc=$p.StartTime.ToUniversalTime().ToString('o');Executable=$native.ExecutablePath;CommandLine=$native.CommandLine;DistroName="pcw-$InstanceId";LinuxUser='worker';VerifierManifestHash=$m.ManifestHash;ProofHash=(Get-FileHash "$root/result-VerifyV2.json").Hash;ForegroundClient=$true;Persistent=$false;RebootTested=$false;IdleReconnectTested=$false}
        Write-WorkerNewFile "$root/result-HoldV2.json" ($report|ConvertTo-Json) $m.Sid
        $report
    }finally{$info.Password=$null}
}
