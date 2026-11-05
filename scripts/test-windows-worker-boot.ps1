$ErrorActionPreference='Stop'
$root=Join-Path $PSScriptRoot '../platforms/windows-11/worker'
. "$root/contract.ps1"
. "$root/boot-contract.ps1"
Get-ChildItem "$root/*.ps1",$PSCommandPath|ForEach-Object{
    $parseErrors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$null,[ref]$parseErrors)
    if($parseErrors){throw $parseErrors}
}
$plan=New-WorkerPlan '2a1084ec-5389-4b0b-a0f0-9a38fcfaece5'
$nonce='0123456789abcdef0123456789abcdef'
$args=@(Get-WorkerBootArguments $plan $nonce)
if($args[0] -cne '--distribution' -or $args[1] -cne $plan.DistroName -or $args[3] -cne 'root' -or $args[5] -cne '/usr/bin/env' -or $args[6] -cne '-i'){throw 'Unsafe boot argv'}
$denied=$false;try{Get-WorkerBootArguments $plan "bad'; command"|Out-Null}catch{$denied=$true};if(-not $denied){throw 'Unsafe nonce accepted'}
$good="nonce=$nonce`nos=Linux`nuid=0`narch=x86_64`nrelease=24.04`ncpu=2`nmem_kb=3900000`nwindows_mount=1`ninterop=1`n"
$report=ConvertFrom-WorkerBootReport $good $nonce
if($report.Cpu -ne 2 -or -not $report.WindowsMountPresent){throw 'Invalid inventory parser'}
foreach($bad in @($good.Replace('uid=0','uid=1000'),$good.Replace('os=Linux','os=Darwin'),$good.Replace('nonce='+$nonce,'nonce=wrong'),($good+"uid=0`n"),$good.Replace('interop=1','interop=unknown'))){
    $denied=$false;try{ConvertFrom-WorkerBootReport $bad $nonce|Out-Null}catch{$denied=$true};if(-not $denied){throw 'Unsafe inventory accepted'}
}
Write-Output 'Worker Linux boot contracts: PASS'
