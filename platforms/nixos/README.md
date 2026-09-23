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
  run 'github:rebuildup/pc-setup?dir=platforms/nixos'
```

`--extra-experimental-features` は feature list を1つの引数として受け取るため、`'nix-command flakes'` は引用符でまとめます。次の形は使用しません:

```bash
# NG: flakes が option の値ではなく別引数になる
nix run 'github:rebuildup/pc-setup?dir=platforms/nixos' \
  --extra-experimental-features nix-command flakes
```

pc-setup の system profile 適用後は `nix-command` / `flakes` が恒久的に有効になるため、それ以降は短い通常 command:

```bash
nix run 'github:rebuildup/pc-setup?dir=platforms/nixos'
```

で実行できます。

必要な bootstrap tools は Flake が解決します。その後`mise.global.toml` のportable CLI baselineを `mise install` し、dotfiles bootstrapまで進みます。個別 package 名を覚えたり、`nix-shell -p ...` を組み立てたりしません。

## What this profile installs

Nix/Home Manager system/build set:

- Git / Git LFS
- curl / wget / tree
- zip / unzip / xz / rsync
- GCC / Clang / LLDB / CMake / Ninja / Make / pkg-config
- mise

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

### `modules/system.nix`

Nix-level system defaultsだけを所有します。

現在は:

- `nix-command`
- Flakes
- Nix store auto optimisation

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
  run 'github:rebuildup/pc-setup?dir=platforms/nixos'
```

Flake app が必要なbootstrap toolsを一時的に用意し、`~/src/pc-setup` のcheckoutを準備して`mise.global.toml` を `~/.config/mise/config.toml` へlinkして `mise install` を実行します。その後 `~/.dotfiles` をcloneし、`script/bootstrap` まで進みます。Git / GitHub CLI / Infisical / cloud CLI / agent CLI等のpackage listを手で覚える必要はありません。

pc-setup の system profile 適用後は `nix-command` / `flakes` が有効になるため、以後は `nix run ...` の短い形も使用できます。

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

```bash
claude
```

browser login 等の対話手順で認証します。

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
  run 'github:rebuildup/pc-setup?dir=platforms/nixos'
```

このFlake appがNix bootstrap toolchain、`mise.global.toml` portable CLI baseline、dotfiles bootstrapを順に担当します。OS/build依存はNixへ、cross-platformな常用CLIは `mise.global.toml` へ追加し、次回からこの1コマンドで自動的に利用可能にします。

恒久的な package install に `nix-env` は使いません。
