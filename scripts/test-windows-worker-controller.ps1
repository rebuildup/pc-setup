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
Write-Output 'Windows worker recovery controller source contract PASS.'
