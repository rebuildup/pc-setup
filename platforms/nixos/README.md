# NixOS setup

NixOS では Ubuntu/WSL のような imperative installer を canonical setup にしません。

`pc-setup` の NixOS profile を Flake input として読み込み、NixOS module + Home Manager module から開発環境を宣言的に構成します。

## Policy

- OS baseline: NixOS 26.05 stable
- Home Manager: `release-26.05`
- fast-moving development tools: `nixos-unstable`
- host hardware / boot / disk / hostname / passwords / secrets: host-specific configuration
- development environment: `pc-setup`
- credentials: Nix store の外
- exact input revisions: concrete host の `flake.lock`
- bootstrap中に実際に必要になった汎用CLI/エディタは、一時導入で終わらせず baseline 候補として profile に昇格する
- NixOSのsystem/build packageはNixをSoTにする
- portableなuser CLI baselineは他OSと同じ `mise.global.toml` を `mise install` で共有する

詳細な判断理由は [`ADR-0003`](../../docs/adr/ADR-0003.md) を参照してください。


## Quick start

fresh NixOS / NixOS-WSL では、まだ `nix-command` / `flakes` が有効でない場合を前提に、この command を入口にします:

```bash
nix --extra-experimental-features 'nix-command flakes' \
  run --no-write-lock-file 'github:rebuildup/pc-setup?dir=platforms/nixos'
```

`--extra-experimental-features` は feature list を1つの引数として受け取るため、`'nix-command flakes'` は引用符でまとめます。次の形は使用しません:

```bash
# NG: flakes が option の値ではなく別引数になる
nix run 'github:rebuildup/pc-setup?dir=platforms/nixos' \
  --extra-experimental-features nix-command flakes
```

remote bootstrap Flake 自体には `flake.lock` を置いていません。GitHub の remote flake は read-only なので、bootstrap 時は `--no-write-lock-file` で generated lock を永続化せずに評価します。exact input revision は actual host 側の concrete `flake.lock` が所有します。

開発中の branch を実機検証する場合、Nix の GitHub flake cache が mutable branch ref の古い snapshot を再利用することがあります。修正直後の検証では commit SHA を URL に固定するか `--refresh` を付けます。release 後の canonical main bootstrap では通常この注意は不要です。

pc-setup の system profile 適用後は `nix-command` / `flakes` が恒久的に有効になります。ただし `github:rebuildup/pc-setup?dir=platforms/nixos` を remote bootstrap として再実行する場合は `--no-write-lock-file` を引き続き付けます。

必要な bootstrap tools は Flake が解決します。その後 `mise.global.toml` のportable CLI baselineを適用します。

NixOSではgeneric Linux binaryをbare hostから直接実行できないため、このmise install phaseだけはFlakeが用意する一時FHS compatibility environment内で実行します。bootstrap中は `MISE_ALL_COMPILE=0`（Node/Pythonもcompile=false）として、miseのNixOS source-build fallbackではなくprebuilt artifactを使用します。これによりBun / rustup / Node等のinstaller child processも同じFHS environment内で動作します。

install 後は `user-baseline` package を persistent out-link `~/.local/state/pc-setup/nix-user-baseline` として構築します。この package は `claude` / `opencode` / `node` / `cargo` / `gcloud` 等の command wrapper を持ち、各 command を FHS environment 内の `mise -C "$PWD" exec` へ渡します。これにより system profile / nix-ld 適用前でも通常 shell からCLIを実行でき、project-local mise configも反映されます。

Bash は `~/.config/pc-setup/shell-init.bash` を source し、この wrapper baseline を PATH に追加します。bootstrap は parent shell の環境を変更できないため、wrapper 構築直後に必ず次の案内を表示します。verify が失敗してもこの案内は再表示されます。

```bash
source ~/.config/pc-setup/shell-init.bash
```

新しい shell を開く場合は手動 source は不要です。

system profile適用後は `programs.nix-ld.enable = true` も利用できます。NixOS全体へ `LD_LIBRARY_PATH` をexportする方式は採りません。

## What this profile installs

Nix/Home Manager system/build set:

