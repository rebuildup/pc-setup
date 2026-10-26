[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Install','Verify','Start','Stop')][string]$Action)
$requestedAction=$Action
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $IsWindows -or -not [Environment]::Is64BitProcess){throw 'Use native x64 PowerShell.'}
. (Join-Path $PSScriptRoot 'task-contract.ps1')
$sshd=Join-Path ([Environment]::SystemDirectory) 'OpenSSH/sshd.exe'
$sshdSignature=Get-AuthenticodeSignature -FilePath $sshd
Assert-PocSshdSignature ([string]$sshdSignature.Status) $sshdSignature.SignerCertificate.Subject
. (Join-Path $PSScriptRoot 'ssh-poc.ps1') -Action Verify
$runtimeRoot=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'pc-setup-ssh-poc-runtime'
$taskName='pc-setup-ssh-poc-22222'
$taskAcl='O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)'
$pwsh=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'PowerShell/7/pwsh.exe'
$taskXml=New-PocTaskXml $state.Id $pwsh (Join-Path $runtimeRoot 'task-worker.ps1')
$scheduler=New-Object -ComObject 'Schedule.Service'
$scheduler.Connect()
$folder=$scheduler.GetFolder('\')
function Get-OwnedTaskCandidate {
    try{$folder.GetTask($taskName)}catch{
        $exception=$_.Exception
        while($exception.InnerException){$exception=$exception.InnerException}
        if($exception.HResult -eq -2147024894){return $null}
        throw
    }
}
function Read-PocTaskRuntime {
    Assert-PrivateAcl $runtimeRoot
    $file=Join-Path $runtimeRoot 'manifest.json'
    Assert-PrivateAcl $file
    $m=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    if($m.Owner -cne 'pc-setup/ssh-poc-task/v1' -or $m.EnrollmentId -cne $state.Id -or $m.EnrollmentManifestHash -cne (Get-FileHash -LiteralPath $manifestPath).Hash -or $m.EnrollmentSid -cne (Get-LocalUser -Name $state.UserName).SID.Value){throw 'Runtime/enrollment ownership drift.'}
    if(@(Get-ChildItem -LiteralPath $runtimeRoot -Force).Count -ne 6){throw 'Unknown/partial runtime state.'}
    foreach($name in @('ssh-poc.ps1','contract.ps1','task-contract.ps1','task-worker.ps1')){
        $path=Join-Path $runtimeRoot $name
        Assert-PrivateAcl $path
        if((Get-FileHash -LiteralPath $path).Hash -cne $m.SourceHashes.$name -or (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name)).Hash -cne $m.SourceHashes.$name){throw 'Runtime source drift; no overwrite.'}
    }
    $logDir=Join-Path $runtimeRoot 'logs';Assert-PrivateAcl $logDir
    if(@(Get-ChildItem -LiteralPath $logDir -Force).Count -ne 1){throw 'Unexpected log contents.'}
    Assert-PrivateAcl (Join-Path $logDir 'sshd.log')
    $task=Get-OwnedTaskCandidate
    if($null -eq $task){throw 'Runtime task missing; preserve partial state.'}
    Assert-PocTaskXml $task.Xml $taskXml
    Assert-PocTaskAcl ($task.GetSecurityDescriptor(7))
    if($task.Definition.Principal.LogonType -ne 5 -or -not $task.Enabled){throw 'Task principal/status drift.'}
    $task
}
$standard=Get-CimInstance Win32_Service -Filter "Name='sshd'"
if($standard.State -ne 'Stopped' -or $standard.StartMode -ne 'Manual'){throw 'Standard sshd must remain Stopped/Manual.'}
if($requestedAction -eq 'Install'){
    if(Test-Path -LiteralPath $runtimeRoot){$null=Read-PocTaskRuntime}
    else{
        if($null -ne (Get-OwnedTaskCandidate)){throw 'Existing task is foreign; no replacement.'}
        $null=New-Item -ItemType Directory -Path $runtimeRoot -ErrorAction Stop
        Set-PrivateAcl $runtimeRoot $true
        $hashes=[ordered]@{}
        foreach($name in @('ssh-poc.ps1','contract.ps1','task-contract.ps1','task-worker.ps1')){
            $path=Join-Path $runtimeRoot $name
            Write-NewFile $path ([IO.File]::ReadAllText((Join-Path $PSScriptRoot $name)))
            $hashes[$name]=(Get-FileHash -LiteralPath $path).Hash
        }
        $logDir=Join-Path $runtimeRoot 'logs'
        $null=New-Item -ItemType Directory -Path $logDir -ErrorAction Stop
        Set-PrivateAcl $logDir $true
        Write-NewFile (Join-Path $logDir 'sshd.log') ''
        $m=[ordered]@{Owner='pc-setup/ssh-poc-task/v1';EnrollmentId=$state.Id;EnrollmentSid=(Get-LocalUser -Name $state.UserName).SID.Value;EnrollmentManifestHash=(Get-FileHash -LiteralPath $manifestPath).Hash;SourceHashes=$hashes}
        Write-NewFile (Join-Path $runtimeRoot 'manifest.json') ($m|ConvertTo-Json -Depth 5)
        # TASK_CREATE=2 and TASK_LOGON_SERVICE_ACCOUNT=5. No password is stored.
        $null=$folder.RegisterTask($taskName,$taskXml,2,'SYSTEM',$null,5,$taskAcl)
        $null=Read-PocTaskRuntime
    }
}
$ownedTask=Read-PocTaskRuntime
switch($requestedAction){
    Start {Assert-NoListener;$null=$ownedTask.Run($null)}
    Stop {$ownedTask.Stop(0)}
}
[ordered]@{Owner='pc-setup/ssh-poc-task/v1';TaskName=$taskName;TaskState=$ownedTask.State;EnrollmentId=$state.Id;ListenAddress=$state.ListenAddress;Port=22222;StandardSshdState=$standard.State;StandardSshdStartMode=$standard.StartMode;BootTriggered=$true;RebootTested=$false}|ConvertTo-Json
