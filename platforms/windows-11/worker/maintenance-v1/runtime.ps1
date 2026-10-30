$approvedModulePaths=[Collections.Generic.List[string]]::new()
$pwshModules=[IO.Path]::Combine($PSHOME,'Modules')
if([IO.Directory]::Exists($pwshModules)){$approvedModulePaths.Add($pwshModules)}
if($IsWindows){$windowsModules=[IO.Path]::Combine([Environment]::SystemDirectory,'WindowsPowerShell','v1.0','Modules');if([IO.Directory]::Exists($windowsModules)){$approvedModulePaths.Add($windowsModules)}}
[Environment]::SetEnvironmentVariable('PSModulePath',[string]::Join([IO.Path]::PathSeparator,$approvedModulePaths),'Process')
. (Join-Path $PSScriptRoot '../wsl-runtime.ps1')
. (Join-Path $PSScriptRoot 'contract.ps1')

$script:WorkerRootMaintenanceOwner='pc-setup/windows-worker-root-maintenance/v1'
$script:WorkerRootMaintenanceScriptHash='6099101DDF8D9A044B9D3B13C4E000146D8017DD53114AE514AA073D29154B98'
$script:WorkerRootMaintenanceCommitRegex='^[0-9a-f]{40}$'

function Get-WorkerRootMaintenanceStagePath([string]$InstanceId){
    $null=New-WorkerPlan $InstanceId
    Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "pc-setup-worker-maintenance-v1-$InstanceId"
}

function Assert-WorkerRootMaintenanceCheckout([string]$RepositoryRoot,[string]$ExpectedCommit){
    if($ExpectedCommit -cnotmatch $script:WorkerRootMaintenanceCommitRegex){throw 'Expected a canonical reviewed pc-setup commit.'}
    if((git -C $RepositoryRoot rev-parse HEAD 2>$null|Out-String).Trim() -cne $ExpectedCommit){throw 'pc-setup checkout differs from the reviewed source commit.'}
    $status=@(& git -C $RepositoryRoot status --porcelain --untracked-files=all 2>$null)
    if($LASTEXITCODE -ne 0 -or $status.Count){throw 'pc-setup checkout must be clean before root maintenance.'}
}

function Read-WorkerRootMaintenanceStage([string]$InstanceId,[string]$RepositoryRoot,[string]$ExpectedCommit){
    Assert-WorkerRootMaintenanceCheckout $RepositoryRoot $ExpectedCommit
    $worker=Read-WorkerState $InstanceId
    $wsl=Read-WorkerWslStage $InstanceId
    $root=Get-WorkerRootMaintenanceStagePath $InstanceId
    $names=@('manifest.json','contract.ps1','child.ps1','child-runtime.ps1','root-maintenance.sh')
    Assert-WorkerResourceAcl $root $worker.Sid Metadata
    $actual=@(Get-ChildItem -LiteralPath $root -Force|ForEach-Object Name|Sort-Object)
    if(Compare-Object ($names|Sort-Object) $actual){throw 'Foreign or partial root maintenance stage.'}
    foreach($name in $names){Assert-WorkerResourceAcl (Join-Path $root $name) $worker.Sid Metadata}
    $manifest=Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw|ConvertFrom-Json
    $plan=New-WorkerPlan $InstanceId
    if($manifest.Owner -cne $script:WorkerRootMaintenanceOwner -or $manifest.InstanceId -cne $InstanceId -or $manifest.Sid -cne $worker.Sid -or $manifest.DistroName -cne $plan.DistroName -or $manifest.InstallLocation -cne $wsl.InstallLocation -or $manifest.WorkerManifest -cne (Join-Path (Get-WorkerPaths $InstanceId).Metadata 'manifest.json') -or $manifest.WorkerManifestHash -cne (Get-FileHash $manifest.WorkerManifest -Algorithm SHA256).Hash -or $manifest.SourceCommit -cne $ExpectedCommit){throw 'Root maintenance stage identity/worker manifest drift.'}
    $manifestPackages=@($manifest.PackageList) -join ',';$expectedPackages=(Get-WorkerRootMaintenancePackages) -join ','
    if($manifestPackages -cne $expectedPackages){throw 'Root maintenance package list drift.'}
    $sourceRoot=Join-Path $RepositoryRoot 'platforms/windows-11/worker/maintenance-v1'
    foreach($name in @('contract.ps1','child.ps1','child-runtime.ps1','root-maintenance.sh')){
        $source=Join-Path $sourceRoot $name;$staged=Join-Path $root $name
        if((Get-FileHash $source -Algorithm SHA256).Hash -cne $manifest.SourceHashes.$name -or (Get-FileHash $staged -Algorithm SHA256).Hash -cne $manifest.SourceHashes.$name){throw 'Root maintenance source/hash drift.'}
    }
    if($manifest.RootScriptHash -cne $script:WorkerRootMaintenanceScriptHash){throw 'Root maintenance script differs from its reviewed pin.'}
    $manifest
}

