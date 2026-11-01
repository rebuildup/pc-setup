param(
    [Parameter(Mandatory)][ValidateSet('Status','WslInventory','GatewayRepair','KeyPrepare','KeyVerifyBefore','KeyUpdate','KeyVerifyAfter','KeyGateway','LifecycleInstall','MaintenanceStage','MaintenanceInspect','MaintenanceApply')][string]$Action,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedCommit,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedControllerSha256,
    [string]$InfisicalSource,
    [string]$ProtectedFile,
    [string]$ProtectedDirectory,
    [string]$InventoryResultPath,
    [string]$OperationId,
    [string]$PreviousOperationId,
    [string]$PublicKeyPath
)

$ErrorActionPreference = 'Stop'
$script:WorkerControllerInstanceId = '2a1084ec-5389-4b0b-a0f0-9a38fcfaece5'
$script:WorkerControllerInfisicalSha256 = 'E840DDA7C58586559F82D364DEA5FDB3DFFF61C28E32E6E2F59715FC7A565305'
$script:WorkerControllerSecretCaptureSha256 = '7DB45CF227FBC44D879C05DAEB33630A3BB120AAEE76B62D8721490A651A5E27'
$script:WorkerControllerSecretName = 'WINDOWS_PASSWORD_2A1084EC_5389_4B0B_A0F0_9A38FCFAECE5'
$script:WorkerControllerProjectId = '65933584-7b10-4469-97eb-bc3c920326fb'

