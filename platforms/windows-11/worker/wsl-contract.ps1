# Pure WSL stage contract. No process, account or filesystem mutation.
function ConvertTo-WorkerWslComparablePath([string]$Path) {
    $value = $Path.Replace('/','\')
    if ($value.StartsWith('\\?\')) { $value = $value.Substring(4) }
    if ($value -notmatch '^[A-Za-z]:\\' -or $value.Substring(2).Contains(':') -or $value -match '(^|\\)\.\.?($|\\)') { throw 'Expected an absolute local Windows path without traversal.' }
    $value.TrimEnd('\').ToLowerInvariant()
}
function Assert-WorkerWslInventory([object[]]$Entries, $Plan, [string]$InstallLocation, [ValidateSet('Inventory','Import','Verify')][string]$Mode) {
    $null = New-WorkerPlan $Plan.InstanceId $Plan.MemoryGB $Plan.Processors
    $expected = ConvertTo-WorkerWslComparablePath $InstallLocation
    if (@($Entries).Count -gt 1) { throw 'Foreign or duplicate WSL registrations in this worker account.' }
    foreach ($entry in $Entries) {
        if ($entry.Name -cne $Plan.DistroName -or $entry.Version -ne 2 -or (ConvertTo-WorkerWslComparablePath $entry.BasePath) -cne $expected) { throw 'WSL registration ownership/location/version mismatch.' }
    }
    if ($Mode -eq 'Import' -and @($Entries).Count) { throw 'Import is one-shot: registration already exists. Use Verify; never adopt or retry.' }
    if ($Mode -eq 'Verify' -and @($Entries).Count -ne 1) { throw 'Owned WSL registration missing.' }
}
function Get-WorkerWslImportArguments($Plan, [string]$InstallLocation, [string]$ImagePath) {
    $null = New-WorkerPlan $Plan.InstanceId $Plan.MemoryGB $Plan.Processors
    $null = ConvertTo-WorkerWslComparablePath $InstallLocation
    $null = ConvertTo-WorkerWslComparablePath $ImagePath
    @('--import', $Plan.DistroName, $InstallLocation, $ImagePath, '--version', '2')
}
function Assert-WorkerWslAccessReport($Report) {
    foreach ($name in @('ProtectedFileReadable','ProtectedDirectoryReadable')) {
        if ($Report[$name] -isnot [bool] -or $Report[$name]) { throw "Worker access denial not proved: $name" }
    }
}
function Assert-WorkerWslProtectedPaths([string]$File, [string]$Directory) {
    foreach ($path in @($File,$Directory)) {
        # Preserve target identity across the controller and worker's different cwd.
        $null = ConvertTo-WorkerWslComparablePath $path
    }
}
