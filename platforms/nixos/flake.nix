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

      mkMiseBootstrapFhs =
        pkgs:
        pkgs.buildFHSEnv {
          name = "pc-setup-mise-bootstrap-fhs";

          targetPkgs =
            fhsPkgs:
            (bootstrapPackages fhsPkgs)
            ++ (with fhsPkgs; [
              bashInteractive
              cacert
              coreutils
              curl
              file
              findutils
              gawk
              gcc
              git
              gnugrep
              gnumake
              gnused
              gzip
              openssl
              pkg-config
              python3
              stdenv.cc.cc.lib
              gnutar
              unzip
              which
              xz
              zlib
            ]);

          runScript = "bash";
        };

      miseWrappedCommands = [
        "node"
        "python"
        "python3"
        "bun"
        "pnpm"
        "rustc"
        "cargo"
        "rustfmt"
        "cargo-clippy"
        "rust-analyzer"
        "gh"
        "infisical"
        "claude"
        "codex"
        "opencode"
        "wt"
        "herdr"
        "gcloud"
        "aws"
        "supabase"
        "vercel"
        "npkill"
        "ocr"
        "cargo-clean-all"
        "rg"
        "fd"
        "fzf"
        "jq"
        "bat"
        "shellcheck"
        "nvim"
      ];

      mkMiseUserBaseline =
        pkgs:
        let
          miseFhs = mkMiseBootstrapFhs pkgs;
          mkWrapper =
            command:
            pkgs.writeShellScriptBin command ''
              exec "${miseFhs}/bin/pc-setup-mise-bootstrap-fhs" \
                -c "exec mise -C \"\$PWD\" exec -- ${command} \"\$@\"" \
                pc-setup-mise-wrapper "$@"
            '';
        in
        pkgs.symlinkJoin {
          name = "pc-setup-nixos-user-baseline";
          paths = [
            pkgs.pcSetupUnstable.mise
          ] ++ map mkWrapper miseWrappedCommands;
        };

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
          miseBootstrapFhs = mkMiseBootstrapFhs pkgs;
          app = pkgs.writeShellApplication {
            name = "pc-setup-bootstrap";
            runtimeInputs = bootstrapPackages pkgs;
            text = ''
              pc_setup_dir="''${PC_SETUP_DIR:-$HOME/src/pc-setup}"
              pc_setup_ref="''${PC_SETUP_REF:-main}"
              pc_setup_repo_url="''${PC_SETUP_REPO_URL:-https://github.com/rebuildup/pc-setup.git}"
              dotfiles_dir="''${DOTFILES_DIR:-$HOME/.dotfiles}"

              bash "${./sync-checkout.sh}" "$pc_setup_repo_url" "$pc_setup_ref" "$pc_setup_dir"

              printf 'installing portable global CLI baseline through mise (NixOS FHS compatibility)\n'
              MISE_ALL_COMPILE=0 \
                MISE_NODE_COMPILE=0 \
                MISE_PYTHON_COMPILE=0 \
                "${miseBootstrapFhs}/bin/pc-setup-mise-bootstrap-fhs" \
                "$pc_setup_dir/scripts/apply-global-mise.sh"

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

              DOTFILES_BOOTSTRAP="$dotfiles_dir/script/bootstrap" \
                MISE_ALL_COMPILE=0 \
                "${miseBootstrapFhs}/bin/pc-setup-mise-bootstrap-fhs" \
                -c "exec mise -C \"\$HOME\" exec -- \"\$DOTFILES_BOOTSTRAP\""

              user_baseline_link="$HOME/.local/state/pc-setup/nix-user-baseline"
              mkdir -p "$(dirname "$user_baseline_link")"

              printf 'building persistent NixOS CLI wrapper baseline\n'
              nix --extra-experimental-features 'nix-command flakes' \
                build --no-write-lock-file \
                --out-link "$user_baseline_link" \
                "$pc_setup_dir/platforms/nixos#user-baseline"

              bash "$pc_setup_dir/platforms/nixos/configure-shell.sh" "$user_baseline_link"

              printf 'verifying pc-setup NixOS baseline through persistent wrappers\n'
              PATH="$user_baseline_link/bin:$PATH" \
                "$pc_setup_dir/platforms/nixos/verify.sh"

              printf '\npc-setup bootstrap complete\n'
              printf 'open a new shell or run: source %s/.config/pc-setup/shell-init.bash\n' "$HOME"
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

      packages = forAllSystems (system: {
        mise-bootstrap-fhs = mkMiseBootstrapFhs (mkPkgs system);
        user-baseline = mkMiseUserBaseline (mkPkgs system);
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
          bootstrap-fhs = self.packages.${system}.mise-bootstrap-fhs;
          user-baseline = self.packages.${system}.user-baseline;
          home-profile = homeProfile.activationPackage;
          nixos-profile = nixosProfile.config.system.build.toplevel;
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