function Initialize-WorkerRootMaintenanceStage([string]$InstanceId,[string]$RepositoryRoot,[string]$ExpectedCommit){
    Assert-WorkerAdministrator
    Assert-WorkerRootMaintenanceCheckout $RepositoryRoot $ExpectedCommit
    $worker=Read-WorkerState $InstanceId;$wsl=Read-WorkerWslStage $InstanceId
    $root=Get-WorkerRootMaintenanceStagePath $InstanceId
    if(Test-Path -LiteralPath $root){return Read-WorkerRootMaintenanceStage $InstanceId $RepositoryRoot $ExpectedCommit}
    $sourceRoot=Join-Path $RepositoryRoot 'platforms/windows-11/worker/maintenance-v1'
    Assert-WorkerPlainPath $sourceRoot
    $names=@('contract.ps1','child.ps1','child-runtime.ps1','root-maintenance.sh')
    if((Get-FileHash (Join-Path $sourceRoot 'root-maintenance.sh') -Algorithm SHA256).Hash -cne $script:WorkerRootMaintenanceScriptHash){throw 'Root maintenance script hash differs from its reviewed pin.'}
    foreach($name in $names){if((Get-Item -LiteralPath (Join-Path $sourceRoot $name) -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Root maintenance source cannot contain reparse points.'}}
    $null=New-Item -ItemType Directory -Path $root -ErrorAction Stop
    Set-WorkerResourceAcl $root $worker.Sid Metadata
    $hashes=[ordered]@{}
    foreach($name in $names){
        $source=Join-Path $sourceRoot $name;$destination=Join-Path $root $name
        [IO.File]::Copy($source,$destination,$false)
        Set-WorkerResourceAcl $destination $worker.Sid Metadata
        $hashes[$name]=(Get-FileHash $destination -Algorithm SHA256).Hash
    }
    $workerManifest=Join-Path (Get-WorkerPaths $InstanceId).Metadata 'manifest.json'
    $plan=New-WorkerPlan $InstanceId
    $manifest=[ordered]@{Owner=$script:WorkerRootMaintenanceOwner;InstanceId=$InstanceId;Sid=$worker.Sid;DistroName=$plan.DistroName;MemoryGB=$plan.MemoryGB;Processors=$plan.Processors;InstallLocation=$wsl.InstallLocation;WorkerManifest=$workerManifest;WorkerManifestHash=(Get-FileHash $workerManifest -Algorithm SHA256).Hash;SourceCommit=$ExpectedCommit;SourceHashes=$hashes;RootScriptHash=$hashes['root-maintenance.sh'];PackageList=@(Get-WorkerRootMaintenancePackages);PreparedAtUtc=[DateTime]::UtcNow.ToString('o')}
    Write-WorkerNewFile (Join-Path $root 'manifest.json') ($manifest|ConvertTo-Json -Depth 6) $worker.Sid
    Set-WorkerResourceAcl (Join-Path $root 'manifest.json') $worker.Sid Metadata
    Read-WorkerRootMaintenanceStage $InstanceId $RepositoryRoot $ExpectedCommit
}

function Start-WorkerRootMaintenanceCredentialedChild([Diagnostics.ProcessStartInfo]$StartInfo) {
    [Diagnostics.Process]::Start($StartInfo)
}

function Invoke-WorkerRootMaintenanceChild([string]$InstanceId,[SecureString]$Password,[ValidateSet('Inspect','Apply')][string]$Action,[string]$RepositoryRoot,[string]$ExpectedCommit){
    $stage=Read-WorkerRootMaintenanceStage $InstanceId $RepositoryRoot $ExpectedCommit
    $worker=Read-WorkerState $InstanceId
    if(-not $Password -or $Password.Length -lt 1){throw 'Supply the in-memory Windows worker credential.'}
    $nonce=[guid]::NewGuid().ToString('N')
    $exe=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'PowerShell/7/pwsh.exe'
    $info=New-CleanWorkerStartInfo $exe (Get-WorkerPaths $InstanceId).Data ([Environment]::GetFolderPath('Windows'))
    $info.UserName=$worker.UserName;$info.Domain=[Environment]::MachineName;$info.Password=$Password;$info.LoadUserProfile=$true
    foreach($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path (Get-WorkerRootMaintenanceStagePath $InstanceId) 'child.ps1'),'-Action',$Action,'-ManifestPath',(Join-Path (Get-WorkerRootMaintenanceStagePath $InstanceId) 'manifest.json'),'-Nonce',$nonce)){$info.ArgumentList.Add($arg)}
    $previousCanary=[Environment]::GetEnvironmentVariable('PC_SETUP_CONTROLLER_CANARY');$process=$null
    try{
        $env:PC_SETUP_CONTROLLER_CANARY=[guid]::NewGuid().ToString('N')
        $process=Start-WorkerRootMaintenanceCredentialedChild $info;$process.StandardInput.Close()
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(510000)){throw 'Worker root maintenance timed out; preserve state/processes and inspect before retrying.'}
        if($process.ExitCode -ne 0){throw 'Worker root maintenance failed; no raw package diagnostics emitted.'}
        $text=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
        if($text.Length -gt 16384 -or $errorText.Length){throw 'Unexpected worker root maintenance child output.'}
        $report=$text|ConvertFrom-Json
        if($report.Sid -cne $stage.Sid -or $report.Administrator -isnot [bool] -or $report.Administrator -or $report.CanaryPresent -isnot [bool] -or $report.CanaryPresent -or $report.InstanceId -cne $InstanceId -or $report.DistroName -cne $stage.DistroName -or $report.Action -cne $Action -or $report.Nonce -cne $nonce -or $report.RootUid -ne 0){throw 'Invalid worker root maintenance report.'}
        $report
    }finally{[Environment]::SetEnvironmentVariable('PC_SETUP_CONTROLLER_CANARY',$previousCanary);$info.Password=$null;if($process){$process.Dispose()}}
}

function Invoke-WorkerRootMaintenanceV1([string]$InstanceId,[SecureString]$Password,[ValidateSet('Inspect','Apply')][string]$Action,[string]$RepositoryRoot,[string]$ExpectedCommit){
    if($Action -eq 'Inspect'){return Invoke-WorkerRootMaintenanceChild $InstanceId $Password Inspect $RepositoryRoot $ExpectedCommit}
    $before=Invoke-WorkerRootMaintenanceChild $InstanceId $Password Inspect $RepositoryRoot $ExpectedCommit
    if(-not $before.Complete){$null=Invoke-WorkerRootMaintenanceChild $InstanceId $Password Apply $RepositoryRoot $ExpectedCommit}
    $after=Invoke-WorkerRootMaintenanceChild $InstanceId $Password Inspect $RepositoryRoot $ExpectedCommit
    if(-not $after.Complete){throw 'Approved OS package baseline remains incomplete after maintenance.'}
    [pscustomobject]@{Action='Apply';BeforeMissing=@($before.Missing);Final=$after;Applied=(-not $before.Complete)}
}
