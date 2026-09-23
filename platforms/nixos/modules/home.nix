{ pkgs, ... }:

let
  unstable = pkgs.pcSetupUnstable;
in
{
  home.packages = with pkgs; [
    gh

    curl
    wget
    jq
    ripgrep
    fd
    fzf
    bat
    tree
    unzip
    zip
    xz
    rsync
    shellcheck
    neovim

    python3

    gcc
    clang
    lldb
    cmake
    ninja
    gnumake
    pkg-config

    nodejs_24
    pnpm

    unstable.bun

    unstable.rustc
    unstable.cargo
    unstable.rustfmt
    unstable.clippy
    unstable.rust-analyzer

    unstable.infisical
    unstable.mise
    unstable.claude-code
    unstable.opencode
    unstable.worktrunk
  ];

  home.sessionPath = [
    "$HOME/.local/bin"
  ];

  programs.git = {
    enable = true;
    lfs.enable = true;
  };

  programs.bash = {
    enable = true;

    initExtra = ''
      if command -v wt >/dev/null 2>&1; then
        eval "$(wt config shell init bash)"
      fi
    '';
  };
}
