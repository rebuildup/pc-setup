$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Join-Path $PSScriptRoot '../platforms/windows-11/ssh-poc'
if(-not(Test-Path "$root/task-contract.ps1")){throw 'SSH task contract not implemented'}
. "$root/task-contract.ps1"
$parseErrors=$null
Get-ChildItem "$root/*.ps1",$PSCommandPath | ForEach-Object {
    $null=[Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$null,[ref]$parseErrors)
    if($parseErrors){throw $parseErrors}
}
function Check($Value,[string]$Message){if(-not $Value){throw $Message}}
function Refuses([scriptblock]$Body){$bad=$false;try{& $Body|Out-Null}catch{$bad=$true};Check $bad 'Expected refusal'}
$id='2a1084ec-5389-4b0b-a0f0-9a38fcfaece5'
$pwsh='C:\Program Files\PowerShell\7\pwsh.exe'
$worker='C:\ProgramData\pc-setup-ssh-poc-runtime\task-worker.ps1'
$xml=New-PocTaskXml $id $pwsh $worker
Assert-PocTaskXml $xml $xml
$doc=[xml]$xml
Check ($doc.Task.Principals.Principal.UserId -ceq 'S-1-5-18') 'Task must run as SYSTEM without a stored password'
Check ($doc.Task.Settings.ExecutionTimeLimit -ceq 'PT0S') 'Server must not stop after a default task time limit'
Check ($doc.Task.Actions.Exec.Arguments -match '-NoProfile' -and $doc.Task.Actions.Exec.Arguments -notmatch '(?i)password|token|private') 'Unsafe task command'
Refuses { Assert-PocTaskXml ($xml.Replace('S-1-5-18','S-1-5-32-544')) $xml }
Refuses { Assert-PocTaskXml ($xml.Replace('-NoProfile','-Command')) $xml }
Refuses { Assert-PocTaskXml ($xml.Replace('<BootTrigger>','<LogonTrigger>').Replace('</BootTrigger>','</LogonTrigger>')) $xml }
Refuses { Assert-PocTaskXml ($xml.Replace('PT0S','PT72H')) $xml }
Refuses { Assert-PocTaskXml ($xml.Replace('IgnoreNew','Parallel')) $xml }
Refuses { Assert-PocTaskXml ($xml.Replace('<BootTrigger>','<BootTrigger><EndBoundary>2000-01-01T00:00:00</EndBoundary>')) $xml }
Refuses { Assert-PocTaskXml ($xml.Replace('<BootTrigger>','<BootTrigger><StartBoundary>2099-01-01T00:00:00</StartBoundary>')) $xml }
Refuses { Assert-PocTaskXml ($xml.Replace('<BootTrigger>','<BootTrigger><Delay>PT5H</Delay>')) $xml }
Refuses { Assert-PocTaskXml ($xml.Replace('<Settings>','<Settings><RunOnlyIfIdle>true</RunOnlyIfIdle>')) $xml }
Refuses { Assert-PocTaskXml ($xml.Replace('<Settings>','<Settings><RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>')) $xml }
Refuses { Assert-PocTaskXml ($xml.Replace('<RunOnlyIfIdle>false','<RunOnlyIfIdle>true')) $xml }
Refuses { Assert-PocTaskXml ($xml.Replace('<RunOnlyIfNetworkAvailable>false','<RunOnlyIfNetworkAvailable>true')) $xml }
Refuses { New-PocTaskXml 'foreign' $pwsh $worker }
Refuses { New-PocTaskXml $id 'relative.exe' $worker }
Assert-PocSshdSignature 'Valid' 'CN=Microsoft Windows, O=Microsoft Corporation, C=US'
Refuses { Assert-PocSshdSignature 'NotSigned' 'CN=Microsoft Windows, O=Microsoft Corporation, C=US' }
Refuses { Assert-PocSshdSignature 'Valid' 'CN=Unknown Vendor, O=Unknown Vendor, C=US' }
if($IsWindows){
    Assert-PocTaskAcl 'O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)'
    Refuses { Assert-PocTaskAcl 'O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;BU)' }
    Refuses { Assert-PocTaskAcl 'O:SYG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)' }
    Refuses { Assert-PocTaskAcl 'O:BAG:BAD:(A;;FA;;;SY)(A;;FA;;;BA)' }
    Refuses { Assert-PocTaskAcl 'O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;SY)' }
    $isAdmin=([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if($isAdmin){
        $service=New-Object -ComObject 'Schedule.Service';$service.Connect()
        $folder=$service.GetFolder('\')
        # TASK_VALIDATE_ONLY=1 checks the real OS schema; it does not create a task.
        $null=$folder.RegisterTask(('pc-setup-validation-'+[guid]::NewGuid().ToString('N')),$xml,1,'SYSTEM',$null,5,'O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)')
        Write-Output 'Task Scheduler schema validation: PASS (validate-only, no task created)'
    }else{Write-Output 'SKIP real Task Scheduler schema validation: elevation required'}
}

# Guard entrypoint ordering: no enrollment/native
# verification may precede the signature gate.
foreach($entry in @('ssh-task.ps1','task-worker.ps1')){
    $source=Get-Content (Join-Path $PSScriptRoot "../platforms/windows-11/ssh-poc/$entry") -Raw
    $signatureAt=$source.IndexOf('Assert-PocSshdSignature ([string]$sshdSignature.Status)')
    $verifyAt=$source.IndexOf("'ssh-poc.ps1') -Action Verify")
    Check ($signatureAt -ge 0 -and $verifyAt -gt $signatureAt) "Signature must precede enrollment/native verification: $entry"
}

Write-Output 'Dedicated SSH task contract tests: PASS'
