# Separate live-repair state for a V3 worker gateway. Historic V3 proofs remain immutable.
. (Join-Path $PSScriptRoot '../verification-v3/gateway.ps1')
. (Join-Path $PSScriptRoot '../key-stage/runtime.ps1')

function Get-WorkerGatewayRepairV1Path([string]$InstanceId) {
    $null = New-WorkerPlan $InstanceId
    Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "pc-setup-wsl-gateway-repair-v1-$InstanceId"
}

function Read-WorkerGatewayRepairBaseV3([string]$InstanceId) {
    $v = Read-WorkerVerificationV3 $InstanceId
    $root = Get-WorkerGatewayV3Path $InstanceId
    Assert-WorkerResourceAcl $root $v.Sid Metadata
    $files = @(Get-ChildItem -LiteralPath $root -Force)
    if ($files.Count -ne 1 -or $files[0].Name -cne 'manifest.json') { throw 'V3 gateway base state drift.' }
    $path = Join-Path $root 'manifest.json'
    Assert-WorkerResourceAcl $path $v.Sid Metadata
    $m = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($m.Owner -cne 'pc-setup/windows-worker-gateway/v3' -or $m.InstanceId -cne $InstanceId -or $m.Sid -cne $v.Sid -or $m.VerifierManifestHash -cne $v.ManifestHash -or $m.ProofHash -cne (Get-FileHash (Join-Path (Get-WorkerVerificationV3Path $InstanceId) 'result-VerifyV3.json')).Hash -or $m.SourceHash -cne (Get-FileHash (Join-Path $PSScriptRoot '../verification-v3/gateway.ps1')).Hash -or $m.HelperHash -cne (Get-FileHash (Join-Path $PSScriptRoot '../gateway.ps1')).Hash -or $m.FirewallContractHash -cne (Get-FileHash (Join-Path $PSScriptRoot '../firewall-contract.ps1')).Hash -or $m.HostFingerprint -cne $v.HostFingerprint -or $m.Port -ne 22224) { throw 'V3 gateway identity/source drift.' }
    Assert-WorkerVpnAddress $m.ListenAddress
    Assert-WorkerVpnAddress $m.ControllerAddress
    foreach ($kind in @('Allow','Block')) { Assert-WorkerGatewayRule "pc-setup-wsl-$InstanceId-22224-$kind" $kind $m }
    $m
}

function Read-WorkerGatewayRepairV1([string]$InstanceId) {
    $gateway = Read-WorkerGatewayRepairBaseV3 $InstanceId
    $root = Get-WorkerGatewayRepairV1Path $InstanceId
    Assert-WorkerResourceAcl $root $gateway.Sid Metadata
    $files = @(Get-ChildItem -LiteralPath $root -Force)
    if ($files.Count -ne 3 -or @($files | Where-Object Name -cnotin @('manifest.json','journal','instance.lock')).Count) { throw 'Unknown repair-stage state.' }
    Assert-WorkerResourceAcl (Join-Path $root 'instance.lock') $gateway.Sid Metadata
    Assert-WorkerResourceAcl (Join-Path $root 'journal') $gateway.Sid Metadata
    foreach ($entry in @(Get-ChildItem -LiteralPath (Join-Path $root 'journal') -Force)) {
        if ($entry.Name -cnotmatch '^[a-f0-9]{32}\.before\.json$') { throw 'Partial repair journal; preserve and inspect.' }
        Assert-WorkerResourceAcl $entry.FullName $gateway.Sid Metadata
    }
    $path = Join-Path $root 'manifest.json'
    Assert-WorkerResourceAcl $path $gateway.Sid Metadata
    $m = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $expected = [ordered]@{
        Owner = 'pc-setup/windows-worker-gateway-repair/v1'
        InstanceId = $InstanceId
        Sid = $gateway.Sid
        SourceHash = (Get-FileHash (Join-Path $PSScriptRoot 'runtime.ps1')).Hash
        SshManifestHash = (Get-FileHash (Join-Path (Get-WorkerSshStagePath $InstanceId) 'manifest.json')).Hash
        VerifierManifestHash = $gateway.VerifierManifestHash
        BaseGatewayManifestHash = (Get-FileHash (Join-Path (Get-WorkerGatewayV3Path $InstanceId) 'manifest.json')).Hash
        HostFingerprint = $gateway.HostFingerprint
        ListenAddress = $gateway.ListenAddress
        ControllerAddress = $gateway.ControllerAddress
        Port = 22224
        SafetyScope = $gateway.SafetyScope
    }
    foreach ($name in $expected.Keys) { if ($m.$name -cne $expected[$name]) { throw 'Repair-stage identity/source drift.' } }
    Assert-WorkerGatewayMapping @(Get-WorkerGatewayMappings) $m.ListenAddress $m.GuestAddress
    $m
}

