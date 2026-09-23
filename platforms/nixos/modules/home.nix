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
    gcc
    clang
    lldb
    cmake
    ninja
    gnumake
    pkg-config

    unstable.mise
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
      if command -v mise >/dev/null 2>&1; then
        eval "$(mise activate bash)"
      fi

      if command -v wt >/dev/null 2>&1; then
        eval "$(wt config shell init bash)"
      fi
    '';
  };
}
