# Separate live-repair state for a V3 worker gateway. Historic V3 proofs remain immutable.
. (Join-Path $PSScriptRoot '../verification-v3/gateway.ps1')
. (Join-Path $PSScriptRoot '../key-stage/runtime.ps1')

function Get-WorkerGatewayRepairV1Path([string]$InstanceId) {
    $null = New-WorkerPlan $InstanceId
    Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "pc-setup-wsl-gateway-repair-v1-$InstanceId"
}

function Replace-WorkerGatewayRepairManifest([string]$Pending,[string]$Manifest,[string]$Backup,[string]$Sid,[string]$ExpectedBackupHash) {
    $pendingVolume = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Pending))
    $manifestVolume = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Manifest))
    $backupVolume = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Backup))
    if ($pendingVolume -ine $manifestVolume -or $manifestVolume -ine $backupVolume) { throw 'Atomic repair manifest replacement must stay on one volume.' }
    if ([IO.File]::Exists($Backup)) { throw 'Repair manifest backup already exists; preserve and inspect.' }
    # PowerShell binds File.Replace(..., $null) as an empty path. Supply a
    # same-volume backup so ReplaceFile performs the manifest swap atomically.
    [IO.File]::Replace($Pending,$Manifest,$Backup)
    Set-WorkerResourceAcl $Manifest $Sid Metadata
    Set-WorkerResourceAcl $Backup $Sid Metadata
    if ((Get-FileHash -LiteralPath $Backup).Hash -cne $ExpectedBackupHash) { throw 'Replaced manifest backup differs from its journaled before hash.' }
}

