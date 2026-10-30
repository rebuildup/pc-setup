function Get-WorkerRootMaintenanceIdentity {
    [Security.Principal.WindowsIdentity]::GetCurrent()
}

function Get-WorkerRootMaintenanceCurrentProfile {
    [Environment]::GetFolderPath('UserProfile')
}

function Get-WorkerRootMaintenanceRegisteredProfile([string]$Sid) {
    [Environment]::ExpandEnvironmentVariables((Get-ItemProperty -LiteralPath "HKLM:/SOFTWARE/Microsoft/Windows NT/CurrentVersion/ProfileList/$Sid").ProfileImagePath)
}

function Get-WorkerRootMaintenanceRegistrations {
    $entries=@();$lxss=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Lxss')
    if($null -ne $lxss){try{foreach($key in $lxss.GetSubKeyNames()){$entry=$lxss.OpenSubKey($key);if($null -eq $entry){throw 'WSL registry changed during inventory.'};try{$name=$entry.GetValue('DistributionName');$base=$entry.GetValue('BasePath');$version=$entry.GetValue('Version');if($name -isnot [string] -or $base -isnot [string] -or $version -isnot [int]){throw 'Malformed WSL registry entry.'};$entries+=@{Name=$name;BasePath=$base;Version=$version}}finally{$entry.Dispose()}}}finally{$lxss.Dispose()}}
    $entries
}

function Get-WorkerRootMaintenanceWslExecutable {
    Join-Path ([Environment]::SystemDirectory) 'wsl.exe'
}

function Invoke-WorkerRootMaintenanceChildCore([ValidateSet('Inspect','Apply')][string]$Action,[string]$ManifestPath,[string]$Nonce){
    if(-not $IsWindows -or -not [Environment]::Is64BitProcess){throw 'Native x64 Windows only.'}
    $stage=Get-Content -LiteralPath $ManifestPath -Raw|ConvertFrom-Json
    $identity=Get-WorkerRootMaintenanceIdentity
    if($stage.Owner -cne 'pc-setup/windows-worker-root-maintenance/v1' -or $identity.User.Value -cne $stage.Sid -or $identity.Groups.Value -contains 'S-1-5-32-544' -or (Test-Path Env:/PC_SETUP_CONTROLLER_CANARY)){throw 'Root maintenance identity/environment mismatch.'}
    $stageRoot=Split-Path -Parent $ManifestPath
    foreach($name in @('contract.ps1','child.ps1','child-runtime.ps1','root-maintenance.sh')){
        $path=Join-Path $stageRoot $name
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $stage.SourceHashes.$name){throw 'Root maintenance source changed.'}
    }
    if((Get-FileHash -LiteralPath $stage.WorkerManifest -Algorithm SHA256).Hash -cne $stage.WorkerManifestHash){throw 'Worker manifest changed.'}
    $state=Get-Content -LiteralPath $stage.WorkerManifest -Raw|ConvertFrom-Json
    $plan=New-WorkerRootMaintenancePlan $state.InstanceId $state.MemoryGB $state.Processors
    if($state.Sid -cne $stage.Sid -or $plan.DistroName -cne $stage.DistroName -or $plan.MemoryGB -ne $stage.MemoryGB -or $plan.Processors -ne $stage.Processors){throw 'Root maintenance worker identity drift.'}
    $profile=Get-WorkerRootMaintenanceCurrentProfile
    $registered=Get-WorkerRootMaintenanceRegisteredProfile $stage.Sid
    if(-not $profile -or $profile -ine $registered -or (Test-Path Env:/PC_SETUP_CONTROLLER_CANARY)){throw 'Native worker profile/environment mismatch.'}
    if(([IO.File]::ReadAllText((Join-Path $profile '.wslconfig')))-cne (Get-WorkerRootMaintenanceWslConfig $plan)){throw 'Worker WSL profile configuration drift.'}
    Assert-WorkerRootMaintenanceRegistration (Get-WorkerRootMaintenanceRegistrations) $plan $stage.InstallLocation|Out-Null
    if((Get-FileHash -LiteralPath (Join-Path $stageRoot 'root-maintenance.sh') -Algorithm SHA256).Hash -cne $stage.RootScriptHash){throw 'Pinned root maintenance script hash mismatch.'}
    $scriptText=[IO.File]::ReadAllText((Join-Path $stageRoot 'root-maintenance.sh')).Replace("`r`n","`n")
    $report=Invoke-WorkerRootMaintenanceWslScript (Get-WorkerRootMaintenanceWslExecutable) $plan $Action $Nonce $scriptText
    [ordered]@{InstanceId=$plan.InstanceId;Sid=$identity.User.Value;Administrator=$false;CanaryPresent=$false;DistroName=$plan.DistroName;Action=$Action;RootUid=$report.Uid;Packages=$report.Packages;Missing=$report.Missing;Complete=$report.Complete;Nonce=$Nonce}|ConvertTo-Json -Compress
}
