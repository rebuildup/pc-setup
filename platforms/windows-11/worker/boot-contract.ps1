# Read-only Linux boot probe. No installer, registration or network command.
function Get-WorkerBootArguments($Plan,[string]$Nonce) {
    $null=New-WorkerPlan $Plan.InstanceId $Plan.MemoryGB $Plan.Processors
    if($Nonce -cnotmatch '^[a-f0-9]{32}$'){throw 'Invalid boot nonce.'}
    $script=@'
set -eu
printf 'nonce=%s\n' '__NONCE__'
printf 'os=%s\n' "$(uname -s)"
printf 'uid=%s\n' "$(id -u)"
printf 'arch=%s\n' "$(uname -m)"
awk -F= '$1=="VERSION_ID" {gsub(/"/,"",$2);printf "release=%s\n",$2}' /etc/os-release
printf 'cpu=%s\n' "$(getconf _NPROCESSORS_ONLN)"
awk '$1=="MemTotal:" {printf "mem_kb=%s\n",$2}' /proc/meminfo
if awk '$2=="/mnt/c" {found=1} END {exit !found}' /proc/mounts; then echo windows_mount=1; else echo windows_mount=0; fi
if test -e /proc/sys/fs/binfmt_misc/WSLInterop; then echo interop=1; else echo interop=0; fi
'@
    @('--distribution',$Plan.DistroName,'--user','root','--exec','/usr/bin/env','-i','PATH=/usr/sbin:/usr/bin:/sbin:/bin','/bin/sh','-c',$script.Replace('__NONCE__',$Nonce))
}
function ConvertFrom-WorkerBootReport([string]$Text,[string]$Nonce) {
    if($Text.Length -gt 2048 -or $Nonce -cnotmatch '^[a-f0-9]{32}$'){throw 'Unexpected boot output.'}
    $fields=@{}
    foreach($line in ($Text -split "`r?`n")){
        if(-not $line){continue}
        if($line -cnotmatch '^([a-z_]+)=([a-zA-Z0-9_.-]+)$' -or $fields.ContainsKey($Matches[1])){throw 'Malformed or duplicate boot inventory.'}
        $fields[$Matches[1]]=$Matches[2]
    }
    $keys=@('nonce','os','uid','arch','release','cpu','mem_kb','windows_mount','interop')
    if($fields.Count -ne $keys.Count -or @($keys|Where-Object{-not $fields.ContainsKey($_)}).Count){throw 'Unexpected inventory fields.'}
    if($fields.nonce -cne $Nonce -or $fields.os -cne 'Linux' -or $fields.uid -cne '0' -or $fields.arch -cne 'x86_64' -or $fields.release -cne '24.04'){throw 'Unexpected Linux identity/image.'}
    if($fields.cpu -cnotmatch '^[1-9][0-9]{0,3}$' -or $fields.mem_kb -cnotmatch '^[1-9][0-9]{0,11}$' -or $fields.windows_mount -cnotmatch '^[01]$' -or $fields.interop -cnotmatch '^[01]$'){throw 'Invalid Linux measurements.'}
    [ordered]@{Nonce=$Nonce;OS=$fields.os;Uid=0;Architecture=$fields.arch;Release=$fields.release;Cpu=[int]$fields.cpu;MemoryKB=[long]$fields.mem_kb;WindowsMountPresent=($fields.windows_mount -eq '1');InteropPresent=($fields.interop -eq '1');SshTested=$false;HerdrTested=$false}
}