function Get-WorkerGatewayRepairWslExecutable {
    $systemDirectory = [Environment]::SystemDirectory
    if ([string]::IsNullOrWhiteSpace($systemDirectory)) { throw 'Windows system directory is unavailable.' }
    Join-Path $systemDirectory 'wsl.exe'
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
    $pendingFiles = @($files | Where-Object Name -cmatch '^[a-f0-9]{32}\.pending\.json$')
    if ($pendingFiles.Count -gt 1 -or $files.Count -ne (3 + $pendingFiles.Count) -or @($files | Where-Object { $_.Name -cnotin @('manifest.json','journal','instance.lock') -and $_.Name -cnotmatch '^[a-f0-9]{32}\.pending\.json$' }).Count) { throw 'Unknown repair-stage state.' }
    Assert-WorkerResourceAcl (Join-Path $root 'instance.lock') $gateway.Sid Metadata
    Assert-WorkerResourceAcl (Join-Path $root 'journal') $gateway.Sid Metadata
    $journalRecords = @{}
    foreach ($entry in @(Get-ChildItem -LiteralPath (Join-Path $root 'journal') -Force)) {
        if ($entry.Name -cnotmatch '^[a-f0-9]{32}\.(before|intent|hold|manifest-backup)\.json$') { throw 'Partial repair journal; preserve and inspect.' }
        Assert-WorkerResourceAcl $entry.FullName $gateway.Sid Metadata
        $record = Get-Content -LiteralPath $entry.FullName -Raw | ConvertFrom-Json
        if ($record.InstanceId -cne $InstanceId -or $record.Sid -cne $gateway.Sid -or $record.Owner -cne 'pc-setup/windows-worker-gateway-repair/v1') { throw 'Repair journal identity drift.' }
        $journalRecords[$entry.Name] = $record
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
    foreach ($name in $expected.Keys) { if ($name -cne 'SourceHash' -and $m.$name -cne $expected[$name]) { throw 'Repair-stage identity/source drift.' } }
    if ($m.SourceHash -cnotin @($expected.SourceHash,'404606904CFAD3D25C33F90AD31F2C47BEEAF8B5245B45BBEFC249E8A941C4B2','1DBB76DBE660317C2BC197DEE81ADA34CE8D2FEA4358D921818C81A01953822A')) { throw 'Repair-stage source is not an explicitly reviewed version.' }
    foreach ($backupName in @($journalRecords.Keys | Where-Object { $_ -match '^[a-f0-9]{32}\.manifest-backup\.json$' })) {
        $backupRecord = $journalRecords[$backupName]
        foreach ($name in @('Owner','InstanceId','Sid','SshManifestHash','VerifierManifestHash','BaseGatewayManifestHash','HostFingerprint','ListenAddress','ControllerAddress','Port','SafetyScope')) {
            if ($backupRecord.$name -cne $m.$name) { throw 'Repair manifest backup identity drift.' }
        }
        if ($backupRecord.SourceHash -cnotin @($expected.SourceHash,'404606904CFAD3D25C33F90AD31F2C47BEEAF8B5245B45BBEFC249E8A941C4B2','1DBB76DBE660317C2BC197DEE81ADA34CE8D2FEA4358D921818C81A01953822A')) { throw 'Repair manifest backup source is not an explicitly reviewed version.' }
        $backupId = [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension($backupName))
        $beforeRecord = $journalRecords["$backupId.before.json"]
        $backupPath = Join-Path $journal $backupName
        if (-not $beforeRecord.PreviousManifestHash -or (Get-FileHash -LiteralPath $backupPath).Hash -cne $beforeRecord.PreviousManifestHash) { throw 'Repair manifest backup differs from its journaled before hash.' }
    }
    $journal = Join-Path $root 'journal'
    $mappingSet = @(Get-WorkerGatewayMappings)
    $mappingChecked = $false
    $mappingTargets = @($m.GuestAddress)
    $lastChange = @(Get-ChildItem -LiteralPath $journal -Filter '*.before.json' -Force | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    if ($lastChange.Count -eq 1) {
        $transition = Get-Content -LiteralPath $lastChange[0].FullName -Raw | ConvertFrom-Json
        if ($transition.Current -match '^(?:\d{1,3}\.){3}\d{1,3}$') { $mappingTargets += $transition.Current }
    }
    foreach ($target in @($mappingTargets | Select-Object -Unique)) {
        try { Assert-WorkerGatewayMapping $mappingSet $m.ListenAddress $target; $mappingChecked=$true; break } catch { }
    }
    if (-not $mappingChecked) { throw 'Gateway mapping is outside the manifest and latest journaled transition.' }
    $holdRecords = @(Get-ChildItem -LiteralPath $journal -Filter '*.hold.json' -Force)
    if ($holdRecords.Count -gt 1) { throw 'Multiple repair hold records; preserve and inspect.' }
    if ($holdRecords.Count -eq 1) {
        $record = Get-Content -LiteralPath $holdRecords[0].FullName -Raw | ConvertFrom-Json
        foreach ($field in @('PID','Executable','CommandLine','StartTimeUtc')) { if (-not $record.Hold.$field) { throw 'Incomplete repair hold record.' } }
    }
    if ($pendingFiles.Count -eq 1) {
        Assert-WorkerResourceAcl $pendingFiles[0].FullName $gateway.Sid Metadata
        $pendingName = $pendingFiles[0].Name
        $changeId = [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension($pendingName))
        $transition = $journalRecords["$changeId.before.json"]
        if (-not $transition) { throw 'Pending repair manifest has no matching before journal.' }
        $candidate = Get-Content -LiteralPath $pendingFiles[0].FullName -Raw | ConvertFrom-Json
        foreach ($name in @('Owner','InstanceId','Sid','SshManifestHash','VerifierManifestHash','BaseGatewayManifestHash','HostFingerprint','ListenAddress','ControllerAddress','Port','SafetyScope')) {
            if ($candidate.$name -cne $m.$name) { throw 'Pending repair manifest identity drift.' }
        }
        if ($candidate.SourceHash -cnotin @($expected.SourceHash,'404606904CFAD3D25C33F90AD31F2C47BEEAF8B5245B45BBEFC249E8A941C4B2','1DBB76DBE660317C2BC197DEE81ADA34CE8D2FEA4358D921818C81A01953822A') -or $candidate.GuestAddress -cne $transition.Current -or $candidate.Hold.PID -ne $transition.CurrentHoldPID) { throw 'Pending repair manifest does not match its journaled transition.' }
        if ($holdRecords.Count -eq 1) { $recordedHold = $record.Hold }
        elseif ($holdRecords.Count -eq 0 -and $m.Hold -and $m.Hold.PID) { $recordedHold = $m.Hold }
        else { throw 'Pending repair manifest has no unique recorded hold identity.' }
        foreach ($field in @('PID','Sid','Executable','CommandLine','StartTimeUtc')) {
            if ($candidate.Hold.$field -cne $recordedHold.$field) { throw 'Pending repair hold differs from the recorded live hold.' }
        }
    }
    $m
}

function Invoke-WorkerGatewayRepairV3ReadOnly([string]$InstanceId,[SecureString]$Password) {
    if (-not $Password -or $Password.Length -lt 1) { throw 'Supply an in-memory credential.' }
    $m = Read-WorkerVerificationV3 $InstanceId
    $state = Read-WorkerState $InstanceId
    $root = Get-WorkerVerificationV3Path $InstanceId
    $exe = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'PowerShell/7/pwsh.exe'
    $p = $null
    $info = $null
    $canary = [Environment]::GetEnvironmentVariable('PC_SETUP_CONTROLLER_CANARY')
    try {
        [Environment]::SetEnvironmentVariable('PC_SETUP_CONTROLLER_CANARY',[guid]::NewGuid().ToString('N'))
        $info = New-CleanWorkerStartInfo $exe (Get-WorkerPaths $InstanceId).Data ([Environment]::GetFolderPath('Windows'))
        Set-WorkerVerificationV3Environment $info ([Environment]::GetFolderPath('CommonApplicationData'))
        $info.UserName = $state.UserName
        $info.Domain = [Environment]::MachineName
        $info.Password = $Password
        $info.LoadUserProfile = $true
        foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $root 'child.ps1'),'-InstanceId',$InstanceId)) { $info.ArgumentList.Add($arg) }
        $p = [Diagnostics.Process]::Start($info)
        $info.Password = $null
        $p.StandardInput.Close()
        $stdout = $p.StandardOutput.ReadToEndAsync()
        $stderr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(120000)) { throw "Repair verifier child timeout; pid=$($p.Id)." }
        $out = $stdout.GetAwaiter().GetResult()
        $err = $stderr.GetAwaiter().GetResult()
        if ($p.ExitCode -ne 0) { throw "Repair verifier child exited; code=$($p.ExitCode); stdoutLength=$($out.Length); stderrLength=$($err.Length)." }
        if ($out.Length -gt 16384 -or $err.Length) { throw 'Repair verifier child returned unexpected output lengths.' }
        $report = $out | ConvertFrom-Json
        Assert-WorkerV3Report $report $m
        $report
    } finally {
        [Environment]::SetEnvironmentVariable('PC_SETUP_CONTROLLER_CANARY',$canary)
        if ($info) { $info.Password = $null }
        if ($p) { $p.Dispose() }
    }
}

