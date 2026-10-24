$ErrorActionPreference = 'Stop'
$module = Join-Path $PSScriptRoot '../platforms/windows-11/ssh-poc/contract.ps1'
if (-not (Test-Path $module)) { throw 'Missing SSH PoC input/config/ownership contract' }
$parseErrors = $null
Get-ChildItem (Join-Path $PSScriptRoot '../platforms/windows-11/ssh-poc/*.ps1'),$PSCommandPath | ForEach-Object {
    $null = [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw $parseErrors }
}
. $module
function Assert-Throws($Block) {
    $caught = $false
    try { & $Block } catch { $caught = $true }
    if (-not $caught) { throw 'Expected refusal' }
}
$key = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA poc'
Assert-PocInput 'rebui' '100.118.123.62' '100.101.102.103' $key
Assert-Throws { Assert-PocInput 'rebui *' '100.118.123.62' '100.101.102.103' $key }
Assert-Throws { Assert-PocInput 'rebui' '0.0.0.0' '100.101.102.103' $key }
Assert-Throws { Assert-PocInput 'rebui' '100.118.123.62' '100.64.0.0/10' $key }
Assert-Throws { Assert-PocInput 'rebui' '100.118.123.62' '100.101.102.103' "$key`n$key" }
Assert-Throws { Assert-PocInput 'rebui' '100.118.123.62' '100.101.102.103' 'ssh-ed25519 YWJj' }
$config = New-PocConfig 'rebui' '100.118.123.62' 'C:/ProgramData/pc-setup-ssh-poc'
foreach ($line in @('Port 22222','ListenAddress 100.118.123.62','AllowUsers rebui','AuthenticationMethods publickey','PasswordAuthentication no','AllowTcpForwarding no','AllowAgentForwarding no','PermitTunnel no')) {
    if (($config -split "`n") -notcontains $line) { throw "Missing required boundary: $line" }
}
if ($config -match '(?m)^(Match|Include) ') { throw 'Global/default configuration must not leak in' }
$temp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory $temp | Out-Null
try {
    Set-Content (Join-Path $temp 'authorized_keys') 'original'
    $files = @{authorized_keys = (Get-FileHash (Join-Path $temp 'authorized_keys')).Hash}
    foreach ($name in @('host_ed25519','host_ed25519.pub','sshd_config')) {
        Set-Content (Join-Path $temp $name) 'fixture'
        $files[$name] = (Get-FileHash (Join-Path $temp $name)).Hash
    }
    Assert-PocFiles $temp $files
    Set-Content (Join-Path $temp 'authorized_keys') 'drift'
    Assert-Throws { Assert-PocFiles $temp $files }
    Set-Content (Join-Path $temp 'authorized_keys') 'original'
    Set-Content (Join-Path $temp 'foreign') 'preserve me'
    Assert-Throws { Assert-PocFiles $temp $files }
} finally { Remove-Item $temp -Recurse -Force }
Write-Host 'SSH PoC contract checks passed'
