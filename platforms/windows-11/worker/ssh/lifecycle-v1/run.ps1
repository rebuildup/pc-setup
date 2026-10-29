param([Parameter(Mandatory)][string]$InstanceId)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'runtime.ps1')

function Invoke-WorkerGatewayLifecycleV1([string]$InstanceId) {
    $manifest = Read-WorkerGatewayLifecycleV1 $InstanceId
    $root = Get-WorkerGatewayLifecycleV1Path $InstanceId
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Join-Path $root 'infisical.exe'
    $info.WorkingDirectory = $root
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $info.Environment.Clear()
    $windows = [Environment]::GetFolderPath('Windows')
    foreach ($name in @('SystemRoot','WINDIR')) { $info.Environment[$name] = $windows }
    $info.Environment['PATH'] = Join-Path $windows 'System32'
    $info.Environment['USERPROFILE'] = [Environment]::GetFolderPath('UserProfile')
    $info.Environment['APPDATA'] = [Environment]::GetFolderPath('ApplicationData')
    $info.Environment['LOCALAPPDATA'] = [Environment]::GetFolderPath('LocalApplicationData')
    $info.Environment['INFISICAL_API_URL'] = 'https://secrets.rebuildup.dev/api'
    $info.Environment['INFISICAL_DOMAIN'] = 'https://secrets.rebuildup.dev/api'
    $info.Environment['NO_COLOR'] = '1'
    $info.Environment['INFISICAL_DISABLE_UPDATE_CHECK'] = 'true'
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false,$true)
    $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false,$true)
    foreach ($arg in @('secrets','get','--plain',"--projectId=$($manifest.InfisicalProjectId)","--env=$($manifest.InfisicalEnvironment)","--path=$($manifest.InfisicalPath)",'--domain=https://secrets.rebuildup.dev/api','--expand=false','--include-imports=false','--secret-overriding=false','--recursive=false','--silent','--telemetry=false','--log-level=error','--log-destination=stderr','--',$manifest.InfisicalSecretKey)) { $info.ArgumentList.Add($arg) }
    Add-Type -Path (Join-Path $root 'SecretCapture.cs') -ErrorAction Stop
    $password = $null
    try {
        $password = [WorkerSecretCapture]::Capture($info,15000)
        if (-not $password -or $password.Length -lt 1) { throw 'Infisical did not provide the required worker credential.' }
        . (Join-Path (Join-Path $root 'bundle/platforms/windows-11/worker') 'ssh/repair-v1/runtime.ps1')
        $null = Invoke-WorkerGatewayRepairV1 $InstanceId $password
        $verified = Read-WorkerGatewayRepairV1 $InstanceId
        if ($verified.ListenAddress -cne $manifest.ListenAddress -or $verified.ControllerAddress -cne $manifest.ControllerAddress -or $verified.HostFingerprint -cne $manifest.HostFingerprint -or $verified.Port -ne 22224) { throw 'Post-repair gateway scope or host pin drift.' }
        $result = [ordered]@{ Owner=$script:WorkerGatewayLifecycleOwner; InstanceId=$InstanceId; Status='pass'; GuestAddress=$verified.GuestAddress; ListenAddress=$verified.ListenAddress; ControllerAddress=$verified.ControllerAddress; Port=22224; HostFingerprint=$verified.HostFingerprint; CheckedAtUtc=[DateTime]::UtcNow.ToString('o') }
        $resultPath = Join-Path (Join-Path $root 'results') (('{0:yyyyMMddTHHmmssfffZ}-{1}.json' -f [DateTime]::UtcNow,[guid]::NewGuid().ToString('N')))
        Write-WorkerNewFile $resultPath ($result | ConvertTo-Json) $manifest.OperatorSid
    }
    finally { if ($password) { $password.Dispose() } }
}

try { Invoke-WorkerGatewayLifecycleV1 $InstanceId | Out-Null; exit 0 }
catch {
    try {
        $root = Get-WorkerGatewayLifecycleV1Path $InstanceId
        $manifest = Read-WorkerGatewayLifecycleV1 $InstanceId
        $resultPath = Join-Path (Join-Path $root 'results') (('{0:yyyyMMddTHHmmssfffZ}-{1}.json' -f [DateTime]::UtcNow,[guid]::NewGuid().ToString('N')))
        $result = [ordered]@{ Owner=$script:WorkerGatewayLifecycleOwner; InstanceId=$InstanceId; Status='fail'; ErrorType=$_.Exception.GetType().FullName; CheckedAtUtc=[DateTime]::UtcNow.ToString('o') }
        Write-WorkerNewFile $resultPath ($result | ConvertTo-Json) $manifest.OperatorSid
    } catch { }
    exit 1
}
