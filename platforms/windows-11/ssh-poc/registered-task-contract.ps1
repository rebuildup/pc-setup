# Task Scheduler's exported XML omits these documented schema defaults.
# Preserve all explicit values and unknown nodes for the strict verifier to reject.
function New-PocRegisteredTaskXml([string]$Id,[string]$PowerShell,[string]$WorkerPath) {
    (New-PocTaskXml $Id $PowerShell $WorkerPath).Replace('<UseUnifiedSchedulingEngine>false</UseUnifiedSchedulingEngine>','<UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>')
}
function Assert-PocRegisteredTaskXml([string]$Actual,[string]$Expected) {
    $doc=[xml]$Actual
    $defaults=[ordered]@{
        'Settings/AllowHardTerminate'='true'
        'Settings/RunOnlyIfNetworkAvailable'='false'
        'Settings/AllowStartOnDemand'='true'
        'Settings/Enabled'='true'
        'Settings/Hidden'='false'
        'Settings/RunOnlyIfIdle'='false'
        'Settings/DisallowStartOnRemoteAppSession'='false'
        'Settings/WakeToRun'='false'
        'Settings/Priority'='7'
        'Triggers/BootTrigger/Enabled'='true'
    }
    foreach($entry in $defaults.GetEnumerator()){
        $parts=$entry.Key -split '/'
        $parentPath='/*[local-name()="Task"]/'+(($parts[0..($parts.Count-2)]|ForEach-Object{'*[local-name()="'+$_+'"]'}) -join '/')
        $parents=@($doc.SelectNodes($parentPath))
        if($parents.Count -ne 1){throw 'Missing/duplicate task defaults parent.'}
        $matches=@($parents[0].ChildNodes|Where-Object LocalName -CEQ $parts[-1])
        if($matches.Count -gt 1){throw 'Duplicate task default.'}
        if($matches.Count -eq 0){
            $node=$doc.CreateElement($parts[-1],$doc.DocumentElement.NamespaceURI)
            $node.InnerText=$entry.Value
            $null=$parents[0].AppendChild($node)
        }
    }
    Assert-PocTaskXml $doc.OuterXml $Expected
}
function Assert-PocRegisteredTaskApiAcl([string]$Sddl) {
    # The API omits SE_DACL_PROTECTED even while the task file retains it.
    # Callers MUST independently Assert-PrivateAcl on the actual OS task file.
    # This conversion only checks the API's exact two explicit full-control ACEs.
    $sd=[Security.AccessControl.RawSecurityDescriptor]::new($Sddl)
    $sd.SetFlags($sd.ControlFlags -bor [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected)
    Assert-PocTaskAcl ($sd.GetSddlForm([Security.AccessControl.AccessControlSections]::All))
}
