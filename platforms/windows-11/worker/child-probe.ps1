[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('PrepareProfile','Probe')][string]$Mode,
    [Parameter(Mandatory)][string]$ManifestPath,
    [string]$ProtectedFile,
    [string]$PeerPath
)
# Fixed probe imports machine modules only, never a worker-writable user module.
$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or -not [Environment]::Is64BitProcess) { throw 'Native x64 Windows only.' }
$state = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = $identity.Groups.Value -contains 'S-1-5-32-544'
if ($identity.User.Value -cne $state.Sid -or $admin) { throw 'Not the enrolled standard worker token.' }
$profile = [Environment]::GetFolderPath('UserProfile')
$registered = (Get-ItemProperty -LiteralPath "HKLM:/SOFTWARE/Microsoft/Windows NT/CurrentVersion/ProfileList/$($state.Sid)").ProfileImagePath
if (-not $profile -or $profile -ine [Environment]::ExpandEnvironmentVariables($registered)) { throw 'Native profile was not loaded for this SID.' }
$current = $profile
while ($current) {
    if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Profile path contains a reparse point.' }
    $next = Split-Path -Parent $current
    if ($next -eq $current) { break }; $current = $next
}
function Get-WorkerRegistryDistroNames([scriptblock]$OpenRegistry) {
    # A missing registry key means no distro. Access denied/error must never mean empty.
    $lxss = & $OpenRegistry
    if ($null -eq $lxss) { return }
    try {
        foreach ($name in $lxss.GetSubKeyNames()) {
            $entry = $lxss.OpenSubKey($name)
            if ($null -eq $entry) { throw 'Distro registry changed during inspection.' }
            try {
                $value = $entry.GetValue('DistributionName')
                if ($value -isnot [string] -or -not $value) { throw 'Malformed distro registration.' }
                $value
            } finally { $entry.Dispose() }
        }
    } finally { $lxss.Dispose() }
}
$distros = @(Get-WorkerRegistryDistroNames { [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Lxss') })
if ($distros.Count -gt 1 -or @($distros | Where-Object { $_ -cne $state.DistroName }).Count) { throw 'Foreign distro in this worker account.' }
$configPath = Join-Path $profile '.wslconfig'
$config = @('[wsl2]',"memory=$($state.MemoryGB)GB", "processors=$($state.Processors)","swap=$($state.SwapGB)GB",'localhostForwarding=false','') -join "`n"
if ($Mode -eq 'PrepareProfile') {
    if (Test-Path -LiteralPath $configPath) {
        if ((Get-Item -LiteralPath $configPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or [IO.File]::ReadAllText($configPath) -cne $config) { throw 'Foreign/profile config drift; no overwrite.' }
    } else {
        $stream = [IO.File]::Open($configPath,'CreateNew','Write','None')
        try { $bytes = [Text.UTF8Encoding]::new($false).GetBytes($config); $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
    }
    @{ Sid = $identity.User.Value; Profile = $profile; ProfileConfig = 'matches'; WslImported = $false } | ConvertTo-Json -Compress
    return
}
if (-not (Test-Path -LiteralPath $configPath) -or (Get-Item -LiteralPath $configPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or [IO.File]::ReadAllText($configPath) -cne $config) { throw 'PrepareProfile required, or profile config drift.' }
function Test-ProtectedFileOpen([string]$Path) {
    # Opening a handle checks access only. Never read private-key contents.
    try { $handle = [IO.File]::Open($Path,'Open','Read','ReadWrite'); $handle.Dispose(); return $true }
    catch [UnauthorizedAccessException] { return $false }
}
function Test-PeerDirectoryRead([string]$Path) {
    try { $iterator = [IO.Directory]::EnumerateFileSystemEntries($Path).GetEnumerator(); try { $null = $iterator.MoveNext() } finally { $iterator.Dispose() }; return $true }
    catch [UnauthorizedAccessException] { return $false }
}
@{
    Sid = $identity.User.Value; Administrator = $admin
    CanaryPresent = (Test-Path Env:/PC_SETUP_CONTROLLER_CANARY)
    ProtectedReadable = (Test-ProtectedFileOpen $ProtectedFile)
    PeerReadable = (Test-PeerDirectoryRead $PeerPath)
    DistroCount = $distros.Count; NativeProfileLoaded = $true
} | ConvertTo-Json -Compress
