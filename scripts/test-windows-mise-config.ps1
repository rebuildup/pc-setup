Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. $PSScriptRoot/windows-mise-config.ps1

$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
$source = Join-Path $repo 'mise.global.toml'
$renderedPath = Join-Path ([System.IO.Path]::GetTempPath()) 'rendered-win-mise.toml'

$sourceText = [System.IO.File]::ReadAllText($source)
$out = ConvertTo-WindowsMiseConfig -Text $sourceText
[System.IO.File]::WriteAllText($renderedPath, $out, (New-Object System.Text.UTF8Encoding($false)))

Write-Host '--- rendered credential_command / guards ---'
($out -split "`n") | Where-Object { $_ -match '^(credential_command|disable_tools|auto_install_disable_tools|MISE_RUSTUP_HOME|MISE_CARGO_HOME)' }

# The rewrite has to replace the command, not the key that carries it: a bare
# `gh auth token ...` line is not TOML and mise would reject the whole config.
if ($out -notmatch "(?m)^credential_command = 'gh auth token --hostname `"%MISE_CREDENTIAL_HOST%`"'") {
    throw 'Windows credential_command line was not rendered in full'
}
Write-Host 'ok      Windows form uses %MISE_CREDENTIAL_HOST%'

# mise manages the Rust toolchain on Windows now, so the old guard that kept
# mise away from Rust must not come back: it would leave the machine with the
# legacy rustup home as the only working one.
if ($out -match '(?m)^\s*disable_tools\s*=') {
    throw 'rendered config disables the rust tool; mise has to manage Rust on Windows'
}
Write-Host 'ok      rust stays enabled'

# A shim-triggered Rust install is what broke the legacy rustup home before, so
# the Windows copy keeps Rust out of the automatic installs.
if ($out -notmatch '(?m)^auto_install_disable_tools = \["rust"\]\r?$') {
    throw 'rendered config does not exclude rust from automatic installs'
}
Write-Host 'ok      rust excluded from automatic installs'

# The Rust and Cargo homes decide where the toolchain lands. They have to be
# under the mise data dir so the machine keeps one rustup home and one Cargo
# home.
foreach ($homeLine in 'MISE_RUSTUP_HOME = "{{env.LOCALAPPDATA}}/mise/rustup"', 'MISE_CARGO_HOME = "{{env.LOCALAPPDATA}}/mise/cargo"') {
    if (-not $out.Contains($homeLine)) { throw "rendered config lost: $homeLine" }
}
Write-Host 'ok      Rust and Cargo homes point at the mise data dir'

# The shared file keeps the Unix form; a Windows-only string here would make the
# Unix machines fail instead. Match the assignment, not the prose around it.
# A Windows checkout keeps CRLF line endings, so the matched line carries a
# trailing carriage return that is not part of the assignment.
$sourceCommand = [regex]::Match($sourceText, '(?m)^credential_command\s*=.*$').Value.TrimEnd("`r")
if ($sourceCommand -ne 'credential_command = ''gh auth token --hostname "$MISE_CREDENTIAL_HOST"''') {
    throw "mise.global.toml must carry the portable `$.` form, got: $sourceCommand"
}
Write-Host 'ok      shared config keeps the portable $MISE_CREDENTIAL_HOST form'

# Re-rendering a rendered config must converge, or a second bootstrap run would
# keep rewriting the user's file.
if ((ConvertTo-WindowsMiseConfig -Text $out) -ne $out) {
    throw 'renderer is not idempotent'
}
Write-Host 'ok      idempotent'

# Every other section has to survive untouched. A renderer that drops or
# restructures a table header produces a config mise refuses to load.
foreach ($required in '[bootstrap.packages]', '"brew:docker-credential-helper"', 'windows-x64 = { asset_pattern = "herdr-windows-x86_64.zip" }') {
    if (-not $out.Contains($required)) { throw "rendered config lost: $required" }
}
Write-Host 'ok      unrelated sections preserved'

# Rust is managed on every OS now, so the shared entry must not be scoped away
# from Windows.
$sharedRust = [regex]::Match($sourceText, '(?m)^rust\s*=.*$').Value
if ($sharedRust -notmatch '"stable"') { throw "mise.global.toml must declare rust = stable, got: $sharedRust" }
if ($sharedRust -match 'os\s*=') { throw "the shared rust entry must not be scoped to other operating systems, got: $sharedRust" }
Write-Host 'ok      shared config manages Rust on every OS'

Write-Host "rendered $renderedPath"