# Install the pinned rebuildup/herdr-plugins set used by herdr-t3
# (pc-setup#239, rebuildup/herdr-t3#358).
#
# The four plugins and their full commit SHAs mirror the contract pins in
# rebuildup/herdr-t3 `docs/migration/contracts/plugins-boundary.md`
# (inbox v0.1.0, git v0.2.0, projects v0.3.0, checkpoints v0.4.0). Each
# plugin installs independently through the official
# `herdr plugin install --ref <sha>` path; state lives under herdr's own
# plugin directories, so reinstalling never loses organize state.
#
# Idempotent: a plugin already installed at the pinned commit is skipped;
# a different commit is re-installed at the pin. `-Check` only reports.
#
# Prerequisites: `herdr` on PATH (herdr >= 0.9.0) and `bun` on PATH —
# plugin manifest commands run `bun run`. Note that non-login ssh
# sessions may not carry the user PATH; run this from an interactive
# shell (rebuildup/herdr-t3#339).
#
# Usage: plugin-set.ps1 [-Check]
param([switch]$Check)

$ErrorActionPreference = "Stop"

function Log($msg) { Write-Host "[herdr-t3 plugins] $msg" }
function Die($msg) { Write-Host "[herdr-t3 plugins] ERROR: $msg" -ForegroundColor Red; exit 1 }

if (-not (Get-Command herdr -ErrorAction SilentlyContinue)) { Die "herdr not found on PATH" }
if (-not (Get-Command bun -ErrorAction SilentlyContinue)) { Die "bun not found on PATH (plugin commands run 'bun run')" }

# name|full commit SHA — keep in sync with plugins-boundary.md.
$Plugins = @(
  @{ Name = "inbox";       Sha = "414e87dea9faa5c221fb27508e5828f086849836" },
  @{ Name = "git";         Sha = "d0578307a856e53af210775f9cb95c9f593d6f87" },
  @{ Name = "projects";    Sha = "2dcb2abfa57b0adcf5d1109f76087e19b3dfae07" },
  @{ Name = "checkpoints"; Sha = "ae4f214c523d05128354a8c4ba493b62cd8e843f" }
)

$listJson = herdr plugin list --json | Out-String
$plugins = ($listJson | ConvertFrom-Json).result.plugins

$rc = 0
foreach ($p in $Plugins) {
  $pluginId = "rebuildup.$($p.Name)"
  $entry = $plugins | Where-Object { $_.plugin_id -eq $pluginId } | Select-Object -First 1
  $have = $entry.source.resolved_commit
  if ($have -eq $p.Sha) {
    Log "$pluginId already at pin $($p.Sha.Substring(0,12))"
    continue
  }
  if ($Check) {
    if (-not $have) { Log "$pluginId MISSING (pin $($p.Sha.Substring(0,12)))" }
    else { Log "$pluginId at $($have.Substring(0,12)), pin is $($p.Sha.Substring(0,12))" }
    $rc = 1
    continue
  }
  Log "installing $pluginId @ $($p.Sha.Substring(0,12))"
  herdr plugin install "rebuildup/herdr-plugins/plugins/$($p.Name)" --ref $p.Sha -y
  if ($LASTEXITCODE -ne 0) { Log "ERROR: install failed for $pluginId"; $rc = 1 }
}

exit $rc
