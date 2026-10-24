[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Bootstrap','Verify','Start','Undo')][string]$Action,
    [string]$UserName,
    [string]$ListenAddress,
    [string]$ControllerAddress,
    [string]$PublicKeyPath
)
# PowerShell 7.3+ preserves the empty ssh-keygen passphrase argument.
if ($PSVersionTable.PSVersion -lt [version]'7.3') { throw 'PowerShell 7.3+ (pwsh) is required.' }
$PSNativeCommandArgumentPassing = 'Standard'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'contract.ps1')

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Run locally on Windows.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Open an elevated PowerShell as the target local administrator account.' }
$root = Join-Path $env:ProgramData 'pc-setup-ssh-poc'
$manifestPath = Join-Path $root 'manifest.json'
$ruleName = 'pc-setup-ssh-poc-22222'
$sshd = Join-Path $env:WINDIR 'System32\OpenSSH\sshd.exe'
$keygen = Join-Path $env:WINDIR 'System32\OpenSSH\ssh-keygen.exe'
$configPath = Join-Path $root 'sshd_config'
$owner = 'pc-setup/ssh-poc/v1'

function Invoke-Native([string]$Command, [string[]]$Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed ($LASTEXITCODE)." }
}
function Set-PrivateAcl([string]$Path, [bool]$Directory = $false) {
    $acl = if ($Directory) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Assert-PrivateAcl([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point: $Path" }
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544') { throw "ACL owner/inheritance drift: $Path" }
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne 2) { throw "Unexpected ACL entries: $Path" }
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $match = @($rules | Where-Object { $_.IdentityReference.Value -eq $sid -and $_.AccessControlType -eq 'Allow' -and $_.FileSystemRights -eq 'FullControl' -and -not $_.IsInherited })
        if ($match.Count -ne 1) { throw "ACL rights drift: $Path" }
    }
}
function Write-NewFile([string]$Path, [string]$Content) {
    $stream = [IO.File]::Open($Path, 'CreateNew', 'Write', 'None')
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Content)
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
    Set-PrivateAcl $Path
}
function Get-PocRule { @(Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue) }
function Assert-PocRule($State) {
    $rules = @(Get-PocRule)
    if ($rules.Count -ne 1) { throw 'Expected exactly one managed firewall rule.' }
    $rule = $rules[0]
    if ($rule.Description -cne "$owner/$($State.Id)" -or $rule.Enabled -ne 'True' -or $rule.Direction -ne 'Inbound' -or $rule.Action -ne 'Allow' -or $rule.Profile -ne 'Any') { throw 'Firewall ownership/policy drift.' }
    $port = $rule | Get-NetFirewallPortFilter
    $address = $rule | Get-NetFirewallAddressFilter
    $app = $rule | Get-NetFirewallApplicationFilter
    if ($port.Protocol -ne 'TCP' -or "$($port.LocalPort)" -ne '22222' -or "$($port.RemotePort)" -ne 'Any' -or "$($address.LocalAddress)" -cne $State.ListenAddress -or "$($address.RemoteAddress)" -cne $State.ControllerAddress -or $app.Program -ine $sshd) { throw 'Firewall scope drift.' }
}
function Assert-NoListener {
    if (@(Get-NetTCPConnection -State Listen -LocalPort 22222 -ErrorAction SilentlyContinue).Count -gt 0) { throw 'Port 22222 is in use. Stop the PoC foreground process and sessions; no process will be killed automatically.' }
}
function Read-State {
    Assert-PrivateAcl $root
    Assert-PrivateAcl $manifestPath
    $state = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($state.Owner -cne $owner -or $state.Id -notmatch '^[0-9a-f-]{36}$') { throw 'Unknown managed root; preserve it and inspect manually.' }
    Assert-PocInput $state.UserName $state.ListenAddress $state.ControllerAddress $state.PublicKey
    $files = @{}
    foreach ($property in $state.Files.PSObject.Properties) { $files[$property.Name] = [string]$property.Value }
    $expected = @('authorized_keys','host_ed25519','host_ed25519.pub','sshd_config')
    if (@($files.Keys).Count -ne $expected.Count) { throw 'Unexpected manifest file set.' }
    foreach ($name in $expected) { if (-not $files.ContainsKey($name)) { throw "Missing owned file: $name" } }
    Assert-PocFiles $root $files
    foreach ($name in $files.Keys) { Assert-PrivateAcl (Join-Path $root $name) }
    if ((Get-Content $configPath -Raw) -cne (New-PocConfig $state.UserName $state.ListenAddress $root)) { throw 'Configuration differs from the current contract.' }
    if ((Get-Content (Join-Path $root 'authorized_keys') -Raw) -cne ($state.PublicKey + "`n")) { throw 'Authorized key differs from enrollment.' }
    return $state
}

