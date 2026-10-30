$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$workerRoot=Join-Path $PSScriptRoot '../platforms/windows-11/worker'
$maintenanceRoot=Join-Path $workerRoot 'maintenance-v1'
. (Join-Path $workerRoot 'contract.ps1')
. (Join-Path $maintenanceRoot 'contract.ps1')
. (Join-Path $maintenanceRoot 'runtime.ps1')

$mise=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../mise.toml') -Raw
$misePackages=@([regex]::Matches($mise,'(?m)^\s*"apt:([^"\r\n]+)"\s*=\s*\{\s*os\s*=\s*"linux"\s*\}')|ForEach-Object{$_.Groups[1].Value})
$scriptText=Get-Content -LiteralPath (Join-Path $maintenanceRoot 'root-maintenance.sh') -Raw
$pinnedHash=[regex]::Match((Get-Content -LiteralPath (Join-Path $maintenanceRoot 'runtime.ps1') -Raw),"WorkerRootMaintenanceScriptHash='([A-F0-9]{64})'")
if(-not $pinnedHash.Success -or (Get-FileHash (Join-Path $maintenanceRoot 'root-maintenance.sh') -Algorithm SHA256).Hash -cne $pinnedHash.Groups[1].Value){throw 'Root maintenance source does not match the reviewed SHA256 pin.'}
$packageBlock=[regex]::Match($scriptText,'(?s)packages=\(\s*(.*?)\s*\)')
if(-not $packageBlock.Success){throw 'Root maintenance package allowlist missing.'}
$scriptPackages=@($packageBlock.Groups[1].Value -split '\s+'|Where-Object{$_ -and $_ -notmatch '^#'})
$contractPackages=@(Get-WorkerRootMaintenancePackages)
if(($misePackages -join ',') -cne ($scriptPackages -join ',') -or ($misePackages -join ',') -cne ($contractPackages -join ',')){throw 'Root maintenance package list differs from mise.toml OS baseline.'}

$plan=New-WorkerPlan '2a1084ec-5389-4b0b-a0f0-9a38fcfaece5'
$nonce='0123456789abcdef0123456789abcdef'
$rootArgs=Get-WorkerRootMaintenanceArguments $plan Inspect $nonce
if(($rootArgs -join ' ') -cne "--distribution $($plan.DistroName) --user root --exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C /bin/bash -s -- Inspect $($plan.InstanceId) $nonce"){throw 'Root maintenance argv is not fixed to exact distro/root/env/script/action.'}
function Refuses([scriptblock]$Body){$denied=$false;try{& $Body|Out-Null}catch{$denied=$true};if(-not $denied){throw 'Expected root maintenance contract refusal.'}}
Refuses {Get-WorkerRootMaintenanceArguments $plan Inspect 'invalid'}
$csv=$contractPackages -join ','
$report=ConvertFrom-WorkerRootMaintenanceReport "action=Inspect`ninstance=$($plan.InstanceId)`nnonce=$nonce`nuid=0`npackages=$csv`nmissing=git`n" Inspect $plan.InstanceId $nonce
if($report.Complete -or $report.Missing.Count -ne 1 -or $report.Missing[0] -cne 'git'){throw 'Root maintenance inspect parser lost missing package state.'}
$complete=ConvertFrom-WorkerRootMaintenanceReport "action=Apply`ninstance=$($plan.InstanceId)`nnonce=$nonce`nuid=0`npackages=$csv`nmissing=`n" Apply $plan.InstanceId $nonce
if(-not $complete.Complete){throw 'Root maintenance apply report did not prove complete baseline.'}
Refuses {ConvertFrom-WorkerRootMaintenanceReport "action=Apply`ninstance=$($plan.InstanceId)`nnonce=$nonce`nuid=0`npackages=$csv`nmissing=git`n" Apply $plan.InstanceId $nonce}
Refuses {ConvertFrom-WorkerRootMaintenanceReport "action=Inspect`ninstance=$($plan.InstanceId)`nnonce=$nonce`nuid=0`npackages=$csv,unapproved`nmissing=`n" Inspect $plan.InstanceId $nonce}
Refuses {ConvertFrom-WorkerRootMaintenanceReport "action=Inspect`ninstance=$($plan.InstanceId)`nnonce=$nonce`nuid=0`npackages=$csv`nmissing=`nextra=x`n" Inspect $plan.InstanceId $nonce}
if($IsWindows){
    $registration=[pscustomobject]@{Name=$plan.DistroName;Version=2;BasePath='C:\ProgramData\pcw-wsl'}
    Assert-WorkerRootMaintenanceRegistration @($registration) $plan 'C:\ProgramData\pcw-wsl'|Out-Null
    Refuses {Assert-WorkerRootMaintenanceRegistration @($registration) $plan 'C:\ProgramData\different'}
}

