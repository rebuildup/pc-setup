$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Join-Path $PSScriptRoot '../platforms/windows-11/worker'
. "$root/contract.ps1"
. "$root/ssh/contract.ps1"
. "$root/ssh/verification-v3/contract.ps1"
. "$root/ssh/key-stage/contract.ps1"
$id='2a1084ec-5389-4b0b-a0f0-9a38fcfaece5'
$mac='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABi+WLmtTWVkJ7Y1o67t1MrDFPuNajIscj0QhDv8KYL mac'
$win='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJfuiMIwEShhED1/ioijKeCqUwp1HIRmz25oQUzSt1ZA windows'
function Refuses([scriptblock]$Action) { $refused=$false; try { & $Action | Out-Null } catch { $refused=$true }; if(-not $refused){throw 'Expected refusal'} }
$initial=New-WorkerKeySet $id @($mac)
$added=Update-WorkerKeySet $id $initial 'Add' $win
if($added.Keys.Count -ne 2 -or $added.Keys[0] -cne $mac -or $added.Keys[1] -cne $win){throw 'Addition did not preserve baseline'}
if($initial.Keys.Count -ne 1 -or $initial.Keys[0] -cne $mac){throw 'Addition mutated input'}
$removed=Update-WorkerKeySet $id $added 'Revoke' $win
if($removed.Keys.Count -ne 1 -or $removed.Keys[0] -cne $mac){throw 'Revocation did not preserve other key'}
if((Update-WorkerKeySet $id $added 'Revoke' ($win.Replace(' windows',' renamed'))).ContentSha256 -cne $initial.ContentSha256){throw 'Revocation must identify key material, not comment'}
$expected=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$mac`n$win`n"))).ToLowerInvariant()
if($added.ContentSha256 -cne $expected){throw 'Key-set hash must represent exact LF-terminated file bytes'}
Refuses { Update-WorkerKeySet $id $added 'Add' ($win.Replace(' windows',' alternate')) }
Refuses { Update-WorkerKeySet $id $initial 'Revoke' $win }
Refuses { Update-WorkerKeySet $id $initial 'Revoke' $mac }
Refuses { New-WorkerKeySet $id @($mac,($mac.Replace(' mac',' other'))) }
Refuses { New-WorkerKeySet $id @($mac,('command="bad" '+$win)) }
$tampered=[pscustomobject]@{InstanceId=$id;Keys=@($mac,$win);ContentSha256=$initial.ContentSha256}
Refuses { Update-WorkerKeySet $id $tampered 'Revoke' $win }
Refuses { Update-WorkerKeySet 'ffffffff-ffff-ffff-ffff-ffffffffffff' $initial 'Add' $win }
$proof=('a' * 64);$hostPin='SHA256:FoPMohEbvfyo3e1b+Zjj8BO2stEFh7HfP38rLV27f6U'
$ledger=New-WorkerKeyLedger $id 0 @($mac) @()
$transition=New-WorkerKeyTransition $id '11111111-2222-4333-8444-555555555555' $ledger 0 'Add' $win $proof $hostPin
if($transition.BeforeSha256 -cne $initial.ContentSha256 -or $transition.AfterSha256 -cne $added.ContentSha256 -or $transition.PreviousProofSha256 -cne $proof -or $transition.HostFingerprint -cne $hostPin -or $transition.Generation -ne 1){throw 'Transition is not bound to before/after/proof/host/generation'}
Refuses { New-WorkerKeyTransition $id '11111111-2222-4333-8444-555555555555' $ledger 0 'Add' $win 'bad' $hostPin }
Refuses { New-WorkerKeyTransition $id '11111111-2222-4333-8444-555555555555' $ledger 0 'Add' $win $proof 'bad' }
$ledger1=Update-WorkerKeyLedger $id $ledger 0 'Add' $win
$ledger2=Update-WorkerKeyLedger $id $ledger1 1 'Revoke' $win
if($ledger2.Generation -ne 2 -or $ledger2.Active.Keys.Count -ne 1 -or $ledger2.Revoked.Count -ne 1){throw 'Incorrect revocation ledger'}
Refuses { Update-WorkerKeyLedger $id $ledger2 2 'Add' ($win.Replace(' windows',' renamed')) }
Refuses { Update-WorkerKeyLedger $id $ledger2 1 'Add' $win }
Refuses { New-WorkerKeyTransition $id '11111111-2222-4333-8444-555555555555' $ledger2 2 'Add' $win $proof $hostPin }
Refuses { New-WorkerKeyLedger $id 0 @($mac) @($mac) }
$report="action=VerifyKeyStage`nauthorization_hash=$($added.ContentSha256)`naddress=172.22.1.2`nport=22224`nlinux_user=worker`nuid=1000`nhost_fp=$hostPin`ninterop_config_disabled=true`nbinfmt_registration=present`nstandard_drive_mount_absent=true`nservice_active=true`n"
$parsed=ConvertFrom-WorkerGuestKeyStage $report $added.ContentSha256
if($parsed.authorization_hash -cne $added.ContentSha256 -or $parsed.action -cne 'VerifyKeyStage'){throw 'Incorrect key-stage verification result'}
Refuses { ConvertFrom-WorkerGuestKeyStage $report $initial.ContentSha256 }
Refuses { ConvertFrom-WorkerGuestKeyStage ($report+"authorization_hash=$($added.ContentSha256)`n") $added.ContentSha256 }
$gateway=[pscustomobject]@{InstanceId=$id;GuestAddress='172.22.1.2';HostFingerprint=$hostPin;Port=22224}
Assert-WorkerKeyGatewayBinding $id $gateway $parsed $added.ContentSha256
$gateway.GuestAddress='172.22.1.3'
Refuses { Assert-WorkerKeyGatewayBinding $id $gateway $parsed $added.ContentSha256 }
$gateway.GuestAddress='172.22.1.2';$gateway.HostFingerprint='SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
Refuses { Assert-WorkerKeyGatewayBinding $id $gateway $parsed $added.ContentSha256 }
Write-Output 'Worker SSH key set contracts: PASS'
