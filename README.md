# pc-setup

自分の開発マシンをOSごとに再現するための personal environment source of truth。

目的は「各OSのpackage managerを覚えること」ではなく、fresh machineから最短のentrypointで普段の開発環境を再現すること。

## Setup

### NixOS / NixOS-WSL

NixOSだけはmachine stateをNixで管理する。

fresh NixOS / NixOS-WSL では `nix-command` / `flakes` がまだ無効な場合があるため、初回 entrypoint は experimental features をその invocation だけ有効化して実行する。

```bash
nix --extra-experimental-features 'nix-command flakes' \
  run --no-write-lock-file 'github:rebuildup/pc-setup?dir=platforms/nixos'
```

`--extra-experimental-features` は feature list を1つの引数として受け取るため、`'nix-command flakes'` は引用符でまとめる。`--extra-experimental-features nix-command flakes` と書くと `flakes` が別引数として解釈され、Flakes は有効にならない。

remote bootstrap Flake 自体には `flake.lock` を置いていない。GitHub の remote flake は read-only なので、初回 bootstrap では `--no-write-lock-file` を付け、解決した input lock をその場限りで使用する。exact input revision は actual host 側の concrete `flake.lock` が所有する。

pc-setup の NixOS system profile 適用後は `nix-command` / `flakes` が恒久的に有効になる。ただし remote bootstrap を再実行する場合は `--no-write-lock-file` は引き続き必要。

Flake / Home Managerがsystem/build packageのcanonical sourceです。portableなユーザーCLIは他OSと同じ `mise.global.toml` を使いますが、NixOS bootstrapでは bare host の dynamic linker に依存しないよう、mise install を一時的な FHS compatibility environment 内で実行します。既存 `~/src/pc-setup` がある場合も `PC_SETUP_REF` へ fast-forward only で同期してから適用します。source compile のNixOS自動fallbackは使わず、bootstrap中だけ `MISE_ALL_COMPILE=0` としてprebuilt artifactを利用します。

NixOS bootstrap は install 済み CLI を bare PATH へ直接出さず、persistent FHS wrapper baseline を `~/.local/state/pc-setup/nix-user-baseline` に構築する。通常 shell の `claude` / `opencode` / `node` 等は、その wrapper から FHS 内の `mise exec` を呼ぶため、system profile 適用前でも generic Linux binary を実行できる。project-local mise config も同じ wrapper から解決する。

pc-setup のNixOS system profileは引き続き `programs.nix-ld.enable = true` を有効化する。global `LD_LIBRARY_PATH` は設定しない。

### Ubuntu / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/rebuildup/pc-setup/main/bootstrap.sh | bash
```

pipe経由で起動しても、controlling TTYがある場合は後段のGitHub / Infisical等のinteractive authenticationへ `/dev/tty` を引き継ぐ。headless環境ではTTYを捏造せずnon-interactiveのままfail-fastする。

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

Open Code Review は npm trust policy を迂回せず、公式 `alibaba/open-code-review` GitHub Release のplatform binaryをmiseから導入する。詳細は [ADR-0007](./docs/adr/ADR-0007.md) を参照。

`mise.global.toml` は `~/.config/mise/config.toml` として適用されます。project固有versionは各projectの `mise.toml` / Flake / toolchain file等が上書きします。

### Continuous update train

machine-global tool の rolling update は各マシンが独立に upstream を解決せず、pc-setup が一度だけ解決・検証して採用します。

```text
desired policy   mise.global.toml
        ↓ daily resolution
adopted state    mise.global.lock
        ↓ locked reconciliation
installed state  each machine
```

`latest` / `stable` は rolling policy のまま維持し、`node = "24"` のような bounded selector はその範囲内で最新へ追従します。GitHub Actions の continuous update train は毎日 `mise lock --global --bump` 相当を実行し、Linux x64 / Windows x64 / macOS x64 / macOS arm64 の adopted state を更新します。

差分がある場合だけ automation PR を作り、同じ head SHA に対する repository CI が成功した場合に限って merge commit で自動採用します。失敗時は `main` を進めず、PR を調査 evidence として残します。通常の source/policy 変更は引き続き release branch workflow を通します。

machine 側は committed lockfile が存在する場合、strict locked install で adopted state へ収束します。各 tool 自身の update notification は、pc-setup が update ownership を持ち、かつ vendor が公式の disable 手段を提供している場合だけ抑制します。

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
- [ADR-0007](./docs/adr/ADR-0007.md) — Open Code Review verified GitHub Release channel
- [ADR-0010](./docs/adr/ADR-0010.md) — machine-global tools continuous update train

## Development

このrepository自体の変更は `project-init` のrelease-driven workflowに従う。

```bash
./scripts/ci.sh
```