$scriptPath=Join-Path $maintenanceRoot 'root-maintenance.sh'
$bash=if($IsWindows){Join-Path $env:ProgramW6432 'Git/bin/bash.exe'}else{(Get-Command bash -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source}
if(-not(Test-Path -LiteralPath $bash)){throw 'Git Bash/Bash executable is required for the root maintenance syntax test.'}
& $bash -n $scriptPath
if($LASTEXITCODE -ne 0){throw 'Root maintenance Bash syntax check failed.'}
$operationalScript=($scriptText -split "`r?`n"|Where-Object{$_ -notmatch '^\s*#'}) -join "`n"
if($operationalScript -match '(?i)\bsudo\b|apt(-get)?\s+(full-upgrade|upgrade|remove|purge|autoremove)|\b(mise|npm|pip|cargo)\b|curl\s+https?://|/home/worker|~\/') {throw 'Root maintenance includes an unapproved runtime/user-scope operation.'}
foreach($required in @('apt-get update','apt-get -s --no-install-recommends --no-upgrade install','grep -Eq ''^(Inst [^[:space:]]+ \[[^]]+\] \(|Remv )''','apt-get install -y --no-install-recommends --no-upgrade')){if($scriptText -cnotmatch [regex]::Escape($required)){throw "Root maintenance fixed boundary missing: $required"}}

foreach($path in @((Join-Path $maintenanceRoot 'runtime.ps1'),(Join-Path $maintenanceRoot 'child.ps1'),(Join-Path $maintenanceRoot 'contract.ps1'))){
    $tokens=$null;$errors=$null
    [Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)|Out-Null
    if($errors){throw "Root maintenance PowerShell syntax error: $path"}
}
$runtimeText=Get-Content (Join-Path $maintenanceRoot 'runtime.ps1') -Raw
$childText=Get-Content (Join-Path $maintenanceRoot 'child.ps1') -Raw
$contractText=Get-Content (Join-Path $maintenanceRoot 'contract.ps1') -Raw
foreach($required in @('Initialize-WorkerRootMaintenanceStage','Invoke-WorkerRootMaintenanceV1','SourceCommit','RootScriptHash','Read-WorkerWslStage')){if($runtimeText -notmatch [regex]::Escape($required) -and $childText -notmatch [regex]::Escape($required)){throw "Root maintenance implementation missing: $required"}}
if($contractText -notmatch 'Assert-WorkerRootMaintenanceRegistration' -or $contractText -notmatch 'Get-WorkerRootMaintenanceWslConfig' -or $childText -notmatch 'Assert-WorkerRootMaintenanceRegistration'){throw 'Root maintenance must validate the exact enrolled WSL registry path and worker profile.'}
if(-not $childText.Contains('$process.StandardInput.Write($scriptText)') -or -not $contractText.Contains("'--user','root'") -or -not $contractText.Contains("'/bin/bash','-s'")){throw 'Root maintenance must pipe only the fixed staged script through stdin to the exact WSL distro.'}
Write-Output 'Worker root maintenance contracts: PASS'
