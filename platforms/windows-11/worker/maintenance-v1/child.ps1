[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Inspect','Apply')][string]$Action,
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$Nonce
)
$approvedModulePaths=[Collections.Generic.List[string]]::new()
$pwshModules=[IO.Path]::Combine($PSHOME,'Modules')
if([IO.Directory]::Exists($pwshModules)){$approvedModulePaths.Add($pwshModules)}
if($IsWindows){$windowsModules=[IO.Path]::Combine([Environment]::SystemDirectory,'WindowsPowerShell','v1.0','Modules');if([IO.Directory]::Exists($windowsModules)){$approvedModulePaths.Add($windowsModules)}}
[Environment]::SetEnvironmentVariable('PSModulePath',[string]::Join([IO.Path]::PathSeparator,$approvedModulePaths),'Process')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $IsWindows -or -not [Environment]::Is64BitProcess){throw 'Native x64 Windows only.'}
. (Join-Path $PSScriptRoot 'contract.ps1')
$stage=Get-Content -LiteralPath $ManifestPath -Raw|ConvertFrom-Json
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if($stage.Owner -cne 'pc-setup/windows-worker-root-maintenance/v1' -or $identity.User.Value -cne $stage.Sid -or $identity.Groups.Value -contains 'S-1-5-32-544' -or (Test-Path Env:/PC_SETUP_CONTROLLER_CANARY)){throw 'Root maintenance identity/environment mismatch.'}
$stageRoot=Split-Path -Parent $ManifestPath
foreach($name in @('contract.ps1','child.ps1','root-maintenance.sh')){
    $path=Join-Path $stageRoot $name
    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $stage.SourceHashes.$name){throw 'Root maintenance source changed.'}
}
if((Get-FileHash -LiteralPath $stage.WorkerManifest -Algorithm SHA256).Hash -cne $stage.WorkerManifestHash){throw 'Worker manifest changed.'}
$state=Get-Content -LiteralPath $stage.WorkerManifest -Raw|ConvertFrom-Json
$plan=New-WorkerRootMaintenancePlan $state.InstanceId $state.MemoryGB $state.Processors
if($state.Sid -cne $stage.Sid -or $plan.DistroName -cne $stage.DistroName -or $plan.MemoryGB -ne $stage.MemoryGB -or $plan.Processors -ne $stage.Processors){throw 'Root maintenance worker identity drift.'}
$profile=[Environment]::GetFolderPath('UserProfile')
$registered=[Environment]::ExpandEnvironmentVariables((Get-ItemProperty -LiteralPath "HKLM:/SOFTWARE/Microsoft/Windows NT/CurrentVersion/ProfileList/$($stage.Sid)").ProfileImagePath)
if(-not $profile -or $profile -ine $registered -or (Test-Path Env:/PC_SETUP_CONTROLLER_CANARY)){throw 'Native worker profile/environment mismatch.'}
if(([IO.File]::ReadAllText((Join-Path $profile '.wslconfig')))-cne (Get-WorkerRootMaintenanceWslConfig $plan)){throw 'Worker WSL profile configuration drift.'}
$entries=@();$lxss=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Lxss')
if($null -ne $lxss){try{foreach($key in $lxss.GetSubKeyNames()){$entry=$lxss.OpenSubKey($key);if($null -eq $entry){throw 'WSL registry changed during inventory.'};try{$name=$entry.GetValue('DistributionName');$base=$entry.GetValue('BasePath');$version=$entry.GetValue('Version');if($name -isnot [string] -or $base -isnot [string] -or $version -isnot [int]){throw 'Malformed WSL registry entry.'};$entries+=@{Name=$name;BasePath=$base;Version=$version}}finally{$entry.Dispose()}}}finally{$lxss.Dispose()}}
Assert-WorkerRootMaintenanceRegistration $entries $plan $stage.InstallLocation|Out-Null
if((Get-FileHash -LiteralPath (Join-Path $stageRoot 'root-maintenance.sh') -Algorithm SHA256).Hash -cne $stage.RootScriptHash){throw 'Pinned root maintenance script hash mismatch.'}
$scriptText=[IO.File]::ReadAllText((Join-Path $stageRoot 'root-maintenance.sh')).Replace("`r`n","`n")
$wsl=Join-Path ([Environment]::SystemDirectory) 'wsl.exe'
$info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$wsl;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
foreach($arg in (Get-WorkerRootMaintenanceArguments $plan $Action $Nonce)){$info.ArgumentList.Add($arg)}
$process=$null
try{
    $process=[Diagnostics.Process]::Start($info)
    $process.StandardInput.Write($scriptText);$process.StandardInput.Close()
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    if(-not $process.WaitForExit(480000)){throw 'Root maintenance timed out; preserve package state and inspect before rerunning.'}
    if($process.ExitCode -ne 0){throw 'Approved WSL root maintenance failed; no raw package diagnostics emitted.'}
    $text=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
    if($text.Length -gt 8192 -or $errorText.Length -gt 16384){throw 'Unexpected root maintenance output size.'}
    $report=ConvertFrom-WorkerRootMaintenanceReport $text $Action $plan.InstanceId $Nonce
    [ordered]@{InstanceId=$plan.InstanceId;Sid=$identity.User.Value;Administrator=$false;CanaryPresent=$false;DistroName=$plan.DistroName;Action=$Action;RootUid=$report.Uid;Packages=$report.Packages;Missing=$report.Missing;Complete=$report.Complete;Nonce=$Nonce}|ConvertTo-Json -Compress
}finally{if($process){$process.Dispose()}}