if ($Action -eq 'Bootstrap') {
    if (-not $PublicKeyPath) { throw 'PublicKeyPath is required.' }
    $key = (Get-Content -LiteralPath $PublicKeyPath -Raw).TrimEnd("`r", "`n")
    Assert-PocInput $UserName $ListenAddress $ControllerAddress $key
    $user = Get-LocalUser -Name $UserName
    if (-not $user.Enabled -or $user.SID.Value -ne $identity.User.Value) { throw 'Target must be the enabled local account running this elevated shell. Domain/Entra accounts are outside this PoC.' }
    if (-not (Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ListenAddress -ErrorAction SilentlyContinue)) { throw 'ListenAddress must already exist locally; connect Tailscale first.' }
    foreach ($binary in @($sshd, $keygen)) { if (-not (Test-Path -LiteralPath $binary)) { throw 'Install the Microsoft OpenSSH Server optional capability first (see runbook).' } }
    if (Test-Path -LiteralPath $root) {
        $state = Read-State
        if ($state.UserName -cne $UserName -or $state.ListenAddress -cne $ListenAddress -or $state.ControllerAddress -cne $ControllerAddress -or $state.PublicKey -cne $key) { throw 'Enrollment parameters changed. Explicit undo and new enrollment are required.' }
        Assert-PocRule $state
        Write-Host 'Existing enrollment matches; no changes made.'
    } else {
        if (@(Get-PocRule).Count) { throw 'Firewall rule name is already owned; refusing replacement.' }
        Assert-NoListener
        # Do not adopt or delete partial state on failure. Inspect it manually.
        New-Item -ItemType Directory -Path $root | Out-Null
        Set-PrivateAcl $root $true
        Write-NewFile $configPath (New-PocConfig $UserName $ListenAddress $root)
        Write-NewFile (Join-Path $root 'authorized_keys') ($key + "`n")
        Invoke-Native $keygen @('-q','-t','ed25519','-N','','-f',(Join-Path $root 'host_ed25519'))
        Set-PrivateAcl (Join-Path $root 'host_ed25519')
        Set-PrivateAcl (Join-Path $root 'host_ed25519.pub')
        Invoke-Native $sshd @('-t','-f',$configPath)
        $files = @{}
        foreach ($file in Get-ChildItem -LiteralPath $root -File) { $files[$file.Name] = (Get-FileHash $file.FullName -Algorithm SHA256).Hash }
        $state = [ordered]@{ Owner = $owner; Id = [guid]::NewGuid().ToString(); UserName = $UserName; ListenAddress = $ListenAddress; ControllerAddress = $ControllerAddress; PublicKey = $key; Files = $files }
        Write-NewFile $manifestPath ($state | ConvertTo-Json -Depth 4)
        New-NetFirewallRule -Name $ruleName -DisplayName 'pc-setup SSH connection PoC' -Description "$owner/$($state.Id)" -Direction Inbound -Action Allow -Enabled True -Profile Any -Protocol TCP -LocalPort 22222 -LocalAddress $ListenAddress -RemoteAddress $ControllerAddress -Program $sshd | Out-Null
    }
}
if ($Action -eq 'Undo' -and -not (Test-Path -LiteralPath $root)) {
    if (@(Get-PocRule).Count) { throw 'Orphan firewall rule exists; refusing adoption/removal.' }
    Write-Host 'Enrollment is already absent; no changes made.'
    return
}
$state = Read-State
if ($Action -eq 'Undo') {
    Assert-NoListener
    $rules = @(Get-PocRule)
    if ($rules.Count -gt 0) {
        Assert-PocRule $state
        Remove-NetFirewallRule -Name $ruleName
    }
    # All children and their hashes/ACLs were checked above; never recursive-delete unknown state.
    foreach ($name in $state.Files.PSObject.Properties.Name) { Remove-Item -LiteralPath (Join-Path $root $name) }
    Remove-Item -LiteralPath $manifestPath
    Remove-Item -LiteralPath $root
    Write-Host 'Owned enrollment removed. OpenSSH capability and all services were preserved.'
    return
}
Assert-PocRule $state
Invoke-Native $sshd @('-t','-f',$configPath)
Write-Host "PoC endpoint: $($state.UserName)@$($state.ListenAddress):22222; controller: $($state.ControllerAddress)"
Invoke-Native $keygen @('-lf',(Join-Path $root 'host_ed25519.pub'),'-E','sha256')
if ($Action -eq 'Start') {
    if ((Get-LocalUser -Name $state.UserName).SID.Value -ne $identity.User.Value) { throw 'Start as the enrolled local administrator account.' }
    Assert-NoListener
    Write-Host 'Foreground debug PoC: one connection only. Restart after keyscan, and before each connection. Ctrl+C stops this listener.'
    Invoke-Native $sshd @('-d','-e','-f',$configPath)
}
