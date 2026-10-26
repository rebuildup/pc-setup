[CmdletBinding()]
param([Parameter(Mandatory)][string]$ManifestPath)
$env:PSModulePath=[IO.Path]::Combine($PSHOME,'Modules')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $IsWindows -or -not [Environment]::Is64BitProcess){throw 'Native x64 only.'}
. (Join-Path $PSScriptRoot 'contract.ps1')
. (Join-Path $PSScriptRoot 'boot-contract.ps1')
$stage=Get-Content -LiteralPath $ManifestPath -Raw|ConvertFrom-Json
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if($stage.Owner -cne 'pc-setup/windows-worker-boot/v1' -or $identity.User.Value -cne $stage.Sid -or $identity.Groups.Value -contains 'S-1-5-32-544' -or (Test-Path Env:/PC_SETUP_CONTROLLER_CANARY)){throw 'Boot identity/environment mismatch.'}
# Reuse the previously pinned credentialed registry/profile checks in a child scope.
$registration=(& (Join-Path $stage.WslStageRoot 'wsl-child.ps1') -Mode Verify -ManifestPath (Join-Path $stage.WslStageRoot 'manifest.json'))|ConvertFrom-Json
if(-not $registration.RegistrationVerified -or $registration.Sid -cne $stage.Sid -or $registration.DistroName -cne $stage.DistroName){throw 'Owned registration mismatch.'}
$plan=New-WorkerPlan $stage.InstanceId
$info=[Diagnostics.ProcessStartInfo]::new()
$info.FileName=Join-Path ([Environment]::SystemDirectory) 'wsl.exe'
$info.UseShellExecute=$false;$info.CreateNoWindow=$true
$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
foreach($arg in (Get-WorkerBootArguments $plan $stage.Nonce)){$info.ArgumentList.Add($arg)}
$p=[Diagnostics.Process]::Start($info)
try{
    $p.StandardInput.Close()
    $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
    if(-not $p.WaitForExit(120000)){throw 'Boot timeout; preserve state/process. No shutdown or retry.'}
    if($p.ExitCode -ne 0){throw 'Owned Linux boot failed; preserve state.'}
    $text=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
    # First-boot vendor notices can exist on stderr; keep private, never print them.
    if($errorText.Length -gt 16384){throw 'Unexpected boot diagnostic size.'}
    $linux=ConvertFrom-WorkerBootReport $text $stage.Nonce
    [ordered]@{Sid=$stage.Sid;Administrator=$false;CanaryPresent=$false;DistroName=$stage.DistroName;RegistrationVerified=$true;LinuxBootTested=$true;DiagnosticPresent=($errorText.Length -gt 0);Linux=$linux}|ConvertTo-Json -Depth 5
}finally{$p.Dispose()}