function Initialize-WorkerGatewayRepairV1([string]$InstanceId) {
    Assert-WorkerAdministrator
    $gateway = Read-WorkerGatewayRepairBaseV3 $InstanceId
    $root = Get-WorkerGatewayRepairV1Path $InstanceId
    if (Test-Path -LiteralPath $root) { return Read-WorkerGatewayRepairV1 $InstanceId }
    Assert-WorkerPlainPath $root
    $null = New-Item -ItemType Directory -Path $root -ErrorAction Stop
    Set-WorkerResourceAcl $root $gateway.Sid Metadata
    Write-WorkerNewFile (Join-Path $root 'instance.lock') '' $gateway.Sid
    $journal = Join-Path $root 'journal'
    $null = New-Item -ItemType Directory -Path $journal -ErrorAction Stop
    Set-WorkerResourceAcl $journal $gateway.Sid Metadata
    $m = [ordered]@{
        Owner = 'pc-setup/windows-worker-gateway-repair/v1'
        InstanceId = $InstanceId
        Sid = $gateway.Sid
        SourceHash = (Get-FileHash (Join-Path $PSScriptRoot 'runtime.ps1')).Hash
        SshManifestHash = (Get-FileHash (Join-Path (Get-WorkerSshStagePath $InstanceId) 'manifest.json')).Hash
        VerifierManifestHash = $gateway.VerifierManifestHash
        BaseGatewayManifestHash = (Get-FileHash (Join-Path (Get-WorkerGatewayV3Path $InstanceId) 'manifest.json')).Hash
        HostFingerprint = $gateway.HostFingerprint
        ListenAddress = $gateway.ListenAddress
        ControllerAddress = $gateway.ControllerAddress
        GuestAddress = $gateway.GuestAddress
        Port = 22224
        SafetyScope = $gateway.SafetyScope
        Hold = $null
        UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-WorkerNewFile (Join-Path $root 'manifest.json') ($m | ConvertTo-Json -Depth 6) $gateway.Sid
    Read-WorkerGatewayRepairV1 $InstanceId
}

function Invoke-WorkerGatewayRepairV1Unlocked([string]$InstanceId,[SecureString]$Password) {
    Assert-WorkerAdministrator
    if (-not $Password -or $Password.Length -lt 1) { throw 'Supply an in-memory credential.' }
    $m = Read-WorkerGatewayRepairV1 $InstanceId
    $v = Read-WorkerVerificationV3 $InstanceId
    $state = Read-WorkerState $InstanceId
    $ssh = Read-WorkerSshStage $InstanceId
    if ($state.Sid -cne $m.Sid -or $v.HostFingerprint -cne $m.HostFingerprint) { throw 'Worker or host identity changed.' }

    $live = Invoke-WorkerVerificationV3 $InstanceId $Password -ReadOnly
    Assert-WorkerGatewayLive $ssh $live $m.ListenAddress $m.ControllerAddress
    if ($live.Guest.host_fp -cne $m.HostFingerprint) { throw 'Live host key changed.' }

    $exe = Join-Path ([Environment]::SystemDirectory) 'wsl.exe'
    $hold = $m.Hold
    $process = $null
    if ($hold) {
        $native = Get-CimInstance Win32_Process -Filter "ProcessId=$($hold.PID)" -ErrorAction SilentlyContinue
        if ($native) {
            $owner = Invoke-CimMethod $native -MethodName GetOwnerSid
            $proc = Get-Process -Id $hold.PID -ErrorAction Stop
            $expectedArgs = @(Get-WorkerSshHoldArguments (New-WorkerSshPlan $InstanceId $ssh.PublicKey))
            if ($owner.Sid -cne $m.Sid -or $native.ExecutablePath -ine $exe -or $native.CommandLine -cne $hold.CommandLine -or -not $native.CommandLine.EndsWith(($expectedArgs -join ' '),[StringComparison]::Ordinal) -or -not (Test-WorkerHoldStartTime $proc.StartTime $hold.StartTimeUtc)) { throw 'Recorded hold identity drift.' }
            $process = $proc
        }
    }
    if (-not $process) {
        $name = (New-WorkerPlan $InstanceId).DistroName
        $foreign = @(Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" | Where-Object { $_.CommandLine -like "*$name*" })
        if ($foreign.Count) { throw 'Unrecorded WSL hold exists; refusing adoption.' }
        $info = New-CleanWorkerStartInfo $exe (Get-WorkerPaths $InstanceId).Data ([Environment]::GetFolderPath('Windows'))
        $info.UserName = $state.UserName
        $info.Domain = [Environment]::MachineName
        $info.Password = $Password
        $info.LoadUserProfile = $true
        $info.RedirectStandardInput = $false
        $info.RedirectStandardOutput = $false
        $info.RedirectStandardError = $false
        $args = @(Get-WorkerSshHoldArguments (New-WorkerSshPlan $InstanceId $ssh.PublicKey))
        foreach ($arg in $args) { $info.ArgumentList.Add($arg) }
        try {
            $process = [Diagnostics.Process]::Start($info)
            $info.Password = $null
            Start-Sleep -Seconds 2
            $process.Refresh()
            if ($process.HasExited) { throw 'Foreground WSL hold exited.' }
            $native = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)"
            $owner = Invoke-CimMethod $native -MethodName GetOwnerSid
            if ($owner.Sid -cne $m.Sid -or $native.ExecutablePath -ine $exe -or -not $native.CommandLine.EndsWith(($args -join ' '),[StringComparison]::Ordinal)) { throw 'New hold identity/command mismatch.' }
            $hold = [ordered]@{ PID=$process.Id; Sid=$owner.Sid; Executable=$native.ExecutablePath; CommandLine=$native.CommandLine; StartTimeUtc=$process.StartTime.ToUniversalTime().ToString('o') }
        } finally { $info.Password = $null }
    }

    $fresh = Invoke-WorkerVerificationV3 $InstanceId $Password -ReadOnly
    Assert-WorkerGatewayLive $ssh $fresh $m.ListenAddress $m.ControllerAddress
    if ($fresh.Guest.host_fp -cne $m.HostFingerprint) { throw 'Live host key changed after hold.' }
    $routes = @(Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -like 'vEthernet (WSL*' -and $_.NextHop -eq '0.0.0.0' })
    if (-not @($routes | Where-Object { Test-WorkerGatewaySubnet $fresh.Guest.address $_.DestinationPrefix }).Count -or @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq $fresh.Guest.address).Count) { throw 'Guest address is outside the connected WSL subnet.' }

    $root = Get-WorkerGatewayRepairV1Path $InstanceId
    $journal = Join-Path $root 'journal'
    $change = [guid]::NewGuid().ToString('N')
    $mappingChanged = $fresh.Guest.address -cne $m.GuestAddress
    $holdChanged = -not $m.Hold -or $m.Hold.PID -ne $hold.PID
    if ($mappingChanged -or $holdChanged) {
        $before = [ordered]@{ Previous=$m.GuestAddress; Current=$fresh.Guest.address; PreviousHoldPID=if($m.Hold){$m.Hold.PID}else{$null}; CurrentHoldPID=$hold.PID; CapturedAtUtc=[DateTime]::UtcNow.ToString('o') }
        Write-WorkerNewFile (Join-Path $journal "$change.before.json") ($before | ConvertTo-Json) $m.Sid
    }
    if ($mappingChanged) {
        Invoke-WorkerPortProxy set $m.ListenAddress $fresh.Guest.address
        Assert-WorkerGatewayMapping @(Get-WorkerGatewayMappings) $m.ListenAddress $fresh.Guest.address
    }
    $helper = Get-CimInstance Win32_Service -Filter "Name='iphlpsvc'"
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort 22224 -ErrorAction SilentlyContinue)
    if ($listeners.Count -ne 1 -or $listeners[0].LocalAddress -cne $m.ListenAddress -or $listeners[0].OwningProcess -notin @(4,[int]$helper.ProcessId)) { throw 'Gateway listener scope/process mismatch.' }
    $m.GuestAddress = $fresh.Guest.address
    $m.Hold = $hold
    $m.UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
    $pending = Join-Path $root "$change.pending.json"
    Write-WorkerNewFile $pending ($m | ConvertTo-Json -Depth 6) $m.Sid
    [IO.File]::Replace($pending,(Join-Path $root 'manifest.json'),$null)
    Set-WorkerResourceAcl (Join-Path $root 'manifest.json') $m.Sid Metadata
    Read-WorkerGatewayRepairV1 $InstanceId
}

