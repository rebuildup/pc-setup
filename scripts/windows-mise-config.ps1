# Renders the machine-global mise config for native Windows.
#
# mise.global.toml is the machine-wide config on every OS, and this file has to
# stay free of anything only one OS can honour. Two settings cannot carry an
# `os` condition because they are `[settings]` keys rather than tools or
# packages, so they are rewritten into the Windows copy of the config instead:
#
#   * `disable_tools` keeps mise from touching the rustup installation, which is
#     canonical on Windows.
#   * `credential_command` is executed by mise's *default inline shell*, which
#     is `sh -o errexit -c` on Unix and `cmd /c` on Windows. mise performs no
#     expansion of the command string itself; it only exports
#     MISE_CREDENTIAL_HOST into the child environment and lets the shell do it.
#     cmd.exe expands %VAR% and not $VAR, so the shared `$MISE_CREDENTIAL_HOST`
#     form reaches gh as the literal text `$MISE_CREDENTIAL_HOST` and the token
#     lookup fails there. Rewriting it to the `%MISE_CREDENTIAL_HOST%` form is
#     the only difference the two platforms need.
#
# The functions here have no side effects and are dot-sourced by
# apply-global-mise.ps1 so that they can be exercised directly in CI.

Set-StrictMode -Version Latest

function Add-WindowsRustGuard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    if ($Text -match '(?m)^\s*disable_tools\s*=') { return $Text }

    $guard = "# Windows: rustup is canonical; mise must never install or upgrade Rust.`ndisable_tools = [`"rust`"]`n"
    $anchor = [regex]::Match($Text, '(?m)^idiomatic_version_file_enable_tools\s*=.*\r?\n')
    if ($anchor.Success) {
        return $Text.Insert($anchor.Index + $anchor.Length, $guard)
    }
    $settings = [regex]::Match($Text, '(?m)^\[settings\].*\r?\n')
    if ($settings.Success) {
        return $Text.Insert($settings.Index + $settings.Length, $guard)
    }
    return $Text.TrimEnd() + "`n`n[settings]`n" + $guard
}

function Set-WindowsCredentialCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }

    # `%MISE_CREDENTIAL_HOST%` is the form cmd.exe expands. The outer quotes are
    # a TOML literal string, so the inner ones need no escaping.
    $windowsCredentialCommand = "credential_command = 'gh auth token --hostname `"%MISE_CREDENTIAL_HOST%`"'"

    $inGithubSettings = $false
    $rewritten = $false

    $lines = foreach ($line in ($Text -split "`r?`n")) {
        # A `[table]` header both opens and closes a section, so anything other
        # than `[settings.github]` must turn the rewrite off again.
        if ($line -match '^\s*\[') {
            $inGithubSettings = $line -match '^\s*\[\s*settings\.github\s*\]'
            $line
        }
        elseif ($inGithubSettings -and $line -match '^\s*credential_command\s*=') {
            $rewritten = $true
            $windowsCredentialCommand
        }
        else {
            $line
        }
    }

    # No credential_command in the source means no policy to apply here; the
    # renderer must not invent one.
    if (-not $rewritten) { return $Text }

    return ($lines -join $newline)
}

function ConvertTo-WindowsMiseConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    return Set-WindowsCredentialCommand (Add-WindowsRustGuard -Text $Text)
}