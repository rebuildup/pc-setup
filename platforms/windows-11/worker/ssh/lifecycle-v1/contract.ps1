. (Join-Path $PSScriptRoot '../../contract.ps1')

function Get-WorkerGatewayLifecycleV1Path([string]$InstanceId) {
    $null = New-WorkerPlan $InstanceId
    Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) "pc-setup-wsl-gateway-lifecycle-v1-$InstanceId"
}

function Get-WorkerGatewayLifecycleV1TaskName([string]$InstanceId) {
    $null = New-WorkerPlan $InstanceId
    "pc-setup-wsl-gateway-lifecycle-v1-$InstanceId"
}

function Resolve-WorkerGatewayLifecycleSid([string]$Identity) {
    if ($Identity -match '^S-1-5-21-(\d+-){3}\d+$') { return $Identity }
    try { return ([Security.Principal.NTAccount]::new($Identity)).Translate([Security.Principal.SecurityIdentifier]).Value }
    catch { throw 'Scheduled task identity cannot be resolved to a local SID.' }
}

function New-WorkerGatewayLifecycleV1TaskPlan(
    [string]$InstanceId,
    [string]$OperatorSid,
    [string]$WorkerSid,
    [string]$OperatorName,
    [string]$PowerShellPath,
    [string]$RunnerPath
) {
    $null = New-WorkerPlan $InstanceId
    foreach ($sid in @($OperatorSid,$WorkerSid)) {
        if ($sid -notmatch '^S-1-5-21-(\d+-){3}\d+$') { throw 'Expected canonical Windows account SIDs.' }
    }
    if ($OperatorSid -ceq $WorkerSid) { throw 'The lifecycle task must run as the distinct logged-in operator.' }
    if ((Resolve-WorkerGatewayLifecycleSid $OperatorName) -cne $OperatorSid) { throw 'Operator name and SID differ.' }
    foreach ($path in @($PowerShellPath,$RunnerPath)) {
        if (-not [IO.Path]::IsPathRooted($path) -or $path.Contains('"') -or $path.Contains("`r") -or $path.Contains("`n")) { throw 'Task executable and runner must be absolute paths without command-line metacharacters.' }
    }
    if ($RunnerPath -match '\s' -and $RunnerPath -notmatch '^".+"$') { throw 'Runner path with spaces must be quoted.' }
    [pscustomobject][ordered]@{
        TaskName = Get-WorkerGatewayLifecycleV1TaskName $InstanceId
        TaskPath = '\'
        Description = "pc-setup/windows-worker-gateway-lifecycle/v1; instance=$InstanceId"
        OperatorSid = $OperatorSid
        OperatorName = $OperatorName
        WorkerSid = $WorkerSid
        LogonType = 'Interactive'
        RunLevel = 'Highest'
        PowerShellPath = $PowerShellPath
        RunnerPath = $RunnerPath.Trim('"')
        Arguments = "-NoLogo -NoProfile -NonInteractive -File `"$($RunnerPath.Trim('"'))`" -InstanceId $InstanceId"
        Trigger = 'Logon'
        StartWhenAvailable = $true
        AllowStartIfOnBatteries = $true
        DontStopIfGoingOnBatteries = $true
        MultipleInstances = 'IgnoreNew'
        ExecutionTimeLimit = [TimeSpan]::FromMinutes(30)
        RestartCount = 0
    }
}

function Assert-WorkerGatewayLifecycleV1Task($Task,$Plan) {
    if ($Task.TaskName -cne $Plan.TaskName -or $Task.TaskPath -cne $Plan.TaskPath -or $Task.Description -cne $Plan.Description) { throw 'Scheduled task name/path/owner description drift.' }
    if ((Resolve-WorkerGatewayLifecycleSid ([string]$Task.Principal.UserId)) -cne $Plan.OperatorSid) { throw 'Scheduled task operator SID drift.' }
    if ([string]$Task.Principal.LogonType -notin @('Interactive','InteractiveToken') -or [string]$Task.Principal.RunLevel -ne 'Highest') { throw 'Scheduled task must use the logged-in operator token at highest available level.' }
    $actions = @($Task.Actions)
    if ($actions.Count -ne 1 -or $actions[0].Execute -ine $Plan.PowerShellPath -or $actions[0].Argument -cne $Plan.Arguments -or $actions[0].WorkingDirectory) { throw 'Scheduled task action drift.' }
    $triggers = @($Task.Triggers)
    if ($triggers.Count -ne 1 -or [string]$triggers[0].CimClass.CimClassName -notmatch 'LogonTrigger' -or (Resolve-WorkerGatewayLifecycleSid ([string]$triggers[0].UserId)) -cne $Plan.OperatorSid) { throw 'Scheduled task logon trigger drift.' }
    $settings = $Task.Settings
    if (-not $settings.StartWhenAvailable -or -not $settings.AllowStartIfOnBatteries -or -not $settings.DontStopIfGoingOnBatteries -or [string]$settings.MultipleInstances -ne $Plan.MultipleInstances -or [TimeSpan]$settings.ExecutionTimeLimit -ne $Plan.ExecutionTimeLimit -or [int]$settings.RestartCount -ne 0) { throw 'Scheduled task settings drift.' }
    $true
}
