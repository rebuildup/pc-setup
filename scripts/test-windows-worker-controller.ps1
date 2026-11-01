$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$path=Join-Path $PSScriptRoot 'windows-worker-controller.ps1'
$source=Get-Content -LiteralPath $path -Raw
$tokens=$null;$errors=$null
[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)|Out-Null
if($errors){throw "Worker controller syntax errors: $($errors.Count)"}

$required=@(
    "WorkerControllerInstanceId = '2a1084ec-5389-4b0b-a0f0-9a38fcfaece5'",
    "WorkerControllerInfisicalSha256 = 'E840DDA7C58586559F82D364DEA5FDB3DFFF61C28E32E6E2F59715FC7A565305'",
    "WorkerControllerSecretCaptureSha256 = '7DB45CF227FBC44D879C05DAEB33630A3BB120AAEE76B62D8721490A651A5E27'",
    '[WorkerSecretCapture]::Capture($info,15000)',
    'Invoke-WorkerGatewayRepairV1 $id $password',
    'Initialize-WorkerKeyStage $id $OperationId $password Add $key $PreviousOperationId',
    'Invoke-WorkerKeyStage $id $OperationId $password $stageAction',
    'Install-WorkerGatewayLifecycleV1 $id $Root $ExpectedCommit $InfisicalSource',
    'Initialize-WorkerRootMaintenanceStage $id $Root $ExpectedCommit',
    'Invoke-WorkerRootMaintenanceV1 $id $password Apply $Root $ExpectedCommit',
    'Invoke-WorkerWslStage $id $password Inventory $ProtectedFile $ProtectedDirectory',
    'WslRegistration -cne ''registered''',
    'FromMinutes(15)',
    "SetAccessRuleProtection(`$true,`$false)",
    'unknown-worker-hive-not-loaded',
    'NoAutomaticRetry=$true'
)
foreach($value in $required){if(-not $source.Contains($value)){throw "Worker controller contract missing: $value"}}
foreach($forbidden in @('wsl --unregister','Remove-LocalUser','Remove-ScheduledTask','Stop-Service -Name sshd','Restart-Service -Name sshd')){if($source.Contains($forbidden)){throw "Worker controller includes forbidden mutation: $forbidden"}}
if($source -match '(?im)Write-Host.+password|ConvertFrom-SecureString|Set-Content.+password|Environment\[[^]]*PASSWORD'){throw 'Worker controller must not serialize or expose credentials.'}

$actions=[regex]::Match($source,"ValidateSet\((?<actions>[^)]*)\)")
if(-not $actions.Success){throw 'Worker controller action allowlist missing.'}
$actionNames=@([regex]::Matches($actions.Groups['actions'].Value,"'([^']+)'" )|ForEach-Object{$_.Groups[1].Value})
$expected=@('Status','WslInventory','GatewayRepair','KeyPrepare','KeyVerifyBefore','KeyUpdate','KeyVerifyAfter','KeyGateway','LifecycleInstall','MaintenanceStage','MaintenanceInspect','MaintenanceApply')
if(($actionNames -join ',') -cne ($expected -join ',')){throw 'Worker controller action set changed without updating its contract test.'}

$moduleBoundary=$source.IndexOf("[Environment]::SetEnvironmentVariable('PSModulePath'",[StringComparison]::Ordinal)
$preference=$source.IndexOf('$ErrorActionPreference = ''Stop''',[StringComparison]::Ordinal)
if($moduleBoundary -lt 0 -or $preference -lt $moduleBoundary){throw 'PSModulePath must be fixed before PowerShell error/cmdlet setup.'}
$prefix=$source.Substring(0,$moduleBoundary)
if($prefix -match '(?im)\b(Get-Item|Get-FileHash|Test-Path|Join-Path|Set-Acl|Get-Acl|Write-Output|Import-Module)\b'){throw 'A PowerShell cmdlet appears before the .NET PSModulePath boundary.'}

# Launch the real entrypoint in a fresh pwsh process whose inherited module
# search path contains a fake CurrentUser Modules directory. The self-test exits
# immediately after the .NET boundary and before privilege/source checks.
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('pc-setup-controller-module-boundary-'+[guid]::NewGuid().ToString('N'))
$poisonModules=Join-Path $fixtureRoot 'CurrentUser/Modules'
[void][IO.Directory]::CreateDirectory($poisonModules)
$pwsh=if($IsWindows){Join-Path $PSHOME 'pwsh.exe'}else{Join-Path $PSHOME 'pwsh'}
$info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$pwsh;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
$info.Environment['PSModulePath']=$poisonModules
foreach($arg in @('-NoProfile','-NonInteractive','-File',$path,'-Action','Status','-ExpectedCommit',('0'*40),'-ExpectedControllerSha256',('0'*64),'-SelfTestModuleBoundary')){$info.ArgumentList.Add($arg)}
$process=$null
try{
    $process=[Diagnostics.Process]::Start($info)
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    if(-not $process.WaitForExit(30000)){throw 'Controller module-boundary child timed out.'}
    $actual=$stdout.GetAwaiter().GetResult().Trim();$errorText=$stderr.GetAwaiter().GetResult()
    if($process.ExitCode -ne 0 -or $errorText -or $actual.Split([IO.Path]::PathSeparator) -contains $poisonModules){throw 'Fresh controller process retained the poisoned module directory.'}
    $expectedModules=[Collections.Generic.List[string]]::new();$pwshModules=[IO.Path]::Combine($PSHOME,'Modules')
    if([IO.Directory]::Exists($pwshModules)){$expectedModules.Add($pwshModules)}
    if($IsWindows){$windowsModules=[IO.Path]::Combine([Environment]::SystemDirectory,'WindowsPowerShell','v1.0','Modules');if([IO.Directory]::Exists($windowsModules)){$expectedModules.Add($windowsModules)}}
    if($actual -cne [string]::Join([IO.Path]::PathSeparator,$expectedModules)){throw 'Fresh controller process module path differs from the approved platform directories.'}
}finally{
    if($process){$process.Dispose()}
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $target=[IO.Path]::GetFullPath($fixtureRoot)
    if($target.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue}
}
Write-Output 'Windows worker recovery controller source contract PASS.'
