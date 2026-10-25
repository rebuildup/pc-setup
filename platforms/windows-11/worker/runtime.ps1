# Windows adapter. Dot-sourcing defines functions only; provisioning is explicit.
. (Join-Path $PSScriptRoot 'contract.ps1')
function Assert-WorkerHost {
    if (-not $IsWindows -or -not [Environment]::Is64BitProcess -or $PSVersionTable.PSVersion -lt [version]'7.3') { throw 'Use native Windows x64 PowerShell 7.3+.' }
}
function Assert-WorkerAdministrator {
    Assert-WorkerHost
    if (-not ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Use an elevated operator shell.' }
}
function Get-WorkerPaths([string]$InstanceId) {
    $null = New-WorkerPlan $InstanceId
    $common = [Environment]::GetFolderPath('CommonApplicationData')
    @{ Metadata = Join-Path $common "pc-setup-worker-$InstanceId"; Data = Join-Path $common "pc-setup-worker-data-$InstanceId" }
}
function Assert-WorkerPlainPath([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    if ($current.StartsWith('\\') -or $current.Substring(2).Contains(':')) { throw 'Only local paths without alternate streams are supported.' }
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point in resource path.' }
        }
        $parent = Split-Path -Parent $current
        if ($parent -eq $current) { break }; $current = $parent
    }
}
function Set-WorkerResourceAcl([string]$Path, [string]$Sid, [ValidateSet('Metadata','Data')][string]$Kind) {
    Assert-WorkerPlainPath $Path
    $directory = (Get-Item -LiteralPath $Path -Force).PSIsContainer
    $acl = if ($directory) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    $inherit = if ($directory) { 'ContainerInherit, ObjectInherit' } else { 'None' }
    foreach ($entry in @(@('S-1-5-18','FullControl'),@('S-1-5-32-544','FullControl'),@($Sid, $(if ($Kind -eq 'Data') {'Modify'} else {'ReadAndExecute'})))) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($entry[0]), $entry[1], $inherit, 'None', 'Allow')
        $null = $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Assert-WorkerResourceAcl([string]$Path, [string]$Sid, [ValidateSet('Metadata','Data')][string]$Kind) {
    Assert-WorkerPlainPath $Path
    $item = Get-Item -LiteralPath $Path -Force
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne 'S-1-5-32-544') { throw 'Resource ACL owner/inheritance drift.' }
    $rules = @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne 3) { throw 'Foreign ACL entries.' }
    $expected = @{ 'S-1-5-18' = 'FullControl'; 'S-1-5-32-544' = 'FullControl' }
    $expected[$Sid] = if ($Kind -eq 'Data') {'Modify, Synchronize'} else {'ReadAndExecute, Synchronize'}
    foreach ($rule in $rules) {
        $identity = $rule.IdentityReference.Value
        if (-not $expected.ContainsKey($identity) -or $rule.AccessControlType -ne 'Allow' -or $rule.IsInherited -or $rule.PropagationFlags -ne 'None') { throw 'Resource ACL drift.' }
        $rights = [Security.AccessControl.FileSystemRights]$expected[$identity]
        if ($rule.FileSystemRights -ne $rights) { throw 'Resource ACL rights drift.' }
        $flags = if ($item.PSIsContainer) { [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit' } else { [Security.AccessControl.InheritanceFlags]::None }
        if ($rule.InheritanceFlags -ne $flags) { throw 'Resource ACL propagation drift.' }
    }
}
function Get-WorkerGroupSids([string]$Sid) {
    foreach ($group in Get-LocalGroup) {
        if (@(Get-LocalGroupMember -SID $group.SID -ErrorAction Stop | Where-Object { $_.SID.Value -ceq $Sid }).Count) { $group.SID.Value }
    }
}
function Write-WorkerNewFile([string]$Path, [string]$Text, [string]$Sid) {
    $stream = [IO.File]::Open($Path, 'CreateNew', 'Write', 'None')
    try { $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text); $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
    Set-WorkerResourceAcl $Path $Sid Metadata
}
function Read-WorkerState([string]$InstanceId) {
    Assert-WorkerAdministrator
    $paths = Get-WorkerPaths $InstanceId
    Assert-WorkerPlainPath $paths.Metadata
    $manifest = Join-Path $paths.Metadata 'manifest.json'
    # Check admin ownership and no worker write BEFORE trusting the manifest's SID.
    $acl = Get-Acl -LiteralPath $manifest
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544' -or -not $acl.AreAccessRulesProtected) { throw 'Foreign manifest.' }
    foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne 'Allow') { throw 'Foreign manifest ACL.' }
        if ($rule.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544') -and ($rule.FileSystemRights -band ([Security.AccessControl.FileSystemRights]'Write,Delete,ChangePermissions,TakeOwnership'))) { throw 'Manifest is writable by a lower-trust principal.' }
    }
    $state = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json -AsHashtable
    $plan = New-WorkerPlan $InstanceId $state.MemoryGB $state.Processors
    foreach ($property in $plan.PSObject.Properties) { if ($state[$property.Name] -cne $property.Value) { throw 'Manifest identity/plan drift.' } }
    Assert-WorkerResourceAcl $paths.Metadata $state.Sid Metadata
    Assert-WorkerResourceAcl $manifest $state.Sid Metadata
    Assert-WorkerResourceAcl $paths.Data $state.Sid Data
    if (@(Get-ChildItem -LiteralPath $paths.Metadata -Force).Count -ne 2) { throw 'Foreign metadata file.' }
    $probe = Join-Path $paths.Metadata 'child-probe.ps1'
    Assert-WorkerResourceAcl $probe $state.Sid Metadata
    if ((Get-FileHash -LiteralPath $probe).Hash -cne $state.ProbeHash) { throw 'Child probe drift.' }
    # Also reject stale runtime code after a source update.
    if ((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'child-probe.ps1')).Hash -cne $state.ProbeHash) { throw 'Installed probe differs from this source; explicit reconciliation required.' }
    $user = Get-LocalUser -Name $state.UserName -ErrorAction Stop
    if (-not $user.Enabled -or $user.Description -cne "$($state.Owner)/$InstanceId") { throw 'Account ownership/status drift.' }
    Assert-WorkerIdentity $state.Sid $user.SID.Value @(Get-WorkerGroupSids $user.SID.Value) @() $state.DistroName
    $state
}
function New-WindowsWorker([string]$InstanceId, [SecureString]$Password, [string]$ImagePath, [string]$SourceUri, [string]$Sha256, [int]$MemoryGB = 4, [int]$Processors = 2) {
    Assert-WorkerAdministrator
    $plan = New-WorkerPlan $InstanceId $MemoryGB $Processors
    $paths = Get-WorkerPaths $InstanceId
    foreach ($path in @($paths.Metadata,$paths.Data,$ImagePath)) { Assert-WorkerPlainPath $path }
    if (-not $Password -or $Password.Length -lt 1) { throw 'An in-memory SecureString password is required.' }
    $image = Get-Item -LiteralPath $ImagePath -Force
    if ($image.PSIsContainer) { throw 'Expected an official fresh image file.' }
    Assert-WorkerImage $SourceUri $Sha256 (Get-FileHash -LiteralPath $ImagePath -Algorithm SHA256).Hash
    if (Test-Path -LiteralPath $paths.Metadata) {
        $state = Read-WorkerState $InstanceId
        if ($state.SourceUri -cne $SourceUri -or $state.Sha256 -ine $Sha256 -or $state.MemoryGB -ne $MemoryGB -or $state.Processors -ne $Processors) { throw 'Provision parameters changed.' }
        return $state # Never reset an existing password.
    }
    if ((Test-Path -LiteralPath $paths.Data) -or (Get-LocalUser -Name $plan.UserName -ErrorAction SilentlyContinue)) { throw 'Foreign account/path or incomplete attempt; refusing adoption.' }
    $os = Get-CimInstance Win32_OperatingSystem
    $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$([IO.Path]::GetPathRoot($paths.Data).TrimEnd('\'))'"
    Assert-WorkerCapacity $plan ($os.FreePhysicalMemory / 1MB) ($drive.FreeSpace / 1GB)
    if ($drive.FileSystem -ne 'NTFS' -or $Processors -gt [Environment]::ProcessorCount) { throw 'Need local NTFS and a feasible CPU budget.' }
    # Failure after here leaves partial state. No automatic deletion, password reset or adoption.
    $user = New-LocalUser -Name $plan.UserName -Password $Password -Description "$($plan.Owner)/$InstanceId" -ErrorAction Stop
    $sid = $user.SID.Value
    $groups = @(Get-WorkerGroupSids $sid)
    if ('S-1-5-32-545' -notin $groups) { Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $user -ErrorAction Stop }
    Assert-WorkerIdentity $sid $sid @(Get-WorkerGroupSids $sid) @() $plan.DistroName
    $null = New-Item -ItemType Directory -Path $paths.Metadata -ErrorAction Stop
    Set-WorkerResourceAcl $paths.Metadata $sid Metadata
    $null = New-Item -ItemType Directory -Path $paths.Data -ErrorAction Stop
    Set-WorkerResourceAcl $paths.Data $sid Data
    $probe = Join-Path $paths.Metadata 'child-probe.ps1'
    Write-WorkerNewFile $probe ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'child-probe.ps1'))) $sid
    $state = [ordered]@{}
    foreach ($property in $plan.PSObject.Properties) { $state[$property.Name] = $property.Value }
    $state.Sid = $sid; $state.SourceUri = $SourceUri; $state.Sha256 = $Sha256.ToLowerInvariant()
    $state.ProbeHash = (Get-FileHash -LiteralPath $probe).Hash
    Write-WorkerNewFile (Join-Path $paths.Metadata 'manifest.json') ($state | ConvertTo-Json) $sid
    Read-WorkerState $InstanceId
}
function Invoke-WorkerChild([string]$InstanceId, [SecureString]$Password, [ValidateSet('PrepareProfile','Probe')][string]$Mode, [string]$ProtectedFile, [string]$PeerInstanceId) {
    $state = Read-WorkerState $InstanceId
    $paths = Get-WorkerPaths $InstanceId
    if (-not $Password -or $Password.Length -lt 1) { throw 'Supply SecureString in process memory.' }
    $peerPath = ''
    if ($Mode -eq 'Probe') {
        if ($PeerInstanceId -ceq $InstanceId) { throw 'A distinct owned peer is required.' }
        $null = Read-WorkerState $PeerInstanceId
        $peerPath = (Get-WorkerPaths $PeerInstanceId).Data
        Assert-WorkerPlainPath $ProtectedFile
        if ((Get-Item -LiteralPath $ProtectedFile -Force).PSIsContainer) { throw 'ProtectedFile must be an existing file.' }
        # Probe does not create a new profile; PrepareProfile is a separate explicit mutation.
        if (-not (Get-CimInstance Win32_UserProfile -Filter "SID='$($state.Sid)'")) { throw 'Run PrepareProfile first.' }
    }
    $windows = [Environment]::GetFolderPath('Windows')
    $executable = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'PowerShell/7/pwsh.exe'
    $previousCanary = [Environment]::GetEnvironmentVariable('PC_SETUP_CONTROLLER_CANARY')
    $process = $null
    try {
    $env:PC_SETUP_CONTROLLER_CANARY = [guid]::NewGuid().ToString()
    $info = New-CleanWorkerStartInfo $executable $paths.Data $windows
    $info.UserName = $state.UserName; $info.Domain = [Environment]::MachineName
    $info.Password = $Password; $info.LoadUserProfile = $true
    foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $paths.Metadata 'child-probe.ps1'),'-Mode',$Mode,'-ManifestPath',(Join-Path $paths.Metadata 'manifest.json'),'-ProtectedFile',$ProtectedFile,'-PeerPath',$peerPath)) { $info.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::Start($info)
    $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Worker child timed out; inspect before retry.' }
        if ($process.ExitCode -ne 0) { throw 'Worker child failed. No credential details are emitted; inspect identity/profile prerequisites locally.' }
        $text = $stdout.GetAwaiter().GetResult()
        if ($text.Length -gt 16384 -or $stderr.GetAwaiter().GetResult().Length) { throw 'Unexpected child output.' }
        $report = $text | ConvertFrom-Json -AsHashtable
        if ($report.Sid -cne $state.Sid) { throw 'Wrong process identity.' }
        if ($Mode -eq 'Probe') { Assert-WorkerReport $report $state.Sid }
        $report
    } finally {
        [Environment]::SetEnvironmentVariable('PC_SETUP_CONTROLLER_CANARY',$previousCanary)
        if ($process) { $process.Dispose() }
        if (Get-Variable info -ErrorAction SilentlyContinue) { $info.Password = $null }
    }
}
