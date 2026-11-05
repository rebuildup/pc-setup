. (Join-Path $PSScriptRoot 'wsl-runtime.ps1')
. (Join-Path $PSScriptRoot 'boot-contract.ps1')
function Read-WorkerBootStage([string]$InstanceId) {
    $wslStage=Read-WorkerWslStage $InstanceId
    $root=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "pc-setup-worker-boot-$InstanceId"
    $names=@('manifest.json','contract.ps1','boot-contract.ps1','boot-child.ps1')
    if(Test-Path -LiteralPath (Join-Path $root 'attempt.marker')){$names+='attempt.marker'}
    Assert-WorkerResourceAcl $root $wslStage.Sid Metadata
    if(@(Get-ChildItem -LiteralPath $root -Force).Count -ne $names.Count){throw 'Foreign/partial boot stage.'}
    foreach($name in $names){Assert-WorkerResourceAcl (Join-Path $root $name) $wslStage.Sid Metadata}
    $m=Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw|ConvertFrom-Json
    $wslRoot=Get-WorkerWslStagePath $InstanceId
    $plan=New-WorkerPlan $InstanceId
    if($m.Owner -cne 'pc-setup/windows-worker-boot/v1' -or $m.InstanceId -cne $InstanceId -or $m.Sid -cne $wslStage.Sid -or $m.WslStageRoot -cne $wslRoot -or $m.DistroName -cne $plan.DistroName -or $m.WslManifestHash -cne (Get-FileHash (Join-Path $wslRoot 'manifest.json')).Hash){throw 'Boot enrollment drift.'}
    foreach($name in @('contract.ps1','boot-contract.ps1','boot-child.ps1')){
        if((Get-FileHash (Join-Path $root $name)).Hash -cne $m.SourceHashes.$name -or (Get-FileHash (Join-Path $PSScriptRoot $name)).Hash -cne $m.SourceHashes.$name){throw 'Boot source drift.'}
    }
    $null=Get-WorkerBootArguments $plan $m.Nonce
    $m
}
function Initialize-WorkerBootStage([string]$InstanceId) {
    Assert-WorkerAdministrator
    $wslStage=Read-WorkerWslStage $InstanceId
    $root=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "pc-setup-worker-boot-$InstanceId"
    if(Test-Path -LiteralPath $root){return Read-WorkerBootStage $InstanceId}
    Assert-WorkerPlainPath $root
    $null=New-Item -ItemType Directory -Path $root -ErrorAction Stop
    Set-WorkerResourceAcl $root $wslStage.Sid Metadata
    $hashes=[ordered]@{}
    foreach($name in @('contract.ps1','boot-contract.ps1','boot-child.ps1')){
        Write-WorkerNewFile (Join-Path $root $name) ([IO.File]::ReadAllText((Join-Path $PSScriptRoot $name))) $wslStage.Sid
        $hashes[$name]=(Get-FileHash (Join-Path $root $name)).Hash
    }
    $wslRoot=Get-WorkerWslStagePath $InstanceId
    $m=[ordered]@{Owner='pc-setup/windows-worker-boot/v1';InstanceId=$InstanceId;Sid=$wslStage.Sid;DistroName=(New-WorkerPlan $InstanceId).DistroName;WslStageRoot=$wslRoot;WslManifestHash=(Get-FileHash (Join-Path $wslRoot 'manifest.json')).Hash;SourceHashes=$hashes;Nonce=[guid]::NewGuid().ToString('N')}
    Write-WorkerNewFile (Join-Path $root 'manifest.json') ($m|ConvertTo-Json -Depth 4) $wslStage.Sid
    Read-WorkerBootStage $InstanceId
}
function Invoke-WorkerBootStage([string]$InstanceId,[SecureString]$Password) {
    Assert-WorkerAdministrator
    $stage=Read-WorkerBootStage $InstanceId
    $state=Read-WorkerState $InstanceId
    if(-not $Password -or $Password.Length -lt 1){throw 'Supply in-memory credential.'}
    $root=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "pc-setup-worker-boot-$InstanceId"
    # CreateNew is the last gate before the first credentialed boot attempt.
    $marker=[IO.File]::Open((Join-Path $root 'attempt.marker'),'CreateNew','Write','None')
    $marker.Dispose()
    Set-WorkerResourceAcl (Join-Path $root 'attempt.marker') $stage.Sid Metadata
    $exe=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'PowerShell/7/pwsh.exe'
    $info=New-CleanWorkerStartInfo $exe (Get-WorkerPaths $InstanceId).Data ([Environment]::GetFolderPath('Windows'))
    $info.UserName=$state.UserName;$info.Domain=[Environment]::MachineName;$info.Password=$Password;$info.LoadUserProfile=$true
    foreach($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $root 'boot-child.ps1'),'-ManifestPath',(Join-Path $root 'manifest.json'))){$info.ArgumentList.Add($arg)}
    $p=$null
    try{
        $p=[Diagnostics.Process]::Start($info);$p.StandardInput.Close()
        $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit(150000)){throw 'Boot controller timeout; preserve processes/state. No retry.'}
        if($p.ExitCode -ne 0){throw 'Credentialed boot failed; no raw diagnostics emitted.'}
        $text=$stdout.GetAwaiter().GetResult()
        if($text.Length -gt 16384 -or $stderr.GetAwaiter().GetResult().Length){throw 'Unexpected boot child output.'}
        $report=$text|ConvertFrom-Json
        if($report.Sid -cne $stage.Sid -or $report.Administrator -isnot [bool] -or $report.Administrator -or $report.CanaryPresent -isnot [bool] -or $report.CanaryPresent -or $report.Linux.Nonce -cne $stage.Nonce -or $report.DistroName -cne $stage.DistroName -or $report.LinuxBootTested -isnot [bool] -or -not $report.LinuxBootTested){throw 'Invalid boot report.'}
        $report
    }finally{$info.Password=$null;if($p){$p.Dispose()}}
}