- Git / Git LFS
- curl / wget / tree
- zip / unzip / xz / rsync
- GCC / Clang / LLDB / CMake / Ninja / Make / pkg-config
- mise

remote bootstrap の persistent `user-baseline` にも、通常 shell の verify に必要な Nix-native host/build tools を含めます。したがって Home Manager の system profile 適用前でも `git`, `git-lfs`, `wget`, `gcc`, `clang`, `lldb`, `cmake`, `ninja`, `make`, `pkg-config` が利用可能です。

verify は bootstrap app の一時 `runtimeInputs` PATH を継承せず、`user-baseline/bin:/run/current-system/sw/bin:$HOME/.local/bin` だけで通常 shell を再現します。これにより bootstrap 内だけ見える Git 等を誤って OK にしません。GitHub HTTPS credential helper が `gh auth git-credential` に接続されていることも確認します。

The bootstrap Flake additionally provides temporary GitHub CLI / Infisical / jq / Neovim before the global layer is active.

Portable user CLI baseline (`mise.global.toml`):

- Node.js / pnpm / Bun / Rust
- GitHub CLI
- Claude Code / Codex / OpenCode
- Worktrunk / Herdr
- Open Code Review / npkill / cargo-clean-all
- Google Cloud CLI / AWS CLI / Supabase CLI / Vercel CLI

Worktrunk の Bash integration も Home Manager で宣言します。

## Repository layout

```text
platforms/nixos/
├── README.md
├── flake.nix
├── modules/
│   ├── system.nix
│   └── home.nix
└── verify.sh
```

### `flake.nix`

reusable outputs:

- `overlays.default`
- `nixosModules.default`
- `homeManagerModules.default`
- `lib.mkPcSetupHost`
- `apps.<system>.default` / `apps.<system>.bootstrap`
- `devShells.<system>.default`
- `checks.<system>.bootstrap-shell`
- `checks.<system>.home-profile`
- `checks.<system>.nixos-profile`
- `packages.<system>.user-baseline`

### `modules/system.nix`

Nix-level system defaultsだけを所有します。

現在は:

- `nix-command`
- Flakes
- Nix store auto optimisation
- `nix-ld`（mise等が管理するgeneric Linux binaryのcompatibility boundary）

を有効にします。

### `modules/home.nix`

ユーザー単位の development toolchain と shell integration を所有します。

## Recommended host integration

actual NixOS host の config repository / `/etc/nixos` に Flake を作り、`pc-setup` の `platforms/nixos` subdirectory を input にします。Nix の flake reference は `dir` attribute で repository 内の subdirectory flake を指定できます。

例:

```nix
{
  description = "my NixOS host";

  inputs = {
    pc-setup.url = "github:rebuildup/pc-setup?dir=platforms/nixos";
  };

  outputs =
    { pc-setup, ... }:
    {
      nixosConfigurations.my-host = pc-setup.lib.mkPcSetupHost {
        system = "x86_64-linux";
        username = "YOUR_USER";

        # 初回インストール時の値を維持する。
        stateVersion = "26.05";
        homeStateVersion = "26.05";

        modules = [
          ./hardware-configuration.nix
          ./configuration.nix
        ];
      };
    };
}
```

`configuration.nix` には host固有情報だけを置きます。

例:

```nix
{ ... }:

{
  networking.hostName = "my-host";

  users.users.YOUR_USER.extraGroups = [
    "networkmanager"
    "wheel"
  ];

  networking.networkmanager.enable = true;

  # boot loader / desktop / GPU / locale 等も host 側で定義する。
}
```

`hardware-configuration.nix` は:

```bash
sudo nixos-generate-config
```

などで actual machine から生成し、別マシンの内容をコピーしません。

## First install

NixOS installation 自体は公式 Installation Guide に従います。

fresh system の canonical entrypoint は1コマンドです。初期 Nix feature state に依存しない形を canonical とします:

```bash
nix --extra-experimental-features 'nix-command flakes' \
  run --no-write-lock-file 'github:rebuildup/pc-setup?dir=platforms/nixos'
```