function Assert-WorkerGatewayRepairV3Live($Stage,$Report,[string]$Listen,[string]$Controller) {
    Assert-WorkerV3Report $Report $Stage
    Assert-WorkerVpnAddress $Listen
    Assert-WorkerVpnAddress $Controller
    if ($Listen -ceq $Controller) { throw 'Controller and gateway must differ.' }
    $routes = @(Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -like 'vEthernet (WSL*' -and $_.NextHop -eq '0.0.0.0' })
    if (-not @($routes | Where-Object { Test-WorkerGatewaySubnet $Report.Guest.address $_.DestinationPrefix }).Count -or @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq $Report.Guest.address).Count) { throw 'Guest must be on the connected WSL subnet, not a Windows address.' }
    $vpn = & 'C:/Program Files/Tailscale/tailscale.exe' status --json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $vpn.BackendState -cne 'Running' -or $vpn.TailscaleIPs -notcontains $Listen -or @($vpn.Peer.PSObject.Properties.Value | Where-Object { $_.TailscaleIPs -contains $Controller -and $_.Online }).Count -ne 1) { throw 'Current VPN attributes mismatch.' }
    if ((Get-CimInstance Win32_Service -Filter "Name='iphlpsvc'").State -cne 'Running') { throw 'Existing IP Helper must already be running.' }
    $interfaces = @(Get-NetIPAddress -AddressFamily IPv4 -IPAddress $Listen)
    if ($interfaces.Count -ne 1) { throw 'Ambiguous VPN interface.' }
    Assert-WorkerGatewayFirewallProfiles @(Get-NetFirewallProfile -PolicyStore ActiveStore) $interfaces[0].InterfaceAlias
}

