# Renders the machine-global mise config for native Windows.
#
# mise.global.toml is the machine-wide config on every OS, and this file has to
# stay free of anything only one OS can honour. One setting cannot carry an `os`
# condition because it is a `[settings]` key rather than a tool or package, so it
# is rewritten into the Windows copy of the config instead:
#
#   * `credential_command` is executed by mise's *default inline shell*, which
#     is `sh -o errexit -c` on Unix and `cmd /c` on Windows. mise performs no
#     expansion of the command string itself; it only exports
#     MISE_CREDENTIAL_HOST into the child environment and lets the shell do it.
#     cmd.exe expands %VAR% and not $VAR, so the shared `$MISE_CREDENTIAL_HOST`
#     form reaches gh as the literal text `$MISE_CREDENTIAL_HOST` and the token
#     lookup fails there. Rewriting it to the `%MISE_CREDENTIAL_HOST%` form is
#     the only difference the two platforms need.
#
# History: this renderer used to inject `disable_tools = ["rust"]` so Windows
# never let mise touch the (assumed) standalone rustup installation. That machine
# had no standalone rustup, so the guard only hid mise's own rustup + stable
# toolchain and made `cargo` unreachable. Rust is mise-managed on Windows too as
# of 2026-11-04; see platforms/windows-11/README.md.
#
# The functions here have no side effects and are dot-sourced by
# apply-global-mise.ps1 so that they can be exercised directly in CI.

Set-StrictMode -Version Latest

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

    $rendered = Set-WindowsCredentialCommand -Text $Text
    return Add-WindowsRustHomes -Text $rendered
}

# Windows keeps exactly one rustup home and one Cargo home, both owned by mise
# under %LOCALAPPDATA%\mise. `[env]` values cannot carry an `os` condition, and
# {{env.LOCALAPPDATA}} does not exist on Linux/macOS, so they are rendered here.
# `auto_install_disable_tools` keeps a shim from installing a toolchain by
# itself; install it explicitly with `mise install rust`.
function Add-WindowsRustHomes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [System.Collections.Generic.List[string]]($Text -split "`r?`n")

    $settingsAt = $lines.FindIndex({ param($l) $l -match '^\s*\[settings\]\s*$' })
    if ($settingsAt -ge 0 -and -not ($Text -match '(?m)^\s*auto_install_disable_tools\s*=')) {
        $lines.Insert($settingsAt + 1, 'auto_install_disable_tools = ["rust"]')
    }

    if (-not ($Text -match '(?m)^\s*\[env\]\s*$')) {
        while ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
        $lines.Add('')
        $lines.Add('[env]')
        foreach ($name in 'MISE_RUSTUP_HOME', 'RUSTUP_HOME') { $lines.Add("$name = '{{env.LOCALAPPDATA}}\mise\rustup'") }
        foreach ($name in 'MISE_CARGO_HOME', 'CARGO_HOME') { $lines.Add("$name = '{{env.LOCALAPPDATA}}\mise\cargo'") }
        $lines.Add('')
    }

    return ($lines -join $newline)
}