# Shared Start Menu shortcut management for the stable herdr-t3 app.
# Dot-source this file; it defines Set-/Test-HerdrT3Shortcut only.

$script:HerdrT3ShortcutPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\herdr-t3.lnk"

function Set-HerdrT3Shortcut {
    param([Parameter(Mandatory = $true)][string]$ExePath)
    if (-not (Test-Path -LiteralPath $ExePath)) { throw "shortcut target missing: $ExePath" }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($script:HerdrT3ShortcutPath)
    $shortcut.TargetPath = $ExePath
    $shortcut.WorkingDirectory = Split-Path -Parent $ExePath
    $shortcut.Description = "herdr-t3 — Herdr desktop client"
    $icon = Join-Path (Split-Path -Parent $ExePath) "herdr-t3.exe"
    if (Test-Path -LiteralPath $icon) { $shortcut.IconLocation = "$icon,0" }
    $shortcut.Save()
}

function Get-HerdrT3ShortcutTarget {
    if (-not (Test-Path -LiteralPath $script:HerdrT3ShortcutPath)) { return $null }
    $shell = New-Object -ComObject WScript.Shell
    return $shell.CreateShortcut($script:HerdrT3ShortcutPath).TargetPath
}
