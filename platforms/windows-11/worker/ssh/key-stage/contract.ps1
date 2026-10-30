function New-WorkerKeySet([string]$InstanceId,[string[]]$Keys) {
    if($Keys.Count -lt 1 -or $Keys.Count -gt 32){throw 'Key set must contain 1 to 32 keys.'}
    $fingerprints=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($key in $Keys){
        $plan=New-WorkerSshPlan $InstanceId $key
        if(-not $fingerprints.Add($plan.ClientFingerprint)){throw 'Duplicate key identity.'}
    }
    $content=($Keys -join "`n")+"`n"
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($content))).ToLowerInvariant()
    [pscustomobject]@{InstanceId=$InstanceId;Keys=@($Keys);ContentSha256=$hash}
}
function Update-WorkerKeySet([string]$InstanceId,$Current,[ValidateSet('Add','Revoke')][string]$Action,[string]$Key) {
    if($Current.InstanceId -cne $InstanceId){throw 'Key set instance mismatch.'}
    $validated=New-WorkerKeySet $InstanceId @($Current.Keys)
    if($validated.ContentSha256 -cne $Current.ContentSha256){throw 'Key set drift.'}
    $fingerprint=(New-WorkerSshPlan $InstanceId $Key).ClientFingerprint
    $kept=[Collections.Generic.List[string]]::new();$found=$false
    foreach($existing in $validated.Keys){
        if((New-WorkerSshPlan $InstanceId $existing).ClientFingerprint -ceq $fingerprint){$found=$true;if($Action -eq 'Revoke'){continue}}
        $kept.Add($existing)
    }
    if($Action -eq 'Add'){if($found){throw 'Key identity already present.'};$kept.Add($Key)}
    elseif(-not $found){throw 'Key identity not present.'}
    New-WorkerKeySet $InstanceId $kept.ToArray()
}
function New-WorkerKeyTransition([string]$InstanceId,[string]$OperationId,$Current,[long]$ExpectedGeneration,[ValidateSet('Add','Revoke')][string]$Action,[string]$Key,[string]$PreviousProofSha256,[string]$HostFingerprint) {
    if($OperationId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or $PreviousProofSha256 -cnotmatch '^[0-9a-f]{64}$' -or $HostFingerprint -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}$'){throw 'Invalid transition identity or proof.'}
    $next=Update-WorkerKeyLedger $InstanceId $Current $ExpectedGeneration $Action $Key
    [pscustomobject]@{InstanceId=$InstanceId;OperationId=$OperationId;Action=$Action;KeyFingerprint=(New-WorkerSshPlan $InstanceId $Key).ClientFingerprint;BeforeSha256=$Current.Active.ContentSha256;AfterSha256=$next.Active.ContentSha256;BeforeRevokedSha256=$Current.RevokedSha256;AfterRevokedSha256=$next.RevokedSha256;Generation=$next.Generation;PreviousProofSha256=$PreviousProofSha256;HostFingerprint=$HostFingerprint;Keys=@($next.Active.Keys);Revoked=@($next.Revoked)}
}
function New-WorkerKeyLedger([string]$InstanceId,[long]$Generation,[string[]]$Active,[string[]]$Revoked) {
    if($Generation -lt 0 -or $Generation -eq [long]::MaxValue -or $Revoked.Count -gt 1024){throw 'Invalid key ledger generation or size.'}
    $activeSet=New-WorkerKeySet $InstanceId $Active
    $identities=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($key in $activeSet.Keys){$null=$identities.Add((New-WorkerSshPlan $InstanceId $key).ClientFingerprint)}
    foreach($key in $Revoked){if(-not $identities.Add((New-WorkerSshPlan $InstanceId $key).ClientFingerprint)){throw 'Active/revoked key collision.'}}
    $revokedText=if($Revoked.Count){($Revoked -join "`n")+"`n"}else{''}
    $revokedHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($revokedText))).ToLowerInvariant()
    [pscustomobject]@{InstanceId=$InstanceId;Generation=$Generation;Active=$activeSet;Revoked=@($Revoked);RevokedSha256=$revokedHash}
}
function Update-WorkerKeyLedger([string]$InstanceId,$Ledger,[long]$ExpectedGeneration,[ValidateSet('Add','Revoke')][string]$Action,[string]$Key) {
    if($Ledger.InstanceId -cne $InstanceId -or $Ledger.Generation -ne $ExpectedGeneration){throw 'Key ledger instance or generation changed.'}
    $current=New-WorkerKeyLedger $InstanceId $Ledger.Generation @($Ledger.Active.Keys) @($Ledger.Revoked)
    if($current.Active.ContentSha256 -cne $Ledger.Active.ContentSha256 -or $current.RevokedSha256 -cne $Ledger.RevokedSha256){throw 'Key ledger drift.'}
    $fingerprint=(New-WorkerSshPlan $InstanceId $Key).ClientFingerprint
    foreach($revokedKey in $current.Revoked){if((New-WorkerSshPlan $InstanceId $revokedKey).ClientFingerprint -ceq $fingerprint){throw 'Revoked key cannot be reused.'}}
    $next=Update-WorkerKeySet $InstanceId $current.Active $Action $Key
    $revoked=@($current.Revoked)
    if($Action -eq 'Revoke'){
        $removed=@($current.Active.Keys|Where-Object{(New-WorkerSshPlan $InstanceId $_).ClientFingerprint -ceq $fingerprint})
        $revoked+=@($removed)
    }
    New-WorkerKeyLedger $InstanceId ($ExpectedGeneration+1) @($next.Keys) $revoked
}
function ConvertFrom-WorkerGuestKeyStage([string]$Text,[string]$ExpectedHash) {
    if($Text.Length -gt 8192 -or $ExpectedHash -cnotmatch '^[0-9a-f]{64}$'){throw 'Invalid key-stage report or expected hash.'}
    $lines=@($Text -split "`r?`n" | Where-Object {$_})
    if(@($lines|Where-Object{$_ -ceq "authorization_hash=$ExpectedHash"}).Count -ne 1 -or @($lines|Where-Object{$_ -clike 'authorization_hash=*'}).Count -ne 1 -or @($lines|Where-Object{$_ -ceq 'action=VerifyKeyStage'}).Count -ne 1){throw 'Authorization evidence mismatch.'}
    $base=@($lines|Where-Object{$_ -cnotlike 'authorization_hash=*'}|ForEach-Object{if($_ -ceq 'action=VerifyKeyStage'){'action=VerifyV3'}else{$_}}) -join "`n"
    $guest=ConvertFrom-WorkerGuestV3 $base
    $guest.action='VerifyKeyStage';$guest['authorization_hash']=$ExpectedHash
    $guest
}
function Assert-WorkerKeyGatewayBinding([string]$InstanceId,$Gateway,$Guest,[string]$ExpectedHash) {
    if($Gateway.InstanceId -cne $InstanceId -or $Gateway.Port -ne 22224 -or $Guest.action -cne 'VerifyKeyStage' -or $Guest.authorization_hash -cne $ExpectedHash -or $Guest.address -cne $Gateway.GuestAddress -or $Guest.host_fp -cne $Gateway.HostFingerprint){throw 'Gateway and fresh key-stage guest evidence mismatch.'}
}
