. (Join-Path $PSScriptRoot '../wsl-runtime.ps1')
. (Join-Path $PSScriptRoot 'contract.ps1')
function Get-WorkerSshStagePath([string]$InstanceId) {
    $null=New-WorkerPlan $InstanceId
    Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "pc-setup-worker-ssh-$InstanceId"
}
function Get-WorkerSshSources {
    [ordered]@{'worker-contract.ps1'=(Join-Path $PSScriptRoot '../contract.ps1');'contract.ps1'=(Join-Path $PSScriptRoot 'contract.ps1');'child.ps1'=(Join-Path $PSScriptRoot 'child.ps1');'guest.sh'=(Join-Path $PSScriptRoot 'guest.sh')}
}
function Read-WorkerSshStage([string]$InstanceId) {
    $wsl=Read-WorkerWslStage $InstanceId
    $root=Get-WorkerSshStagePath $InstanceId
    Assert-WorkerResourceAcl $root $wsl.Sid Metadata
    $sources=Get-WorkerSshSources
    $allowed=@('manifest.json')+@($sources.Keys)
    foreach($action in @('Inspect','Configure','Restart','Verify','Hold')){
        $allowed+="attempt-$action.marker";$allowed+="result-$action.json"
    }
    $actual=@(Get-ChildItem -LiteralPath $root -Force)
    foreach($item in $actual){if($item.Name -cnotin $allowed){throw 'Unknown SSH stage state.'};Assert-WorkerResourceAcl $item.FullName $wsl.Sid Metadata}
    foreach($name in @('manifest.json')+@($sources.Keys)){if(-not(Test-Path -LiteralPath (Join-Path $root $name))){throw 'Partial SSH source stage.'}}
    $m=Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw|ConvertFrom-Json
    $plan=New-WorkerSshPlan $InstanceId $m.PublicKey
    $wslRoot=Get-WorkerWslStagePath $InstanceId
    if($m.Owner -cne $plan.Owner -or $m.InstanceId -cne $InstanceId -or $m.Sid -cne $wsl.Sid -or $m.WslStageRoot -cne $wslRoot -or $m.WslManifestHash -cne (Get-FileHash (Join-Path $wslRoot 'manifest.json')).Hash -or @($m.SourceHashes.PSObject.Properties).Count -ne 4){throw 'SSH enrollment drift.'}
    foreach($name in $sources.Keys){
        if((Get-FileHash (Join-Path $root $name)).Hash -cne $m.SourceHashes.$name -or (Get-FileHash $sources[$name]).Hash -cne $m.SourceHashes.$name){throw 'SSH source drift; no overwrite.'}
    }
    $script=[IO.File]::ReadAllText((Join-Path $root 'guest.sh')).Replace("`r`n","`n")
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($script))).ToLowerInvariant()
    if($hash -cne $m.GuestScriptSha256){throw 'Guest stdin source hash drift.'}
    $m
}
function Start-WorkerSshHold([string]$InstanceId,[SecureString]$Password) {
    Assert-WorkerAdministrator
    $m=Read-WorkerSshStage $InstanceId;$state=Read-WorkerState $InstanceId
    if(-not $Password -or $Password.Length -lt 1){throw 'Supply an in-memory credential.'}
    $root=Get-WorkerSshStagePath $InstanceId
    $verified=Get-Content (Join-Path $root 'result-Verify.json') -Raw|ConvertFrom-Json
    if($verified.Sid -cne $m.Sid -or $verified.Action -cne 'Verify' -or $verified.Guest.service_active -cne 'true'){throw 'Verify the new guest before the owned foreground hold.'}
    $marker=Join-Path $root 'attempt-Hold.marker'
    $handle=[IO.File]::Open($marker,'CreateNew','Write','None');$handle.Dispose();Set-WorkerResourceAcl $marker $m.Sid Metadata
    $exe=Join-Path ([Environment]::SystemDirectory) 'wsl.exe'
    $info=New-CleanWorkerStartInfo $exe (Get-WorkerPaths $InstanceId).Data ([Environment]::GetFolderPath('Windows'))
    $info.UserName=$state.UserName;$info.Domain=[Environment]::MachineName;$info.Password=$Password;$info.LoadUserProfile=$true
    # Keep no controller pipe/reader dependency. This owned client deliberately stays alive.
    $info.RedirectStandardOutput=$false;$info.RedirectStandardError=$false
    $args=@(Get-WorkerSshHoldArguments (New-WorkerSshPlan $InstanceId $m.PublicKey))
    foreach($arg in $args){$info.ArgumentList.Add($arg)}
    try{
        $p=[Diagnostics.Process]::Start($info);$p.StandardInput.Close()
        Start-Sleep -Seconds 2;$p.Refresh()
        if($p.HasExited){throw 'Foreground WSL hold exited; preserve state, no retry.'}
        $native=Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)"
        $sid=Invoke-CimMethod $native -MethodName GetOwnerSid
        if($sid.Sid -cne $m.Sid -or $native.ExecutablePath -ine $exe -or -not $native.CommandLine.EndsWith(($args -join ' '),[StringComparison]::Ordinal)){throw 'Foreground hold identity/command mismatch; preserve process.'}
        $report=[ordered]@{InstanceId=$InstanceId;Sid=$sid.Sid;PID=$p.Id;StartTimeUtc=$p.StartTime.ToUniversalTime().ToString('o');Executable=$native.ExecutablePath;CommandLine=$native.CommandLine;DistroName=(New-WorkerPlan $InstanceId).DistroName;LinuxUser='worker';ForegroundClient=$true;Persistent=$false;RebootTested=$false;IdleReconnectTested=$false}
        Write-WorkerNewFile (Join-Path $root 'result-Hold.json') ($report|ConvertTo-Json) $m.Sid
        $report
    }finally{$info.Password=$null}
}
function Initialize-WorkerSshStage([string]$InstanceId,[string]$PublicKey) {
    Assert-WorkerAdministrator
    $wsl=Read-WorkerWslStage $InstanceId
    $plan=New-WorkerSshPlan $InstanceId $PublicKey
    $root=Get-WorkerSshStagePath $InstanceId
    if(Test-Path -LiteralPath $root){$m=Read-WorkerSshStage $InstanceId;if($m.PublicKey -cne $PublicKey){throw 'Client identity changed.'};return $m}
    Assert-WorkerPlainPath $root
    $null=New-Item -ItemType Directory -Path $root -ErrorAction Stop
    Set-WorkerResourceAcl $root $wsl.Sid Metadata
    $sources=Get-WorkerSshSources;$hashes=[ordered]@{}
    foreach($name in $sources.Keys){
        Write-WorkerNewFile (Join-Path $root $name) ([IO.File]::ReadAllText($sources[$name])) $wsl.Sid
        $hashes[$name]=(Get-FileHash (Join-Path $root $name)).Hash
    }
    $script=[IO.File]::ReadAllText((Join-Path $root 'guest.sh')).Replace("`r`n","`n")
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($script))).ToLowerInvariant()
    $wslRoot=Get-WorkerWslStagePath $InstanceId
    $m=[ordered]@{Owner=$plan.Owner;InstanceId=$InstanceId;Sid=$wsl.Sid;PublicKey=$PublicKey;WslStageRoot=$wslRoot;WslManifestHash=(Get-FileHash (Join-Path $wslRoot 'manifest.json')).Hash;SourceHashes=$hashes;GuestScriptSha256=$hash}
    Write-WorkerNewFile (Join-Path $root 'manifest.json') ($m|ConvertTo-Json -Depth 5) $wsl.Sid
    Read-WorkerSshStage $InstanceId
}
function Invoke-WorkerSshStage([string]$InstanceId,[SecureString]$Password,[ValidateSet('Inspect','Configure','Restart','Verify')][string]$Action,[string]$ExpectedWslConfHash,[switch]$ReadOnly) {
    Assert-WorkerAdministrator
    $m=Read-WorkerSshStage $InstanceId
    $state=Read-WorkerState $InstanceId
    if(-not $Password -or $Password.Length -lt 1){throw 'Supply an in-memory credential.'}
    if($ReadOnly -and $Action -ne 'Verify'){throw 'ReadOnly is limited to boundary verification.'}
    $root=Get-WorkerSshStagePath $InstanceId
    switch($Action){
        Configure {
            $prior=Get-Content (Join-Path $root 'result-Inspect.json') -Raw|ConvertFrom-Json
            if($prior.Sid -cne $m.Sid -or $prior.Action -cne 'Inspect' -or $prior.Guest.wsl_conf_hash -cne $ExpectedWslConfHash){throw 'Reviewed Linux baseline mismatch.'}
            foreach($name in @('server_installed','user_exists','policy_exists','stage_exists','home_exists','group_exists','auth_exists','unit_exists')){if($prior.Guest.$name -cne 'false'){throw 'Foreign Linux baseline; no adoption.'}}
        }
        Restart {
            $prior=Get-Content (Join-Path $root 'result-Configure.json') -Raw|ConvertFrom-Json
            if($prior.Sid -cne $m.Sid -or $prior.Action -cne 'Configure' -or $prior.Guest.restart_required -cne 'true'){throw 'Configure before the one-distro restart.'}
        }
        Verify {
            $prior=Get-Content (Join-Path $root 'result-Restart.json') -Raw|ConvertFrom-Json
            if($prior.Sid -cne $m.Sid -or $prior.Action -cne 'Restart' -or $prior.Guest.distro_stopped -isnot [bool] -or -not $prior.Guest.distro_stopped){throw 'Restart before boundary verification.'}
        }
    }
    if(-not $ReadOnly){
        $marker=Join-Path $root "attempt-$Action.marker"
        $handle=[IO.File]::Open($marker,'CreateNew','Write','None');$handle.Dispose()
        Set-WorkerResourceAcl $marker $m.Sid Metadata
    }
    $exe=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'PowerShell/7/pwsh.exe'
    $info=New-CleanWorkerStartInfo $exe (Get-WorkerPaths $InstanceId).Data ([Environment]::GetFolderPath('Windows'))
    $info.UserName=$state.UserName;$info.Domain=[Environment]::MachineName;$info.Password=$Password;$info.LoadUserProfile=$true
    foreach($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $root 'child.ps1'),'-Action',$Action,'-ManifestPath',(Join-Path $root 'manifest.json'))){$info.ArgumentList.Add($arg)}
    if($Action -eq 'Configure'){$info.ArgumentList.Add('-ExpectedWslConfHash');$info.ArgumentList.Add($ExpectedWslConfHash)}
    $p=$null;$canary=[Environment]::GetEnvironmentVariable('PC_SETUP_CONTROLLER_CANARY')
    try{
        $env:PC_SETUP_CONTROLLER_CANARY=[guid]::NewGuid().ToString('N')
        $p=[Diagnostics.Process]::Start($info);$p.StandardInput.Close()
        $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit(540000)){throw 'SSH stage timeout; preserve processes/state, no retry.'}
        if($p.ExitCode -ne 0){throw 'Credentialed SSH stage failed; raw diagnostics not emitted.'}
        $text=$stdout.GetAwaiter().GetResult()
        # Like the earlier WSL adapter, this is an exit-time size check, not a streaming bound.
        if($text.Length -gt 16384 -or $stderr.GetAwaiter().GetResult().Length){throw 'Unexpected child output.'}
        $report=$text|ConvertFrom-Json
        if($report.Sid -cne $m.Sid -or $report.Administrator -isnot [bool] -or $report.Administrator -or $report.CanaryPresent -isnot [bool] -or $report.CanaryPresent -or $report.Action -cne $Action -or $report.DistroName -cne (New-WorkerPlan $InstanceId).DistroName){throw 'Worker report identity mismatch.'}
        if($Action -eq 'Verify'){
            $configured=Get-Content (Join-Path $root 'result-Configure.json') -Raw|ConvertFrom-Json
            if($report.Guest.host_fp -cne $configured.Guest.host_fp){throw 'Guest host identity changed.'}
        }
        if(-not $ReadOnly){Write-WorkerNewFile (Join-Path $root "result-$Action.json") ($report|ConvertTo-Json -Depth 6) $m.Sid}
        $report
    }finally{[Environment]::SetEnvironmentVariable('PC_SETUP_CONTROLLER_CANARY',$canary);$info.Password=$null;if($p){$p.Dispose()}}
}