function Assert-WorkerGatewayRepairHold([string]$InstanceId,[string]$Sid,$Hold,[string]$PublicKey) {
    $exe = Get-WorkerGatewayRepairWslExecutable
    $native = Get-CimInstance Win32_Process -Filter "ProcessId=$($Hold.PID)" -ErrorAction SilentlyContinue
    if (-not $native) { throw 'Recorded repair hold is no longer running.' }
    $owner = Invoke-CimMethod $native -MethodName GetOwnerSid
    $process = Get-Process -Id $Hold.PID -ErrorAction Stop
    $args = @(Get-WorkerSshHoldArguments (New-WorkerSshPlan $InstanceId $PublicKey))
    if ($owner.Sid -cne $Sid -or $native.ExecutablePath -ine $exe -or $native.CommandLine -cne $Hold.CommandLine -or -not $native.CommandLine.EndsWith(($args -join ' '),[StringComparison]::Ordinal) -or -not (Test-WorkerHoldStartTime $process.StartTime $Hold.StartTimeUtc)) { throw 'Recorded repair hold identity drift.' }
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
    $global:PCSetupWorkerGatewayRepairStep = 'read-only-v3-verification'
    if (-not $Password -or $Password.Length -lt 1) { throw 'Supply an in-memory credential.' }
    $m = Read-WorkerGatewayRepairV1 $InstanceId
    $v = Read-WorkerVerificationV3 $InstanceId
    $state = Read-WorkerState $InstanceId
    $ssh = Read-WorkerSshStage $InstanceId
    if ($state.Sid -cne $m.Sid -or $v.HostFingerprint -cne $m.HostFingerprint) { throw 'Worker or host identity changed.' }

    $live = Invoke-WorkerGatewayRepairV3ReadOnly $InstanceId $Password
    Assert-WorkerGatewayRepairV3Live $v $live $m.ListenAddress $m.ControllerAddress
    if ($live.Guest.host_fp -cne $m.HostFingerprint) { throw 'Live host key changed.' }

    $global:PCSetupWorkerGatewayRepairStep = 'hold-process-resume-or-start'
    $exe = Get-WorkerGatewayRepairWslExecutable
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
        $journal = Join-Path (Get-WorkerGatewayRepairV1Path $InstanceId) 'journal'
        $receipts = @(Get-ChildItem -LiteralPath $journal -Filter '*.hold.json' -Force)
        if ($receipts.Count -gt 1) { throw 'Multiple repair hold records; preserve and inspect.' }
        if ($receipts.Count -eq 1) {
            $receipt = Get-Content -LiteralPath $receipts[0].FullName -Raw | ConvertFrom-Json
            $saved = $receipt.Hold
            $native = Get-CimInstance Win32_Process -Filter "ProcessId=$($saved.PID)" -ErrorAction SilentlyContinue
            if (-not $native) { throw 'Recorded repair hold is no longer running; preserve journal for operator review.' }
            $owner = Invoke-CimMethod $native -MethodName GetOwnerSid
            $proc = Get-Process -Id $saved.PID -ErrorAction Stop
            $expectedArgs = @(Get-WorkerSshHoldArguments (New-WorkerSshPlan $InstanceId $ssh.PublicKey))
            if ($owner.Sid -cne $m.Sid -or $native.ExecutablePath -ine $exe -or $native.CommandLine -cne $saved.CommandLine -or -not $native.CommandLine.EndsWith(($expectedArgs -join ' '),[StringComparison]::Ordinal) -or -not (Test-WorkerHoldStartTime $proc.StartTime $saved.StartTimeUtc)) { throw 'Recorded repair hold identity drift.' }
            $hold = $saved
            $process = $proc
        }
        if (-not $process) {
            $intents = @(Get-ChildItem -LiteralPath $journal -Filter '*.intent.json' -Force | Sort-Object LastWriteTimeUtc -Descending)
            if ($intents.Count -gt 0) {
                $intentPath = $intents[0].FullName
                $intent = Get-Content -LiteralPath $intentPath -Raw | ConvertFrom-Json
                $expectedArgs = @(Get-WorkerSshHoldArguments (New-WorkerSshPlan $InstanceId $ssh.PublicKey))
                if ($intent.Executable -ine $exe -or ($intent.Arguments -join ' ') -cne ($expectedArgs -join ' ')) { throw 'Pending launch intent command drift.' }
                $cutoff = [DateTime]::Parse($intent.CreatedAtUtc).ToUniversalTime()
                $candidates = [Collections.Generic.List[object]]::new()
                foreach ($nativeCandidate in @(Get-CimInstance Win32_Process -Filter "Name='wsl.exe'")) {
                    if ($nativeCandidate.ExecutablePath -ine $exe -or -not $nativeCandidate.CommandLine.EndsWith(($expectedArgs -join ' '),[StringComparison]::Ordinal)) { continue }
                    $candidateOwner = Invoke-CimMethod $nativeCandidate -MethodName GetOwnerSid
                    if ($candidateOwner.Sid -cne $m.Sid) { continue }
                    $candidateProcess = Get-Process -Id $nativeCandidate.ProcessId -ErrorAction Stop
                    if ($candidateProcess.StartTime.ToUniversalTime() -ge $cutoff) { $candidates.Add([pscustomobject]@{ Native=$nativeCandidate; Owner=$candidateOwner; Process=$candidateProcess }) }
                }
                if ($candidates.Count -ne 1) { throw 'Pending launch intent has no unique matching hold; preserve journal for operator review.' }
                $candidate = $candidates[0]
                $hold = [ordered]@{ PID=$candidate.Process.Id; Sid=$candidate.Owner.Sid; Executable=$candidate.Native.ExecutablePath; CommandLine=$candidate.Native.CommandLine; StartTimeUtc=$candidate.Process.StartTime.ToUniversalTime().ToString('o') }
                $intentId = [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension($intentPath))
                $receipt = [ordered]@{ Owner='pc-setup/windows-worker-gateway-repair/v1'; InstanceId=$InstanceId; Sid=$m.Sid; Hold=$hold; IntentId=$intentId; RecordedAtUtc=[DateTime]::UtcNow.ToString('o') }
                Write-WorkerNewFile (Join-Path $journal "$intentId.hold.json") ($receipt | ConvertTo-Json -Depth 6) $m.Sid
                $process = $candidate.Process
            }
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
        $change = [guid]::NewGuid().ToString('N')
        $intent = [ordered]@{ Owner='pc-setup/windows-worker-gateway-repair/v1'; InstanceId=$InstanceId; Sid=$m.Sid; Executable=$exe; Arguments=$args; CreatedAtUtc=[DateTime]::UtcNow.ToString('o') }
        Write-WorkerNewFile (Join-Path (Get-WorkerGatewayRepairV1Path $InstanceId) "journal\$change.intent.json") ($intent | ConvertTo-Json -Depth 5) $m.Sid
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
            $receipt = [ordered]@{ Owner='pc-setup/windows-worker-gateway-repair/v1'; InstanceId=$InstanceId; Sid=$m.Sid; Hold=$hold; IntentId=$change; RecordedAtUtc=[DateTime]::UtcNow.ToString('o') }
            Write-WorkerNewFile (Join-Path (Get-WorkerGatewayRepairV1Path $InstanceId) "journal\$change.hold.json") ($receipt | ConvertTo-Json -Depth 6) $m.Sid
        } finally { $info.Password = $null }
    }

    $global:PCSetupWorkerGatewayRepairStep = 'read-only-post-hold-verification'
    $fresh = Invoke-WorkerVerificationV3 $InstanceId $Password -ReadOnly
    Assert-WorkerGatewayRepairV3Live $v $fresh $m.ListenAddress $m.ControllerAddress
    if ($fresh.Guest.host_fp -cne $m.HostFingerprint) { throw 'Live host key changed after hold.' }
    Assert-WorkerGatewayRepairHold $InstanceId $m.Sid $hold $ssh.PublicKey
    $routes = @(Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -like 'vEthernet (WSL*' -and $_.NextHop -eq '0.0.0.0' })
    if (-not @($routes | Where-Object { Test-WorkerGatewaySubnet $fresh.Guest.address $_.DestinationPrefix }).Count -or @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq $fresh.Guest.address).Count) { throw 'Guest address is outside the connected WSL subnet.' }

    $root = Get-WorkerGatewayRepairV1Path $InstanceId
    $journal = Join-Path $root 'journal'
    $manifestPath = Join-Path $root 'manifest.json'
    $change = [guid]::NewGuid().ToString('N')
    $mappingChanged = $fresh.Guest.address -cne $m.GuestAddress
    $holdChanged = -not $m.Hold -or $m.Hold.PID -ne $hold.PID
    $commitBeforeHash = (Get-FileHash -LiteralPath $manifestPath).Hash
    if ($mappingChanged -or $holdChanged) {
        $change = [guid]::NewGuid().ToString('N')
        $before = [ordered]@{ Owner='pc-setup/windows-worker-gateway-repair/v1'; InstanceId=$InstanceId; Sid=$m.Sid; Previous=$m.GuestAddress; Current=$fresh.Guest.address; PreviousHoldPID=if($m.Hold){$m.Hold.PID}else{$null}; CurrentHoldPID=$hold.PID; PreviousManifestHash=$commitBeforeHash; CapturedAtUtc=[DateTime]::UtcNow.ToString('o') }
        Write-WorkerNewFile (Join-Path $journal "$change.before.json") ($before | ConvertTo-Json) $m.Sid
    }
    if ($mappingChanged) {
        $global:PCSetupWorkerGatewayRepairStep = 'owned-portproxy-update'
        Invoke-WorkerPortProxy set $m.ListenAddress $fresh.Guest.address
        Assert-WorkerGatewayMapping @(Get-WorkerGatewayMappings) $m.ListenAddress $fresh.Guest.address
    }
    $helper = Get-CimInstance Win32_Service -Filter "Name='iphlpsvc'"
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort 22224 -ErrorAction SilentlyContinue)
    if ($listeners.Count -ne 1 -or $listeners[0].LocalAddress -cne $m.ListenAddress -or $listeners[0].OwningProcess -notin @(4,[int]$helper.ProcessId)) { throw 'Gateway listener scope/process mismatch.' }
    $m.GuestAddress = $fresh.Guest.address
    $m.Hold = $hold
    $m.SourceHash = (Get-FileHash (Join-Path $PSScriptRoot 'runtime.ps1')).Hash
    $m.UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
    $global:PCSetupWorkerGatewayRepairStep = 'manifest-commit'
    if (-not $mappingChanged -and -not $holdChanged) {
        $before = [ordered]@{ Owner='pc-setup/windows-worker-gateway-repair/v1'; InstanceId=$InstanceId; Sid=$m.Sid; Previous=$m.GuestAddress; Current=$m.GuestAddress; PreviousHoldPID=$hold.PID; CurrentHoldPID=$hold.PID; PreviousManifestHash=$commitBeforeHash; CapturedAtUtc=[DateTime]::UtcNow.ToString('o') }
        Write-WorkerNewFile (Join-Path $journal "$change.before.json") ($before | ConvertTo-Json) $m.Sid
    }
    $pendingFiles = @(Get-ChildItem -LiteralPath $root -Filter '*.pending.json' -Force)
    if ($pendingFiles.Count -gt 1) { throw 'Multiple pending repair manifests; preserve and inspect.' }
    if ($pendingFiles.Count -eq 1) {
        $pending = $pendingFiles[0].FullName
        $candidate = Get-Content -LiteralPath $pending -Raw | ConvertFrom-Json
        foreach ($field in @('Owner','InstanceId','Sid','SshManifestHash','VerifierManifestHash','BaseGatewayManifestHash','HostFingerprint','ListenAddress','ControllerAddress','GuestAddress','Port','SafetyScope')) {
            if ($candidate.$field -cne $m.$field) { throw 'Pending repair manifest does not match the freshly verified repair state.' }
        }
        foreach ($field in @('PID','Sid','Executable','CommandLine','StartTimeUtc')) { if ($candidate.Hold.$field -cne $m.Hold.$field) { throw 'Pending repair hold differs from the freshly verified hold.' } }
        if ($candidate.SourceHash -cnotin @((Get-FileHash (Join-Path $PSScriptRoot 'runtime.ps1')).Hash,'404606904CFAD3D25C33F90AD31F2C47BEEAF8B5245B45BBEFC249E8A941C4B2','1DBB76DBE660317C2BC197DEE81ADA34CE8D2FEA4358D921818C81A01953822A')) { throw 'Pending repair manifest source is not an explicitly reviewed version.' }
        $backupPath = Join-Path $journal "$change.manifest-backup.json"
        Replace-WorkerGatewayRepairManifest $pending $manifestPath $backupPath $m.Sid $commitBeforeHash
        if ($candidate.SourceHash -cne $m.SourceHash) {
            $upgradeId = [guid]::NewGuid().ToString('N')
            $upgradeBefore = [ordered]@{ Owner='pc-setup/windows-worker-gateway-repair/v1'; InstanceId=$InstanceId; Sid=$m.Sid; Previous=$m.GuestAddress; Current=$m.GuestAddress; PreviousHoldPID=$hold.PID; CurrentHoldPID=$hold.PID; PreviousManifestHash=(Get-FileHash -LiteralPath $manifestPath).Hash; CapturedAtUtc=[DateTime]::UtcNow.ToString('o') }
            Write-WorkerNewFile (Join-Path $journal "$upgradeId.before.json") ($upgradeBefore | ConvertTo-Json) $m.Sid
            $pending = Join-Path $root "$upgradeId.pending.json"
            Write-WorkerNewFile $pending ($m | ConvertTo-Json -Depth 6) $m.Sid
            $backupPath = Join-Path $journal "$upgradeId.manifest-backup.json"
            Replace-WorkerGatewayRepairManifest $pending $manifestPath $backupPath $m.Sid $upgradeBefore.PreviousManifestHash
        }
    } else {
        $pending = Join-Path $root "$change.pending.json"
        Write-WorkerNewFile $pending ($m | ConvertTo-Json -Depth 6) $m.Sid
        $backupPath = Join-Path $journal "$change.manifest-backup.json"
        Replace-WorkerGatewayRepairManifest $pending $manifestPath $backupPath $m.Sid $commitBeforeHash
    }
    foreach ($receipt in @(Get-ChildItem -LiteralPath $journal -Filter '*.hold.json' -Force)) {
        $record = Get-Content -LiteralPath $receipt.FullName -Raw | ConvertFrom-Json
        if ($record.Hold.PID -eq $hold.PID) {
            $intentPath = Join-Path $journal "$($record.IntentId).intent.json"
            Remove-Item -LiteralPath $receipt.FullName -Force
            if (Test-Path -LiteralPath $intentPath) { Remove-Item -LiteralPath $intentPath -Force }
        }
    }
    $verified = Read-WorkerGatewayRepairV1 $InstanceId
    foreach ($backup in @(Get-ChildItem -LiteralPath $journal -Filter '*.manifest-backup.json' -Force)) {
        Assert-WorkerResourceAcl $backup.FullName $m.Sid Metadata
        Remove-Item -LiteralPath $backup.FullName -Force
    }
    $verified
    $global:PCSetupWorkerGatewayRepairStep = 'complete'
}

