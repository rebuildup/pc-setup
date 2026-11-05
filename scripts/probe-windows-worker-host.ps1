# No accounts/profiles/WSL are created. Child uses CURRENT token, not a worker token.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../platforms/windows-11/worker/runtime.ps1')
Assert-WorkerHost
$previous = [Environment]::GetEnvironmentVariable('PC_SETUP_CONTROLLER_CANARY')
$process = $null
try {
    $env:PC_SETUP_CONTROLLER_CANARY = [guid]::NewGuid().ToString()
    $windows = [Environment]::GetFolderPath('Windows')
    $exe = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'PowerShell/7/pwsh.exe'
    $info = New-CleanWorkerStartInfo $exe ([IO.Path]::GetTempPath()) $windows
    # pwsh prepends its own PSHOME at startup; allow that trusted machine path,
    # not any controller-user PATH entry.
    foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-Command', '@{ Sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value; CanaryPresent=(Test-Path Env:/PC_SETUP_CONTROLLER_CANARY); PathIsSystemOnly=($env:PATH -ieq ($PSHOME + ";" + (Join-Path $env:SystemRoot System32))) } | ConvertTo-Json -Compress')) { $info.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::Start($info)
    $process.StandardInput.Close()
    $out = $process.StandardOutput.ReadToEndAsync(); $err = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Self probe timed out.' }
    if ($process.ExitCode -ne 0 -or $err.GetAwaiter().GetResult()) { throw 'Self probe failed.' }
    $report = $out.GetAwaiter().GetResult() | ConvertFrom-Json
    if ($report.Sid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or $report.CanaryPresent -or -not $report.PathIsSystemOnly) { throw ("Clean self-process boundary failed: " + ($report | ConvertTo-Json -Compress)) }
    $exports = @{}
    foreach ($entry in @(@('advapi32.dll','CreateProcessWithLogonW'),@('userenv.dll','LoadUserProfileW'))) {
        $library = [Runtime.InteropServices.NativeLibrary]::Load($entry[0])
        try { $null = [Runtime.InteropServices.NativeLibrary]::GetExport($library,$entry[1]); $exports[$entry[1]] = $true } finally { [Runtime.InteropServices.NativeLibrary]::Free($library) }
    }
    @{ CurrentSid = $report.Sid; CleanEnvironmentSelfProbe = 'pass'; NativeExports = $exports; WorkerLogonTested = $false; ProfileCreationTested = $false; CrossUserDenialTested = $false } | ConvertTo-Json -Depth 3
} finally {
    [Environment]::SetEnvironmentVariable('PC_SETUP_CONTROLLER_CANARY',$previous)
    if ($process) { $process.Dispose() }
}
