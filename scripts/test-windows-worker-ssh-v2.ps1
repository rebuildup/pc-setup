$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=Join-Path $PSScriptRoot '../platforms/windows-11/worker/ssh/verification-v2'
. "$root/contract.ps1"
function Refuses([scriptblock]$Body){$denied=$false;try{& $Body|Out-Null}catch{$denied=$true};if(-not $denied){throw 'Expected refusal.'}}
$instance='2a1084ec-5389-4b0b-a0f0-9a38fcfaece5'
$fp='SHA256:FoPMohEbvfyo3e1b+Zjj8BO2stEFh7HfP38rLV27f6U'
$valid="action=VerifyV2`naddress=172.22.157.236`nport=22224`nlinux_user=worker`nuid=1000`nhost_fp=$fp`ninterop_config_disabled=true`nbinfmt_registration=present`nwindows_drive_mount=false`nservice_active=true`n"
$guest=ConvertFrom-WorkerGuestV2 $valid
$null=ConvertFrom-WorkerGuestV2 ($valid.Replace('registration=present','registration=absent'))
foreach($bad in @($valid.Replace('config_disabled=true','config_disabled=false'),$valid.Replace('uid=1000','uid=0'),$valid.Replace('linux_user=worker','linux_user=root'),$valid.Replace('mount=false','mount=true'),$valid.Replace('service_active=true','service_active=false'),$valid.Replace('registration=present','registration=disabled'),$valid.Replace('172.22.157.236','172.999.1.1'),($valid+"action=VerifyV2`n"),($valid+"interop=false`n"))){Refuses {ConvertFrom-WorkerGuestV2 $bad}}
$stage=[pscustomobject]@{InstanceId=$instance;Sid='test-sid';SetupManifestHash='setup-hash';ManifestHash='verifier-hash';HostFingerprint=$fp}
$report=[pscustomobject]@{VerificationOwner='pc-setup/windows-worker-ssh-verification/v2';InstanceId=$instance;Sid='test-sid';Action='VerifyV2';Administrator=$false;CanaryPresent=$false;DiagnosticPresent=$false;DistroName="pcw-$instance";SetupManifestHash='setup-hash';VerifierManifestHash='verifier-hash';SafetyScope='authenticated-single-controller-poc';Guest=($guest|ConvertTo-Json|ConvertFrom-Json)}
Assert-WorkerV2Report $report $stage
foreach($entry in @(@('Sid','foreign-sid'),@('InstanceId',[guid]::NewGuid().ToString()),@('VerifierManifestHash','stale'),@('SetupManifestHash','verifier-hash'),@('Action','Verify'),@('Administrator',$true),@('Administrator','false'),@('DiagnosticPresent',$true),@('SafetyScope','fully-isolated'))){$bad=$report|ConvertTo-Json -Depth 5|ConvertFrom-Json;$bad.($entry[0])=$entry[1];Refuses {Assert-WorkerV2Report $bad $stage}}
# Integration regression: changed guest or ineffective rules must prevent publication.
foreach($scenario in @('guest-changed','rule-ineffective','success')){
    & {
        . "$root/gateway.ps1"
        $fixture=Join-Path ([IO.Path]::GetTempPath()) ('pc-setup-gateway-v2-test-'+[guid]::NewGuid().ToString('N'))
        $verification=Join-Path $fixture 'verification';$gateway=Join-Path $fixture 'gateway'
        $null=New-Item -ItemType Directory -Path $verification -Force
        [IO.File]::WriteAllText("$verification/result-VerifyV2.json",($report|ConvertTo-Json -Depth 5))
        $effects=[Collections.Generic.List[string]]::new();$script:v2Calls=0
        $password=ConvertTo-SecureString 'fixture-only' -AsPlainText -Force
        function Assert-WorkerAdministrator {}
        function Read-WorkerVerificationV2 { $stage }
        function Get-WorkerVerificationV2Path { $verification }
        function Get-WorkerGatewayV2Path { $gateway }
        function Get-WorkerGatewayPath { Join-Path $fixture 'absent-v1' }
        function Assert-WorkerGatewayV2Live { $effects.Add('live-checked') }
        function Invoke-WorkerVerificationV2 {
            $script:v2Calls++;$effects.Add('guest-verified')
            $value=$report|ConvertTo-Json -Depth 5|ConvertFrom-Json
            if($scenario -ceq 'guest-changed' -and $script:v2Calls -eq 2){$value.Guest.address='172.22.157.237'}
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
        function Read-WorkerGatewayV2 { [pscustomobject]@{Status='verified-fixture'} }
        try{
            $failure=$null
            try{$null=Initialize-WorkerGatewayV2 $instance $password '100.118.123.62' '100.83.203.34'}catch{$failure=$_.Exception.Message}
            if($scenario -ceq 'success'){
                if($failure -or -not $effects.Contains('published') -or $script:v2Calls -ne 2 -or @($effects|Where-Object{$_ -ceq 'rule-checked'}).Count -ne 2 -or $effects.IndexOf('published') -lt $effects.LastIndexOf('rule-checked') -or -not(Test-Path "$gateway/manifest.json")){throw "Expected publication only after fresh guest and both rules: $failure"}
            }else{
                $expected=if($scenario -ceq 'guest-changed'){'Guest address changed before publication; preserve partial rules.'}else{'test-ineffective-rule'}
                if($failure -cne $expected -or $effects.Contains('published') -or -not(Test-Path "$gateway/pending.json")){throw "Failed safety regression: $scenario / $failure"}
            }
        }finally{
            $password.Dispose()
            $resolved=[IO.Path]::GetFullPath($fixture);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]'\/')
            if([IO.Path]::GetDirectoryName($resolved) -cne $parent -or [IO.Path]::GetFileName($resolved) -cnotmatch '^pc-setup-gateway-v2-test-[a-f0-9]{32}$' -or (Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unsafe fixture cleanup; preserve files.'}
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
Get-ChildItem "$root/*.ps1",$PSCommandPath|ForEach-Object{$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$null,[ref]$errors);if($errors){throw $errors}}
'Worker SSH verification v2: PASS'
