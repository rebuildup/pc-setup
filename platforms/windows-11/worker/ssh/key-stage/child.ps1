[CmdletBinding()]
param([Parameter(Mandatory)][string]$InstanceId,[Parameter(Mandatory)][string]$OperationId,[Parameter(Mandatory)][ValidateSet('VerifyBefore','Update','VerifyAfter')][string]$Action)
$env:PSModulePath=[IO.Path]::Combine($PSHOME,'Modules')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if(-not $IsWindows -or -not [Environment]::Is64BitProcess -or $InstanceId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or $OperationId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'){throw 'Unexpected native instance or operation.'}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent();$sid=$identity.User.Value
if($identity.Groups.Value -contains 'S-1-5-32-544' -or (Test-Path Env:/PC_SETUP_CONTROLLER_CANARY)){throw 'Unexpected worker token/environment.'}
function Assert-Metadata([string]$Path){
    $current=[IO.Path]::GetFullPath($Path)
    while($current){if((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse metadata ancestor.'};$parent=Split-Path -Parent $current;if($current -ceq $parent){break};$current=$parent}
    $item=Get-Item -LiteralPath $Path -Force;$acl=Get-Acl -LiteralPath $Path
    if(-not $acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne 'S-1-5-32-544'){throw 'Untrusted metadata owner.'}
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    $expected=@{'S-1-5-18'='FullControl';'S-1-5-32-544'='FullControl'};$expected[$sid]='ReadAndExecute, Synchronize'
    if($rules.Count -ne 3){throw 'Unexpected metadata ACL.'}
    foreach($principal in $expected.Keys){if(@($rules|Where-Object{$_.IdentityReference.Value -ceq $principal}).Count -ne 1){throw 'Duplicate/missing metadata principal.'}}
    $flags=if($item.PSIsContainer){[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'}else{[Security.AccessControl.InheritanceFlags]::None}
    foreach($r in $rules){if(-not $expected.ContainsKey($r.IdentityReference.Value) -or $r.AccessControlType -ne 'Allow' -or $r.IsInherited -or $r.PropagationFlags -ne 'None' -or $r.InheritanceFlags -ne $flags -or $r.FileSystemRights -ne [Security.AccessControl.FileSystemRights]$expected[$r.IdentityReference.Value]){throw 'Metadata rights drift.'}}
}
$common=[Environment]::GetFolderPath('CommonApplicationData')
$root=Join-Path $common "pc-setup-worker-ssh-verification-v3-$InstanceId"
$keyRoot=Join-Path $common "pc-setup-worker-ssh-keys-$InstanceId-$OperationId"
if($PSScriptRoot -cne $keyRoot){throw 'Unexpected key-stage location.'}
Assert-Metadata $root;Assert-Metadata "$root/manifest.json"
$v=Get-Content "$root/manifest.json" -Raw|ConvertFrom-Json
if($v.Owner -cne 'pc-setup/windows-worker-ssh-verification/v3' -or $v.InstanceId -cne $InstanceId -or $v.Sid -cne $sid -or @($v.SourceHashes.PSObject.Properties).Count -ne 4){throw 'Verifier enrollment mismatch.'}
foreach($name in @('child.ps1','contract.ps1','guest.sh','sshd-checks.sh')){Assert-Metadata "$root/$name";if((Get-FileHash "$root/$name").Hash -cne $v.SourceHashes.$name){throw 'Verifier source drift.'}}
. "$root/contract.ps1"
$setupRoot=Join-Path $common "pc-setup-worker-ssh-$InstanceId"
Assert-Metadata $setupRoot;Assert-Metadata "$setupRoot/manifest.json"
if((Get-FileHash "$setupRoot/manifest.json").Hash -cne $v.SetupManifestHash){throw 'Original setup manifest changed.'}
$m=Get-Content "$setupRoot/manifest.json" -Raw|ConvertFrom-Json
if($m.Owner -cne 'pc-setup/windows-worker-ssh/v1' -or $m.InstanceId -cne $InstanceId -or $m.Sid -cne $sid -or $m.GuestScriptSha256 -cne $v.SetupGuestScriptSha256 -or @($m.SourceHashes.PSObject.Properties).Count -ne 4){throw 'Original setup enrollment changed.'}
foreach($name in @('worker-contract.ps1','contract.ps1','child.ps1','guest.sh')){Assert-Metadata "$setupRoot/$name";if((Get-FileHash "$setupRoot/$name").Hash -cne $m.SourceHashes.$name){throw 'Original setup source drift.'}}
Assert-Metadata $keyRoot;Assert-Metadata "$keyRoot/manifest.json"
$k=Get-Content "$keyRoot/manifest.json" -Raw|ConvertFrom-Json
if($k.Owner -cne 'pc-setup/windows-worker-ssh-keys/v1' -or $k.InstanceId -cne $InstanceId -or $k.OperationId -cne $OperationId -or $k.Sid -cne $sid -or $k.SetupManifestHash -cne $v.SetupManifestHash -or $k.VerifierManifestHash -cne (Get-FileHash "$root/manifest.json").Hash -or $k.HostFingerprint -cne $v.HostFingerprint -or @($k.SourceHashes.PSObject.Properties).Count -ne 6){throw 'Key-stage identity mismatch.'}
foreach($name in @('child.ps1','contract.ps1','update-guest.sh','transaction.sh','verify-guest.sh','sshd-checks.sh')){Assert-Metadata "$keyRoot/$name";if((Get-FileHash "$keyRoot/$name").Hash -cne $k.SourceHashes.$name){throw 'Key-stage source changed.'}}
. "$setupRoot/worker-contract.ps1"; . "$setupRoot/contract.ps1"; . "$keyRoot/contract.ps1"
$plan=New-WorkerKeyTransition $InstanceId $OperationId $k.Current $k.Current.Generation $k.Action $k.Key $k.PreviousProofSha256 $k.HostFingerprint
if($plan.BeforeSha256 -cne $k.BeforeSha256 -or $plan.AfterSha256 -cne $k.AfterSha256 -or $plan.BeforeRevokedSha256 -cne $k.BeforeRevokedSha256 -or $plan.AfterRevokedSha256 -cne $k.AfterRevokedSha256 -or $plan.Generation -ne $k.Generation){throw 'Key-stage transition changed.'}
$wslRoot=Join-Path $common "pc-setup-worker-wsl-$InstanceId"
if($m.WslStageRoot -cne $wslRoot){throw 'Original WSL location changed.'}
Assert-Metadata $wslRoot;Assert-Metadata "$wslRoot/manifest.json"
if((Get-FileHash "$wslRoot/manifest.json").Hash -cne $m.WslManifestHash){throw 'Original WSL manifest changed.'}
$w=Get-Content "$wslRoot/manifest.json" -Raw|ConvertFrom-Json
if($w.Sid -cne $sid -or $w.InstanceId -cne $InstanceId){throw 'Original WSL identity changed.'}
foreach($name in @('contract.ps1','wsl-contract.ps1','wsl-child.ps1')){Assert-Metadata "$wslRoot/$name";if((Get-FileHash "$wslRoot/$name").Hash -cne $w.SourceHashes.$name){throw 'Original WSL source changed.'}}
$registration=(& "$wslRoot/wsl-child.ps1" -Mode Verify -ManifestPath "$wslRoot/manifest.json")|ConvertFrom-Json
if($registration.Sid -cne $sid -or -not $registration.RegistrationVerified -or -not $registration.NativeProfileLoaded -or $registration.Administrator -or $registration.DistroName -cne "pcw-$InstanceId"){throw 'Own WSL registration/profile mismatch.'}
$info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=Join-Path ([Environment]::SystemDirectory) 'wsl.exe';$info.UseShellExecute=$false;$info.CreateNoWindow=$true
$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
$args=@('--distribution',$registration.DistroName,'--user','root','--exec','/usr/bin/env','-i','PATH=/usr/sbin:/usr/bin:/sbin:/bin','/bin/bash','-s','--',$InstanceId)
if($Action -eq 'Update'){
    $encoded=[Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes((@($plan.Keys) -join "`n")+"`n"))
    $args+=@($OperationId,$k.BeforeSha256,$k.AfterSha256,$k.HostFingerprint,$encoded)
}else{
    $expected=if($Action -eq 'VerifyBefore'){$k.BeforeSha256}else{$k.AfterSha256}
    $args+=@($m.PublicKey,$v.SetupGuestScriptSha256,$expected)
}
foreach($arg in $args){$info.ArgumentList.Add($arg)}
$p=[Diagnostics.Process]::Start($info)
try{
    $out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
    $helper=if($Action -eq 'Update'){'transaction.sh'}else{'sshd-checks.sh'}
    $script=if($Action -eq 'Update'){'update-guest.sh'}else{'verify-guest.sh'}
    $checks=[IO.File]::ReadAllText("$keyRoot/$helper").Replace("`r`n","`n")
    $guestScript=[IO.File]::ReadAllText("$keyRoot/$script").Replace("`r`n","`n")
    $p.StandardInput.Write($checks+"`n"+$guestScript);$p.StandardInput.Close()
    if(-not $p.WaitForExit(90000) -or $p.ExitCode -ne 0){throw 'Read-only guest verifier failed; preserve state.'}
    $text=$out.GetAwaiter().GetResult();$errorText=$err.GetAwaiter().GetResult()
    if($text.Length -gt 8192 -or $errorText.Length){throw 'Unexpected verifier diagnostics.'}
    if($Action -eq 'Update'){
        $expectedText="action=UpdateKeyStage`ninstance=$InstanceId`noperation=$OperationId`nauthorization_hash=$($k.AfterSha256)`nhost_fp=$($k.HostFingerprint)`n"
        if($text.Replace("`r`n","`n") -cne $expectedText){throw 'Unexpected update report.'}
        $guest=[ordered]@{authorization_hash=$k.AfterSha256;host_fp=$k.HostFingerprint}
    }else{$guest=ConvertFrom-WorkerGuestKeyStage $text $expected}
    if($guest.host_fp -cne $v.HostFingerprint){throw 'Guest host identity changed.'}
    [ordered]@{Owner=$k.Owner;InstanceId=$InstanceId;OperationId=$OperationId;Sid=$sid;Administrator=$false;CanaryPresent=$false;DistroName=$registration.DistroName;Action=$Action;Guest=$guest;DiagnosticPresent=$false;KeyManifestHash=(Get-FileHash "$keyRoot/manifest.json").Hash;VerifierManifestHash=(Get-FileHash "$root/manifest.json").Hash}|ConvertTo-Json -Depth 6
}finally{$p.Dispose()}
