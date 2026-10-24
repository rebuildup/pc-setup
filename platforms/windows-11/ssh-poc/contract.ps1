# Pure contract helpers: also exercised on non-Windows PowerShell.
function Assert-PocInput([string]$UserName, [string]$ListenAddress, [string]$ControllerAddress, [string]$PublicKey) {
    if ($UserName -cnotmatch '^[a-z0-9][a-z0-9._-]{0,31}$') { throw 'Use an explicit lowercase local Windows account name.' }
    foreach ($address in @($ListenAddress, $ControllerAddress)) {
        $ip = $null
        if (-not [Net.IPAddress]::TryParse($address, [ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork' -or $ip.ToString() -cne $address) { throw 'Expected one canonical VPN IPv4 address.' }
        $bytes = $ip.GetAddressBytes()
        if ($bytes[0] -ne 100 -or $bytes[1] -lt 64 -or $bytes[1] -gt 127) { throw 'Expected an address in the Tailscale IPv4 range.' }
    }
    if ($PublicKey -notmatch '^ssh-ed25519 ([A-Za-z0-9+/]+={0,2})( [^\r\n]*)?$') { throw 'Supply exactly one dedicated Ed25519 public key, without key options.' }
    $blob = [Convert]::FromBase64String($Matches[1])
    # RFC 4253 string("ssh-ed25519") + string(32-byte key).
    $prefix = [byte[]](0,0,0,11,115,115,104,45,101,100,50,53,53,49,57,0,0,0,32)
    if ($blob.Length -ne 51) { throw 'Invalid Ed25519 key length.' }
    for ($i = 0; $i -lt $prefix.Length; $i++) {
        if ($blob[$i] -ne $prefix[$i]) { throw 'Invalid Ed25519 key wire format.' }
    }
}
function New-PocConfig([string]$UserName, [string]$ListenAddress, [string]$Root) {
    if ($Root -match '["\r\n]') { throw 'Unsafe configuration path.' }
    $path = $Root.Replace('\','/')
    return @"
Port 22222
AddressFamily inet
ListenAddress $ListenAddress
HostKey "$path/host_ed25519"
AuthorizedKeysFile "$path/authorized_keys"
PidFile none
AllowUsers $UserName
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
PermitEmptyPasswords no
StrictModes yes
AllowAgentForwarding no
AllowTcpForwarding no
GatewayPorts no
PermitTunnel no
X11Forwarding no
LogLevel VERBOSE
"@
}
function Assert-PocFiles([string]$Root, $Files) {
    $rootItem = Get-Item -LiteralPath $Root -Force
    if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Managed root is a reparse point.' }
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or $item.PSIsContainer) { throw 'Unexpected directory/reparse point; refusing changes.' }
        if ($item.Name -eq 'manifest.json') { continue }
        if (-not $Files.Contains($item.Name)) { throw "Foreign file: $($item.Name)" }
    }
    foreach ($name in $Files.Keys) {
        if ($name -cnotin @('authorized_keys','host_ed25519','host_ed25519.pub','sshd_config')) { throw 'Unsafe manifest filename.' }
        if ((Get-FileHash -LiteralPath (Join-Path $Root $name) -Algorithm SHA256).Hash -cne $Files[$name]) { throw "Managed file drift: $name" }
    }
}
