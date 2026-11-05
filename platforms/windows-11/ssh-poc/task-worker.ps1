# Fixed OS-managed entrypoint. No parameters, credentials or controller environment.
$env:PSModulePath=[IO.Path]::Combine($PSHOME,'Modules')+';'+[IO.Path]::Combine([Environment]::SystemDirectory,'WindowsPowerShell/v1.0/Modules')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $IsWindows -or -not [Environment]::Is64BitProcess -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne 'S-1-5-18'){throw 'Run only as the dedicated SYSTEM scheduled task.'}
$runtimeRoot=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'pc-setup-ssh-poc-runtime'
$sourceNames=@('ssh-poc.ps1','contract.ps1','task-contract.ps1','task-worker.ps1')
# Verify the trust boundary before dot-sourcing any installed code.
foreach($path in @($runtimeRoot,(Join-Path $runtimeRoot 'manifest.json'))+@($sourceNames | ForEach-Object {Join-Path $runtimeRoot $_})){
    $item=Get-Item -LiteralPath $path -Force
    $acl=Get-Acl -LiteralPath $path
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or -not $acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne 'S-1-5-32-544'){throw 'Runtime path trust drift.'}
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if($rules.Count -ne 2){throw 'Runtime ACL entry drift.'}
    foreach($rule in $rules){if($rule.AccessControlType -ne 'Allow' -or $rule.IsInherited -or $rule.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544') -or $rule.FileSystemRights -ne 'FullControl'){throw 'Runtime ACL rights drift.'}}
}
$runtimeState=Get-Content -LiteralPath (Join-Path $runtimeRoot 'manifest.json') -Raw | ConvertFrom-Json
if($runtimeState.Owner -cne 'pc-setup/ssh-poc-task/v1'){throw 'Foreign runtime owner.'}
foreach($name in $sourceNames){if((Get-FileHash -LiteralPath (Join-Path $runtimeRoot $name)).Hash -cne $runtimeState.SourceHashes.$name){throw 'Runtime source hash drift.'}}
if(@(Get-ChildItem -LiteralPath $runtimeRoot -Force).Count -ne 6){throw 'Unexpected runtime files.'}
. (Join-Path $runtimeRoot 'task-contract.ps1')
$sshd=Join-Path ([Environment]::SystemDirectory) 'OpenSSH/sshd.exe'
$sshdSignature=Get-AuthenticodeSignature -FilePath $sshd
Assert-PocSshdSignature ([string]$sshdSignature.Status) $sshdSignature.SignerCertificate.Subject
. (Join-Path $runtimeRoot 'ssh-poc.ps1') -Action Verify
if($state.Id -cne $runtimeState.EnrollmentId -or (Get-FileHash -LiteralPath $manifestPath).Hash -cne $runtimeState.EnrollmentManifestHash -or (Get-LocalUser -Name $state.UserName).SID.Value -cne $runtimeState.EnrollmentSid){throw 'Enrollment identity drift.'}
$standard=Get-CimInstance Win32_Service -Filter "Name='sshd'"
if($standard.State -ne 'Stopped' -or $standard.StartMode -ne 'Manual'){throw 'Standard sshd changed; do not take over.'}
$logDir=Join-Path $runtimeRoot 'logs'
Assert-PrivateAcl $logDir
if(@(Get-ChildItem -LiteralPath $logDir -Force).Count -ne 1){throw 'Unexpected private log files.'}
$log=Join-Path $logDir 'sshd.log'
Assert-PrivateAcl $log
# VPN may come up after the startup trigger. Never change its registration or settings.
$ready=$false
for($i=0;$i -lt 60;$i++){
    if(Get-NetIPAddress -AddressFamily IPv4 -IPAddress $state.ListenAddress -ErrorAction SilentlyContinue){$ready=$true;break}
    Start-Sleep -Seconds 5
}
if(-not $ready){throw 'VPN address not ready; task retry policy owns recovery.'}
Assert-NoListener
& $sshd -D -f $configPath -E $log
if($LASTEXITCODE -ne 0){throw 'Dedicated sshd exited with failure; task retry policy owns recovery.'}
