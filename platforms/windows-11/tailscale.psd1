@{
    Infisical = @{
        SiteUrl = 'https://secrets.rebuildup.dev'
        ApiUrl = 'https://secrets.rebuildup.dev/api'
        ProjectId = 'd4c2fc09-a923-4a38-9cf4-b51769aadb76'
        Environment = 'prod'
        Path = '/infrastructure/tailscale'
        RequiredSecrets = @(
            'TAILSCALE_OAUTH_CLIENT_SECRET'
        )
    }

    Tailscale = @{
        AdvertiseTag = 'tag:personal-device'
        AuthKeyParameters = 'ephemeral=false&preauthorized=true'
        Serve = @(
            @{
                Label = 'Ubuntu SSH'
                ListenPort = 2222
                Target = 'tcp://127.0.0.1:2222'
            }
            @{
                Label = 'Ubuntu2 SSH'
                ListenPort = 2223
                Target = 'tcp://127.0.0.1:2223'
            }
        )
    }
}