function Assert-WorkerControllerPrerequisites {
    if (-not $IsWindows -or -not [Environment]::Is64BitProcess -or $PSVersionTable.PSVersion -lt [version]'7.3') { throw 'Use native Windows x64 PowerShell 7.3+.' }
    if (-not ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run from the target local administrator account in an elevated shell.' }
    $root = Split-Path -Parent $PSScriptRoot
    foreach($path in @($PSCommandPath,(Join-Path $root 'platforms/windows-11/worker/ssh/lifecycle-v1/SecretCapture.cs'))){if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Controller/source must not be a reparse point.'}}
    if ((Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash -ine $ExpectedControllerSha256) { throw 'Controller SHA256 differs from the reviewed pin.' }
    if ((git -C $root rev-parse HEAD 2>$null | Out-String).Trim() -cne $ExpectedCommit) { throw 'pc-setup checkout differs from the reviewed commit.' }
    $status = @(& git -C $root status --porcelain --untracked-files=all 2>$null)
    if ($LASTEXITCODE -ne 0 -or $status.Count -ne 0) { throw 'Use a clean pc-setup checkout at the reviewed commit.' }
    if ($Action -in @('GatewayRepair','KeyPrepare','KeyVerifyBefore','KeyUpdate','KeyVerifyAfter','KeyGateway','LifecycleInstall','MaintenanceInspect','MaintenanceApply')) {
        if (-not $InfisicalSource -or -not (Test-Path -LiteralPath $InfisicalSource -PathType Leaf) -or (Get-Item -LiteralPath $InfisicalSource -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or (Get-FileHash -LiteralPath $InfisicalSource -Algorithm SHA256).Hash -ine $script:WorkerControllerInfisicalSha256) { throw 'Infisical CLI differs from the reviewed official binary pin.' }
    }
    $capture = Join-Path $root 'platforms/windows-11/worker/ssh/lifecycle-v1/SecretCapture.cs'
    if ((Get-FileHash -LiteralPath $capture -Algorithm SHA256).Hash -ine $script:WorkerControllerSecretCaptureSha256) { throw 'SecretCapture source differs from the reviewed pin.' }
    $root
}

function Get-WorkerControllerCredential([string]$Root) {
    if ('WorkerSecretCapture' -as [type]) { throw 'Start a fresh -NoProfile PowerShell process for credential capture.' }
    Add-Type -Path (Join-Path $Root 'platforms/windows-11/worker/ssh/lifecycle-v1/SecretCapture.cs') -ErrorAction Stop
    $windows = [Environment]::GetFolderPath('Windows')
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $InfisicalSource
    $info.WorkingDirectory = [Environment]::GetFolderPath('UserProfile')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false,$true)
    $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false,$true)
    $info.Environment.Clear()
    foreach ($name in @('SystemRoot','WINDIR')) { $info.Environment[$name] = $windows }
    $info.Environment['PATH'] = Join-Path $windows 'System32'
    $info.Environment['USERPROFILE'] = [Environment]::GetFolderPath('UserProfile')
    $info.Environment['APPDATA'] = [Environment]::GetFolderPath('ApplicationData')
    $info.Environment['LOCALAPPDATA'] = [Environment]::GetFolderPath('LocalApplicationData')
    $info.Environment['INFISICAL_API_URL'] = 'https://secrets.rebuildup.dev/api'
    $info.Environment['INFISICAL_DOMAIN'] = 'https://secrets.rebuildup.dev/api'
    $info.Environment['NO_COLOR'] = '1'
    $info.Environment['INFISICAL_DISABLE_UPDATE_CHECK'] = 'true'
    foreach ($arg in @('secrets','get','--plain',"--projectId=$($script:WorkerControllerProjectId)",'--env=dev','--path=/','--domain=https://secrets.rebuildup.dev/api','--expand=false','--include-imports=false','--secret-overriding=false','--recursive=false','--silent','--telemetry=false','--log-level=error','--log-destination=stderr','--',$script:WorkerControllerSecretName)) { $info.ArgumentList.Add($arg) }
    [WorkerSecretCapture]::Capture($info,15000)
}

function Write-WorkerControllerResult([string]$Status,[object]$Evidence) {
    $base = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "pc-setup-worker-controller-$($script:WorkerControllerInstanceId)"
    if (-not (Test-Path -LiteralPath $base)) {
        $null = New-Item -ItemType Directory -Path $base -ErrorAction Stop
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true,$false)
        $acl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
        foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544')) {
            $rule = [Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow')
            $null = $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $base -AclObject $acl
    }
    $baseItem=Get-Item -LiteralPath $base -Force
    $baseAcl=Get-Acl -LiteralPath $base
    $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $baseRules=@($baseAcl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if(-not $baseItem.PSIsContainer -or ($baseItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not $baseAcl.AreAccessRulesProtected -or $baseAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $owner -or $baseRules.Count -ne 3){throw 'Controller result directory ownership/ACL drift.'}
    $allowed=@($owner,'S-1-5-18','S-1-5-32-544')
    foreach($rule in $baseRules){if($rule.IdentityReference.Value -notin $allowed -or $rule.AccessControlType -ne 'Allow' -or $rule.IsInherited -or $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl){throw 'Controller result directory ACL drift.'}}
    $record = [ordered]@{ Owner='pc-setup/windows-worker-controller/v1'; InstanceId=$script:WorkerControllerInstanceId; Action=$Action; Status=$Status; SourceCommit=$ExpectedCommit; ControllerSha256=$ExpectedControllerSha256.ToUpperInvariant(); CheckedAtUtc=[DateTime]::UtcNow.ToString('o'); Evidence=$Evidence }
    $path = Join-Path $base (('{0:yyyyMMddTHHmmssfffZ}-{1}.json' -f [DateTime]::UtcNow,[guid]::NewGuid().ToString('N')))
    $json = $record | ConvertTo-Json -Depth 10
    $stream = [IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $bytes=[Text.UTF8Encoding]::new($false).GetBytes($json);$stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
    $fileAcl=[Security.AccessControl.FileSecurity]::new()
    $fileAcl.SetAccessRuleProtection($true,$false)
    $fileAcl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544')) {
        $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','None','None','Allow')
        $null=$fileAcl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $path -AclObject $fileAcl
    [pscustomobject]@{ Status=$Status; Action=$Action; InstanceId=$script:WorkerControllerInstanceId; Evidence=$Evidence; ResultPath=$path }
}

function Get-WorkerControllerStatus([string]$Root) {
    $evidence = [ordered]@{ InstanceId=$script:WorkerControllerInstanceId; Worker='unknown'; WslStage='unknown'; WslRegistration='unknown'; V3='unknown'; Repair='unknown'; Lifecycle='unknown'; KeyStageCount=0; Maintenance='unknown'; Port22224Listeners=@() }
    try { $worker=Read-WorkerState $script:WorkerControllerInstanceId; $evidence.Worker=[ordered]@{Status='pass';Sid=$worker.Sid;UserName=$worker.UserName;DistroName=$worker.DistroName;ManifestHash=(Get-FileHash (Join-Path (Get-WorkerPaths $script:WorkerControllerInstanceId).Metadata 'manifest.json')).Hash} } catch { $evidence.Worker='invalid-or-missing' }
    if ($evidence.Worker -is [System.Collections.IDictionary] -and $evidence.Worker.Status -eq 'pass') {
        try { $wsl=Read-WorkerWslStage $script:WorkerControllerInstanceId; $evidence.WslStage=[ordered]@{Status='pass';InstallLocation=$wsl.InstallLocation;ImageSha256=$wsl.ImageSha256} } catch { $evidence.WslStage='invalid-or-missing' }
        $hive="Registry::HKEY_USERS\$($worker.Sid)\Software\Microsoft\Windows\CurrentVersion\Lxss"
        if (Test-Path -LiteralPath $hive) {
            $names=@(Get-ChildItem -LiteralPath $hive | ForEach-Object { (Get-ItemProperty -LiteralPath $_.PSPath).DistributionName })
            $expected="pcw-$($script:WorkerControllerInstanceId)"
            $evidence.WslRegistration=if ($names -ccontains $expected) {'registered'} else {'not-registered-for-loaded-worker-hive'}
        } else { $evidence.WslRegistration='unknown-worker-hive-not-loaded' }
        try { $v=Read-WorkerVerificationV3 $script:WorkerControllerInstanceId; $evidence.V3=[ordered]@{Status='pass';HostFingerprint=$v.HostFingerprint;ManifestHash=$v.ManifestHash} } catch { $evidence.V3='invalid-or-missing' }
        try { $r=Read-WorkerGatewayRepairV1 $script:WorkerControllerInstanceId; $evidence.Repair=[ordered]@{Status='pass';ListenAddress=$r.ListenAddress;ControllerAddress=$r.ControllerAddress;GuestAddress=$r.GuestAddress;Port=$r.Port;HostFingerprint=$r.HostFingerprint} } catch { $evidence.Repair='invalid-or-missing' }
        try { $evidence.Lifecycle=if (Get-ScheduledTask -TaskName (Get-WorkerGatewayLifecycleV1TaskName $script:WorkerControllerInstanceId) -TaskPath '\' -ErrorAction SilentlyContinue) {'registered'} else {'not-registered'} } catch { $evidence.Lifecycle='unknown' }
        try { $keyRoot=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "pc-setup-worker-ssh-keys-$($script:WorkerControllerInstanceId)-*"; $evidence.KeyStageCount=@(Get-ChildItem -Path $keyRoot -Directory -Force -ErrorAction SilentlyContinue).Count } catch { $evidence.KeyStageCount='unknown' }
        try { $null=Read-WorkerRootMaintenanceStage $script:WorkerControllerInstanceId $Root $ExpectedCommit; $evidence.Maintenance='stage-valid' } catch { $evidence.Maintenance='missing-or-invalid' }
    }
    $evidence.Port22224Listeners=@(Get-NetTCPConnection -State Listen -LocalPort 22224 -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{LocalAddress=$_.LocalAddress;OwningProcess=$_.OwningProcess} })
    $evidence
}

function Assert-WorkerControllerInventoryEvidence {
    if (-not $InventoryResultPath -or -not (Test-Path -LiteralPath $InventoryResultPath -PathType Leaf)) { throw 'A successful WslInventory result path is required before worker mutation.' }
    $item=Get-Item -LiteralPath $InventoryResultPath -Force
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Inventory result cannot be a reparse point.'}
    $acl=Get-Acl -LiteralPath $InventoryResultPath
    $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if(-not $acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $owner -or $rules.Count -ne 3){throw 'Inventory result ACL/owner drift.'}
    foreach($rule in $rules){if($rule.IdentityReference.Value -notin @($owner,'S-1-5-18','S-1-5-32-544') -or $rule.AccessControlType -ne 'Allow' -or $rule.IsInherited -or $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl){throw 'Inventory result ACL drift.'}}
    $record=Get-Content -LiteralPath $InventoryResultPath -Raw|ConvertFrom-Json
    $age=[DateTime]::UtcNow-[DateTime]::Parse($record.CheckedAtUtc).ToUniversalTime()
    if($age -lt [TimeSpan]::Zero -or $age -gt [TimeSpan]::FromMinutes(15) -or $record.Owner -cne 'pc-setup/windows-worker-controller/v1' -or $record.InstanceId -cne $script:WorkerControllerInstanceId -or $record.Action -cne 'WslInventory' -or $record.Status -cne 'pass' -or $record.SourceCommit -cne $ExpectedCommit -or $record.ControllerSha256 -ine $ExpectedControllerSha256 -or $record.Evidence.WslRegistration -cne 'registered'){throw 'Fresh successful worker registration inventory is required; preserve state and inspect.'}
}

function Invoke-WorkerControllerAction([string]$Root) {
    $id=$script:WorkerControllerInstanceId
    if ($Action -eq 'WslInventory') {
        if (-not $ProtectedFile -or -not $ProtectedDirectory) { throw 'WslInventory requires existing operator-owned protected file and directory paths.' }
        $password=Get-WorkerControllerCredential $Root
        try {
            $inventory=Invoke-WorkerWslStage $id $password Inventory $ProtectedFile $ProtectedDirectory
            $registration=if($inventory.RegistryCountBefore -eq 1){'registered'}else{'not-registered'}
            return [ordered]@{ WslRegistration=$registration; WorkerSid=$inventory.Sid; DistroName=$inventory.DistroName; InstallLocation=$inventory.InstallLocation; RegistryCountBefore=$inventory.RegistryCountBefore; NativeProfileLoaded=$inventory.NativeProfileLoaded; ProtectedFileReadable=$inventory.ProtectedFileReadable; ProtectedDirectoryReadable=$inventory.ProtectedDirectoryReadable; ImportCommandSucceeded=$false }
        } finally { $password.Dispose() }
    }
    if($Action -ne 'Status'){Assert-WorkerControllerInventoryEvidence}
    if ($Action -match '^Key' -and $OperationId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw 'Supply the recorded lower-case key-stage OperationId.' }
    if ($Action -eq 'KeyPrepare' -and (-not $PublicKeyPath -or -not (Test-Path -LiteralPath $PublicKeyPath -PathType Leaf))) { throw 'KeyPrepare requires an existing public-key file.' }
    if ($Action -eq 'LifecycleInstall') {
        $cliHash=(Get-FileHash -LiteralPath $InfisicalSource -Algorithm SHA256).Hash
        if ($cliHash -ine $script:WorkerControllerInfisicalSha256) { throw 'Infisical CLI hash mismatch.' }
        return Install-WorkerGatewayLifecycleV1 $id $Root $ExpectedCommit $InfisicalSource
    }
    if ($Action -eq 'MaintenanceStage') { return Initialize-WorkerRootMaintenanceStage $id $Root $ExpectedCommit }
    if ($Action -in @('MaintenanceInspect','MaintenanceApply','GatewayRepair','KeyPrepare','KeyVerifyBefore','KeyUpdate','KeyVerifyAfter','KeyGateway')) {
        $password=$null
        try {
            $password=Get-WorkerControllerCredential $Root
            switch ($Action) {
                GatewayRepair { return Invoke-WorkerGatewayRepairV1 $id $password }
                KeyPrepare {
                    if ($OperationId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or -not $PublicKeyPath) { throw 'KeyPrepare requires a new OperationId and a public key file.' }
                    $key=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $PublicKeyPath)).TrimEnd("`r","`n")
                    return Initialize-WorkerKeyStage $id $OperationId $password Add $key $PreviousOperationId
                }
                {$_ -in @('KeyVerifyBefore','KeyUpdate','KeyVerifyAfter')} {
                    if ($OperationId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw 'A previously prepared OperationId is required.' }
                    $stageAction=@{KeyVerifyBefore='VerifyBefore';KeyUpdate='Update';KeyVerifyAfter='VerifyAfter'}[$Action]
                    return Invoke-WorkerKeyStage $id $OperationId $password $stageAction
                }
                KeyGateway {
                    if ($OperationId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw 'A completed OperationId is required.' }
                    return Test-WorkerKeyStageGatewayRepairV1 $id $OperationId $password
                }
                MaintenanceInspect { return Invoke-WorkerRootMaintenanceV1 $id $password Inspect $Root $ExpectedCommit }
                MaintenanceApply { return Invoke-WorkerRootMaintenanceV1 $id $password Apply $Root $ExpectedCommit }
            }
        } finally { if ($password) { $password.Dispose() } }
    }
    throw 'Unsupported controller action.'
}

$root = $null
try {
    $root = Assert-WorkerControllerPrerequisites
    . (Join-Path $root 'platforms/windows-11/worker/runtime.ps1')
    . (Join-Path $root 'platforms/windows-11/worker/wsl-runtime.ps1')
    . (Join-Path $root 'platforms/windows-11/worker/ssh/runtime.ps1')
    . (Join-Path $root 'platforms/windows-11/worker/ssh/verification-v3/runtime.ps1')
    . (Join-Path $root 'platforms/windows-11/worker/ssh/repair-v1/runtime.ps1')
    . (Join-Path $root 'platforms/windows-11/worker/ssh/key-stage/runtime.ps1')
    . (Join-Path $root 'platforms/windows-11/worker/ssh/lifecycle-v1/runtime.ps1')
    . (Join-Path $root 'platforms/windows-11/worker/maintenance-v1/runtime.ps1')
    $evidence = if ($Action -eq 'Status') { Get-WorkerControllerStatus $root } else { Invoke-WorkerControllerAction $root }
    $result = Write-WorkerControllerResult pass $evidence
    $result | ConvertTo-Json -Depth 10
} catch {
    $safe = [ordered]@{ ErrorType=$_.Exception.GetType().FullName; ErrorMessage=$_.Exception.Message; NoAutomaticRetry=$true }
    if ($root) { try { $result=Write-WorkerControllerResult fail $safe; $result | ConvertTo-Json -Depth 6 } catch { '{"Status":"fail","ResultPath":"unavailable","NoAutomaticRetry":true}' } }
    else { '{"Status":"fail","Preflight":"failed","NoAutomaticRetry":true}' }
    exit 1
}
