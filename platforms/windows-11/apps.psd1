# Canonical desktop app inventory.
#
# Id          exact WinGet package ID (required)
# Name        display name used in logs
# AppxName    optional regex: the same app already installed as an MSIX/Store package
# DisplayName optional regex: the same app already installed by a vendor installer
#
# AppxName/DisplayName let install-apps.ps1 and verify.ps1 adopt an existing
# install made through another channel instead of installing a second copy.
@{
    WingetApps = @(
        @{ Id = 'Vivaldi.Vivaldi'; Name = 'Vivaldi' }
        @{ Id = 'Discord.Discord'; Name = 'Discord' }
        @{ Id = 'Microsoft.PowerToys'; Name = 'PowerToys' }
        @{ Id = 'AntibodySoftware.WizTree'; Name = 'WizTree' }
        @{ Id = 'Google.JapaneseIME'; Name = 'Google Japanese Input' }
        @{ Id = 'Logitech.GHUB'; Name = 'Logitech G HUB'; DisplayName = '^Log(itech|icool) G HUB' }
        @{ Id = 'LinearOrbit.Linear'; Name = 'Linear' }
        @{ Id = 'SlackTechnologies.Slack'; Name = 'Slack'; AppxName = '^91750D7E\.Slack$'; DisplayName = '^Slack' }
        @{ Id = 'Microsoft.Teams'; Name = 'Microsoft Teams'; AppxName = '^MSTeams$' }
        @{ Id = 'Anysphere.Cursor'; Name = 'Cursor'; DisplayName = '^Cursor' }
        @{ Id = 'Microsoft.VisualStudioCode'; Name = 'Visual Studio Code' }
        @{ Id = 'Warp.Warp'; Name = 'Warp'; DisplayName = '^Warp' }
        @{ Id = 'Adobe.CreativeCloud'; Name = 'Adobe Creative Cloud' }
        @{ Id = 'jtroo.kanata_gui'; Name = 'kanata GUI' }
    )
}
