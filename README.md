# pc-setup

普段使っているPC・OSごとの開発環境を、別マシンや新しいOS環境でも再現できるように保存するための repository です。

一般的な「おすすめツール集」ではなく、**実際に使っている環境の desired state と、その再現手順を管理する personal environment source of truth** として扱います。

## Platforms

| Platform | Status | Entry point |
| --- | --- | --- |
| Ubuntu on WSL2 | Active | [`platforms/ubuntu-wsl/README.md`](./platforms/ubuntu-wsl/README.md) |
| NixOS | Active | [`platforms/nixos/README.md`](./platforms/nixos/README.md) |
| Windows 11 | Not captured yet | future work |
| macOS | Not captured yet | future work |

現在の active platform は Ubuntu/WSL2 と NixOS です。

## Repository model

各 platform は原則として次の3層で管理します。

1. **Guide** — 人間が読んで理由・順序・手動作業まで理解できる手順
2. **Bootstrap** — 再実行可能な自動セットアップ
3. **Verify** — desired state を満たしているか確認する deterministic check

時点依存の実バージョンは desired state と分離し、必要な場合だけ [`snapshots/`](./snapshots/README.md) に保存します。

```text
.
├── platforms/
│   ├── ubuntu-wsl/
│   │   ├── README.md
│   │   ├── apt-packages.txt
│   │   ├── bootstrap.sh
│   │   └── verify.sh
│   └── nixos/
│       ├── README.md
│       ├── flake.nix
│       ├── modules/
│       └── verify.sh
├── config/
│   └── shell/
│       └── env.sh
├── docs/
│   └── adr/
├── snapshots/
├── scripts/
├── AGENTS.md
├── CLAUDE.md
└── CONTRIBUTING.md
```

## Ubuntu/WSL quick start

WSL2 上の Ubuntu で、この repository 自体も Linux filesystem 側に clone します。

```bash
mkdir -p ~/src
cd ~/src
git clone https://github.com/rebuildup/pc-setup.git
cd pc-setup

./platforms/ubuntu-wsl/bootstrap.sh
exec bash
./platforms/ubuntu-wsl/verify.sh
```

bootstrap は以下を整備します。

- base CLI / build toolchain
- GitHub CLI
- Rust / Cargo
- Bun
- Claude Code
- OpenCode
- Worktrunk
- ripgrep / fd / fzf / jq / bat 等のCLI
- `~/.local/bin`, Bun, Cargo を含む shell PATH
- `~/src` workspace

認証は意図的に自動化しません。インストール後に GitHub / Claude / OpenCode の各アカウントへ対話的にログインします。詳細は [`platforms/ubuntu-wsl/README.md`](./platforms/ubuntu-wsl/README.md) を参照してください。

## NixOS quick start

NixOS は imperative bootstrap ではなく、Flakes + Home Manager の reusable profile として管理します。

host-specific Flake から `pc-setup.lib.mkPcSetupHost` を呼び出し、hardware / boot / hostname / stateVersion 等だけ host 側で与えます。

詳細は [`platforms/nixos/README.md`](./platforms/nixos/README.md) を参照してください。

## Principles

- password、API key、token、cookie、private key 等は commit しない。
- WSL の開発 repository は原則 `/mnt/c` ではなく Linux filesystem (`~/src` 等) に置く。
- platform native の declarative package graph が使える場合はそれを優先し、そうでない場合は official installer / official package repository を優先する。
- 「latest stable を追うもの」と「version pin するもの」を区別する。
- setup 手順の変更理由が長期的に残る場合は ADR を追加する。
- automation が壊れても人間が README から復旧できる状態を維持する。
- bootstrap の成功だけで setup 完了とせず、verify の結果を確認する。

## Decisions

- [`ADR-0001`](./docs/adr/ADR-0001.md) — personal environment を platform guide + bootstrap + verify で管理する
- [`ADR-0002`](./docs/adr/ADR-0002.md) — Ubuntu/WSL2 の baseline toolchain と installation channel
- [`ADR-0003`](./docs/adr/ADR-0003.md) — NixOS の declarative stable-system / unstable-tooling profile

## Development

この repository 自体の変更は `project-init` の release-driven workflow に従います。詳細は [`CONTRIBUTING.md`](./CONTRIBUTING.md) と [`AGENTS.md`](./AGENTS.md) を参照してください。

Shell validation:

```bash
./scripts/ci.sh
```

NixOS profile evaluation:

```bash
nix flake check --no-build ./platforms/nixos
```