function Invoke-WorkerGatewayRepairV1([string]$InstanceId,[SecureString]$Password) {
    Assert-WorkerAdministrator
    $root = Get-WorkerGatewayRepairV1Path $InstanceId
    $lockPath = Join-Path $root 'instance.lock'
    Assert-WorkerResourceAcl $lockPath (Read-WorkerVerificationV3 $InstanceId).Sid Metadata
    $lock = $null
    try {
        $lock = [IO.File]::Open($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    } catch [IO.IOException] {
        throw 'Another gateway repair operation owns the instance lock.'
    }
    try { Invoke-WorkerGatewayRepairV1Unlocked $InstanceId $Password }
    finally { $lock.Dispose() }
}

function Test-WorkerKeyStageGatewayRepairV1([string]$InstanceId,[string]$OperationId,[SecureString]$Password) {
    Assert-WorkerAdministrator
    $null = Invoke-WorkerGatewayRepairV1 $InstanceId $Password
    $repair = Read-WorkerGatewayRepairV1 $InstanceId
    $stage = Read-WorkerKeyStage $InstanceId $OperationId
    $fresh = Invoke-WorkerKeyStage $InstanceId $OperationId $Password 'VerifyAfter' -ReadOnly
    Assert-WorkerKeyGatewayBinding $InstanceId $repair $fresh.Guest $stage.AfterSha256
    $ssh = Read-WorkerSshStage $InstanceId
    $live = Invoke-WorkerVerificationV3 $InstanceId $Password -ReadOnly
    Assert-WorkerGatewayLive $ssh $live $repair.ListenAddress $repair.ControllerAddress
    if ($live.Guest.address -cne $repair.GuestAddress -or $live.Guest.host_fp -cne $repair.HostFingerprint) { throw 'Live guest/gateway binding drift.' }
    $helper = Get-CimInstance Win32_Service -Filter "Name='iphlpsvc'"
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort 22224 -ErrorAction SilentlyContinue)
    if ($listeners.Count -ne 1 -or $listeners[0].LocalAddress -cne $repair.ListenAddress -or $listeners[0].OwningProcess -notin @(4,[int]$helper.ProcessId)) { throw 'Gateway listener scope/process mismatch.' }
    [ordered]@{ InstanceId=$InstanceId; OperationId=$OperationId; Generation=$stage.Generation; AuthorizationHash=$stage.AfterSha256; RepairManifestHash=(Get-FileHash (Join-Path (Get-WorkerGatewayRepairV1Path $InstanceId) 'manifest.json')).Hash; ListenAddress=$repair.ListenAddress; ControllerAddress=$repair.ControllerAddress; GuestAddress=$repair.GuestAddress; Port=22224; HostFingerprint=$repair.HostFingerprint; RemoteAuthenticationTested=$false; IdleReconnectTested=$false; RebootTested=$false }
}
