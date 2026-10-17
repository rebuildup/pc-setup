# Visual Studio capability check. Dot-source; defines functions only.
#
# pc-setup does not require a specific Visual Studio product or year (2022
# Community, 2026 Insiders, Build Tools, ...). It requires the capabilities the
# Windows toolchain needs: the MSVC x64/x86 tools and a Windows 10/11 SDK. The
# check is read-only; it never runs the Visual Studio installer and never
# changes workloads.

$script:RequiredVsComponents = @(
    @{ Label = 'MSVC x64/x86 build tools'; Pattern = '^Microsoft\.VisualStudio\.Component\.VC\.Tools\.x86\.x64$' }
    @{ Label = 'Windows SDK'; Pattern = '^Microsoft\.VisualStudio\.Component\.Windows1[01]SDK\.\d+$' }
)

# Reported as WARN only: which workloads matter depends on the active project.
$script:RecommendedVsWorkloads = @(
    'Microsoft.VisualStudio.Workload.NativeDesktop'
    'Microsoft.VisualStudio.Workload.ManagedDesktop'
)

function Get-VswherePath {
    $candidates = @()
    if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe' }
    if ($env:ProgramFiles) { $candidates += Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe' }
    return $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

# Returns one object per VS-family instance with the evaluated capabilities.
function Get-VisualStudioStatus {
    param([Parameter(Mandatory)][string]$VswherePath)

    $json = & $VswherePath -all -prerelease -products '*' -include packages -format json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return @() }

    foreach ($instance in @($json | ConvertFrom-Json)) {
        $ids = @($instance.packages | ForEach-Object { $_.id })
        [pscustomobject]@{
            Name      = $instance.displayName
            Version   = $instance.installationVersion
            Path      = $instance.installationPath
            Missing   = @($script:RequiredVsComponents | Where-Object { $p = $_.Pattern; -not ($ids | Where-Object { $_ -match $p }) } | ForEach-Object { $_.Label })
            Workloads = @($instance.packages | Where-Object { $_.type -eq 'Workload' } | ForEach-Object { $_.id })
            MissingRecommendedWorkloads = @($script:RecommendedVsWorkloads | Where-Object { $ids -notcontains $_ })
        }
    }
}