Flake app が必要なbootstrap toolsとFHS compatibility environmentを一時的に用意し、`~/src/pc-setup` のcheckoutを準備します。既存checkoutがある場合はoriginを検証し、`PC_SETUP_REF` をfetchしてtracking branchへ切り替え、fast-forward onlyで同期します。その後 `mise.global.toml` を適用し、`mise install` とdotfiles bootstrapをFHS environment内で実行します。最後に persistent CLI wrapper baseline を構築し、通常 shell 相当の PATH で `verify.sh` を通してから `pc-setup bootstrap complete` とします。

pc-setup の system profile 適用後は `nix-command` / `flakes` が有効になります。remote bootstrap 側は read-only GitHub flake なので、再実行時も `--no-write-lock-file` は維持します。

bootstrap後、host config で `pc-setup` を参照し:

```bash
sudo nixos-rebuild test --flake /etc/nixos#my-host
sudo nixos-rebuild switch --flake /etc/nixos#my-host
```

の順で反映します。

`test` は boot default を書き換えずに current system へ構成を適用できるため、`switch` 前の確認として使います。

手動でbootstrap environmentへ入りたい場合だけ:

```bash
nix develop 'github:rebuildup/pc-setup?dir=platforms/nixos'
```

を使います。これは通常のsetup手順ではなく、debug/fallback用です。

## Update

OS baseline / Home Manager / unstable tooling の exact revision は host側 `flake.lock` が固定します。

更新時:

```bash
cd /etc/nixos
nix flake update

sudo nixos-rebuild test --flake .#my-host
/path/to/pc-setup/platforms/nixos/verify.sh

sudo nixos-rebuild switch --flake .#my-host
```

差分確認前に blindly `switch` しないことを推奨します。

## Worktrunk

NixOSでは:

```bash
wt config shell install
```

を canonical setup として実行しません。

Home Manager が Bash に次を宣言します。

```bash
eval "$(wt config shell init bash)"
```

したがって Worktrunk update 後も shell wrapper は次の Home Manager generation で current package から生成されます。

確認:

```bash
type wt
wt --version
wt config show
```

## Authentication

package installation と authentication は分離します。

### GitHub

```bash
gh auth login
gh auth setup-git
gh auth status
```

### Claude Code

Claude Code 本体は `mise.global.toml` の portable CLI baseline から導入します。

provider 接続は machine provisioning ではなく `rebuildup/dotfiles` の Infisical runtime integration が所有します。MiMo 利用時は dotfiles の provider entrypoint 経由で起動します。

```bash
claude
# equivalent: ~/.dotfiles/script/agent/mimo claude
```

`~/.config/pc-setup/shell-init.bash` は `~/.dotfiles/script/agent` を PATH 先頭に置き、`mimo` entrypoint が存在する場合に `claude` を process-scoped injection へ委譲します。委譲は shell function と、agent 配下の `claude` PATH shim の両方で行うため、function 未定義のシェルでも素の Claude Code に落ちません。provider URL / model / credential は shell には export されません。

### OpenCode

```bash
opencode auth login
opencode auth list
```

API key / token / provider credential を `flake.nix`、Home Manager module、Nix store path に直接書きません。

## Git identity

Git identity は machine/user-specific state なのでこの reusable profile では固定しません。

必要なら host/user config 側で明示します。

```nix
programs.git = {
  enable = true;
  settings = {
    user.name = "YOUR_NAME";
    user.email = "YOUR_EMAIL";
  };
};
```

dotfiles を使用する環境では `~/.gitconfig` 自体が symlink-managed なので、`git config --global user.*` は使用しません。初回 identity/auth setup は:

```bash
~/.dotfiles/script/bootstrap
```

で行い、identity は `~/.gitconfig.local` に保持します。

## Verify

```bash
./platforms/nixos/verify.sh
```

verify は:

- NixOS であること
- Flakes capability
- baseline CLI
- JS/TS toolchain
- Rust toolchain
- Claude Code / OpenCode / Worktrunk
- GitHub auth
- Git identity

を確認します。

toolが無い場合は FAIL、対話認証や Git identity 未設定は WARN です。

## Evaluate the reusable profile

repository から:

```bash
nix flake check --no-build ./platforms/nixos
```

これにより NixOS module と Home Manager profile を両方評価します。

formatter:

```bash
nix fmt ./platforms/nixos
```

