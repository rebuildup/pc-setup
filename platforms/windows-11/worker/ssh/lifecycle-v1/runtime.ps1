. (Join-Path $PSScriptRoot '../../runtime.ps1')
. (Join-Path $PSScriptRoot '../repair-v1/runtime.ps1')
. (Join-Path $PSScriptRoot 'contract.ps1')

$script:WorkerGatewayLifecycleOwner = 'pc-setup/windows-worker-gateway-lifecycle/v1'
$script:WorkerGatewayLifecycleInfisicalHash = 'E840DDA7C58586559F82D364DEA5FDB3DFFF61C28E32E6E2F59715FC7A565305'
$script:WorkerGatewayLifecycleSecretCaptureHash = '7DB45CF227FBC44D879C05DAEB33630A3BB120AAEE76B62D8721490A651A5E27'

function Get-WorkerGatewayLifecycleRelativeFiles([string]$WorkerSourceRoot) {
    @(Get-ChildItem -LiteralPath $WorkerSourceRoot -File -Recurse -Force |
        Where-Object { $_.Extension -in @('.ps1','.sh') } |
        Sort-Object FullName |
        ForEach-Object { $_.FullName.Substring($WorkerSourceRoot.TrimEnd('\').Length + 1) })
}

function Copy-WorkerGatewayLifecycleNewFile([string]$Source,[string]$Destination) {
    $stream = [IO.File]::Open($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $input = [IO.File]::OpenRead($Source)
        try { $input.CopyTo($stream) } finally { $input.Dispose() }
    } finally { $stream.Dispose() }
}

function Read-WorkerGatewayLifecycleV1([string]$InstanceId) {
    $root = Get-WorkerGatewayLifecycleV1Path $InstanceId
    $manifestPath = Join-Path $root 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Lifecycle bundle manifest is missing.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.Owner -cne $script:WorkerGatewayLifecycleOwner -or $manifest.InstanceId -cne $InstanceId) { throw 'Lifecycle bundle owner/instance drift.' }
    Assert-WorkerResourceAcl $root $manifest.OperatorSid Metadata
    Assert-WorkerResourceAcl $manifestPath $manifest.OperatorSid Metadata
    foreach ($name in @('bundle','results','temp')) { Assert-WorkerResourceAcl (Join-Path $root $name) $manifest.OperatorSid Metadata }
    foreach ($name in @('infisical.exe','SecretCapture.cs')) { Assert-WorkerResourceAcl (Join-Path $root $name) $manifest.OperatorSid Metadata }
    $rootEntries = @(Get-ChildItem -LiteralPath $root -Force | ForEach-Object Name | Sort-Object)
    if ((Compare-Object @('SecretCapture.cs','bundle','infisical.exe','manifest.json','results','temp') $rootEntries)) { throw 'Lifecycle root file set drift.' }

    $bundleRoot = Join-Path $root 'bundle'
    $actual = @(Get-ChildItem -LiteralPath $bundleRoot -File -Recurse -Force | ForEach-Object { $_.FullName.Substring($bundleRoot.TrimEnd('\').Length + 1).Replace('\','/') } | Sort-Object)
    $expected = @($manifest.Files.PSObject.Properties.Name | Where-Object { $_ -like 'bundle/*' } | ForEach-Object { $_.Substring(7) } | Sort-Object)
    if ((Compare-Object $expected $actual)) { throw 'Lifecycle source bundle file set drift.' }
    $actualDirectories = @(Get-ChildItem -LiteralPath $bundleRoot -Directory -Recurse -Force | ForEach-Object { $_.FullName.Substring($bundleRoot.TrimEnd('\').Length + 1).Replace('\','/') } | Sort-Object)
    $expectedDirectories = @($expected | ForEach-Object { $parts = $_.Split('/'); for ($i=1; $i -lt $parts.Count; $i++) { $parts[0..($i-1)] -join '/' } } | Sort-Object -Unique)
    if ((Compare-Object $expectedDirectories $actualDirectories)) { throw 'Lifecycle source bundle directory set drift.' }
    foreach ($relativeDirectory in $actualDirectories) { Assert-WorkerResourceAcl (Join-Path $bundleRoot $relativeDirectory.Replace('/','\')) $manifest.OperatorSid Metadata }
    foreach ($relative in @($manifest.Files.PSObject.Properties.Name | Where-Object { $_ -like 'bundle/*' })) {
        $path = Join-Path $root ($relative.Replace('/','\'))
        Assert-WorkerResourceAcl $path $manifest.OperatorSid Metadata
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $manifest.Files.$relative) { throw 'Lifecycle source bundle hash drift.' }
    }
    foreach ($name in @('infisical.exe','SecretCapture.cs')) {
        $path = Join-Path $root $name
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $manifest.Files.$name) { throw 'Lifecycle helper executable/source hash drift.' }
    }
    if ($manifest.Files.'infisical.exe' -cne $script:WorkerGatewayLifecycleInfisicalHash -or $manifest.Files.'SecretCapture.cs' -cne $script:WorkerGatewayLifecycleSecretCaptureHash) { throw 'Lifecycle helper differs from the reviewed official CLI/SecretCapture hashes.' }
    $manifest
}

function New-WorkerGatewayLifecycleV1Manifest(
    [string]$InstanceId,[string]$OperatorSid,[string]$OperatorName,[string]$WorkerSid,
    [string]$SourceCommit,[string]$ListenAddress,[string]$ControllerAddress,[string]$HostFingerprint,
    [hashtable]$Files,[pscustomobject]$TaskPlan
) {
    [ordered]@{
        Owner = $script:WorkerGatewayLifecycleOwner
        InstanceId = $InstanceId
        OperatorSid = $OperatorSid
        OperatorName = $OperatorName
        WorkerSid = $WorkerSid
        SourceCommit = $SourceCommit
        ListenAddress = $ListenAddress
        ControllerAddress = $ControllerAddress
        HostFingerprint = $HostFingerprint
        InfisicalProjectId = '65933584-7b10-4469-97eb-bc3c920326fb'
        InfisicalEnvironment = 'dev'
        InfisicalPath = '/'
        InfisicalSecretKey = "WINDOWS_PASSWORD_$($InstanceId.Replace('-','_').ToUpperInvariant())"
        TaskName = $TaskPlan.TaskName
        TaskPath = $TaskPlan.TaskPath
        TaskDescription = $TaskPlan.Description
        TaskLogonType = $TaskPlan.LogonType
        TaskRunLevel = $TaskPlan.RunLevel
        Files = $Files
        InstalledAtUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function New-WorkerGatewayLifecycleV1Task([pscustomobject]$Plan) {
    $action = New-ScheduledTaskAction -Execute $Plan.PowerShellPath -Argument $Plan.Arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $Plan.OperatorName
    $principal = New-ScheduledTaskPrincipal -UserId $Plan.OperatorName -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit $Plan.ExecutionTimeLimit
    Register-ScheduledTask -TaskName $Plan.TaskName -TaskPath $Plan.TaskPath -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description $Plan.Description -ErrorAction Stop
}

function Install-WorkerGatewayLifecycleV1([string]$InstanceId,[string]$RepositoryRoot,[string]$ExpectedCommit,[string]$InfisicalSource) {
    Assert-WorkerAdministrator
    $null = New-WorkerPlan $InstanceId
    if ($PSVersionTable.PSVersion -lt [version]'7.3' -or [IntPtr]::Size -ne 8) { throw 'Use 64-bit PowerShell 7.3 or later.' }
    $state = Read-WorkerState $InstanceId
    $repair = Read-WorkerGatewayRepairV1 $InstanceId
    $operator = [Security.Principal.WindowsIdentity]::GetCurrent()
    $operatorSid = $operator.User.Value
    $operatorName = $operator.Name
    if ($operatorSid -ceq $state.Sid -or $repair.Sid -cne $state.Sid) { throw 'Expected the distinct operator and dedicated worker identities.' }
    if ((git -C $RepositoryRoot rev-parse HEAD 2>$null | Out-String).Trim() -cne $ExpectedCommit) { throw 'pc-setup checkout differs from the reviewed source commit.' }
    $status = @(& git -C $RepositoryRoot status --porcelain --untracked-files=all 2>$null)
    if ($LASTEXITCODE -ne 0 -or $status.Count -ne 0) { throw 'pc-setup checkout must be clean before installing the protected lifecycle bundle.' }
    if (-not (Test-WorkerGatewayRepairAcceptedSourceHash $repair.SourceHash) -or $repair.ListenAddress -notmatch '^100\.' -or $repair.ControllerAddress -notmatch '^100\.' -or $repair.HostFingerprint -notmatch '^SHA256:[A-Za-z0-9+/]{43}$') { throw 'Current repaired worker manifest/source/scope differs from the expected VPN SSH worker.' }

    $root = Get-WorkerGatewayLifecycleV1Path $InstanceId
    $taskName = Get-WorkerGatewayLifecycleV1TaskName $InstanceId
    $existingTask = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($existingTask) { throw 'Lifecycle task name already exists; inspect it without replacing it.' }
    if (Test-Path -LiteralPath $root) { throw 'Lifecycle ProgramData path already exists; inspect it without adopting or overwriting.' }
    if ((Get-FileHash -LiteralPath $InfisicalSource -Algorithm SHA256).Hash -cne $script:WorkerGatewayLifecycleInfisicalHash) { throw 'Infisical CLI differs from the verified official v0.44.4 Windows amd64 binary.' }

    $workerSourceRoot = Join-Path $RepositoryRoot 'platforms/windows-11/worker'
    Assert-WorkerPlainPath $workerSourceRoot
    $sourceFiles = @(Get-WorkerGatewayLifecycleRelativeFiles $workerSourceRoot)
    if ($sourceFiles.Count -lt 10 -or $sourceFiles -notcontains 'ssh/lifecycle-v1/run.ps1' -or $sourceFiles -notcontains 'ssh/repair-v1/runtime.ps1') { throw 'Required worker lifecycle/repair sources are missing.' }
    foreach ($relative in $sourceFiles) { if ((Get-Item -LiteralPath (Join-Path $workerSourceRoot $relative) -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Worker source bundle cannot contain reparse points.' } }
    $rootItem = New-Item -ItemType Directory -Path $root -ErrorAction Stop
    Set-WorkerResourceAcl $root $operatorSid Metadata
    $bundleRoot = Join-Path $root 'bundle'
    $null = New-Item -ItemType Directory -Path $bundleRoot -ErrorAction Stop
    $resultsRoot = Join-Path $root 'results'
    $null = New-Item -ItemType Directory -Path $resultsRoot -ErrorAction Stop
    $tempRoot = Join-Path $root 'temp'
    $null = New-Item -ItemType Directory -Path $tempRoot -ErrorAction Stop

    $files = [ordered]@{}
    foreach ($relative in $sourceFiles) {
        $source = Join-Path $workerSourceRoot $relative
        $destinationRelative = "bundle/platforms/windows-11/worker/$($relative.Replace('\','/'))"
        $destination = Join-Path $root ($destinationRelative.Replace('/','\'))
        $destinationDirectory = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destinationDirectory)) { $null = New-Item -ItemType Directory -Path $destinationDirectory -Force -ErrorAction Stop }
        Copy-WorkerGatewayLifecycleNewFile $source $destination
        $files[$destinationRelative] = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    }
    $secretCaptureSource = Join-Path $workerSourceRoot 'ssh/lifecycle-v1/SecretCapture.cs'
    if ((Get-FileHash -LiteralPath $secretCaptureSource -Algorithm SHA256).Hash -cne $script:WorkerGatewayLifecycleSecretCaptureHash) { throw 'SecretCapture source hash differs from its audit.' }
    $secretCapturePath = Join-Path $root 'SecretCapture.cs'
    Copy-WorkerGatewayLifecycleNewFile $secretCaptureSource $secretCapturePath
    $files['SecretCapture.cs'] = (Get-FileHash -LiteralPath $secretCapturePath -Algorithm SHA256).Hash
    $infisicalPath = Join-Path $root 'infisical.exe'
    Copy-WorkerGatewayLifecycleNewFile $InfisicalSource $infisicalPath
    $files['infisical.exe'] = (Get-FileHash -LiteralPath $infisicalPath -Algorithm SHA256).Hash

    $directories = @(Get-ChildItem -LiteralPath $root -Directory -Recurse -Force | Sort-Object { $_.FullName.Length } -Descending)
    foreach ($directory in $directories) { Set-WorkerResourceAcl $directory.FullName $operatorSid Metadata }
    $rootFiles = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force)
    foreach ($file in $rootFiles) { Set-WorkerResourceAcl $file.FullName $operatorSid Metadata }
    Set-WorkerResourceAcl $root $operatorSid Metadata
    Set-WorkerResourceAcl $resultsRoot $operatorSid Metadata
    Set-WorkerResourceAcl $tempRoot $operatorSid Metadata

    $runner = Join-Path $root 'bundle/platforms/windows-11/worker/ssh/lifecycle-v1/run.ps1'
    $pwsh = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'PowerShell/7/pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwsh -PathType Leaf)) { throw 'PowerShell 7 executable missing from Program Files.' }
    $plan = New-WorkerGatewayLifecycleV1TaskPlan $InstanceId $operatorSid $state.Sid $operatorName $pwsh $runner
    $manifest = New-WorkerGatewayLifecycleV1Manifest $InstanceId $operatorSid $operatorName $state.Sid $ExpectedCommit $repair.ListenAddress $repair.ControllerAddress $repair.HostFingerprint $files $plan
    Write-WorkerNewFile (Join-Path $root 'manifest.json') ($manifest | ConvertTo-Json -Depth 8) $operatorSid
    Set-WorkerResourceAcl (Join-Path $root 'manifest.json') $operatorSid Metadata
    $null = Read-WorkerGatewayLifecycleV1 $InstanceId
    $registered = New-WorkerGatewayLifecycleV1Task $plan
    $registered = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop
    Assert-WorkerGatewayLifecycleV1Task $registered $plan | Out-Null
    [pscustomobject]@{ Owner=$script:WorkerGatewayLifecycleOwner; InstanceId=$InstanceId; TaskName=$taskName; TaskPath='\'; OperatorSid=$operatorSid; LogonType='Interactive'; RunLevel='Highest'; Trigger='AtLogOn'; PasswordStored=$false; StartupBeforeInteractiveLogon=$false; SourceCommit=$ExpectedCommit; BundlePath=$root; ListenAddress=$repair.ListenAddress; ControllerAddress=$repair.ControllerAddress; Port=22224; HostFingerprint=$repair.HostFingerprint }
}

function Remove-WorkerGatewayLifecycleV1Task([string]$InstanceId) {
    Assert-WorkerAdministrator
    $manifest = Read-WorkerGatewayLifecycleV1 $InstanceId
    $root = Get-WorkerGatewayLifecycleV1Path $InstanceId
    $runner = Join-Path $root 'bundle/platforms/windows-11/worker/ssh/lifecycle-v1/run.ps1'
    $pwsh = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'PowerShell/7/pwsh.exe'
    $plan = New-WorkerGatewayLifecycleV1TaskPlan $InstanceId $manifest.OperatorSid $manifest.WorkerSid $manifest.OperatorName $pwsh $runner
    $task = Get-ScheduledTask -TaskName $plan.TaskName -TaskPath $plan.TaskPath -ErrorAction Stop
    Assert-WorkerGatewayLifecycleV1Task $task $plan | Out-Null
    Unregister-ScheduledTask -TaskName $plan.TaskName -TaskPath $plan.TaskPath -Confirm:$false -ErrorAction Stop
    'Removed only the owned lifecycle task. The protected bundle, SSH service, WSL hold, firewall and portproxy remain untouched.'
}
