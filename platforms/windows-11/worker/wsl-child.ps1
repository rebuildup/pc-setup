[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Inventory','Import','Verify')][string]$Mode,
    [Parameter(Mandatory)][string]$ManifestPath,
    [string]$ProtectedFile,
    [string]$ProtectedDirectory
)
$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or -not [Environment]::Is64BitProcess) { throw 'Native x64 Windows only.' }
. (Join-Path $PSScriptRoot 'contract.ps1')
. (Join-Path $PSScriptRoot 'wsl-contract.ps1')
$stage = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.User.Value -cne $stage.Sid -or $identity.Groups.Value -contains 'S-1-5-32-544') { throw 'Not the enrolled standard worker token.' }
if ((Get-FileHash -LiteralPath $stage.WorkerManifest).Hash -cne $stage.WorkerManifestHash) { throw 'Worker manifest changed.' }
$state = Get-Content -LiteralPath $stage.WorkerManifest -Raw | ConvertFrom-Json
$plan = New-WorkerPlan $state.InstanceId $state.MemoryGB $state.Processors
if ($stage.InstanceId -cne $plan.InstanceId -or $stage.Sid -cne $state.Sid) { throw 'Stage identity mismatch.' }
$profile = [Environment]::GetFolderPath('UserProfile')
$registered = (Get-ItemProperty -LiteralPath "HKLM:/SOFTWARE/Microsoft/Windows NT/CurrentVersion/ProfileList/$($stage.Sid)").ProfileImagePath
if (-not $profile -or $profile -ine [Environment]::ExpandEnvironmentVariables($registered)) { throw 'Native worker profile not loaded.' }
if (([IO.File]::ReadAllText((Join-Path $profile '.wslconfig'))) -cne (New-WorkerWslConfig $plan)) { throw 'Worker profile config drift.' }
if (Test-Path Env:/PC_SETUP_CONTROLLER_CANARY) { throw 'Controller environment inherited.' }
$entries = @()
$lxss = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Lxss')
if ($null -ne $lxss) {
    try {
        foreach ($key in $lxss.GetSubKeyNames()) {
            $entry = $lxss.OpenSubKey($key)
            if ($null -eq $entry) { throw 'Registry changed during inspection.' }
            try {
                $name = $entry.GetValue('DistributionName'); $base = $entry.GetValue('BasePath'); $version = $entry.GetValue('Version')
                if ($name -isnot [string] -or $base -isnot [string] -or $version -isnot [int]) { throw 'Malformed WSL registration.' }
                $entries += @{ Name = $name; BasePath = $base; Version = $version }
            } finally { $entry.Dispose() }
        }
    } finally { $lxss.Dispose() }
}
Assert-WorkerWslInventory $entries $plan $stage.InstallLocation $Mode
$denial = @{}
if ($Mode -eq 'Inventory') {
    # Only an explicit ACL denial is evidence. Never read any private-key bytes.
    try {
        $handle = [IO.File]::Open($ProtectedFile,'Open','Read','ReadWrite')
        $handle.Dispose(); $denial.ProtectedFileReadable = $true
    } catch [UnauthorizedAccessException] { $denial.ProtectedFileReadable = $false }
    try {
        $iterator = [IO.Directory]::EnumerateFileSystemEntries($ProtectedDirectory).GetEnumerator()
        try { $null = $iterator.MoveNext() } finally { $iterator.Dispose() }
        $denial.ProtectedDirectoryReadable = $true
    } catch [UnauthorizedAccessException] { $denial.ProtectedDirectoryReadable = $false }
    Assert-WorkerWslAccessReport $denial
}
if ($Mode -eq 'Import') {
    if (Test-Path -LiteralPath $stage.InstallLocation) { throw 'Install path already exists; preserve partial state.' }
    if ((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'image.wsl') -Algorithm SHA256).Hash -ine $stage.ImageSha256) { throw 'Image hash mismatch.' }
    $null = New-Item -ItemType Directory -Path $stage.InstallLocation -ErrorAction Stop
    $wsl = Join-Path ([Environment]::SystemDirectory) 'wsl.exe'
    $args = @(Get-WorkerWslImportArguments $plan $stage.InstallLocation (Join-Path $PSScriptRoot 'image.wsl'))
    # Use native argv, no shell. Output cannot contain a password: none is passed to wsl.
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $wsl; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    foreach ($arg in $args) { $info.ArgumentList.Add($arg) }
    $p = [Diagnostics.Process]::Start($info)
    try {
        $p.StandardInput.Close()
        $stdout = $p.StandardOutput.ReadToEndAsync(); $stderr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(240000)) { throw 'WSL import timeout; preserve state and inspect before any further action.' }
        if ($p.ExitCode -ne 0) { throw "WSL import failed with native exit $($p.ExitCode); no retry or rollback." }
        $null = $stdout.GetAwaiter().GetResult(); $null = $stderr.GetAwaiter().GetResult()
    } finally { $p.Dispose() }
}
$report = @{
    InstanceId = $plan.InstanceId; Sid = $identity.User.Value; Administrator = $false
    CanaryPresent = $false; NativeProfileLoaded = $true; Mode = $Mode
    DistroName = $plan.DistroName; InstallLocation = $stage.InstallLocation
    RegistryCountBefore = $entries.Count; ImportCommandSucceeded = ($Mode -eq 'Import')
    RegistrationVerified = ($Mode -eq 'Verify'); LinuxBootTested = $false
}
if ($Mode -eq 'Inventory') {
    $report.ProtectedFileReadable = $denial.ProtectedFileReadable
    $report.ProtectedDirectoryReadable = $denial.ProtectedDirectoryReadable
    $report.DenialScope = 'Existing operator file/directory only; not another standard worker.'
}
$report | ConvertTo-Json -Compress