## Secrets

FlakeやNix expressionの内容は Nix store に入り得るため、secret を直接記述しません。

commitしないもの:

- API key / provider token
- `INFISICAL_TOKEN` / Infisical client secret
- GitHub token
- SSH private key
- browser cookie
- cloud credentials
- plaintext `.env`

portable secret の source of truth / runtime injection は `rebuildup/dotfiles` の Infisical policy が所有します。

この NixOS profile は runtime dependency として `infisical` CLI を `nixos-unstable` から導入します。Secret valuesやInfisical user/session credentialsは Nix expression / Nix store に入れません。

dotfiles bootstrap:

```bash
~/.dotfiles/script/bootstrap
~/.dotfiles/script/secrets-doctor
```

ローカル開発者はInfisical user loginを使用します。CI / agent / cloud workload は専用Machine Identityを使い、runtimeが対応する場合はOIDC / cloud-native identityなどの短期認証を優先します。

Infisical CLIはLinuxではOS Secret Serviceを利用し、利用できない環境ではCLI側のencrypted-file keyring fallbackを使用できます。そのlocal credential/cache stateもdotfilesやNix storeへ取り込みません。

## Project-specific dependencies

この profile は machine-wide の development baseline です。

各 project が要求する:

- PostgreSQL
- specific OpenSSL/native library
- framework-specific compiler
- pinned Node/Rust toolchain
- database/cache/runtime

などは project側の Flake / devShell / container / toolchain definition で管理します。

global profile に全projectの依存を集約しません。

## References

- NixOS Manual: https://nixos.org/manual/nixos/stable/
- Flakes: https://wiki.nixos.org/wiki/Flakes
- Home Manager: https://github.com/nix-community/home-manager
- Worktrunk shell integration: https://worktrunk.dev/shell-integration/


## NixOS on WSL

NixOS-WSL では通常の hardware configuration / boot loader を追加せず、NixOS-WSL module を host boundary として維持します。公式の flake 構成でも `nixos-wsl.nixosModules.default` と `wsl.enable = true` を組み合わせます。

既存の NixOS-WSL を pc-setup profile へ移行する前に、現在値を確認してください:

```bash
whoami
grep -n 'system.stateVersion\|wsl.defaultUser' /etc/nixos/configuration.nix
```

新しい host flake の基本形:

```nix
{
  inputs = {
    pc-setup.url = "github:rebuildup/pc-setup?dir=platforms/nixos";
    nixos-wsl.url = "github:nix-community/NixOS-WSL/release-26.05";
  };

  outputs = { pc-setup, nixos-wsl, ... }: {
    nixosConfigurations.nixos = pc-setup.lib.mkPcSetupHost {
      system = "x86_64-linux";
      username = "YOUR_CURRENT_WSL_USER";

      # Existing installation valueを維持する。新しいreleaseへ合わせて変更しない。
      stateVersion = "YOUR_EXISTING_STATE_VERSION";
      homeStateVersion = "YOUR_EXISTING_STATE_VERSION";

      modules = [
        nixos-wsl.nixosModules.default
        {
          wsl.enable = true;
          wsl.defaultUser = "YOUR_CURRENT_WSL_USER";
        }
      ];
    };
  };
}
```

NixOS-WSL の stable branch は NixOS release と揃えます。NixOS 26.05 profile では `release-26.05` を使用します。

初回は:

```bash
sudo nixos-rebuild test --flake /etc/nixos#nixos
./platforms/nixos/verify.sh
sudo nixos-rebuild switch --flake /etc/nixos#nixos
```

の順で適用します。

fresh NixOS-WSL でも package list は手入力しません。初回入口は同じです:

```bash
nix --extra-experimental-features 'nix-command flakes' \
  run --no-write-lock-file 'github:rebuildup/pc-setup?dir=platforms/nixos'
```

このFlake appがNix bootstrap toolchain、`mise.global.toml` portable CLI baseline、dotfiles bootstrapを順に担当します。OS/build依存はNixへ、cross-platformな常用CLIは `mise.global.toml` へ追加し、次回からこの1コマンドで自動的に利用可能にします。

恒久的な package install に `nix-env` は使いません。
