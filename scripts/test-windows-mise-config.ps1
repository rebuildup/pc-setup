Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. $PSScriptRoot/windows-mise-config.ps1

$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
$source = Join-Path $repo 'mise.global.toml'
$renderedPath = Join-Path ([System.IO.Path]::GetTempPath()) 'rendered-win-mise.toml'

$sourceText = [System.IO.File]::ReadAllText($source)
$out = ConvertTo-WindowsMiseConfig -Text $sourceText
[System.IO.File]::WriteAllText($renderedPath, $out, (New-Object System.Text.UTF8Encoding($false)))

Write-Host '--- rendered credential_command ---'
($out -split "`n") | Where-Object { $_ -match '^credential_command' }

# Rust is mise-managed on Windows too (see platforms/windows-11/README.md); the
# renderer must never re-inject the old guard that hid `cargo` from PATH.
if ($out -match '(?m)^\s*disable_tools\s*=') { throw 'rendered Windows config must not disable tools' }
Write-Host 'ok      no disable_tools guard rendered'
foreach ($line in 'auto_install_disable_tools = ["rust"]', "CARGO_HOME = '{{env.LOCALAPPDATA}}\mise\cargo'", "RUSTUP_HOME = '{{env.LOCALAPPDATA}}\mise\rustup'") {
    if (-not $out.Contains($line)) { throw "rendered Windows config is missing: $line" }
}
if ($sourceText -match '(?m)^\[env\]') { throw 'shared mise.global.toml must not carry Windows-only [env]' }
Write-Host 'ok      Windows rust homes rendered; shared source stays portable'

# The rewrite has to replace the command, not the key that carries it: a bare
# `gh auth token ...` line is not TOML and mise would reject the whole config.
if ($out -notmatch "(?m)^credential_command = 'gh auth token --hostname `"%MISE_CREDENTIAL_HOST%`"'") {
    throw 'Windows credential_command line was not rendered in full'
}
Write-Host 'ok      Windows form uses %MISE_CREDENTIAL_HOST%'

# The shared file keeps the Unix form; a Windows-only string here would make the
# Unix machines fail instead. Match the assignment, not the prose around it.
$sourceCommand = [regex]::Match($sourceText, '(?m)^credential_command\s*=.*$').Value
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

Write-Host "rendered $renderedPath"