function Invoke-WorkerGatewayRepairV1([string]$InstanceId,[SecureString]$Password) {
    Assert-WorkerAdministrator
    $global:PCSetupWorkerGatewayRepairStep = 'acquire-instance-lock'
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
    $live = Invoke-WorkerGatewayRepairV3ReadOnly $InstanceId $Password
    $v = Read-WorkerVerificationV3 $InstanceId
    Assert-WorkerGatewayRepairV3Live $v $live $repair.ListenAddress $repair.ControllerAddress
    if ($live.Guest.address -cne $repair.GuestAddress -or $live.Guest.host_fp -cne $repair.HostFingerprint) { throw 'Live guest/gateway binding drift.' }
    $helper = Get-CimInstance Win32_Service -Filter "Name='iphlpsvc'"
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort 22224 -ErrorAction SilentlyContinue)
    if ($listeners.Count -ne 1 -or $listeners[0].LocalAddress -cne $repair.ListenAddress -or $listeners[0].OwningProcess -notin @(4,[int]$helper.ProcessId)) { throw 'Gateway listener scope/process mismatch.' }
    [ordered]@{ InstanceId=$InstanceId; OperationId=$OperationId; Generation=$stage.Generation; AuthorizationHash=$stage.AfterSha256; RepairManifestHash=(Get-FileHash (Join-Path (Get-WorkerGatewayRepairV1Path $InstanceId) 'manifest.json')).Hash; ListenAddress=$repair.ListenAddress; ControllerAddress=$repair.ControllerAddress; GuestAddress=$repair.GuestAddress; Port=22224; HostFingerprint=$repair.HostFingerprint; RemoteAuthenticationTested=$false; IdleReconnectTested=$false; RebootTested=$false }
}
