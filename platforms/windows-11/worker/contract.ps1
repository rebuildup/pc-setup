# Pure boundary checks; no account, profile, WSL or credential side effects.
function New-WorkerPlan([string]$InstanceId, [int]$MemoryGB = 4, [int]$Processors = 2) {
    $parsed = [guid]::Empty
    if (-not [guid]::TryParseExact($InstanceId, 'D', [ref]$parsed) -or $parsed -eq [guid]::Empty -or $parsed.ToString('D') -cne $InstanceId) { throw 'Use a nonzero canonical lowercase instance UUID.' }
    if ($MemoryGB -lt 2 -or $MemoryGB -gt 8 -or $Processors -lt 1 -or $Processors -gt 4) { throw 'Worker budget: memory 2..8 GiB, processors 1..4.' }
    [pscustomobject][ordered]@{
        Owner = 'pc-setup/windows-worker/v1'; Schema = 1; InstanceId = $InstanceId
        AccountDescription = "pcw/v1/$InstanceId"
        UserName = 'pcw-' + $parsed.ToString('N').Substring(0,12)
        DistroName = "pcw-$InstanceId"; MemoryGB = $MemoryGB; Processors = $Processors; SwapGB = 1
    }
}
function Assert-WorkerCapacity($Plan, [double]$AvailableMemoryGB, [double]$FreeDiskGB) {
    if ($AvailableMemoryGB -lt ($Plan.MemoryGB + 2) -or $FreeDiskGB -lt 20) { throw 'Need requested memory plus 2 GiB available, and 20 GiB free on the worker volume. Re-measure before every worker.' }
}
function Assert-WorkerImage([string]$SourceUri, [string]$ExpectedHash, [string]$ActualHash) {
    $uri = $null
    if (-not [uri]::TryCreate($SourceUri, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.Host -notin @('releases.ubuntu.com','cloud-images.ubuntu.com') -or $uri.UserInfo -or -not $uri.IsDefaultPort -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -notmatch '\.(wsl|tar\.gz|tar\.xz)$') { throw 'Use an explicit official Canonical HTTPS image URL without credentials/query/fragment.' }
    if ($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$' -or $ActualHash -notmatch '^[a-fA-F0-9]{64}$' -or $ExpectedHash -ine $ActualHash) { throw 'Fresh image SHA256 mismatch. Obtain the expected hash independently from the official release.' }
}
function Assert-WorkerIdentity([string]$ExpectedSid, [string]$ActualSid, [string[]]$GroupSids, [string[]]$DistroNames, [string]$ExpectedDistro) {
    if ($ExpectedSid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$' -or $ActualSid -cne $ExpectedSid) { throw 'Worker SID drift.' }
    if (@($GroupSids).Count -ne 1 -or $GroupSids[0] -cne 'S-1-5-32-545') { throw 'Worker must belong only to local Users; refusing privileged/foreign group membership.' }
    if (@($DistroNames | Where-Object { $_ -cne $ExpectedDistro }).Count -or @($DistroNames).Count -gt 1) { throw 'Foreign distro in this Windows account.' }
}
function Assert-WorkerReport($Report, [string]$Sid) {
    if ($Report.Sid -cne $Sid) { throw 'Child ran as another SID.' }
    foreach ($field in @('Administrator','CanaryPresent','ProtectedReadable','PeerReadable')) {
        if ($Report[$field] -isnot [bool] -or $Report[$field]) { throw "Worker isolation probe failed: $field" }
    }
}
function New-WorkerWslConfig($Plan) {
    @('[wsl2]',"memory=$($Plan.MemoryGB)GB", "processors=$($Plan.Processors)", "swap=$($Plan.SwapGB)GB",'localhostForwarding=false','') -join "`n"
}
function New-CleanWorkerStartInfo([string]$Executable, [string]$Directory, [string]$WindowsDirectory) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable; $info.WorkingDirectory = $Directory
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $info.Environment.Clear()
    $info.Environment['SystemRoot'] = $WindowsDirectory
    $info.Environment['WINDIR'] = $WindowsDirectory
    $info.Environment['PATH'] = (Join-Path $WindowsDirectory 'System32')
    $info.Environment['COMSPEC'] = (Join-Path $WindowsDirectory 'System32/cmd.exe')
    $info.Environment['PSModulePath'] = Join-Path (Split-Path -Parent $Executable) 'Modules'
    $info
}
