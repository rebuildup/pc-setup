{
  description = "pc-setup reusable NixOS development environment profile";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      nixpkgs-unstable,
      home-manager,
      ...
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      unstableOverlay = final: _prev: {
        pcSetupUnstable = import nixpkgs-unstable {
          system = final.stdenv.hostPlatform.system;
          config.allowUnfreePredicate =
            pkg:
            builtins.elem (final.lib.getName pkg) [
              "claude-code"
            ];
        };
      };

      mkPkgs =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ unstableOverlay ];
        };

      bootstrapPackages =
        pkgs:
        with pkgs; [
          git
          gh
          jq
          neovim
          pcSetupUnstable.infisical
          pcSetupUnstable.mise
        ];

      mkBootstrapShell =
        system:
        let
          pkgs = mkPkgs system;
        in
        pkgs.mkShell {
          packages = bootstrapPackages pkgs;

          shellHook = ''
            printf '%s\n' 'pc-setup bootstrap shell'
            printf '%s\n' 'tools are provided by this flake; no manual package list is needed'
          '';
        };

      mkBootstrapApp =
        system:
        let
          pkgs = mkPkgs system;
          app = pkgs.writeShellApplication {
            name = "pc-setup-bootstrap";
            runtimeInputs = bootstrapPackages pkgs;
            text = ''
              dotfiles_dir="''${DOTFILES_DIR:-$HOME/.dotfiles}"

              if [[ ! -e "$dotfiles_dir" ]]; then
                printf 'cloning dotfiles -> %s\n' "$dotfiles_dir"
                git clone https://github.com/rebuildup/dotfiles.git "$dotfiles_dir"
              elif [[ ! -d "$dotfiles_dir/.git" ]]; then
                printf 'refusing to overwrite non-git path: %s\n' "$dotfiles_dir" >&2
                exit 1
              else
                printf 'using existing dotfiles checkout: %s\n' "$dotfiles_dir"
              fi

              if [[ ! -x "$dotfiles_dir/script/bootstrap" ]]; then
                printf 'dotfiles bootstrap is unavailable in %s\n' "$dotfiles_dir" >&2
                printf 'update the checkout to a release containing script/bootstrap, then retry\n' >&2
                exit 1
              fi

              exec "$dotfiles_dir/script/bootstrap"
            '';
          };
        in
        {
          type = "app";
          program = "${app}/bin/pc-setup-bootstrap";
        };
    in
    {
      overlays.default = unstableOverlay;

      nixosModules.default = {
        imports = [ ./modules/system.nix ];
        nixpkgs.overlays = [ unstableOverlay ];
      };

      homeManagerModules.default = import ./modules/home.nix;

      lib.mkPcSetupHost =
        {
          system ? "x86_64-linux",
          username,
          stateVersion,
          homeStateVersion ? stateVersion,
          modules ? [ ],
        }:
        nixpkgs.lib.nixosSystem {
          inherit system;

          specialArgs = {
            inherit inputs username;
          };

          modules = [
            self.nixosModules.default
            home-manager.nixosModules.home-manager

            {
              users.users.${username}.isNormalUser = true;

              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;

              home-manager.users.${username} = {
                imports = [ self.homeManagerModules.default ];

                home.username = username;
                home.homeDirectory = "/home/${username}";
                home.stateVersion = homeStateVersion;
              };

              system.stateVersion = stateVersion;
            }
          ]
          ++ modules;
        };

      apps = forAllSystems (system: {
        default = mkBootstrapApp system;
        bootstrap = mkBootstrapApp system;
      });

      devShells = forAllSystems (system: {
        default = mkBootstrapShell system;
      });

      checks = forAllSystems (
        system:
        let
          pkgs = mkPkgs system;

          homeProfile = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;

            modules = [
              self.homeManagerModules.default
              {
                home.username = "pc-setup-check";
                home.homeDirectory = "/home/pc-setup-check";
                home.stateVersion = "26.05";
              }
            ];
          };

          nixosProfile = nixpkgs.lib.nixosSystem {
            inherit system;

            modules = [
              self.nixosModules.default
              {
                boot.isContainer = true;
                system.stateVersion = "26.05";
              }
            ];
          };
        in
        {
          bootstrap-shell = self.devShells.${system}.default;
          home-profile = homeProfile.activationPackage;
          nixos-profile = nixosProfile.config.system.build.toplevel;
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
