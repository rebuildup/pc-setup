# pc-setup

自分の開発マシンをOSごとに再現するための personal environment source of truth。

目的は「各OSのpackage managerを覚えること」ではなく、fresh machineから最短のentrypointで普段の開発環境を再現すること。

## Setup

### NixOS / NixOS-WSL

NixOSだけはmachine stateをNixで管理する。

```bash
nix run 'github:rebuildup/pc-setup?dir=platforms/nixos'
```

Flake / Home Managerがcanonicalであり、machine package installationをmiseへ移さない。

### Ubuntu / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/rebuildup/pc-setup/main/bootstrap.sh | bash
```

### macOS

```bash
curl -fsSL https://raw.githubusercontent.com/rebuildup/pc-setup/main/bootstrap.sh | bash
```

fresh macOSでGitがまだ使えない場合はApple Command Line Toolsの導入が先に必要になる。bootstrapが検出して案内する。

### Windows 11

PowerShell:

```powershell
irm https://raw.githubusercontent.com/rebuildup/pc-setup/main/bootstrap.ps1 | iex
```

WinGet経由でGitとmiseを用意し、その後のdesired stateをmiseへ委譲する。

## Bootstrap model

NixOS以外はmiseを共通orchestratorとして使う。

```text
fresh machine
  -> minimal Git + mise
  -> mise bootstrap
     -> host packages / GUI apps
     -> ~/.dotfiles checkout
     -> portable dev tools
     -> dotfiles bootstrap/auth
     -> verify
```

root `mise.toml` が共通desired state。

### mise `[tools]`

OSに依存しにくい開発CLI/runtimeは一度だけ宣言する。

現在のbaseline:

- Node.js 24
- Python
- Bun
- Rust
- GitHub CLI
- Infisical CLI
- Claude Code
- Codex
- OpenCode
- Worktrunk
- ripgrep / fd / fzf / jq / bat
- ShellCheck
- Neovim

project固有versionは各projectの `mise.toml` / Flake / toolchain file等が所有する。ここはmachine-wide default。

### mise `[bootstrap.packages]`

OS固有package/applicationはnative package managerを使うが、人間が直接package一覧を実行しない。

- Ubuntu: APT
- macOS: mise built-in Homebrew formula/cask backend
- Windows: WinGet

HomebrewはmacOS setupのentrypointではなくbackendの1つ。

## dotfiles / secrets

miseは `rebuildup/dotfiles` を:

```text
~/.dotfiles
```

へcloneする。

Unixではportable tool installation後に:

```bash
~/.dotfiles/script/bootstrap
```

を実行し、以下を引き継ぐ。

- Git identity
- GitHub authentication
- Infisical authentication
- private agent-config submodules
- user-level symlink configuration

Secret valuesはpc-setupへ保存しない。portable secretのsource of truthはInfisical。

Windows nativeのdotfiles symlinkはcross-platform adapterが完成するまで自動適用しない。Windows machine setup自体はmiseで進め、user-level agent configは当面WSL側をcanonicalとする。

## Platform state

| Platform | Machine bootstrap | Status |
| --- | --- | --- |
| Ubuntu / WSL2 | mise + APT | Active |
| NixOS / NixOS-WSL | Flake + Home Manager | Active |
| Windows 11 | mise + WinGet | Active / native dotfiles linking pending |
| macOS | mise + Homebrew backend | Candidate until actual Mac reconciliation |

Platform固有のmanual boundary / verificationは各directoryに残す。

```text
platforms/
  ubuntu-wsl/
  nixos/
  windows-11/
plans/
  macos/
```

## Existing checkout

repositoryをすでにcloneしている場合はrootから:

Unix:

```bash
./bootstrap.sh
```

Windows:

```powershell
.\bootstrap.ps1
```

miseがcurrent checkoutの `mise.toml` を適用する。

## Verification

共通setup後もplatform固有verifyを実行する。

Ubuntu / WSL:

```bash
./platforms/ubuntu-wsl/verify.sh
```

NixOS:

```bash
./platforms/nixos/verify.sh
```

Windows:

```powershell
.\platforms\windows-11\verify.ps1
```

bootstrapが終了したことと、desired stateを満たしていることは別。verifyを通してsetup完了とする。

## Principles

- setup entrypointを短く保つ
- portable tool inventoryをOSごとに重複させない
- host package managerはmiseのbackendとして利用する
- NixOSではNixをmachine stateのSoTとして維持する
- credentials / token / private keyをrepositoryへ保存しない
- project-specific dependencyをmachine-wide baselineへ集約しない
- actual machineとの差異はverify/snapshotで検出する
- automationが壊れた場合でもREADME/ADRから復旧可能にする

## Decisions

- [ADR-0001](./docs/adr/ADR-0001.md) — personal environment source of truth
- [ADR-0002](./docs/adr/ADR-0002.md) — historical Ubuntu/WSL installation-channel decision
- [ADR-0006](./docs/adr/ADR-0006.md) — mise cross-platform bootstrap orchestrator

## Development

このrepository自体の変更は `project-init` のrelease-driven workflowに従う。

```bash
./scripts/ci.sh
```
