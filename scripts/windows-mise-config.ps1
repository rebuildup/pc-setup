# Renders the machine-global mise config for native Windows.
#
# mise.global.toml is the machine-wide config on every OS, and this file has to
# stay free of anything only one OS can honour. Two settings cannot carry an
# `os` condition because they are `[settings]` keys rather than tools or
# packages, so they are rewritten into the Windows copy of the config instead:
#
#   * `auto_install_disable_tools` keeps a shim-triggered Rust install from
#     happening. The Rust toolchain is installed explicitly with
#     `mise install rust`, so the toolchain a directory resolves to only ever
#     changes on purpose.
#   * `credential_command` is executed by mise's *default inline shell*, which
#     is `sh -o errexit -c` on Unix and `cmd /c` on Windows. mise performs no
#     expansion of the command string itself; it only exports
#     MISE_CREDENTIAL_HOST into the child environment and lets the shell do it.
#     cmd.exe expands %VAR% and not $VAR, so the shared `$MISE_CREDENTIAL_HOST`
#     form reaches gh as the literal text `$MISE_CREDENTIAL_HOST` and the token
#     lookup fails there. Rewriting it to the `%MISE_CREDENTIAL_HOST%` form is
#     the only difference the two platforms need.
#
# The Windows copy also carries the Rust and Cargo homes in an `[env]` section.
# They are paths under the local app data dir, so only Windows can name them;
# the shared file keeps the default homes on Unix and macOS. Both the mise
# prefixed variables and the plain ones are set so the homes agree whether a
# process is started by mise or by hand.
#
# The functions here have no side effects and are dot-sourced by
# apply-global-mise.ps1 so that they can be exercised directly in CI.

Set-StrictMode -Version Latest

function Add-WindowsRustAutoInstallGuard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    if ($Text -match '(?m)^\s*auto_install_disable_tools\s*=') { return $Text }

    $guard = "# Windows: a shim must never install a Rust toolchain on its own;`n# install it explicitly with `mise install rust`.`nauto_install_disable_tools = [`"rust`"]`n"
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

function Add-WindowsRustHomes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    if ($Text -match '(?m)^\s*MISE_RUSTUP_HOME\s*=') { return $Text }

    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = @(
        '[env]',
        '# Windows: the Rust toolchain and the Cargo home live under the local app',
        '# data dir, so the machine has exactly one rustup home and one Cargo',
        '# home, both owned by mise. The legacy %USERPROFILE%\.rustup and',
        '# %USERPROFILE%\.cargo installations are retired with this.',
        # TOML literal strings keep the backslashes as written, so the value
        # is a native Windows path instead of a half-translated one.
        "MISE_RUSTUP_HOME = '{{env.LOCALAPPDATA}}\mise\rustup'",
        "MISE_CARGO_HOME = '{{env.LOCALAPPDATA}}\mise\cargo'",
        "RUSTUP_HOME = '{{env.LOCALAPPDATA}}\mise\rustup'",
        "CARGO_HOME = '{{env.LOCALAPPDATA}}\mise\cargo'",
        ''
    ) -join $newline

    return $Text.TrimEnd() + $newline + $newline + $lines
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

    return Add-WindowsRustHomes (Set-WindowsCredentialCommand (Add-WindowsRustAutoInstallGuard -Text $Text))
}