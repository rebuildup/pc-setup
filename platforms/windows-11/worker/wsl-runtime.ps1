. (Join-Path $PSScriptRoot 'runtime.ps1')
. (Join-Path $PSScriptRoot 'wsl-contract.ps1')
function Get-WorkerWslStagePath([string]$InstanceId) {
    $null = New-WorkerPlan $InstanceId
    Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "pc-setup-worker-wsl-$InstanceId"
}
function Read-WorkerWslStage([string]$InstanceId) {
    $state = Read-WorkerState $InstanceId
    $root = Get-WorkerWslStagePath $InstanceId
    Assert-WorkerResourceAcl $root $state.Sid Metadata
    $expected = @('manifest.json','contract.ps1','wsl-contract.ps1','wsl-child.ps1','image.wsl')
    $actual = @(Get-ChildItem -LiteralPath $root -Force)
    if ($actual.Count -ne $expected.Count) { throw 'Foreign or partial WSL stage files.' }
    foreach ($name in $expected) { Assert-WorkerResourceAcl (Join-Path $root $name) $state.Sid Metadata }
    $stage = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json
    $paths = Get-WorkerPaths $InstanceId
    if ($stage.Owner -cne 'pc-setup/windows-worker-wsl/v1' -or $stage.InstanceId -cne $InstanceId -or $stage.Sid -cne $state.Sid -or $stage.InstallLocation -cne (Join-Path $paths.Data 'wsl') -or $stage.WorkerManifest -cne (Join-Path $paths.Metadata 'manifest.json')) { throw 'WSL stage ownership drift.' }
    Assert-WorkerPlainPath $stage.InstallLocation
    if ((Get-FileHash -LiteralPath $stage.WorkerManifest).Hash -cne $stage.WorkerManifestHash) { throw 'Original worker manifest drift.' }
    if ($stage.ImageSha256 -ine $state.Sha256 -or (Get-FileHash -LiteralPath (Join-Path $root 'image.wsl')).Hash -ine $state.Sha256) { throw 'WSL stage image drift.' }
    foreach ($name in @('contract.ps1','wsl-contract.ps1','wsl-child.ps1')) {
        $hash = $stage.SourceHashes.$name
        if ((Get-FileHash -LiteralPath (Join-Path $root $name)).Hash -cne $hash -or (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name)).Hash -cne $hash) { throw 'WSL stage source drift; explicit reconciliation required.' }
    }
    $stage
}
function Initialize-WorkerWslStage([string]$InstanceId, [string]$ImagePath) {
    $state = Read-WorkerState $InstanceId
    $root = Get-WorkerWslStagePath $InstanceId
    if (Test-Path -LiteralPath $root) { return Read-WorkerWslStage $InstanceId }
    Assert-WorkerPlainPath $root; Assert-WorkerPlainPath $ImagePath
    $paths = Get-WorkerPaths $InstanceId
    if (Test-Path -LiteralPath (Join-Path $paths.Data 'wsl')) { throw 'Existing install directory; refusing adoption.' }
    Assert-WorkerImage $state.SourceUri $state.Sha256 (Get-FileHash -LiteralPath $ImagePath).Hash
    $os = Get-CimInstance Win32_OperatingSystem
    $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$([IO.Path]::GetPathRoot($paths.Data).TrimEnd('\'))'"
    Assert-WorkerCapacity $state ($os.FreePhysicalMemory / 1MB) ($drive.FreeSpace / 1GB)
    if ($drive.FileSystem -ne 'NTFS') { throw 'WSL requires the owned local NTFS volume.' }
    $null = New-Item -ItemType Directory -Path $root -ErrorAction Stop
    Set-WorkerResourceAcl $root $state.Sid Metadata
    $hashes = [ordered]@{}
    foreach ($name in @('contract.ps1','wsl-contract.ps1','wsl-child.ps1')) {
        Write-WorkerNewFile (Join-Path $root $name) ([IO.File]::ReadAllText((Join-Path $PSScriptRoot $name))) $state.Sid
        $hashes[$name] = (Get-FileHash -LiteralPath (Join-Path $root $name)).Hash
    }
    [IO.File]::Copy($ImagePath, (Join-Path $root 'image.wsl'), $false)
    Set-WorkerResourceAcl (Join-Path $root 'image.wsl') $state.Sid Metadata
    $manifest = [ordered]@{
        Owner = 'pc-setup/windows-worker-wsl/v1'; InstanceId = $InstanceId; Sid = $state.Sid
        WorkerManifest = (Join-Path $paths.Metadata 'manifest.json')
        WorkerManifestHash = (Get-FileHash -LiteralPath (Join-Path $paths.Metadata 'manifest.json')).Hash
        ImageSha256 = $state.Sha256; InstallLocation = (Join-Path $paths.Data 'wsl'); SourceHashes = $hashes
    }
    Write-WorkerNewFile (Join-Path $root 'manifest.json') ($manifest | ConvertTo-Json -Depth 5) $state.Sid
    Read-WorkerWslStage $InstanceId
}
function Invoke-WorkerWslStage([string]$InstanceId, [SecureString]$Password, [ValidateSet('Inventory','Import','Verify')][string]$Mode, [string]$ProtectedFile, [string]$ProtectedDirectory) {
    $stage = Read-WorkerWslStage $InstanceId
    $state = Read-WorkerState $InstanceId
    if (-not $Password -or $Password.Length -lt 1) { throw 'Supply an in-memory SecureString.' }
    if ($Mode -eq 'Inventory') {
        Assert-WorkerWslProtectedPaths $ProtectedFile $ProtectedDirectory
        $operatorSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if ($operatorSid -ceq $state.Sid) { throw 'Expected a distinct operator.' }
        foreach ($path in @($ProtectedFile,$ProtectedDirectory)) {
            Assert-WorkerPlainPath $path
            if ((Get-Acl -LiteralPath $path).GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $operatorSid) { throw 'Protected target is not owned by this operator.' }
        }
        if ((Get-Item -LiteralPath $ProtectedFile).PSIsContainer -or -not (Get-Item -LiteralPath $ProtectedDirectory).PSIsContainer) { throw 'Protected target type mismatch.' }
    }
    if ($Mode -eq 'Import') {
        $os = Get-CimInstance Win32_OperatingSystem
        $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$([IO.Path]::GetPathRoot($stage.InstallLocation).TrimEnd('\'))'"
        Assert-WorkerCapacity $state ($os.FreePhysicalMemory / 1MB) ($drive.FreeSpace / 1GB)
        if ($drive.FileSystem -ne 'NTFS' -or $state.Processors -gt [Environment]::ProcessorCount) { throw 'Import capacity/volume/CPU gate failed.' }
    }
    $executable = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'PowerShell/7/pwsh.exe'
    $info = New-CleanWorkerStartInfo $executable (Get-WorkerPaths $InstanceId).Data ([Environment]::GetFolderPath('Windows'))
    $info.UserName = $state.UserName; $info.Domain = [Environment]::MachineName
    $info.Password = $Password; $info.LoadUserProfile = $true
    $root = Get-WorkerWslStagePath $InstanceId
    foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $root 'wsl-child.ps1'),'-Mode',$Mode,'-ManifestPath',(Join-Path $root 'manifest.json'))) { $info.ArgumentList.Add($arg) }
    if ($Mode -eq 'Inventory') {
        foreach ($arg in @('-ProtectedFile',$ProtectedFile,'-ProtectedDirectory',$ProtectedDirectory)) { $info.ArgumentList.Add($arg) }
    }
    $p = $null
    $previousCanary = [Environment]::GetEnvironmentVariable('PC_SETUP_CONTROLLER_CANARY')
    try {
        $env:PC_SETUP_CONTROLLER_CANARY = [guid]::NewGuid().ToString('N')
        $p = [Diagnostics.Process]::Start($info)
        $p.StandardInput.Close()
        $stdout = $p.StandardOutput.ReadToEndAsync(); $stderr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(270000)) { throw 'WSL stage timed out; preserve state/processes and inspect. Do not retry import.' }
        if ($p.ExitCode -ne 0) { throw 'Credentialed WSL stage failed; preserve partial state. No credential details emitted.' }
        $text = $stdout.GetAwaiter().GetResult()
        if ($text.Length -gt 16384 -or $stderr.GetAwaiter().GetResult().Length) { throw 'Unexpected WSL stage output.' }
        $report = $text | ConvertFrom-Json
        if ($report.Sid -cne $stage.Sid -or $report.Administrator -isnot [bool] -or $report.Administrator -or $report.CanaryPresent -isnot [bool] -or $report.CanaryPresent -or $report.Mode -cne $Mode) { throw 'Invalid child identity/environment report.' }
        if ($Mode -eq 'Inventory') { Assert-WorkerWslAccessReport ($text | ConvertFrom-Json -AsHashtable) }
        $report
    } finally {
        [Environment]::SetEnvironmentVariable('PC_SETUP_CONTROLLER_CANARY',$previousCanary)
        $info.Password = $null; if ($p) { $p.Dispose() }
    }
}
