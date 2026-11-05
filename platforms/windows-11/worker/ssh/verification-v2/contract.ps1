function ConvertFrom-WorkerGuestV2([string]$Text) {
    if($Text.Length -gt 8192){throw 'Unexpected guest verification size.'}
    $fields=[ordered]@{}
    foreach($line in ($Text -split "`r?`n")){
        if(-not $line){continue}
        if($line -cnotmatch '^([a-z_]+)=([A-Za-z0-9_:/+.-]+)$' -or $fields.Contains($Matches[1])){throw 'Unexpected guest verification field.'}
        $fields[$Matches[1]]=$Matches[2]
    }
    $expected=@('action','address','port','linux_user','uid','host_fp','interop_config_disabled','binfmt_registration','standard_drive_mount_absent','service_active')
    if($fields.Count -ne $expected.Count -or @($expected|Where-Object{-not $fields.Contains($_)}).Count){throw 'Incomplete guest verification.'}
    $ip=$null
    if(-not [Net.IPAddress]::TryParse($fields.address,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $ip.ToString() -cne $fields.address){throw 'Invalid guest IPv4.'}
    if($fields.action -cne 'VerifyV2' -or $fields.port -cne '22224' -or $fields.linux_user -cne 'worker' -or $fields.uid -cnotmatch '^[1-9][0-9]{3,4}$' -or $fields.host_fp -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}$' -or $fields.interop_config_disabled -cne 'true' -or $fields.binfmt_registration -cnotin @('present','absent') -or $fields.standard_drive_mount_absent -cne 'true' -or $fields.service_active -cne 'true'){throw 'Guest configuration or service mismatch.'}
    $fields
}
function Assert-WorkerV2Report($Report,$Stage) {
    if($Report.VerificationOwner -cne 'pc-setup/windows-worker-ssh-verification/v2' -or $Report.InstanceId -cne $Stage.InstanceId -or $Report.Sid -cne $Stage.Sid -or $Report.Action -cne 'VerifyV2' -or $Report.Administrator -isnot [bool] -or $Report.Administrator -or $Report.CanaryPresent -isnot [bool] -or $Report.CanaryPresent -or $Report.DiagnosticPresent -isnot [bool] -or $Report.DiagnosticPresent -or $Report.DistroName -cne "pcw-$($Stage.InstanceId)" -or $Report.SetupManifestHash -cne $Stage.SetupManifestHash -or $Report.VerifierManifestHash -cne $Stage.ManifestHash -or $Report.SafetyScope -cne 'authenticated-single-controller-poc'){throw 'V2 report identity/source mismatch.'}
    $text=($Report.Guest.PSObject.Properties|ForEach-Object{"$($_.Name)=$($_.Value)"}) -join "`n"
    $guest=ConvertFrom-WorkerGuestV2 $text
    if($guest.host_fp -cne $Stage.HostFingerprint){throw 'Guest host identity changed.'}
}
