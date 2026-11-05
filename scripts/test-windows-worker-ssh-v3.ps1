$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=Join-Path $PSScriptRoot '../platforms/windows-11/worker/ssh/verification-v3'
. "$root/contract.ps1"
function Refuses([scriptblock]$Body){$denied=$false;try{& $Body|Out-Null}catch{$denied=$true};if(-not $denied){throw 'Expected refusal.'}}
$instance='2a1084ec-5389-4b0b-a0f0-9a38fcfaece5'
$fp='SHA256:FoPMohEbvfyo3e1b+Zjj8BO2stEFh7HfP38rLV37f6U'
$valid="action=VerifyV3`naddress=172.22.157.236`nport=22224`nlinux_user=worker`nuid=1000`nhost_fp=$fp`ninterop_config_disabled=true`nbinfmt_registration=present`nstandard_drive_mount_absent=true`nservice_active=true`n"
$guest=ConvertFrom-WorkerGuestV3 $valid
$null=ConvertFrom-WorkerGuestV3 ($valid.Replace('registration=present','registration=absent'))
foreach($bad in @($valid.Replace('config_disabled=true','config_disabled=false'),$valid.Replace('uid=1000','uid=0'),$valid.Replace('linux_user=worker','linux_user=root'),$valid.Replace('mount_absent=true','mount_absent=false'),$valid.Replace('service_active=true','service_active=false'),$valid.Replace('registration=present','registration=disabled'),$valid.Replace('172.22.157.236','172.999.1.1'),($valid+"action=VerifyV3`n"),($valid+"interop=false`n"))){Refuses {ConvertFrom-WorkerGuestV3 $bad}}
. (Join-Path $root '../../contract.ps1')
$savedCanary=[Environment]::GetEnvironmentVariable('PC_SETUP_CONTROLLER_CANARY')
try{
    $canary=[guid]::NewGuid().ToString('N');[Environment]::SetEnvironmentVariable('PC_SETUP_CONTROLLER_CANARY',$canary)
    $clean=New-CleanWorkerStartInfo (Join-Path $PSHOME 'pwsh') ([IO.Path]::GetTempPath()) ([IO.Path]::GetTempPath())
    if([Environment]::GetEnvironmentVariable('PC_SETUP_CONTROLLER_CANARY') -cne $canary -or $clean.Environment.ContainsKey('PC_SETUP_CONTROLLER_CANARY')){throw 'Parent canary leaked into child environment.'}
    Set-WorkerVerificationV3Environment $clean ([IO.Path]::GetTempPath())
    if($clean.Environment['ProgramData'] -cne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()) -or $clean.Environment.ContainsKey('PC_SETUP_CONTROLLER_CANARY')){throw 'Required common-data path or clean environment is missing.'}
    Refuses {Set-WorkerVerificationV3Environment $clean ''}
    Refuses {Set-WorkerVerificationV3Environment $clean 'relative-path'}
}finally{[Environment]::SetEnvironmentVariable('PC_SETUP_CONTROLLER_CANARY',$savedCanary)}
$stage=[pscustomobject]@{InstanceId=$instance;Sid='test-sid';SetupManifestHash='setup-hash';ManifestHash='verifier-hash';HostFingerprint=$fp}
$report=[pscustomobject]@{VerificationOwner='pc-setup/windows-worker-ssh-verification/v3';InstanceId=$instance;Sid='test-sid';Action='VerifyV3';Administrator=$false;CanaryPresent=$false;DiagnosticPresent=$false;DistroName="pcw-$instance";SetupManifestHash='setup-hash';VerifierManifestHash='verifier-hash';SafetyScope='authenticated-single-controller-poc';Guest=($guest|ConvertTo-Json|ConvertFrom-Json)}
Assert-WorkerV3Report $report $stage
& {
    . "$root/gateway.ps1"
    $stamp='2026-10-28T04:14:47.5247931Z'
    $json="{`"start`":`"$stamp`"}"|ConvertFrom-Json
    $actual=[datetime]::ParseExact($stamp,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    if(-not(Test-WorkerHoldStartTime $actual $stamp) -or -not(Test-WorkerHoldStartTime $actual $json.start)){throw 'Valid hold timestamp was rejected.'}
    if((Test-WorkerHoldStartTime $actual.AddTicks(1) $stamp) -or (Test-WorkerHoldStartTime $actual '2026-10-28T04:14:47') -or (Test-WorkerHoldStartTime $actual ([datetime]::SpecifyKind($actual,[DateTimeKind]::Unspecified))) -or (Test-WorkerHoldStartTime $actual $null)){throw 'Changed or ambiguous hold timestamp was accepted.'}
}
foreach($entry in @(@('Sid','foreign-sid'),@('InstanceId',[guid]::NewGuid().ToString()),@('VerifierManifestHash','stale'),@('SetupManifestHash','verifier-hash'),@('Action','Verify'),@('Administrator',$true),@('Administrator','false'),@('DiagnosticPresent',$true),@('SafetyScope','fully-isolated'))){$bad=$report|ConvertTo-Json -Depth 5|ConvertFrom-Json;$bad.($entry[0])=$entry[1];Refuses {Assert-WorkerV3Report $bad $stage}}
# Integration regression: changed guest or ineffective rules must prevent publication.
foreach($scenario in @('guest-changed','rule-ineffective','success')){
    & {
        . "$root/gateway.ps1"
        $fixture=Join-Path ([IO.Path]::GetTempPath()) ('pc-setup-gateway-v3-test-'+[guid]::NewGuid().ToString('N'))
        $verification=Join-Path $fixture 'verification';$gateway=Join-Path $fixture 'gateway'
        $null=New-Item -ItemType Directory -Path $verification -Force
        [IO.File]::WriteAllText("$verification/result-VerifyV3.json",($report|ConvertTo-Json -Depth 5))
        $effects=[Collections.Generic.List[string]]::new();$script:v3Calls=0
        $password=ConvertTo-SecureString 'fixture-only' -AsPlainText -Force
        function Assert-WorkerAdministrator {}
        function Read-WorkerVerificationV3 { $stage }
        function Get-WorkerVerificationV3Path { $verification }
        function Get-WorkerGatewayV3Path { $gateway }
        function Get-WorkerGatewayPath { Join-Path $fixture 'absent-v1' }
        function Get-WorkerGatewayLegacyV2Path { Join-Path $fixture 'absent-v2' }
        function Assert-WorkerGatewayV3Live { $effects.Add('live-checked') }
        function Invoke-WorkerVerificationV3 {
            $script:v3Calls++;$effects.Add('guest-verified')
            $value=$report|ConvertTo-Json -Depth 5|ConvertFrom-Json
            if($scenario -ceq 'guest-changed' -and $script:v3Calls -eq 2){$value.Guest.address='172.22.157.237'}
            $value
        }
        function Get-WorkerGatewayMappings { @() }
        function Get-NetTCPConnection { @() }
        function Get-NetFirewallRule { @() }
        function Assert-WorkerPlainPath {}
        function Set-WorkerResourceAcl {}
        function Write-WorkerNewFile($Path,$Text) { [IO.File]::WriteAllText($Path,$Text) }
        function New-NetFirewallRule { $effects.Add('rule-created') }
        function Assert-WorkerGatewayRule { $effects.Add('rule-checked');if($scenario -ceq 'rule-ineffective'){throw 'test-ineffective-rule'} }
        function Invoke-WorkerPortProxy { $effects.Add('published') }
        function Read-WorkerGatewayV3 { [pscustomobject]@{Status='verified-fixture'} }
        try{
            $failure=$null
            try{$null=Initialize-WorkerGatewayV3 $instance $password '100.118.123.62' '100.83.203.34'}catch{$failure=$_.Exception.Message}
            if($scenario -ceq 'success'){
                if($failure -or -not $effects.Contains('published') -or $script:v3Calls -ne 2 -or @($effects|Where-Object{$_ -ceq 'rule-checked'}).Count -ne 2 -or $effects.IndexOf('published') -lt $effects.LastIndexOf('rule-checked') -or -not(Test-Path "$gateway/manifest.json")){throw "Expected publication only after fresh guest and both rules: $failure"}
            }else{
                $expected=if($scenario -ceq 'guest-changed'){'Guest address changed before publication; preserve partial rules.'}else{'test-ineffective-rule'}
                if($failure -cne $expected -or $effects.Contains('published') -or -not(Test-Path "$gateway/pending.json")){throw "Failed safety regression: $scenario / $failure"}
            }
        }finally{
            $password.Dispose()
            $resolved=[IO.Path]::GetFullPath($fixture);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]'\/')
            if([IO.Path]::GetDirectoryName($resolved) -cne $parent -or [IO.Path]::GetFileName($resolved) -cnotmatch '^pc-setup-gateway-v3-test-[a-f0-9]{32}$' -or (Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unsafe fixture cleanup; preserve files.'}
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
Get-ChildItem "$root/*.ps1",$PSCommandPath|ForEach-Object{$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$null,[ref]$errors);if($errors){throw $errors}}
'Worker SSH verification v3: PASS'
