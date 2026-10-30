function Get-WorkerRootMaintenancePackages {
    @('ca-certificates','curl','wget','gnupg','git','git-lfs','build-essential','pkg-config','libssl-dev','cmake','ninja-build','clang','lldb','tree','unzip','zip','xz-utils','rsync','python3-venv','openssh-client')
}

function New-WorkerRootMaintenancePlan([string]$InstanceId,[int]$MemoryGB,[int]$Processors) {
    $parsed=[guid]::Empty
    if(-not [guid]::TryParseExact($InstanceId,'D',[ref]$parsed) -or $parsed -eq [guid]::Empty -or $parsed.ToString('D') -cne $InstanceId){throw 'Invalid worker instance UUID.'}
    if($MemoryGB -lt 2 -or $MemoryGB -gt 8 -or $Processors -lt 1 -or $Processors -gt 4){throw 'Invalid worker WSL budget.'}
    [pscustomobject]@{InstanceId=$InstanceId;DistroName="pcw-$InstanceId";MemoryGB=$MemoryGB;Processors=$Processors;SwapGB=1}
}

function Get-WorkerRootMaintenanceWslConfig($Plan) {
    @('[wsl2]',"memory=$($Plan.MemoryGB)GB","processors=$($Plan.Processors)","swap=$($Plan.SwapGB)GB",'localhostForwarding=false','') -join "`n"
}

function ConvertTo-WorkerRootMaintenancePath([string]$Path) {
    $value=$Path.Replace('/','\')
    if($value.StartsWith('\\?\')){$value=$value.Substring(4)}
    if($value -notmatch '^[A-Za-z]:\\' -or $value.Substring(2).Contains(':') -or $value -match '(^|\\)\.\.?($|\\)'){throw 'Expected an absolute local Windows WSL path without alternate streams or traversal.'}
    [IO.Path]::GetFullPath($value).TrimEnd([char[]]'\/').ToLowerInvariant()
}

function Assert-WorkerRootMaintenanceRegistration([object[]]$Entries,$Plan,[string]$InstallLocation) {
    $expected=ConvertTo-WorkerRootMaintenancePath $InstallLocation
    if(@($Entries).Count -ne 1 -or $Entries[0].Name -cne $Plan.DistroName -or $Entries[0].Version -ne 2 -or (ConvertTo-WorkerRootMaintenancePath $Entries[0].BasePath) -cne $expected){throw 'UUID-owned WSL registration mismatch.'}
    $true
}

function Get-WorkerRootMaintenanceArguments($Plan,[ValidateSet('Inspect','Apply')][string]$Action,[string]$Nonce) {
    $null = New-WorkerRootMaintenancePlan $Plan.InstanceId $Plan.MemoryGB $Plan.Processors
    if ($Nonce -cnotmatch '^[a-f0-9]{32}$') { throw 'Invalid root maintenance nonce.' }
    @('--distribution',$Plan.DistroName,'--user','root','--exec','/usr/bin/env','-i','PATH=/usr/sbin:/usr/bin:/sbin:/bin','LC_ALL=C','/bin/bash','-s','--',$Action,$Plan.InstanceId,$Nonce)
}

function ConvertFrom-WorkerRootMaintenanceReport([string]$Text,[ValidateSet('Inspect','Apply')][string]$Action,[string]$InstanceId,[string]$Nonce) {
    if($InstanceId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'){throw 'Invalid worker instance UUID.'}
    if ($Text.Length -gt 8192 -or $Nonce -cnotmatch '^[a-f0-9]{32}$') { throw 'Unexpected root maintenance output.' }
    $fields=[ordered]@{}
    foreach($line in ($Text -split "`r?`n")){
        if(-not $line){continue}
        if($line -cnotmatch '^([a-z_]+)=([A-Za-z0-9_,-]*)$' -or $fields.Contains($Matches[1])){throw 'Malformed root maintenance report.'}
        $fields[$Matches[1]]=$Matches[2]
    }
    $requiredFields=@('action','instance','nonce','uid','packages','missing')
    if($fields.Count -ne $requiredFields.Count -or @($requiredFields|Where-Object{-not $fields.Contains($_)}).Count){throw 'Unexpected root maintenance fields.'}
    $packages=@(Get-WorkerRootMaintenancePackages)
    if($fields.action -cne $Action -or $fields.instance -cne $InstanceId -or $fields.nonce -cne $Nonce -or $fields.uid -cne '0' -or $fields.packages -cne ($packages -join ',')){throw 'Root maintenance identity or package contract mismatch.'}
    $missing=@();if($fields.missing){$missing=@($fields.missing -split ',')}
    if(@($missing|Where-Object{$_ -notin $packages}).Count){throw 'Root maintenance reported an unapproved package.'}
    if($Action -eq 'Apply' -and $missing.Count){throw 'Approved OS package baseline remains incomplete.'}
    [pscustomobject][ordered]@{Action=$Action;InstanceId=$InstanceId;Nonce=$Nonce;Uid=0;Packages=$packages;Missing=$missing;Complete=($missing.Count -eq 0)}
}
