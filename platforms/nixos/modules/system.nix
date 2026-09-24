{ ... }:

{
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];

    auto-optimise-store = true;
  };

  # mise and several agent/runtime installers distribute generic Linux
  # executables. Keep the canonical cross-platform mise inventory usable
  # after this system profile is applied without exporting LD_LIBRARY_PATH.
  programs.nix-ld.enable = true;
}
