# pc-setup

自分の開発マシンをOSごとに再現するための personal environment source of truth。

目的は「各OSのpackage managerを覚えること」ではなく、fresh machineから最短のentrypointで普段の開発環境を再現すること。

## Setup

> 0.1.0 is still in its release stack. Until it reaches `main`, setup commands intentionally pin branch `1` for the common mise bootstrap and branch `4` for NixOS. After release these references return to `main`.


### NixOS / NixOS-WSL

NixOSだけはmachine stateをNixで管理する。

```bash
nix run 'github:rebuildup/pc-setup/4?dir=platforms/nixos'
```

Flake / Home Managerがsystem/build packageのcanonical sourceです。portableなユーザーCLIは他OSと同じ `mise.global.toml` を使い、NixOS bootstrapでも同じglobal configを適用します。

### Ubuntu / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/rebuildup/pc-setup/1/bootstrap.sh | bash
```

### macOS

```bash
curl -fsSL https://raw.githubusercontent.com/rebuildup/pc-setup/1/bootstrap.sh | bash
```

fresh macOSでGitがまだ使えない場合はApple Command Line Toolsの導入が先に必要になる。bootstrapが検出して案内する。

### Windows 11

PowerShell:

```powershell
irm https://raw.githubusercontent.com/rebuildup/pc-setup/1/bootstrap.ps1 | iex
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

root `mise.toml` がmachine orchestration、`mise.global.toml` がportableなmachine-global CLI defaultsのSoTです。

### `mise.global.toml` `[tools]`

OSに依存しにくい開発CLI/runtimeは一度だけ宣言する。

現在のbaseline:

- Node.js 24 / pnpm / Bun
- Python / Rust
- GitHub CLI / Infisical CLI
- Claude Code / Codex / OpenCode
- Worktrunk / Herdr
- Open Code Review / npkill / cargo-clean-all
- Google Cloud CLI / AWS CLI
- Supabase CLI / Vercel CLI
- ripgrep / fd / fzf / jq / bat
- ShellCheck / Neovim

`mise.global.toml` は `~/.config/mise/config.toml` として適用されます。project固有versionは各projectの `mise.toml` / Flake / toolchain file等が上書きします。

### mise `[bootstrap.packages]`

OS固有package/applicationはnative package managerを使うが、人間が直接package一覧を実行しない。

- Ubuntu: APT
- macOS: mise built-in Homebrew formula/cask backend
- Windows: WinGet

Desktop applications that are genuinely machine-global are also part of the baseline. Windows currently includes VS Code, Linear, and Notion; macOS candidate state contains their Homebrew cask equivalents. WSL does not install duplicate Linux GUI copies.

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

root `mise.toml` がhost packages/reposを適用し、`scripts/apply-global-mise.*` が `mise.global.toml` をmachine-global configとして適用します。

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
