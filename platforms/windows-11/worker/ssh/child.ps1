[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Inspect','Configure','Restart','Verify')][string]$Action,[Parameter(Mandatory)][string]$ManifestPath,[string]$ExpectedWslConfHash)
$env:PSModulePath=[IO.Path]::Combine($PSHOME,'Modules')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $IsWindows -or -not [Environment]::Is64BitProcess){throw 'Native x64 only.'}
. (Join-Path $PSScriptRoot 'worker-contract.ps1')
. (Join-Path $PSScriptRoot 'contract.ps1')
$stage=Get-Content -LiteralPath $ManifestPath -Raw|ConvertFrom-Json
$plan=New-WorkerSshPlan $stage.InstanceId $stage.PublicKey
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if($stage.Owner -cne $plan.Owner -or $identity.User.Value -cne $stage.Sid -or $identity.Groups.Value -contains 'S-1-5-32-544' -or (Test-Path Env:/PC_SETUP_CONTROLLER_CANARY)){throw 'Worker SSH identity/environment mismatch.'}
$registration=(& (Join-Path $stage.WslStageRoot 'wsl-child.ps1') -Mode Verify -ManifestPath (Join-Path $stage.WslStageRoot 'manifest.json'))|ConvertFrom-Json
if(-not $registration.RegistrationVerified -or $registration.Sid -cne $stage.Sid -or $registration.DistroName -cne $plan.DistroName){throw 'Owned WSL registry mismatch.'}
$script=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'guest.sh')).Replace("`r`n","`n")
$scriptHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($script))).ToLowerInvariant()
if($scriptHash -cne $stage.GuestScriptSha256){throw 'Guest stdin source drift.'}
if($Action -eq 'Configure' -and $ExpectedWslConfHash -cnotmatch '^(absent|[a-f0-9]{64})$'){throw 'Provide the reviewed baseline hash.'}
$info=[Diagnostics.ProcessStartInfo]::new()
$info.FileName=Join-Path ([Environment]::SystemDirectory) 'wsl.exe';$info.UseShellExecute=$false;$info.CreateNoWindow=$true
$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
if($Action -eq 'Restart'){
    # Stop only this newly enrolled distro. No global shutdown, unregister or retry.
    foreach($arg in @('--terminate',$plan.DistroName)){$info.ArgumentList.Add($arg)}
}else{
    foreach($arg in @('--distribution',$plan.DistroName,'--user','root','--exec','/usr/bin/env','-i','PATH=/usr/sbin:/usr/bin:/sbin:/bin','/bin/bash','-s','--',$Action,$plan.InstanceId,$plan.PublicKey,$scriptHash,$(if($ExpectedWslConfHash){$ExpectedWslConfHash}else{'absent'}))){$info.ArgumentList.Add($arg)}
}
$p=[Diagnostics.Process]::Start($info)
try{
    $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
    if($Action -ne 'Restart'){$p.StandardInput.Write($script)}
    $p.StandardInput.Close()
    if(-not $p.WaitForExit(480000)){throw 'Guest stage timeout; preserve state/process, no retry.'}
    if($p.ExitCode -ne 0){throw 'Guest SSH stage failed; inspect owned private diagnostics.'}
    $text=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
    if($text.Length -gt 8192 -or $errorText.Length -gt 16384){throw 'Unexpected guest output size.'}
    $guest=if($Action -eq 'Restart'){@{action='Restart';distro_stopped=$true}}else{ConvertFrom-WorkerGuestReport $text $Action}
    [ordered]@{Sid=$stage.Sid;Administrator=$false;CanaryPresent=$false;DistroName=$plan.DistroName;Action=$Action;Guest=$guest;DiagnosticPresent=($errorText.Length -gt 0)}|ConvertTo-Json -Depth 5
}finally{$p.Dispose()}
