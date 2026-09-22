# Ubuntu on WSL2 setup

WSL2上のUbuntu distributionを、新しい開発環境として立ち上げる手順です。

対象は「とりあえずCLIが動く状態」ではなく、普段の開発で使うGit/GitHub、Rust/C/C++、JS/TS、AI coding agent、worktree workflowまでを再現した状態です。

## 0. Scope and assumptions

- Windows側でWSL2とUbuntu distribution自体は作成済みとする。
- 以降のコマンドは **Ubuntu/WSL terminal内** で実行する。
- source repositoryは原則Linux filesystem側に置く。
- Windows側に同じCLIが入っていても、WSL側には別途install/authする。
- credentialはこのrepositoryへ保存しない。

Recommended workspace:

```text
/home/<user>/src
├── pc-setup/
├── project-init/
├── tastile-web/
└── ...
```

避ける:

```text
/mnt/c/Users/<user>/...
```

`/mnt/c` はWindowsとのファイル受け渡しには使えるが、Git、大量の`node_modules`、build/watch、worktreeを日常的に動かすworkspaceにはしない。

## 1. Clone pc-setup

fresh Ubuntuに最低限Gitだけ入れてcloneする。

```bash
sudo apt-get update
sudo apt-get install -y git ca-certificates curl

mkdir -p ~/src
cd ~/src
git clone https://github.com/rebuildup/pc-setup.git
cd pc-setup
```

## 2. Run bootstrap

Full setup:

```bash
./platforms/ubuntu-wsl/bootstrap.sh
```

Claude Code / OpenCodeを後回しにする場合:

```bash
./platforms/ubuntu-wsl/bootstrap.sh --skip-agents
```

bootstrapはOS全体の`apt upgrade`を行わない。環境構築のついでにdistribution全体を更新しないためである。

### What bootstrap installs

#### Ubuntu APT baseline

`apt-packages.txt`をsourceとして、以下のcategoryを導入する。

- transport/security: `ca-certificates`, `curl`, `wget`, `gnupg`
- Git: `git`, `git-lfs`
- native build: `build-essential`, `pkg-config`, `libssl-dev`, `cmake`, `ninja-build`, `clang`, `lldb`
- CLI: `jq`, `ripgrep`, `fd-find`, `fzf`, `bat`, `tree`
- archive/sync: `unzip`, `zip`, `xz-utils`, `rsync`
- shell quality: `shellcheck`
- Python utility runtime: `python3`, `python3-venv`
- SSH: `openssh-client`

Ubuntuではcommand nameが異なるため、bootstrapがuser-local symlinkを作る。

```text
~/.local/bin/fd  -> fdfind
~/.local/bin/bat -> batcat
```

#### Shell paths

repository-controlled [`config/shell/env.sh`](../../config/shell/env.sh) を:

```text
~/.config/pc-setup/env.sh
```

へcopyし、`.bashrc`から次のmanaged blockでsourceする。

```bash
# >>> pc-setup >>>
if [ -f "$HOME/.config/pc-setup/env.sh" ]; then
  . "$HOME/.config/pc-setup/env.sh"
fi
# <<< pc-setup <<<
```

このファイルで最低限次をPATHへ入れる。

```text
~/.local/bin
~/.bun/bin
~/.cargo/bin
```

既存`.bashrc`全体をrepository版で置換しない。

## 3. GitHub CLI

Ubuntu標準archive版ではなく、GitHub CLI公式APT repositoryを使う。

bootstrapがrepository登録と`gh` installationまで行う。

完了後、手動で認証する。

```bash
gh auth login
gh auth setup-git
gh auth status
```

WSL側の`gh`はWindows側の`gh`とは別machine identityとして扱う。

Official source:

- https://github.com/cli/cli/blob/trunk/docs/install_linux.md

## 4. Rust

Rustは`rustup` stableを使う。

bootstrapのcanonical flow:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --profile default --default-toolchain stable

