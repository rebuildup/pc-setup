function New-PocTaskXml([string]$Id,[string]$PowerShell,[string]$WorkerPath) {
    $uuid=[guid]::Empty
    if(-not [guid]::TryParseExact($Id,'D',[ref]$uuid) -or $uuid -eq [guid]::Empty -or $uuid.ToString('D') -cne $Id){throw 'Canonical task enrollment UUID required.'}
    foreach($path in @($PowerShell,$WorkerPath)){
        if($path -notmatch '^[A-Za-z]:[\\/]' -or $path.Substring(2).Contains(':') -or $path -match '["\r\n]' -or $path -match '(^|[\\/])\.\.?([\\/]|$)'){throw 'Task paths must be absolute local paths.'}
    }
    $exe=[Security.SecurityElement]::Escape($PowerShell)
    $args=[Security.SecurityElement]::Escape("-NoLogo -NoProfile -NonInteractive -File `"$WorkerPath`"")
    @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Author>pc-setup</Author><Description>pc-setup/ssh-poc-task/v1/$Id</Description></RegistrationInfo>
  <Triggers><BootTrigger><Enabled>true</Enabled></BootTrigger></Triggers>
  <Principals><Principal id="Owner"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><AllowHardTerminate>true</AllowHardTerminate><StartWhenAvailable>true</StartWhenAvailable><RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable><IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings><AllowStartOnDemand>true</AllowStartOnDemand><Enabled>true</Enabled><Hidden>false</Hidden><RunOnlyIfIdle>false</RunOnlyIfIdle><DisallowStartOnRemoteAppSession>false</DisallowStartOnRemoteAppSession><UseUnifiedSchedulingEngine>false</UseUnifiedSchedulingEngine><WakeToRun>false</WakeToRun><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Priority>7</Priority><RestartOnFailure><Interval>PT1M</Interval><Count>3</Count></RestartOnFailure></Settings>
  <Actions Context="Owner"><Exec><Command>$exe</Command><Arguments>$args</Arguments></Exec></Actions>
</Task>
"@
}
function Assert-PocTaskXml([string]$Actual,[string]$Expected) {
    $a=[xml]$Actual;$e=[xml]$Expected
    function Assert-TaskSettingsTree($ActualNode,$ExpectedNode) {
        if($ActualNode.ChildNodes.Count -ne $ExpectedNode.ChildNodes.Count){throw 'Unexpected task settings shape.'}
        foreach($node in $ExpectedNode.ChildNodes){
            $matches=@($ActualNode.ChildNodes | Where-Object LocalName -CEQ $node.LocalName)
            if($matches.Count -ne 1){throw 'Missing/duplicate task setting.'}
            if(@($node.ChildNodes | Where-Object NodeType -eq 'Element').Count){Assert-TaskSettingsTree $matches[0] $node}
            elseif($matches[0].InnerText -cne $node.InnerText){throw "Task setting drift: $($node.LocalName)"}
        }
    }
    Assert-TaskSettingsTree $a.Task.Settings $e.Task.Settings
    if(@($a.Task.Actions.ChildNodes).Count -ne 1 -or @($a.Task.Principals.ChildNodes).Count -ne 1 -or @($a.Task.Triggers.ChildNodes).Count -ne 1 -or $a.Task.Triggers.FirstChild.LocalName -cne 'BootTrigger'){throw 'Foreign task topology.'}
    foreach($node in $a.Task.Triggers.BootTrigger.ChildNodes){
        if($node.LocalName -eq 'Enabled'){continue}
        if($node.LocalName -eq 'Delay' -and $node.InnerText -ceq 'PT0S'){continue}
        throw 'Unapproved boot trigger timing/repetition policy.'
    }
    # Service-account logon is supplied as TASK_LOGON_SERVICE_ACCOUNT=5 to COM registration;
    # it is not a valid XML LogonType enumeration in the official task schema.
    if($a.SelectNodes('//*[local-name()="LogonType"]').Count){throw 'Task must not store a password or use interactive logon.'}
    foreach($path in @('RegistrationInfo/Author','RegistrationInfo/Description','Principals/Principal/UserId','Principals/Principal/RunLevel','Actions/Exec/Command','Actions/Exec/Arguments','Triggers/BootTrigger/Enabled','Settings/MultipleInstancesPolicy','Settings/DisallowStartIfOnBatteries','Settings/StopIfGoingOnBatteries','Settings/AllowHardTerminate','Settings/StartWhenAvailable','Settings/AllowStartOnDemand','Settings/Enabled','Settings/ExecutionTimeLimit','Settings/RestartOnFailure/Interval','Settings/RestartOnFailure/Count')){
        $selector='/*[local-name()="Task"]/' + (($path -split '/' | ForEach-Object {'*[local-name()="'+$_+'"]'}) -join '/')
        $actualNode=$a.SelectSingleNode($selector);$expectedNode=$e.SelectSingleNode($selector)
        if($null -eq $actualNode -or $actualNode.InnerText -cne $expectedNode.InnerText){throw "Task policy drift: $path"}
    }
}
function Assert-PocTaskAcl([string]$Sddl) {
    $sd=[Security.AccessControl.RawSecurityDescriptor]::new($Sddl)
    if($sd.Owner.Value -cne 'S-1-5-32-544' -or -not ($sd.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected) -or $sd.DiscretionaryAcl.Count -ne 2){throw 'Task security ownership drift.'}
    foreach($ace in $sd.DiscretionaryAcl){
        if($ace.AceType -ne [Security.AccessControl.AceType]::AccessAllowed -or $ace.AceFlags -ne [Security.AccessControl.AceFlags]::None -or $ace.SecurityIdentifier.Value -notin @('S-1-5-18','S-1-5-32-544') -or $ace.AccessMask -ne 0x1f01ff){throw 'Task security access drift.'}
    }
    foreach($sid in @('S-1-5-18','S-1-5-32-544')){
        if(@($sd.DiscretionaryAcl | Where-Object {$_.SecurityIdentifier.Value -ceq $sid}).Count -ne 1){throw 'Task ACL must contain SYSTEM and Administrators exactly once.'}
    }
}
function Assert-PocSshdSignature([string]$Status,[string]$Publisher) {
    if($Status -cne 'Valid' -or $Publisher -notmatch '(^|, )CN=Microsoft Windows(,|$)' -or $Publisher -notmatch '(^|, )O=Microsoft Corporation(,|$)'){throw 'Expected signed Microsoft Windows OpenSSH.'}
}