source "$HOME/.cargo/env"
rustup toolchain install stable
rustup default stable
```

確認:

```bash
rustup show
rustc --version
cargo --version
```

Official source:

- https://rustup.rs/

## 5. Worktrunk

Rust/Cargo導入後、Worktrunkをinstallする。

```bash
cargo install worktrunk
wt config shell install
```

新しいshellを開いて確認:

```bash
wt --version
wt list
```

WorktrunkはWSL/Linux上のdefault worktree frontendとして使う。

代表操作:

```bash
wt switch <branch>
wt switch --create <branch>
wt switch pr:<number>
wt list --full
wt remove
```

注意:

- WorktrunkはGitHub delivery policyを置き換えない。
- worktree単体はsandbox/runtime isolationではない。
- project-specificな`.config/wt.toml`は各project側で管理する。

Official sources:

- https://worktrunk.dev/
- https://worktrunk.dev/shell-integration/

## 6. Bun

JS/TSの普段使いruntime/package toolingとしてBun stableをofficial installerから導入する。

```bash
curl -fsSL https://bun.sh/install | bash
```

確認:

```bash
bun --version
```

Official source:

- https://bun.sh/

## 7. Claude Code

macOS/Linux/WSL向けのnative installerを使う。

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

確認:

```bash
claude --version
```

初回認証:

```bash
claude
```

browser login等のinteractive authenticationはbootstrapに含めない。

npm global版はこのrepositoryのcanonical installation pathにしない。

Official source:

- https://github.com/anthropics/claude-code

## 8. OpenCode

stable installer:

```bash
curl -fsSL https://opencode.ai/install | bash
```

確認:

```bash
opencode --version
```

provider authentication:

```bash
opencode auth login
opencode auth list
```

TUIからは`/connect`でもproviderを追加できる。

credential storeはOpenCodeが管理する。credential valueを`pc-setup`へcopyしない。

WSL利用はOpenCode側も推奨している。

Official sources:

- https://opencode.ai/docs/
- https://opencode.ai/docs/windows-wsl/
- https://opencode.ai/docs/cli/
- https://opencode.ai/docs/providers/

## 9. Git identity

machine-specificなGit identityはrepositoryには固定しない。

新しいdistributionで未設定なら手動設定する。

```bash
git config --global user.name "<name>"
git config --global user.email "<email>"
```

確認:

```bash
git config --global --get user.name
git config --global --get user.email
```

## 10. Verify

shell integrationを反映するため新しいbashへ入り直す。

```bash
exec bash
```

その後:

```bash
cd ~/src/pc-setup
./platforms/ubuntu-wsl/verify.sh
```

`FAIL`はsetup incomplete。

`WARN`は主に対話操作が必要な項目で、例えばGitHub authやGit identityが該当する。

## 11. Capture a version snapshot

desired stateはstable channelを追うため、現在のversionを固定値としてREADMEへ大量に書かない。

必要なときだけ:

```bash
mkdir -p snapshots
./platforms/ubuntu-wsl/verify.sh --snapshot \
  > "snapshots/ubuntu-wsl-$(date +%F).txt"
```

snapshotはcredentialを含めず、command versionだけを記録する。

## 12. Updating an existing WSL distribution

日常更新は各official channelに従う。

```bash
sudo apt-get update
sudo apt-get upgrade

rustup update stable

cargo install worktrunk
```

Bun / Claude Code / OpenCodeのself-update behaviorやupgrade commandはupstreamで変わり得るため、更新手順を変更する場合はcurrent official docsを確認する。

bootstrapを再実行してmissing componentをrepairすることもできる。

```bash
./platforms/ubuntu-wsl/bootstrap.sh
./platforms/ubuntu-wsl/verify.sh
```

## Troubleshooting

### `fd: command not found`

Ubuntuのpackage binaryは`fdfind`。

bootstrapが次を作る。

```text
~/.local/bin/fd -> /usr/bin/fdfind
```

`~/.local/bin`がPATHにあるか確認する。

```bash
echo "$PATH"
ls -l ~/.local/bin/fd
```

### `bat: command not found`

Ubuntuでは`batcat`の場合がある。

```bash
ls -l ~/.local/bin/bat
batcat --version
```

### `wt switch`でdirectoryが変わらない

Worktrunk shell integrationを再実行する。

```bash
wt config shell install
exec bash
```

### installer後にcommandが見つからない

まずshellを再起動する。

```bash
exec bash
```

次を確認:

```bash
printf '%s\n' "$PATH" | tr ':' '\n'
```

最低限:

```text
~/.local/bin
~/.bun/bin
~/.cargo/bin
```

が含まれていること。

### repositoryが`/mnt/c`にある

cloneし直す。

```bash
mkdir -p ~/src
cd ~/src
git clone https://github.com/rebuildup/pc-setup.git
```

Windows側からLinux filesystemへアクセスするときはExplorerのWSL integration等を使い、workspaceそのものをWindows-mounted filesystemへ戻さない。
